#!/usr/bin/env bash
# persist-session.sh — Stop hook: persist session CO2 data to SQLite DB.
# Parses the session JSONL + subagent JSONLs directly (same logic as backfill):
# deduplicates assistant messages by (message.id, requestId) so replayed messages
# in resumed/compacted sessions are not double-counted, and stores the raw token
# breakdown (input, cache_write, cache_read, output) so cost/CO2 can be re-derived later
# via recompute.sh without the (30-day-purged) JSONL.
# Intentionally no set -euo pipefail: this hook must exit 0 silently in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
DB_PATH="${CLAUDE_CARBON_DB:-${HOME}/.claude/claude-carbon/carbon.db}"

METHODOLOGY_VERSION=2

# Exit silently if DB doesn't exist (plugin not set up yet)
[ -f "$DB_PATH" ] || exit 0

# Migrate schema if needed (idempotent; no-ops once the columns exist)
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true

# Load emission factors once
FACTOR_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_SONNET_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_SONNET_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_HAIKU_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE" 2>/dev/null)" || exit 0
FACTOR_HAIKU_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE" 2>/dev/null)" || exit 0
# Energy of a cache_read token as a fraction of an uncached input token (see METHODOLOGY.md).
CACHE_READ_FACTOR="$(jq -r '.cache_read_factor // 0.08' "$FACTORS_FILE" 2>/dev/null)" || CACHE_READ_FACTOR="0.08"

# Load pricing once (USD per million tokens, current Anthropic list price).
# The Stop hook doesn't provide the actual billed cost, so we estimate the API list value.
PRICE_OPUS_IN="$(jq -r '.models.opus.input' "$PRICES_FILE" 2>/dev/null)" || PRICE_OPUS_IN="5"
PRICE_OPUS_OUT="$(jq -r '.models.opus.output' "$PRICES_FILE" 2>/dev/null)" || PRICE_OPUS_OUT="25"
PRICE_SONNET_IN="$(jq -r '.models.sonnet.input' "$PRICES_FILE" 2>/dev/null)" || PRICE_SONNET_IN="3"
PRICE_SONNET_OUT="$(jq -r '.models.sonnet.output' "$PRICES_FILE" 2>/dev/null)" || PRICE_SONNET_OUT="15"
PRICE_HAIKU_IN="$(jq -r '.models.haiku.input' "$PRICES_FILE" 2>/dev/null)" || PRICE_HAIKU_IN="1"
PRICE_HAIKU_OUT="$(jq -r '.models.haiku.output' "$PRICES_FILE" 2>/dev/null)" || PRICE_HAIKU_OUT="5"
CACHE_WRITE_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$PRICES_FILE" 2>/dev/null)" || CACHE_WRITE_MULT="1.25"
CACHE_READ_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$PRICES_FILE" 2>/dev/null)" || CACHE_READ_MULT="0.1"

# Read stdin
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

# Extract fields from Stop hook JSON
# Stop hook provides: session_id, transcript_path, cwd
# It does NOT provide: model.id, context_window, cost
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0

TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
CURRENT_DIR="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0

# Helper: aggregate tokens from a JSONL file.
# Dedups assistant messages by (message.id|requestId) keeping the LAST occurrence; tracks
# input, cache_creation (write), cache_read, and output separately.
aggregate_jsonl() {
  local result
  result="$(jq -s '
    [.[] | select(.type == "assistant" and .message.usage != null)] as $all
    | (
        ($all | map(select(.message.id != null and .requestId != null))
              | reduce .[] as $m ({}; .[($m.message.id|tostring) + "|" + ($m.requestId|tostring)] = $m)
              | [.[]])
        + ($all | map(select(.message.id == null or .requestId == null)))
      ) as $d
    | {
        input_tokens:   ($d | map(.message.usage.input_tokens // 0) | add // 0),
        cache_creation: ($d | map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
        cache_read:     ($d | map(.message.usage.cache_read_input_tokens // 0) | add // 0),
        output_tokens:  ($d | map(.message.usage.output_tokens // 0) | add // 0),
        models:         ($d | map(.message.model // "") | map(select(length > 0)))
      }
  ' "$1" 2>/dev/null)" && echo "$result" && return 0
  # Fallback: line-by-line for corrupted files, same dedup applied at the end.
  while IFS= read -r line; do
    echo "$line" | jq -c 'select(.type == "assistant" and .message.usage != null) | {
      input_tokens: (.message.usage.input_tokens // 0),
      cache_creation: (.message.usage.cache_creation_input_tokens // 0),
      cache_read: (.message.usage.cache_read_input_tokens // 0),
      output_tokens: (.message.usage.output_tokens // 0),
      model: (.message.model // ""),
      id: (.message.id // null),
      rid: (.requestId // null)
    }' 2>/dev/null
  done < "$1" | jq -s '
    . as $all
    | (
        ($all | map(select(.id != null and .rid != null))
              | reduce .[] as $m ({}; .[($m.id|tostring) + "|" + ($m.rid|tostring)] = $m)
              | [.[]])
        + ($all | map(select(.id == null or .rid == null)))
      ) as $d
    | {
        input_tokens:   ($d | map(.input_tokens) | add // 0),
        cache_creation: ($d | map(.cache_creation) | add // 0),
        cache_read:     ($d | map(.cache_read) | add // 0),
        output_tokens:  ($d | map(.output_tokens) | add // 0),
        models:         ($d | map(.model) | map(select(length > 0)))
      }
  ' 2>/dev/null
}

# Helper: compute CO2 and theoretical API cost for aggregated data using its own model.
# CO2  = (input + cache_write) * factor_in + cache_read * (factor_in * CACHE_READ_FACTOR) + output * factor_out
# Cost = input * pin + cache_write * (CACHE_WRITE_MULT*pin) + cache_read * (CACHE_READ_MULT*pin) + output * pout
# Returns: total_input(=input+cache_write) cache_creation cache_read output co2 cost
compute_co2() {
  local agg="$1"
  local it cw cr out model family fin fout pin pout co2 cost total_input

  it="$(echo "$agg" | jq -r '.input_tokens // 0')"
  cw="$(echo "$agg" | jq -r '.cache_creation // 0')"
  cr="$(echo "$agg" | jq -r '.cache_read // 0')"
  out="$(echo "$agg" | jq -r '.output_tokens // 0')"
  model="$(echo "$agg" | jq -r '.models | if length == 0 then "claude-sonnet" else group_by(.) | sort_by(-length) | first | first end')"

  family="sonnet"
  echo "$model" | grep -qi "opus" && family="opus"
  echo "$model" | grep -qi "haiku" && family="haiku"

  case "$family" in
    opus)  fin="$FACTOR_OPUS_IN"; fout="$FACTOR_OPUS_OUT"; pin="$PRICE_OPUS_IN"; pout="$PRICE_OPUS_OUT" ;;
    haiku) fin="$FACTOR_HAIKU_IN"; fout="$FACTOR_HAIKU_OUT"; pin="$PRICE_HAIKU_IN"; pout="$PRICE_HAIKU_OUT" ;;
    *)     fin="$FACTOR_SONNET_IN"; fout="$FACTOR_SONNET_OUT"; pin="$PRICE_SONNET_IN"; pout="$PRICE_SONNET_OUT" ;;
  esac

  co2="$(echo "$it $cw $cr $out $fin $fout $CACHE_READ_FACTOR" | LC_ALL=C awk \
    '{printf "%.4f", (($1 + $2) * $5 + $3 * ($5 * $7) + $4 * $6) / 1000000}')"
  cost="$(echo "$it $cw $cr $out $pin $pout $CACHE_WRITE_MULT $CACHE_READ_MULT" | LC_ALL=C awk \
    '{printf "%.6f", ($1 * $5 + $2 * ($5 * $7) + $3 * ($5 * $8) + $4 * $6) / 1000000}')"
  total_input="$(echo "$it $cw" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
  echo "$total_input $cw $cr $out $co2 $cost"
}

# Find the JSONL file: use transcript_path from hook, fallback to search by session_id
JSONL_FILE=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  JSONL_FILE="$TRANSCRIPT_PATH"
else
  for DIR in "${HOME}/.claude/projects"/*; do
    [ -d "$DIR" ] || continue
    CANDIDATE="${DIR}/${SESSION_ID}.jsonl"
    if [ -f "$CANDIDATE" ]; then
      JSONL_FILE="$CANDIDATE"
      break
    fi
  done
fi

# Exit if no JSONL found
[ -n "$JSONL_FILE" ] && [ -f "$JSONL_FILE" ] || exit 0

# Parse main JSONL
MAIN_AGG="$(aggregate_jsonl "$JSONL_FILE")" || exit 0
read -r INPUT_TOKENS CACHE_CREATION CACHE_READ OUTPUT_TOKENS CO2_G COST_USD <<< "$(compute_co2 "$MAIN_AGG")"

# Extract model from JSONL (not available in Stop hook JSON)
MODEL_RAW="$(echo "$MAIN_AGG" | jq -r '.models | if length == 0 then "claude-sonnet" else group_by(.) | sort_by(-length) | first | first end' 2>/dev/null)" || MODEL_RAW="claude-sonnet"

# Parse subagent JSONLs (each with its own model/factor)
SUBAGENT_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
if [ -d "$SUBAGENT_DIR" ]; then
  for SUB_FILE in "$SUBAGENT_DIR"/*.jsonl; do
    [ -f "$SUB_FILE" ] || continue
    SUB_AGG="$(aggregate_jsonl "$SUB_FILE")" || continue

    read -r SUB_IN SUB_CW SUB_CR SUB_OUT SUB_CO2 SUB_COST <<< "$(compute_co2 "$SUB_AGG")"
    INPUT_TOKENS="$(echo "$INPUT_TOKENS $SUB_IN" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
    CACHE_CREATION="$(echo "$CACHE_CREATION $SUB_CW" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
    CACHE_READ="$(echo "$CACHE_READ $SUB_CR" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
    OUTPUT_TOKENS="$(echo "$OUTPUT_TOKENS $SUB_OUT" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
    CO2_G="$(echo "$CO2_G $SUB_CO2" | LC_ALL=C awk '{printf "%.4f", $1 + $2}')"
    COST_USD="$(echo "$COST_USD $SUB_COST" | LC_ALL=C awk '{printf "%.6f", $1 + $2}')"
  done
fi

# Project name = last path segment of cwd
PROJECT="$(basename "$CURRENT_DIR" 2>/dev/null)" || PROJECT="unknown"

# Current timestamp
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""

# Sanitize strings for SQL
SESSION_ID="${SESSION_ID//\'/\'\'}"
PROJECT="${PROJECT//\'/\'\'}"
MODEL_RAW="${MODEL_RAW//\'/\'\'}"
NOW="${NOW//\'/\'\'}"

# INSERT OR REPLACE into sessions (source='live', cost = theoretical API list price)
sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, started_at, ended_at, source, methodology_version) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${INPUT_TOKENS}, ${OUTPUT_TOKENS}, ${CACHE_READ}, ${CACHE_CREATION}, ${COST_USD}, ${CO2_G}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SESSION_ID}'), '${NOW}'), '${NOW}', 'live', ${METHODOLOGY_VERSION});" 2>/dev/null || true

exit 0
