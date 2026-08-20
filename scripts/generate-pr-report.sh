#!/usr/bin/env bash
# generate-pr-report.sh — Post the development footprint of the current branch
# as a sticky PR comment: the local Claude Code sessions recorded for this
# project on this branch (git_branch column, captured by the Stop hook).
# Runs on the developer's machine, where carbon.db and the gh auth live; the
# CI runner never sees this data. Opt-in by nature: nothing is posted unless
# the developer runs it.
# Usage: generate-pr-report.sh [--dry-run] [--pr <number>]
#   --dry-run  print the comment body and post nothing (no gh needed)
#   --pr N     target PR number (default: the PR of the current branch via gh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FACTORS_FILE="$PROJECT_DIR/data/factors.json"
DB_PATH="${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}"
REPO_URL="https://github.com/gwittebolle/claude-carbon"
MARKER="<!-- claude-carbon-dev-report -->"

DRY_RUN=0
PR_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --pr) PR_NUMBER="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: generate-pr-report.sh [--dry-run] [--pr <number>]" >&2; exit 2 ;;
  esac
done

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 jq bc git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found. Run setup.sh first." >&2
  exit 1
fi

# ── Git context: the branch is the attribution key ──────────
if ! TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi
# symbolic-ref rather than rev-parse: it resolves the branch name even before
# the first commit, and returns nothing (not "HEAD") when detached.
BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")"
if [ -z "$BRANCH" ]; then
  echo "Error: no current branch (detached HEAD?)." >&2
  exit 1
fi
# Project name = basename of the repo root, matching how the Stop hook derives
# it from the session cwd (sessions started in subdirectories store the
# subdirectory's basename and will not be attributed; see README).
PROJECT="$(basename "$TOPLEVEL")"

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
# tokens metric is input + output, cache reads shown separately, matching the
# report and the CI action.
SQL_PROJECT="${PROJECT//\'/\'\'}"
SQL_BRANCH="${BRANCH//\'/\'\'}"
WHERE="WHERE project = '${SQL_PROJECT}' AND git_branch = '${SQL_BRANCH}' AND COALESCE(excluded, 0) = 0"

read -r N_SESSIONS TOTAL_CO2 TOTAL_COST TOTAL_TOKENS TOTAL_CACHE_READ <<EOF
$(sqlite3 "$DB_PATH" "SELECT COUNT(*), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0), COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0), COALESCE(SUM(cache_read_tokens), 0) FROM sessions ${WHERE};" | tr '|' ' ')
EOF

if [ "$N_SESSIONS" = "0" ]; then
  echo "No sessions recorded for branch '${BRANCH}' of project '${PROJECT}'."
  echo "Sessions captured before the git_branch column (v1.4.0) carry no branch;"
  echo "run scripts/backfill.sh to repair them while their transcripts still exist."
  exit 0
fi

# The DB folds cache write into input_tokens (schema v2), so pure input is
# input_tokens - cache_creation_tokens; legacy v1 rows default the cache
# columns to 0 and show their whole input in the Input column.
MODEL_ROWS=""
while IFS="$(printf '\t')" read -r MODEL M_N M_IN M_CW M_CR M_OUT M_CO2 M_COST; do
  [ -n "$MODEL" ] || continue
  MODEL_ROWS="${MODEL_ROWS}| \`${MODEL}\` | ${M_N} | $(format_tokens "$M_IN") | $(format_tokens "$M_CW") | $(format_tokens "$M_CR") | $(format_tokens "$M_OUT") | $(format_co2 "$M_CO2") | \$$(echo "$M_COST" | awk '{printf "%.2f", $1}') |
"
done <<EOF
$(sqlite3 -separator "$(printf '\t')" "$DB_PATH" "SELECT model, COUNT(*), COALESCE(SUM(input_tokens), 0) - COALESCE(SUM(cache_creation_tokens), 0), COALESCE(SUM(cache_creation_tokens), 0), COALESCE(SUM(cache_read_tokens), 0), COALESCE(SUM(output_tokens), 0), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0) FROM sessions ${WHERE} GROUP BY model ORDER BY SUM(co2_grams) DESC;")
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

# Same tone contract as the CI action's comment: figures only, no score, no
# threshold, no judgement, no em-dash. "Estimated", the methodology link and
# the "turn off" link are invariants.
BODY="${MARKER}
**Claude Code carbon report** · developing this PR

| CO2e | Cost (API list) | Tokens (in + cache write + out) | Cache reads | Sessions |
|---|---|---|---|---|
| **${CO2_DISPLAY}** | ${COST_DISPLAY} | ${TOKENS_DISPLAY} | ${CACHE_READ_DISPLAY} | ${N_SESSIONS} |

${EQUIV_LINE}

<details>
<summary>Token detail per model</summary>

| Model | Sessions | Input | Cache write | Cache read | Output | CO2e | Cost |
|---|---|---|---|---|---|---|---|
${MODEL_ROWS}
</details>

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
