#!/usr/bin/env bash
# persist-session.sh — Stop hook: persist session CO2 data to SQLite DB.
# Reads Stop hook JSON from stdin, parses transcript JSONL for token counts.
# Intentionally no set -euo pipefail: this hook must exit 0 silently in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

# Exit silently if DB doesn't exist
[ -f "$DB_PATH" ] || exit 0

# Read stdin
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

# Extract session_id and transcript_path from Stop hook JSON
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0

TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
[ -f "$TRANSCRIPT_PATH" ] || exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
PROJECT="$(basename "$CWD" 2>/dev/null)" || PROJECT="unknown"

# Parse transcript JSONL to extract totals
PARSED="$(python3 "${SCRIPT_DIR}/parse-transcript.py" "$TRANSCRIPT_PATH" 2>/dev/null)" || exit 0

[ -n "$PARSED" ] || exit 0

MODEL_ID="$(echo "$PARSED" | cut -d'|' -f1)"
INPUT_TOKENS="$(echo "$PARSED" | cut -d'|' -f2)"
OUTPUT_TOKENS="$(echo "$PARSED" | cut -d'|' -f3)"
STARTED_AT="$(echo "$PARSED" | cut -d'|' -f4)"
ENDED_AT="$(echo "$PARSED" | cut -d'|' -f5)"

[ -n "$INPUT_TOKENS" ] || exit 0

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

# Calculate CO2 in grams
CO2_G="$(echo "$INPUT_TOKENS $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | LC_ALL=C awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}' 2>/dev/null)" || exit 0

# Fallback timestamp
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""
[ -n "$STARTED_AT" ] || STARTED_AT="$NOW"
[ -n "$ENDED_AT" ] || ENDED_AT="$NOW"

# Sanitize strings for SQL
SESSION_ID="${SESSION_ID//\'/\'\'}"
PROJECT="${PROJECT//\'/\'\'}"
MODEL_ID="${MODEL_ID//\'/\'\'}"

sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_ID}', ${INPUT_TOKENS}, ${OUTPUT_TOKENS}, 0, ${CO2_G}, '${STARTED_AT}', '${ENDED_AT}', 'live');" 2>/dev/null || true

exit 0
