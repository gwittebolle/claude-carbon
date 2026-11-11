#!/usr/bin/env bash
# generate-pr-report.sh — Post the development footprint of the current branch
# as a sticky PR comment: the local Claude Code sessions recorded for this
# project on this branch (git_branch column, captured by the Stop hook).
# Runs on the developer's machine, where carbon.db and the gh auth live; the
# CI runner never sees this data. Opt-in by nature: nothing is posted unless
# the developer runs it.
# Usage: generate-pr-report.sh [--dry-run] [--pr <number>] [--consent yes|never] [--auto]
#   --dry-run  print the comment body and post nothing (no gh needed, except with --pr,
#              whose branch is read through gh)
#   --pr N     report PR N: its own branch (read through gh), wherever the command runs
#              (default: the current branch and its open PR). A PR from a fork is refused.
#   --consent yes|never
#              this developer's answer for the current repository, when its shared settings
#              ask for the report on every PR (CLAUDE_CARBON_PR): kept on this machine in
#              pr-consent.tsv. After a `yes` the Stop hook posts the report when the answer
#              ends; `never` posts nothing. `yes` is only taken in a repository that asks,
#              once the question was put there.
#   --summary [--since YYYY-MM-DD]
#              read back the reports already posted on this repository's merged PRs
#              (through gh) and total them per month and per author. Printed here only:
#              nothing is posted, and carbon.db is not read.
#   --auto     the run the Stop hook starts by itself (pr-flush.sh): a PR whose branch
#              lives in a fork is refused, so nothing lands on another project unasked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FACTORS_FILE="$PROJECT_DIR/data/factors.json"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}")"
REPO_URL="https://github.com/gwittebolle/claude-carbon"
MARKER="<!-- claude-carbon-dev-report -->"

DRY_RUN=0
PR_GIVEN=0
PR_NUMBER=""
CONSENT=""
AUTO=0
SUMMARY=0
SINCE=""
USAGE_LINE="Usage: generate-pr-report.sh [--dry-run] [--pr <number>] [--consent yes|never] [--summary [--since YYYY-MM-DD]]"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --pr) PR_GIVEN=1; PR_NUMBER="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --auto) AUTO=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    --since) SINCE="${2:-}"; shift; [ $# -gt 0 ] && shift
      case "$SINCE" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "Error: --since takes a date as YYYY-MM-DD, not '${SINCE}'." >&2; exit 2 ;; esac ;;
    --consent) CONSENT="${2:-}"; shift; [ $# -gt 0 ] && shift
      case "$CONSENT" in yes|never) ;; *) echo "Error: --consent takes yes or never, not '${CONSENT}'." >&2; exit 2 ;; esac ;;
    *) echo "Unknown option: $1" >&2; echo "$USAGE_LINE" >&2; exit 2 ;;
  esac
done

# A number only: gh would also take a branch name or a URL, and read another PR than meant
if [ "$PR_GIVEN" = "1" ]; then
  case "$PR_NUMBER" in
    ''|*[!0-9]*) echo "Error: --pr takes a PR number, not '${PR_NUMBER}'." >&2; exit 2 ;;
  esac
fi

# ── The answer to a repository that asks for the report on every PR ─────────
if [ -n "$CONSENT" ]; then
  if ! CONSENT_TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Error: not inside a git repository." >&2
    exit 1
  fi
  CONSENT_DIR="$(cc_pr_data_dir "$CONSENT_TOP")"
  if [ -z "$CONSENT_DIR" ]; then
    echo "Error: the Claude config folder (CLAUDE_CONFIG_DIR) or the database (CLAUDE_CARBON_DB) is inside this repository or relative: an answer is not kept there. Nothing recorded." >&2
    exit 1
  fi
  CONSENT_KEY="$(cc_repo_key "$CONSENT_TOP")"
  if [ "$CONSENT" = "yes" ]; then
    # A yes only answers a question: this repository asks, and it was put to this developer
    if ! cc_pr_asked_for "$CONSENT_TOP"; then
      echo "Error: this repository does not ask for the report on its pull requests (no CLAUDE_CARBON_PR in its .claude/settings.json); nothing recorded. Run /carbon-pr to post one yourself." >&2
      exit 1
    fi
    if [ -z "$(cc_pr_consent_get "$CONSENT_DIR" "$CONSENT_KEY")" ]; then
      echo "Error: no question was asked for this repository yet (it comes with your first 'gh pr create' in Claude Code here); nothing recorded. Run /carbon-pr to post one yourself." >&2
      exit 1
    fi
  fi
  if ! cc_pr_consent_set "$CONSENT_DIR" "$CONSENT_KEY" "$CONSENT"; then
    echo "Error: could not write ${CONSENT_DIR}/pr-consent.tsv." >&2
    exit 1
  fi
  if [ "$CONSENT" = "never" ]; then
    echo "Noted: no carbon report is posted by itself on this repository's pull requests from this machine. /carbon-pr still posts one when you run it."
    exit 0
  fi
  # The answer comes in the middle of a turn, before its tokens are recorded: the report
  # is left for the Stop hook, as after a push (pr-flush.sh), instead of posting a figure
  # that lacks this turn, or none at all on a branch whose first session is this one.
  CONSENT_BRANCH="$(cc_git_branch "$CONSENT_TOP")"
  if [ -n "$CONSENT_BRANCH" ]; then
    CONSENT_PENDING="$(cc_pr_pending "$CONSENT_DIR" "$CONSENT_TOP" "$CONSENT_BRANCH")"
    mkdir -p "$(dirname "$CONSENT_PENDING")" 2>/dev/null \
      && printf '%s\n%s\n' "$CONSENT_TOP" "$CONSENT_BRANCH" >"$CONSENT_PENDING" 2>/dev/null || true
  fi
  echo "Noted: the carbon report is posted on this branch's pull request when this answer ends, then updated when you push, on your pull requests of this repository. Change your mind with --consent never."
  exit 0
fi

# ── The reports already posted on the repository's merged PRs, totalled ─────
# Each comment's own first table row is read back: "| **575 g** | $17.26 | … | 1 |". A
# comment in the older one-line form, or edited by hand, is counted as unread.
if [ "$SUMMARY" = "1" ]; then
  for cmd in gh jq awk git; do
    command -v "$cmd" &>/dev/null || { echo "Error: $cmd is required for --summary." >&2; exit 1; }
  done
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Error: not inside a git repository." >&2
    exit 1
  fi
  TAB="$(printf '\t')"
  # shellcheck source=scripts/format-lib.sh
  . "$SCRIPT_DIR/format-lib.sh"
  SUM_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  if [ -z "$SUM_REPO" ]; then
    echo "Error: gh could not name this repository (is it on GitHub, and are you logged in?)." >&2
    exit 1
  fi
  SUM_QUERY="repo:${SUM_REPO} is:pr is:merged in:comments \"claude-carbon-dev-report\""
  [ -n "$SINCE" ] && SUM_QUERY="${SUM_QUERY} merged:>=${SINCE}"
  if ! SUM_FOUND="$(gh api -X GET search/issues -f q="$SUM_QUERY" -f per_page=100 \
      --jq '(.total_count | tostring), (.items[] | "\(.number)\t\(.pull_request.merged_at // .closed_at // "")")' 2>/dev/null)"; then
    echo "Error: the search for merged PRs failed (gh api search/issues)." >&2
    exit 1
  fi
  SUM_TOTAL="$(printf '%s\n' "$SUM_FOUND" | head -1)"
  SUM_ROWS=""
  SUM_UNREAD=0
  while IFS="$TAB" read -r SUM_PR SUM_MERGED; do
    case "$SUM_PR" in ''|*[!0-9]*) continue ;; esac
    SUM_LINE="$(gh api "repos/${SUM_REPO}/issues/${SUM_PR}/comments?per_page=100" \
      --jq '[.[] | select(.body | contains("claude-carbon-dev-report"))][0] | select(. != null) | .user.login + "\t" + ((.body | split("\n") | map(select(startswith("| **"))))[0] // "")' 2>/dev/null || true)"
    SUM_AUTHOR="${SUM_LINE%%"$TAB"*}"
    SUM_CELLS="${SUM_LINE#*"$TAB"}"
    # grams, dollars, sessions out of "| **575 g** | $17.26 | 1.6M | 90.9M | 1 |"
    SUM_PARSED="$(printf '%s\n' "$SUM_CELLS" | LC_ALL=C awk -F '|' '
      { co2 = $2; gsub(/[* ]/, "", co2); cost = $3; gsub(/[$ ]/, "", cost); n = $6; gsub(/ /, "", n)
        g = -1
        if (co2 ~ /^[0-9.]+kg$/) { sub(/kg$/, "", co2); g = co2 * 1000 }
        else if (co2 ~ /^[0-9.]+g$/) { sub(/g$/, "", co2); g = co2 + 0 }
        else if (co2 ~ /^[0-9.]+t$/) { sub(/t$/, "", co2); g = co2 * 1000000 }
        if (g >= 0 && cost ~ /^[0-9.]+$/ && n ~ /^[0-9]+$/) printf "%.0f\t%.2f\t%d", g, cost, n }')"
    # A login is letters, digits and hyphens: anything else is not printed
    case "$SUM_AUTHOR" in ''|*[!A-Za-z0-9-]*) SUM_AUTHOR="" ;; esac
    if [ -z "$SUM_AUTHOR" ] || [ -z "$SUM_PARSED" ]; then
      SUM_UNREAD=$((SUM_UNREAD + 1))
      continue
    fi
    SUM_ROWS="${SUM_ROWS}${SUM_MERGED%%T*}${TAB}${SUM_AUTHOR}${TAB}${SUM_PARSED}
"
  done <<SUMMARY_LIST
$(printf '%s\n' "$SUM_FOUND" | tail -n +2)
SUMMARY_LIST

  if [ -z "$SUM_ROWS" ]; then
    echo "No carbon report found on the merged pull requests of ${SUM_REPO}${SINCE:+ since ${SINCE}}."
    [ "$SUM_UNREAD" -gt 0 ] && echo "${SUM_UNREAD} comment(s) could not be read (an older format, or edited)."
    exit 0
  fi
  echo "Carbon reports on the merged pull requests of ${SUM_REPO}${SINCE:+ since ${SINCE}}"
  echo "Each figure is what its author posted: their local Claude Code sessions on the PR's branch."
  echo ""
  sum_table() { # $1 = what to group by (1 the month merged, 2 the author), $2 = heading
    printf '%-22s %5s %9s %10s %10s\n' "$2" "PRs" "Sessions" "CO2e" "Cost"
    printf '%s' "$SUM_ROWS" | LC_ALL=C awk -F '\t' -v f="$1" '
      { k = (f == 1) ? substr($1, 1, 7) : $2; prs[k]++; g[k] += $3; c[k] += $4; s[k] += $5 }
      END { for (k in prs) printf "%s\t%d\t%d\t%.0f\t%.2f\n", k, prs[k], s[k], g[k], c[k] }' \
      | LC_ALL=C sort | while IFS="$TAB" read -r K P S G C; do
        printf '%-22s %5s %9s %10s %10s\n' "$K" "$P" "$S" "$(format_co2 "$G")" "\$${C}"
      done
  }
  sum_table 1 "Month merged"
  echo ""
  sum_table 2 "Author"
  echo ""
  printf '%s' "$SUM_ROWS" | LC_ALL=C awk -F '\t' '{ g += $3; c += $4; s += $5 } END { printf "%d\t%d\t%.0f\t%.2f\n", NR, s, g, c }' \
    | while IFS="$TAB" read -r P S G C; do
        echo "Total: ${P} PRs, ${S} sessions, $(format_co2 "$G") CO2e, \$${C} at API list price."
      done
  [ "$SUM_UNREAD" -gt 0 ] && echo "${SUM_UNREAD} comment(s) could not be read (an older format, or edited) and are left out."
  case "$SUM_TOTAL" in
    ''|*[!0-9]*) ;;
    *) [ "$SUM_TOTAL" -gt 100 ] && echo "Only the first 100 of ${SUM_TOTAL} pull requests were read: narrow it with --since." ;;
  esac
  exit 0
fi

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 jq awk git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found. Run setup.sh first." >&2
  exit 1
fi

# session_models may postdate this DB (idempotent; one probe once migrated).
cc_ensure_schema "$DB_PATH"

# ── Git context: the branch is the attribution key ──────────
if ! TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi
# The branch checked out here: symbolic-ref rather than rev-parse resolves it even before
# the first commit, and returns nothing (not "HEAD") when detached. Its full name, without
# refs/heads/: the short form reads heads/<name> when a tag has the same name.
CURRENT="$(git symbolic-ref -q HEAD 2>/dev/null || echo "")"
CURRENT="${CURRENT%$'\r'}"
CURRENT="${CURRENT#refs/heads/}"
# With --pr, the PR's own head branch: run from main, the command once summed main's
# sessions and posted them on the PR as if they were its footprint. Otherwise the
# current branch.
if [ -n "$PR_NUMBER" ]; then
  if ! command -v gh &>/dev/null; then
    echo "Error: gh is required to read the branch of PR #${PR_NUMBER}." >&2
    exit 1
  fi
  # gh's own message is shown when it fails: an older gh that lacks a field says so there
  GH_ERR="$(mktemp "$(cc_tmpdir)/carbon-pr-gh.XXXXXX")"
  PR_HEAD="$(gh pr view "$PR_NUMBER" --json headRefName,isCrossRepository --jq '.headRefName + " " + (.isCrossRepository | tostring)' 2>"$GH_ERR" || true)"
  BRANCH="${PR_HEAD% *}"
  if [ -z "$PR_HEAD" ] || [ -z "$BRANCH" ] || [ "$BRANCH" = "$PR_HEAD" ]; then
    if [ -s "$GH_ERR" ]; then
      echo "Error: could not read the branch of PR #${PR_NUMBER} through gh:" >&2
      sed 's/^/  /' "$GH_ERR" >&2
    else
      echo "Error: could not read the branch of PR #${PR_NUMBER} (gh auth, or a PR of another repository?)." >&2
    fi
    rm -f "$GH_ERR"
    exit 1
  fi
  rm -f "$GH_ERR"
  # A fork's branch is not a branch of this repository: a local branch of the same name
  # (its main, often) would be summed as the PR's footprint
  if [ "${PR_HEAD##* }" = "true" ]; then
    echo "Error: PR #${PR_NUMBER} comes from a fork, so its branch '${BRANCH}' is not one of this repository's; nothing posted." >&2
    echo "Run /carbon-pr without --pr from the fork's clone, on the PR's branch." >&2
    exit 1
  fi
else
  BRANCH="$CURRENT"
  if [ -z "$BRANCH" ]; then
    echo "Error: no current branch (detached HEAD?)." >&2
    exit 1
  fi
fi
# Project name = basename of the repo root, matching how the Stop hook derives
# it from the session's last cwd (sessions that end in a subdirectory store the
# subdirectory's basename and will not be attributed; see README).
PROJECT="$(basename "$TOPLEVEL")"
# The repository, as the SubagentStop hook records an agent's branch: its common git folder,
# absolute, links resolved (git before 2.31 prints the flag back and a relative folder)
REPO_GIT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | tr -d '\r' || true)"
case "$REPO_GIT" in
  /*|[A-Za-z]:/*) ;;
  *) REPO_GIT="$(cd "$TOPLEVEL" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null | tr -d '\r' || true)"
     case "$REPO_GIT" in ''|/*|[A-Za-z]:/*) ;; *) REPO_GIT="${TOPLEVEL}/${REPO_GIT}" ;; esac ;;
esac
REPO_GIT="$( (cd "$REPO_GIT" 2>/dev/null && pwd -P) || true)"
if cc_is_windows; then REPO_GIT="$(printf '%s' "$REPO_GIT" | tr 'A-Z' 'a-z')"; fi

# Pick the equivalence set before LC_ALL=C masks the locale.
# shellcheck source=scripts/equiv-lib.sh
. "$SCRIPT_DIR/equiv-lib.sh"
EQUIV_SET="$(detect_equiv_set)"
export LC_ALL=C
# shellcheck source=scripts/format-lib.sh
. "$SCRIPT_DIR/format-lib.sh"

format_tokens() {
  echo "$1" | awk '{
    if ($1 >= 1000000)   printf "%.1fM", $1 / 1000000
    else if ($1 >= 1000) printf "%.0fk", $1 / 1000
    else                 printf "%d", $1
  }'
}

# ── Query the branch's sessions ─────────────────────────────
# The DB input_tokens column already folds cache write in (schema v2), so the
# tokens metric is input + output, cache reads shown separately, matching
# /carbon-report and the CI action (the shareable card counts cache reads in its total).
#
# What the branch adds up to, with the agents' branches the SubagentStop hook recorded
# (agent_usage, one row per agent and model):
#   + the sessions that ended on it (BASE)
#   - their agents that worked on another branch of this repository
#   + the agents of the repository's other sessions that worked on it
# An agent is moved only when its session's row is present, not excluded, holds all its
# agents (agents_collected), is of the current methodology and ends after the agent's last
# message (an agent that ended after its session's last Stop is not in that row yet:
# taking it out would leave less than nothing). A Stop hook writes the end in whole
# seconds, so an agent that ended in that same second waits for the next Stop; an end the
# rescan took from the transcripts has their precision and may equal the agent's last
# message. The branches then add up to the sessions. An agent recorded in another repository (or in this one before it moved, its
# common folder spelled otherwise) stays with its session. Without agent rows for this
# repository, or without the table (a database that could not be migrated), this is the
# sum of BASE, as before agent_usage existed.
SQL_BRANCH="${BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"
Q_REPO="'${REPO_GIT//$CC_SQ/$CC_SQ$CC_SQ}'"
HAS_AGENTS=0
if [ -n "$REPO_GIT" ] && [ "$(cc_sql "$DB_PATH" "SELECT EXISTS (SELECT 1 FROM agent_usage WHERE repo = ${Q_REPO});" 2>/dev/null || true)" = "1" ]; then
  HAS_AGENTS=1
fi

# ── The folders the branch's sessions are recorded under ────
# A session is recorded under the name of the folder it ran in. Run from the branch's
# own folder, that is this one, as before agent_usage existed. With agents of this
# repository on record, the report also takes, wherever it runs, the repository's main
# folder, the folder the branch is checked out in and the worktrees its agents worked in
# (one removed since, as after a merge). A branch checked out nowhere, whose
# name sessions in other folders also carry, is refused: those sessions may be its own,
# and a figure without them would be posted as the PR's.
PROJECT_LIST="'${PROJECT//$CC_SQ/$CC_SQ$CC_SQ}'"
PROJECT_NAMES="'${PROJECT}'"
add_project() {
  local q="'${1//$CC_SQ/$CC_SQ$CC_SQ}'"
  [ -n "$1" ] || return 0
  case ",${PROJECT_LIST}," in *",${q},"*) return 0 ;; esac
  PROJECT_LIST="${PROJECT_LIST},${q}"
  PROJECT_NAMES="${PROJECT_NAMES}, '${1}'"
}
if [ "$HAS_AGENTS" = "1" ]; then
  # The same folders wherever the command runs, so that the comment does not depend on the
  # folder it was last posted from. Two lines: the repository's main folder (its sessions on
  # the branch are the branch's), then the worktree the branch is checked out in, if any
  WT_PATHS="$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null \
    | awk -v want="branch refs/heads/${BRANCH}" '{ sub(/\r$/, "") } /^worktree / { p = substr($0, 10); if (main == "") main = p }
        $0 == want { found = p } END { print main; print found }' || true)"
  WT_MAIN="${WT_PATHS%%$'\n'*}"
  WT_PATH="${WT_PATHS#*$'\n'}"
  [ "$WT_PATH" != "$WT_PATHS" ] || WT_PATH=""
  add_project "${WT_MAIN##*/}"
  LOCATED=1
  if [ -n "$WT_PATH" ]; then
    add_project "${WT_PATH##*/}"
  elif [ "$BRANCH" != "$CURRENT" ]; then
    LOCATED=0
  fi
  while IFS= read -r W; do
    W="${W%$'\r'}"
    add_project "${W##*/}"
  done <<EOF
$(cc_sql "$DB_PATH" "SELECT DISTINCT worktree FROM agent_usage WHERE repo = ${Q_REPO} AND git_branch = '${SQL_BRANCH}' AND worktree <> '';" 2>/dev/null || true)
EOF
  if [ "$LOCATED" = "0" ]; then
    OTHERS="$(cc_sql "$DB_PATH" "SELECT group_concat(name, ', ') FROM (SELECT quote(project) AS name FROM sessions WHERE git_branch = '${SQL_BRANCH}' AND COALESCE(excluded, 0) = 0 AND project NOT IN (${PROJECT_LIST}) GROUP BY project ORDER BY COUNT(*) DESC LIMIT 3);" 2>/dev/null || true)"
    if [ -n "$OTHERS" ]; then
      echo "Error: branch '${BRANCH}' is checked out in no worktree of this repository, and sessions on a branch of that name were recorded in other folders (${OTHERS}). They may be this branch's: nothing posted, rather than a figure without them." >&2
      echo "Run /carbon-pr from the branch's worktree, or switch to the branch in the folder its sessions ran in and run /carbon-pr there without --pr." >&2
      exit 1
    fi
  fi
fi

BASE="s.project IN (${PROJECT_LIST}) AND s.git_branch = '${SQL_BRANCH}' AND COALESCE(s.excluded, 0) = 0"
AGENT_OK="COALESCE(s.excluded, 0) = 0 AND COALESCE(s.methodology_version, 1) >= 2 AND COALESCE(s.agents_collected, 0) >= 2 AND ((length(COALESCE(s.ended_at, '')) > 20 AND COALESCE(a.last_ts, '') <= s.ended_at) OR substr(COALESCE(a.last_ts, ''), 1, 19) < substr(COALESCE(s.ended_at, ''), 1, 19))"
HERE="a.git_branch = '${SQL_BRANCH}' AND a.repo = ${Q_REPO}"
OUT_AGENTS="FROM agent_usage a JOIN sessions s ON s.session_id = a.session_id WHERE ${BASE} AND ${AGENT_OK} AND a.repo = ${Q_REPO} AND a.git_branch <> '${SQL_BRANCH}'"
IN_AGENTS="FROM agent_usage a JOIN sessions s ON s.session_id = a.session_id WHERE ${HERE} AND ${AGENT_OK} AND NOT (${BASE})"
TOTAL_AGENTS=""
MODEL_AGENTS=""
if [ "$HAS_AGENTS" = "1" ]; then
  TOTAL_AGENTS="
  UNION ALL SELECT a.session_id, a.co2_grams, a.cost_usd, a.input_tokens, a.output_tokens, a.cache_read_tokens, -1, 0 ${OUT_AGENTS}
  UNION ALL SELECT a.session_id, a.co2_grams, a.cost_usd, a.input_tokens, a.output_tokens, a.cache_read_tokens, 1, 1 ${IN_AGENTS}"
  MODEL_AGENTS="
  UNION ALL SELECT a.session_id, -1, a.model, a.input_tokens, a.cache_creation_tokens, a.cache_read_tokens, a.output_tokens, a.co2_grams, a.cost_usd ${OUT_AGENTS}
  UNION ALL SELECT a.session_id, 1, a.model, a.input_tokens, a.cache_creation_tokens, a.cache_read_tokens, a.output_tokens, a.co2_grams, a.cost_usd ${IN_AGENTS}"
fi

read -r N_SESSIONS TOTAL_CO2 TOTAL_COST TOTAL_TOKENS TOTAL_CACHE_READ N_ELSEWHERE <<EOF
$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT CASE WHEN sign > 0 THEN sid END), COALESCE(SUM(sign * co2), 0), COALESCE(SUM(sign * cost), 0), COALESCE(SUM(sign * inp), 0) + COALESCE(SUM(sign * outp), 0), COALESCE(SUM(sign * cr), 0), COUNT(DISTINCT CASE WHEN elsewhere = 1 THEN sid END) FROM (
  SELECT s.session_id AS sid, s.co2_grams AS co2, s.cost_usd AS cost, s.input_tokens AS inp, s.output_tokens AS outp, s.cache_read_tokens AS cr, 1 AS sign, 0 AS elsewhere FROM sessions s WHERE ${BASE}${TOTAL_AGENTS});" | tr -d '\r' | tr '|' ' ')
EOF

if [ "$N_SESSIONS" = "0" ]; then
  echo "No sessions recorded for branch '${BRANCH}' of project ${PROJECT_NAMES}: nothing posted."
  if [ "$HAS_AGENTS" = "1" ]; then
    echo "A session counts for the branch it ended on, and so do its agents, except an agent"
    echo "that worked in a worktree of another branch, recorded as it ended: it counts there."
  else
    echo "A session counts for the branch it ended on: work driven from a session on another"
    echo "branch (agents in a worktree, for one) is recorded under that session's branch."
  fi
  echo "Sessions captured before the git_branch column (v1.4.0) carry no branch;"
  echo "run scripts/backfill.sh to repair them while their transcripts still exist."
  exit 0
fi

# The DB folds cache write into input_tokens (schema v2), so pure input is
# input_tokens - cache_creation_tokens; legacy v1 rows default the cache
# columns to 0 and show their whole input in the Input column.
# Per model at message grain: a session's session_models rows (main transcript and
# subagents, each message under the model that produced it) when it has them; the
# whole session under its dominant model otherwise (recorded before the table
# existed). Agents that left are taken out, agents that came are added, per model. The
# Sessions column counts the sessions that used each model, so it can add up to more than
# the total.
PER_MODEL="SELECT s.session_id AS session_id, 1 AS sign,
    CASE WHEN m.session_id IS NULL THEN s.model ELSE m.model END AS model,
    CASE WHEN m.session_id IS NULL THEN s.input_tokens ELSE m.input_tokens END AS inp,
    CASE WHEN m.session_id IS NULL THEN s.cache_creation_tokens ELSE m.cache_creation_tokens END AS cw,
    CASE WHEN m.session_id IS NULL THEN s.cache_read_tokens ELSE m.cache_read_tokens END AS cr,
    CASE WHEN m.session_id IS NULL THEN s.output_tokens ELSE m.output_tokens END AS outp,
    CASE WHEN m.session_id IS NULL THEN s.co2_grams ELSE m.co2_grams END AS co2,
    CASE WHEN m.session_id IS NULL THEN s.cost_usd ELSE m.cost_usd END AS cost
  FROM sessions s LEFT JOIN session_models m ON m.session_id = s.session_id WHERE ${BASE}${MODEL_AGENTS}"
MODEL_ROWS=""
while IFS="$(printf '\t')" read -r MODEL M_N M_IN M_CW M_CR M_OUT M_CO2 M_COST; do
  [ -n "$MODEL" ] || continue
  MODEL_ROWS="${MODEL_ROWS}| \`${MODEL}\` | ${M_N} | $(format_tokens "$M_IN") | $(format_tokens "$M_CW") | $(format_tokens "$M_CR") | $(format_tokens "$M_OUT") | $(format_co2 "$M_CO2") | \$$(echo "$M_COST" | awk '{printf "%.2f", $1}') |
"
done <<EOF
$(sqlite3 -separator "$(printf '\t')" "$DB_PATH" "SELECT model, COUNT(DISTINCT CASE WHEN sign > 0 THEN session_id END), COALESCE(SUM(sign * inp), 0) - COALESCE(SUM(sign * cw), 0), COALESCE(SUM(sign * cw), 0), COALESCE(SUM(sign * cr), 0), COALESCE(SUM(sign * outp), 0), COALESCE(SUM(sign * co2), 0), COALESCE(SUM(sign * cost), 0) FROM (${PER_MODEL}) GROUP BY model HAVING MIN(sign) > 0 OR SUM(sign * (inp + cr + outp)) > 0 ORDER BY SUM(sign * co2) DESC;")
EOF

# ── Format ──────────────────────────────────────────────────
CO2_DISPLAY="$(format_co2 "$TOTAL_CO2")"
COST_DISPLAY="\$$(echo "$TOTAL_COST" | awk '{printf "%.2f", $1}')"
TOKENS_DISPLAY="$(format_tokens "$TOTAL_TOKENS")"
CACHE_READ_DISPLAY="$(format_tokens "$TOTAL_CACHE_READ")"

EQUIV_LINE=""
read -r EQUIV_DIVISOR EQUIV_UNIT <<EOF
$(jq -r --arg set "$EQUIV_SET" '.equivalences[$set][] | select(.id == "car") | "\(.divisor) \(.unit)"' "$FACTORS_FILE" 2>/dev/null)
EOF
if [ -n "${EQUIV_DIVISOR:-}" ]; then
  EQUIV_VALUE="$(echo "$TOTAL_CO2 $EQUIV_DIVISOR" | awk '{
    v = $1 / $2
    if (v >= 10) printf "%.0f", v
    else if (v >= 1) printf "%.1f", v
    else printf "%.2f", v
  }')"
  EQUIV_TAG="$(jq -r --arg set "$EQUIV_SET" '.equivalences[$set][] | select(.id == "car") | .tag // .source' "$FACTORS_FILE" 2>/dev/null)"
  EQUIV_LINE="≈ ${EQUIV_VALUE} ${EQUIV_UNIT} driven by car (${EQUIV_TAG})"
fi

# Said when part of the sum comes from agents of sessions recorded under another branch or
# folder (a session on main that sent them to work in this branch's worktree)
AGENTS_LINE=""
if [ "${N_ELSEWHERE:-0}" -gt 0 ] 2>/dev/null; then
  AGENTS_LINE="
<sub>Includes the agents of ${N_ELSEWHERE} session(s) recorded under another branch or folder that worked on this branch.</sub>
"
fi

# Same tone contract as the CI action's comment: figures only, no score, no
# threshold, no judgement, no em-dash. "Estimated", the methodology link and
# the "turn off" link are invariants.
BODY="${MARKER}
**Claude Code carbon report** · developing this PR

| CO2e | Cost* | Tokens (in + cache write + out) | Cache reads | Sessions |
|---|---|---|---|---|
| **${CO2_DISPLAY}** | ${COST_DISPLAY} | ${TOKENS_DISPLAY} | ${CACHE_READ_DISPLAY} | ${N_SESSIONS} |

${EQUIV_LINE}

<details>
<summary>Token detail per model</summary>

| Model | Sessions | Uncached input | Cache write | Cache read | Output | CO2e | Cost |
|---|---|---|---|---|---|---|---|
${MODEL_ROWS}
</details>

<sub>*API list price of the equivalent usage; a subscription bills its flat fee instead.</sub>
${AGENTS_LINE}
<sub>Local Claude Code sessions on \`${BRANCH}\` · Estimated by [claude-carbon](${REPO_URL}) · [methodology](${REPO_URL}/blob/main/METHODOLOGY.md) · [turn off](${REPO_URL}#pr-dev-footprint-carbon-pr) · team view · [tokenclimate.com](https://tokenclimate.com/en?ref=carbon-pr)</sub>"

if [ "$DRY_RUN" = "1" ]; then
  echo "$BODY"
  exit 0
fi

# ── Sticky upsert via gh (the developer's own auth) ─────────
if ! command -v gh &>/dev/null; then
  echo "Error: gh is required to post (or use --dry-run to preview)." >&2
  exit 1
fi
# Posted by itself, the report goes to the repository the answer was given for: gh is not
# told another one, the answers and the database are not the repository's own files, and
# the repository gh aims at is the one named by origin.
if [ "$AUTO" = "1" ]; then
  unset GH_REPO GH_HOST
  AUTO_KEY="$(cc_repo_key "$TOPLEVEL")"
  AUTO_URL="$(gh repo view --json url --jq '.url' 2>/dev/null || true)"
  AUTO_TARGET="$(printf '%s' "$AUTO_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]')"
  if [ -z "$(cc_pr_data_dir "$TOPLEVEL")" ] || [ -z "$AUTO_KEY" ] || [ -z "$AUTO_TARGET" ] \
    || [ "$AUTO_TARGET" != "$(printf '%s' "$AUTO_KEY" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "Error: the repository gh would post to is not the one this folder's origin names (or it could not be read): nothing posted by itself. Run /carbon-pr to post it yourself." >&2
    exit 1
  fi
fi
if [ -z "$PR_NUMBER" ]; then
  PR_FOUND="$(gh pr view --json number,isCrossRepository --jq '(.number | tostring) + " " + (.isCrossRepository | tostring)' 2>/dev/null || true)"
  PR_NUMBER="${PR_FOUND%% *}"
  # An older gh without isCrossRepository: the number alone, for a run asked by hand
  if [ -z "$PR_NUMBER" ] && [ "$AUTO" = "0" ]; then
    PR_NUMBER="$(gh pr view --json number --jq '.number' 2>/dev/null || true)"
  fi
  # Posted by itself, the report stays inside the repository that asked for it
  if [ "$AUTO" = "1" ] && [ -n "$PR_NUMBER" ] && [ "${PR_FOUND#* }" != "false" ]; then
    echo "Error: PR #${PR_NUMBER} comes from a fork (or its origin could not be read): nothing posted by itself. Run /carbon-pr to post it yourself." >&2
    exit 1
  fi
fi
if [ -z "$PR_NUMBER" ]; then
  echo "Error: no open PR found for branch '${BRANCH}' (push and open one, or pass --pr <number>)." >&2
  exit 1
fi

BODY_FILE="$(mktemp "$(cc_tmpdir)/carbon-pr.XXXXXX")"
trap 'rm -f "$BODY_FILE"' EXIT
jq -n --arg body "$BODY" '{body: $body}' > "$BODY_FILE"

COMMENT_ID="$(gh api "repos/{owner}/{repo}/issues/${PR_NUMBER}/comments?per_page=100" \
  --jq "[.[] | select(.body | contains(\"${MARKER}\"))][0].id // \"\"" 2>/dev/null || true)"

if [ -n "$COMMENT_ID" ]; then
  gh api -X PATCH "repos/{owner}/{repo}/issues/comments/${COMMENT_ID}" --input "$BODY_FILE" >/dev/null
  echo "Updated the dev carbon report on PR #${PR_NUMBER} (${CO2_DISPLAY} CO2e, ${N_SESSIONS} sessions on ${BRANCH})."
else
  gh api -X POST "repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" --input "$BODY_FILE" >/dev/null
  echo "Posted the dev carbon report on PR #${PR_NUMBER} (${CO2_DISPLAY} CO2e, ${N_SESSIONS} sessions on ${BRANCH})."
fi
