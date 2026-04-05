#!/usr/bin/env bash
# persist-session.sh — Stop hook: persist session CO2 data to SQLite DB.
# Reads JSON from stdin (same format as statusline). Never fails, never prints output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

# Exit silently if DB doesn't exist (plugin not set up yet)
[ -f "$DB_PATH" ] || exit 0

# Read stdin
INPUT="$(cat 2>/dev/null)" || exit 0

# Exit silently if no input
[ -n "$INPUT" ] || exit 0

# Extract session_id — exit silently if missing
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0

# Extract remaining fields
MODEL_ID="$(echo "$INPUT" | jq -r '.model.id // ""' 2>/dev/null)" || exit 0
CURRENT_DIR="$(echo "$INPUT" | jq -r '.workspace.current_dir // ""' 2>/dev/null)" || exit 0
COST_USD="$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)" || exit 0
INPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)" || exit 0
OUTPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)" || exit 0

# Project name = last path segment
PROJECT="$(basename "$CURRENT_DIR" 2>/dev/null)" || PROJECT="unknown"

# Resolve model family
MODEL_FAMILY="sonnet"
if echo "$MODEL_ID" | grep -qi "opus" 2>/dev/null; then
  MODEL_FAMILY="opus"
elif echo "$MODEL_ID" | grep -qi "haiku" 2>/dev/null; then
  MODEL_FAMILY="haiku"
fi

# Load emission factors
FACTOR_IN="$(jq -r ".models.${MODEL_FAMILY}.input" "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_OUT="$(jq -r ".models.${MODEL_FAMILY}.output" "$FACTORS_FILE" 2>/dev/null)" || exit 0

# Calculate CO2
CO2_G="$(echo "$INPUT_TOKENS $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}' 2>/dev/null)" || exit 0

# Current timestamp
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""

# INSERT OR REPLACE into sessions (source='live')
sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_ID}', ${INPUT_TOKENS}, ${OUTPUT_TOKENS}, ${COST_USD}, ${CO2_G}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SESSION_ID}'), '${NOW}'), '${NOW}', 'live');" 2>/dev/null || true

exit 0
