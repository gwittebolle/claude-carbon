#!/usr/bin/env bash
# action-report.sh — the GitHub Action entrypoint behind action.yml: parse a
# claude-code-action execution log, compute the run's footprint with the
# plugin's methodology (scripts/compute-lib.sh), write the job summary and
# outputs, and upsert one sticky PR comment.
#
# Contract: this script NEVER fails the caller's CI. No `set -e`; every
# degraded path logs a ::notice::/::warning:: annotation and the single exit
# at the bottom is 0. action.yml adds one more `|| echo` guard on top.
#
# Inputs (env, wired by action.yml): INPUT_EXECUTION_FILE, INPUT_COMMENT,
# INPUT_OPT_OUT_LABEL, INPUT_LOCALE, GH_TOKEN.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FACTORS_FILE="$PROJECT_DIR/data/factors.json"
PRICES_FILE="$PROJECT_DIR/data/prices.json"

export LC_ALL=C
# shellcheck source=scripts/compute-lib.sh
. "$SCRIPT_DIR/compute-lib.sh"
# shellcheck source=scripts/format-lib.sh
. "$SCRIPT_DIR/format-lib.sh"

MARKER="<!-- claude-carbon-report -->"
REPO_URL="https://github.com/gwittebolle/claude-carbon"

# set_output <name> <value> — append to $GITHUB_OUTPUT when it exists (absent
# in local test runs without a stub).
set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

# finish <status> — write the status output and leave with the never-fail code.
finish() {
  set_output "status" "$1"
  exit 0
}

skip_empty() {
  set_output "co2_grams" ""
  set_output "cost_usd" ""
  set_output "total_tokens" ""
  set_output "cache_read_tokens" ""
  set_output "comment_markdown" ""
  finish "$1"
}

for cmd in jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "::notice::claude-carbon: $cmd not found on this runner; skipping the carbon report"
    skip_empty "skipped"
  fi
done

# ── 1. Locate and validate the execution log ────────────────
EXEC_FILE="${INPUT_EXECUTION_FILE:-${RUNNER_TEMP:-/tmp}/claude-execution-output.json}"
if [ ! -s "$EXEC_FILE" ]; then
  echo "::notice::claude-carbon: no execution file at $EXEC_FILE (claude step skipped, or ran in another job?); skipping the carbon report"
  skip_empty "skipped"
fi
if ! jq -e 'type == "array"' "$EXEC_FILE" >/dev/null 2>&1; then
  echo "::notice::claude-carbon: $EXEC_FILE is not a JSON array of messages; skipping the carbon report"
  skip_empty "skipped"
fi

# ── 2. Aggregate per model ──────────────────────────────────
# Same dedup as persist-session.sh aggregate_jsonl: assistant messages keyed by
# (message.id, requestId), last occurrence wins, keyless messages all kept.
# Subagent messages sit in the same flat array (parent_tool_use_id set), so
# summing everything includes them without double counting.
PER_MODEL="$(jq -r '
  [.[] | select(.type == "assistant" and .message.usage != null)] as $all
  | (
      ($all | map(select(.message.id != null and .requestId != null))
            | reduce .[] as $m ({}; .[($m.message.id|tostring) + "|" + ($m.requestId|tostring)] = $m)
            | [.[]])
      + ($all | map(select(.message.id == null or .requestId == null)))
    )
  | group_by(.message.model // "claude-sonnet")
  | map({
      model:  (.[0].message.model // "claude-sonnet"),
      input:  (map(.message.usage.input_tokens // 0) | add // 0),
      cw:     (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      cr:     (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
      output: (map(.message.usage.output_tokens // 0) | add // 0)
    })
  | .[] | [.model, .input, .cw, .cr, .output] | @tsv' "$EXEC_FILE" 2>/dev/null)"

ASSISTANT_COUNT="$(jq -r '[.[] | select(.type == "assistant")] | length' "$EXEC_FILE" 2>/dev/null || echo 0)"

if [ -z "$PER_MODEL" ] && [ "$ASSISTANT_COUNT" -gt 0 ] 2>/dev/null; then
  echo "::warning::claude-carbon: the execution file has assistant messages but none carried a usage object; the claude-code-action log format may have changed"
  skip_empty "error"
fi
if [ -z "$PER_MODEL" ]; then
  echo "::notice::claude-carbon: no assistant messages with usage in $EXEC_FILE; skipping the carbon report"
  skip_empty "skipped"
fi

if ! carbon_load_rates "$FACTORS_FILE" "$PRICES_FILE"; then
  echo "::warning::claude-carbon: cannot read $FACTORS_FILE / $PRICES_FILE; skipping the carbon report"
  skip_empty "error"
fi

# ── 3. Compute totals ───────────────────────────────────────
format_tokens() {
  echo "$1" | awk '{
    if ($1 >= 1000000)   printf "%.1fM", $1 / 1000000
    else if ($1 >= 1000) printf "%.0fk", $1 / 1000
    else                 printf "%d", $1
  }'
}

TOTAL_CO2="0"; TOTAL_COST="0"; TOTAL_TOKENS=0; TOTAL_CACHE_READ=0
MODEL_ROWS="" # markdown rows for the collapsed per-model detail table

while IFS="$(printf '\t')" read -r MODEL IN CW CR OUT; do
  [ -n "$MODEL" ] || continue
  read -r CO2 COST <<EOF
$(carbon_compute "$MODEL" "$IN" "$CW" "$CR" "$OUT")
EOF
  TOTAL_CO2="$(echo "$TOTAL_CO2 $CO2" | awk '{printf "%.4f", $1 + $2}')"
  TOTAL_COST="$(echo "$TOTAL_COST $COST" | awk '{printf "%.6f", $1 + $2}')"
  # The repo's tokens metric: input + cache_write + output; cache reads are
  # reported separately (they dominate CI runs and would drown the figure).
  TOTAL_TOKENS="$(echo "$TOTAL_TOKENS $IN $CW $OUT" | awk '{printf "%d", $1 + $2 + $3 + $4}')"
  TOTAL_CACHE_READ="$(echo "$TOTAL_CACHE_READ $CR" | awk '{printf "%d", $1 + $2}')"
  TOKEN_CELLS="$(format_tokens "$IN") | $(format_tokens "$CW") | $(format_tokens "$CR") | $(format_tokens "$OUT")"
  if carbon_is_excluded_model "$MODEL"; then
    MODEL_ROWS="${MODEL_ROWS}| \`${MODEL}\` (excluded) | ${TOKEN_CELLS} | - | - |
"
  else
    MODEL_ROWS="${MODEL_ROWS}| \`${MODEL}\` | ${TOKEN_CELLS} | $(format_co2 "$CO2") | \$$(echo "$COST" | awk '{printf "%.2f", $1}') |
"
  fi
done <<EOF
$PER_MODEL
EOF

# All-zero totals over real assistant entries smell like schema drift (renamed
# usage fields): refuse to post a plausible-looking zero report.
if [ "$(echo "$TOTAL_CO2 $TOTAL_COST $TOTAL_TOKENS $TOTAL_CACHE_READ" | awk '{print ($1 == 0 && $2 == 0 && $3 == 0 && $4 == 0) ? 1 : 0}')" = "1" ]; then
  echo "::warning::claude-carbon: aggregated zero tokens from $ASSISTANT_COUNT assistant messages; the claude-code-action log format may have changed"
  skip_empty "error"
fi

# ── 4. Format the figures ───────────────────────────────────
CO2_DISPLAY="$(format_co2 "$TOTAL_CO2")"
COST_DISPLAY="\$$(echo "$TOTAL_COST" | awk '{printf "%.2f", $1}')"
TOKENS_DISPLAY="$(format_tokens "$TOTAL_TOKENS")"
CACHE_READ_DISPLAY="$(format_tokens "$TOTAL_CACHE_READ")"

# One car equivalence from the requested set (world by default: a runner has no
# meaningful user locale). Sub-unit values keep enough decimals to stay non-zero.
LOCALE_SET="${INPUT_LOCALE:-world}"
case "$LOCALE_SET" in fr|us|world) ;; *) LOCALE_SET="world" ;; esac
EQUIV_LINE=""
read -r EQUIV_DIVISOR EQUIV_UNIT <<EOF
$(jq -r --arg set "$LOCALE_SET" '.equivalences[$set][] | select(.id == "car") | "\(.divisor) \(.unit)"' "$FACTORS_FILE" 2>/dev/null)
EOF
if [ -n "${EQUIV_DIVISOR:-}" ]; then
  EQUIV_VALUE="$(echo "$TOTAL_CO2 $EQUIV_DIVISOR" | awk '{
    v = $1 / $2
    if (v >= 10) printf "%.0f", v
    else if (v >= 1) printf "%.1f", v
    else printf "%.2f", v
  }')"
  EQUIV_TAG="$(jq -r --arg set "$LOCALE_SET" '.equivalences[$set][] | select(.id == "car") | .tag // .source' "$FACTORS_FILE" 2>/dev/null)"
  EQUIV_LINE="≈ ${EQUIV_VALUE} ${EQUIV_UNIT} driven by car (${EQUIV_TAG})"
fi

# ── 5. Build the report body ────────────────────────────────
# Tone contract (see README "Carbon report on your PRs"): figures only. No
# score, no threshold, no alarm emoji, no judgement — the number informs, the
# reader decides. "Estimated", the methodology link and the "turn off" link
# are invariants: the claim stays honest and the reader keeps the off switch.
# No em-dash anywhere in the rendered text (house writing rule).
BODY="${MARKER}
**Claude Code carbon report** · this run

| CO2e | Cost (API list) | Tokens | Cache reads |
|---|---|---|---|
| **${CO2_DISPLAY}** | ${COST_DISPLAY} | ${TOKENS_DISPLAY} | ${CACHE_READ_DISPLAY} |

${EQUIV_LINE}

<details>
<summary>Token detail per model</summary>

| Model | Input | Cache write | Cache read | Output | CO2e | Cost |
|---|---|---|---|---|---|---|
${MODEL_ROWS}
</details>

<sub>Estimated by [claude-carbon](${REPO_URL}) · [methodology](${REPO_URL}/blob/main/METHODOLOGY.md) · [turn off](${REPO_URL}#carbon-report-on-your-prs-github-action) · team view · [tokenclimate.com](https://tokenclimate.com/en?ref=github-action)</sub>"

SUMMARY_BODY="$BODY"

# ── 6. Outputs + job summary (always, even with comment: false) ──
set_output "co2_grams" "$TOTAL_CO2"
set_output "cost_usd" "$TOTAL_COST"
set_output "total_tokens" "$TOTAL_TOKENS"
set_output "cache_read_tokens" "$TOTAL_CACHE_READ"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "comment_markdown<<CLAUDE_CARBON_EOF"
    echo "$BODY"
    echo "CLAUDE_CARBON_EOF"
  } >> "$GITHUB_OUTPUT"
fi
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$SUMMARY_BODY" >> "$GITHUB_STEP_SUMMARY"

# ── 7. Sticky PR comment ────────────────────────────────────
if [ "${INPUT_COMMENT:-true}" = "false" ]; then
  echo "claude-carbon: comment disabled (comment: false); job summary and outputs written"
  finish "ok"
fi

EVENT_PATH="${GITHUB_EVENT_PATH:-}"
if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
  echo "claude-carbon: no event payload; job summary and outputs written"
  finish "ok"
fi

# PR conversation comments are issue comments; issue_comment events (the usual
# @claude trigger) carry the PR number under .issue.
PR_NUMBER="$(jq -r '.pull_request.number // (.issue | select(.pull_request != null) | .number) // ""' "$EVENT_PATH" 2>/dev/null)"
if [ -z "$PR_NUMBER" ]; then
  echo "claude-carbon: not a pull request event; job summary and outputs written"
  finish "ok"
fi

OPT_OUT_LABEL="${INPUT_OPT_OUT_LABEL:-no-carbon-report}"
HAS_LABEL="$(jq -r --arg l "$OPT_OUT_LABEL" '[(.pull_request.labels // .issue.labels // [])[].name] | contains([$l])' "$EVENT_PATH" 2>/dev/null)"
if [ "$HAS_LABEL" = "true" ]; then
  echo "::notice::claude-carbon: PR #${PR_NUMBER} carries the '${OPT_OUT_LABEL}' label; comment skipped (job summary still written)"
  finish "ok"
fi

if [ -z "${GH_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "::notice::claude-carbon: no token or repository in the environment; comment skipped"
  finish "ok"
fi

API="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/issues"
AUTH="Authorization: Bearer ${GH_TOKEN}"
PAYLOAD="$(jq -n --arg body "$BODY" '{body: $body}')"

# Find our own comment by marker (paginated, capped at 3 pages / 300 comments).
COMMENT_ID=""
PAGE=1
while [ "$PAGE" -le 3 ]; do
  RESP="$(curl -sf --max-time 30 -H "$AUTH" "${API}/${PR_NUMBER}/comments?per_page=100&page=${PAGE}" 2>/dev/null)" || break
  COMMENT_ID="$(echo "$RESP" | jq -r --arg m "$MARKER" '[.[] | select(.body | contains($m))][0].id // ""' 2>/dev/null)"
  [ -n "$COMMENT_ID" ] && break
  [ "$(echo "$RESP" | jq -r 'length' 2>/dev/null)" = "100" ] || break
  PAGE=$((PAGE + 1))
done

if [ -n "$COMMENT_ID" ]; then
  if curl -sf --max-time 30 -X PATCH -H "$AUTH" -d "$PAYLOAD" "${API}/comments/${COMMENT_ID}" >/dev/null 2>&1; then
    echo "claude-carbon: updated the sticky comment on PR #${PR_NUMBER}"
    finish "ok"
  fi
else
  if curl -sf --max-time 30 -X POST -H "$AUTH" -d "$PAYLOAD" "${API}/${PR_NUMBER}/comments" >/dev/null 2>&1; then
    echo "claude-carbon: posted the sticky comment on PR #${PR_NUMBER}"
    finish "ok"
  fi
fi

echo "::warning::claude-carbon: could not post the PR comment (read-only token on a fork PR? missing pull-requests: write?); see the job summary instead"
finish "ok"
