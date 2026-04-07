#!/usr/bin/env bash
# persist-session.sh — Stop hook: persist session CO2 data to SQLite DB.
# Parses the session JSONL + subagent JSONLs directly (same logic as backfill)
# to ensure cache_read tokens are excluded and subagents are counted.
# Intentionally no set -euo pipefail: this hook must exit 0 silently in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

# Exit silently if DB doesn't exist (plugin not set up yet)
[ -f "$DB_PATH" ] || exit 0

# Load emission factors once
FACTOR_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_SONNET_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_SONNET_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_HAIKU_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_HAIKU_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0

# Read stdin
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

# Extract session_id
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0

# Extract metadata from hook JSON
MODEL_ID="$(echo "$INPUT" | jq -r '.model.id // ""' 2>/dev/null)" || exit 0
CURRENT_DIR="$(echo "$INPUT" | jq -r '.workspace.current_dir // ""' 2>/dev/null)" || exit 0
COST_USD="$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)" || exit 0

# Helper: aggregate tokens from a JSONL file (excludes cache_read)
aggregate_jsonl() {
  local result
  result="$(jq -s '
    [.[] | select(.type == "assistant" and .message.usage != null)] |
    {
      input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
      cache_creation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
      models: ([.[] | .message.model // ""] | map(select(length > 0)))
    } |
    .total_input = (.input_tokens + .cache_creation)
  ' "$1" 2>/dev/null)" && echo "$result" && return 0
  # Fallback: line-by-line for corrupted files
  while IFS= read -r line; do
    echo "$line" | jq 'select(.type == "assistant" and .message.usage != null) | {
      input_tokens: (.message.usage.input_tokens // 0),
      cache_creation: (.message.usage.cache_creation_input_tokens // 0),
      output_tokens: (.message.usage.output_tokens // 0),
      model: (.message.model // "")
    }' 2>/dev/null
  done < "$1" | jq -s '{
    input_tokens: (map(.input_tokens) | add // 0),
    cache_creation: (map(.cache_creation) | add // 0),
    output_tokens: (map(.output_tokens) | add // 0),
    models: [.[].model | select(length > 0)]
  } | .total_input = (.input_tokens + .cache_creation)' 2>/dev/null
}

# Helper: compute CO2 for aggregated data using its own model
compute_co2() {
  local agg="$1"
  local tin out model family fin fout

  tin="$(echo "$agg" | jq -r '.total_input // 0')"
  out="$(echo "$agg" | jq -r '.output_tokens // 0')"
  model="$(echo "$agg" | jq -r '.models | if length == 0 then "claude-sonnet" else group_by(.) | sort_by(-length) | first | first end')"

  family="sonnet"
  echo "$model" | grep -qi "opus" && family="opus"
  echo "$model" | grep -qi "haiku" && family="haiku"

  case "$family" in
    opus)  fin="$FACTOR_OPUS_IN"; fout="$FACTOR_OPUS_OUT" ;;
    haiku) fin="$FACTOR_HAIKU_IN"; fout="$FACTOR_HAIKU_OUT" ;;
    *)     fin="$FACTOR_SONNET_IN"; fout="$FACTOR_SONNET_OUT" ;;
  esac

  local co2
  co2="$(echo "$tin $fin $out $fout" | LC_ALL=C awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}')"
  echo "$tin $out $co2"
}

# Find the JSONL file for this session
JSONL_FILE=""
for DIR in "${HOME}/.claude/projects"/*; do
  [ -d "$DIR" ] || continue
  CANDIDATE="${DIR}/${SESSION_ID}.jsonl"
  if [ -f "$CANDIDATE" ]; then
    JSONL_FILE="$CANDIDATE"
    break
  fi
done

# Fallback: if no JSONL found, use hook data directly (less accurate, no subagents)
if [ -z "$JSONL_FILE" ] || [ ! -f "$JSONL_FILE" ]; then
  INPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)" || exit 0
  OUTPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)" || exit 0

  MODEL_FAMILY="sonnet"
  echo "$MODEL_ID" | grep -qi "opus" 2>/dev/null && MODEL_FAMILY="opus"
  echo "$MODEL_ID" | grep -qi "haiku" 2>/dev/null && MODEL_FAMILY="haiku"

  FACTOR_IN="$(jq -r ".models.${MODEL_FAMILY}.input" "$FACTORS_FILE" 2>/dev/null)" || exit 0
  FACTOR_OUT="$(jq -r ".models.${MODEL_FAMILY}.output" "$FACTORS_FILE" 2>/dev/null)" || exit 0
  CO2_G="$(echo "$INPUT_TOKENS $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | LC_ALL=C awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}' 2>/dev/null)" || exit 0
else
  # Parse main JSONL
  MAIN_AGG="$(aggregate_jsonl "$JSONL_FILE")" || exit 0
  read -r INPUT_TOKENS OUTPUT_TOKENS CO2_G <<< "$(compute_co2 "$MAIN_AGG")"

  # Parse subagent JSONLs (each with its own model/factor)
  SUBAGENT_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
  if [ -d "$SUBAGENT_DIR" ]; then
    for SUB_FILE in "$SUBAGENT_DIR"/*.jsonl; do
      [ -f "$SUB_FILE" ] || continue
      SUB_AGG="$(aggregate_jsonl "$SUB_FILE")" || continue

      read -r SUB_IN SUB_OUT SUB_CO2 <<< "$(compute_co2 "$SUB_AGG")"
      INPUT_TOKENS="$(echo "$INPUT_TOKENS $SUB_IN" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      OUTPUT_TOKENS="$(echo "$OUTPUT_TOKENS $SUB_OUT" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      CO2_G="$(echo "$CO2_G $SUB_CO2" | LC_ALL=C awk '{printf "%.4f", $1 + $2}')"
    done
  fi
fi

# Project name = last path segment
PROJECT="$(basename "$CURRENT_DIR" 2>/dev/null)" || PROJECT="unknown"

# Current timestamp
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""

# Sanitize strings for SQL
SESSION_ID="${SESSION_ID//\'/\'\'}"
PROJECT="${PROJECT//\'/\'\'}"
MODEL_ID="${MODEL_ID//\'/\'\'}"
NOW="${NOW//\'/\'\'}"

# INSERT OR REPLACE into sessions (source='live')
sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_ID}', ${INPUT_TOKENS}, ${OUTPUT_TOKENS}, ${COST_USD}, ${CO2_G}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SESSION_ID}'), '${NOW}'), '${NOW}', 'live');" 2>/dev/null || true

exit 0
