#!/usr/bin/env bash
# generate-pr-report.sh — Post the development footprint of the current branch
# as a sticky PR comment: the local Claude Code sessions recorded for this
# project on this branch (git_branch column, captured by the Stop hook).
# Runs on the developer's machine, where carbon.db and the gh auth live; the
# CI runner never sees this data. Opt-in by nature: nothing is posted unless
# the developer runs it.
# Usage: generate-pr-report.sh [--dry-run] [--pr <number>]
#   --dry-run  print the comment body and post nothing (no gh needed, except with --pr,
#              whose branch is read through gh)
#   --pr N     report PR N: its own branch (read through gh), wherever the command runs
#              (default: the current branch and its open PR). A PR from a fork is refused.
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
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --pr) PR_GIVEN=1; PR_NUMBER="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: generate-pr-report.sh [--dry-run] [--pr <number>]" >&2; exit 2 ;;
  esac
done

# A number only: gh would also take a branch name or a URL, and read another PR than meant
if [ "$PR_GIVEN" = "1" ]; then
  case "$PR_NUMBER" in
    ''|*[!0-9]*) echo "Error: --pr takes a PR number, not '${PR_NUMBER}'." >&2; exit 2 ;;
  esac
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
# With --pr, the PR's own head branch: run from main, the command once summed main's
# sessions and posted them on the PR as if they were its footprint. Otherwise the
# current branch: symbolic-ref rather than rev-parse resolves it even before the first
# commit, and returns nothing (not "HEAD") when detached.
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
  BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")"
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
#   - their agents that worked on another branch of this repository, or on another one
#   + the agents of the repository's other sessions that worked on it
# An agent is moved only when its session's row is present, not excluded, holds all its
# agents (agents_collected), is of the current methodology and was written after the
# agent's last message (an agent that ended after its session's last Stop is not in that
# row yet: taking it out would leave less than nothing). The branches then add up to the
# sessions. Without agent rows, or without the table (a database that could not be
# migrated), this is the sum of BASE, as before agent_usage existed.
SQL_PROJECT="${PROJECT//$CC_SQ/$CC_SQ$CC_SQ}"
SQL_BRANCH="${BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"
Q_REPO="$(cc_sql_quote "$REPO_GIT")"
BASE="s.project = '${SQL_PROJECT}' AND s.git_branch = '${SQL_BRANCH}' AND COALESCE(s.excluded, 0) = 0"
AGENT_OK="COALESCE(s.excluded, 0) = 0 AND COALESCE(s.methodology_version, 1) >= 2 AND COALESCE(s.agents_collected, 0) >= 2 AND substr(COALESCE(a.last_ts, ''), 1, 19) <= substr(COALESCE(s.ended_at, ''), 1, 19)"
HERE="a.git_branch = '${SQL_BRANCH}' AND a.repo = ${Q_REPO}"
OUT_AGENTS="FROM agent_usage a JOIN sessions s ON s.session_id = a.session_id WHERE ${BASE} AND ${AGENT_OK} AND NOT (${HERE})"
IN_AGENTS="FROM agent_usage a JOIN sessions s ON s.session_id = a.session_id WHERE ${HERE} AND ${AGENT_OK} AND NOT (${BASE})"
TOTAL_AGENTS=""
MODEL_AGENTS=""
if [ "$(cc_sql "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'agent_usage';" 2>/dev/null)" = "1" ]; then
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
  echo "No sessions recorded for branch '${BRANCH}' of project '${PROJECT}': nothing posted."
  echo "A session counts for the branch it ended on, and so do its agents, except an agent"
  echo "that worked in a worktree of another branch, recorded as it ended: it counts there."
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
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER="$(gh pr view --json number --jq '.number' 2>/dev/null || true)"
fi
if [ -z "$PR_NUMBER" ]; then
  echo "Error: no open PR found for branch '${BRANCH}' (push and open one, or pass --pr <number>)." >&2
  exit 1
fi

BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/carbon-pr.XXXXXX")"
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
