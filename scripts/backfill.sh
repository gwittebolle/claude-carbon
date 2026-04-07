#!/usr/bin/env bash
set -euo pipefail

# backfill.sh — Parse all historical Claude Code JSONL transcripts and insert into carbon.db.
# Includes subagent JSONL files in the calculation (each with its own model/factor).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

# Load emission factors once
FACTOR_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE")"
FACTOR_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE")"
FACTOR_SONNET_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE")"
FACTOR_SONNET_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE")"
FACTOR_HAIKU_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE")"
FACTOR_HAIKU_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE")"

# Pricing per million tokens
PRICE_OPUS_IN="15"; PRICE_OPUS_OUT="75"
PRICE_SONNET_IN="3"; PRICE_SONNET_OUT="15"
PRICE_HAIKU_IN="0.80"; PRICE_HAIKU_OUT="4"

ADDED=0
SKIPPED=0
ERRORS=0

# UUID regex pattern
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Helper: aggregate tokens from a JSONL file (excludes cache_read)
# Tries fast jq -s first, falls back to line-by-line for corrupted files
aggregate_jsonl() {
  local file="$1"
  local result
  # Fast path: slurp entire file
  result="$(jq -s '
    [.[] | select(.type == "assistant" and .message.usage != null)] |
    {
      input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
      cache_creation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
      models: ([.[] | .message.model // ""] | map(select(length > 0))),
      first_ts: (map(.timestamp // "") | map(select(length > 0)) | sort | first // ""),
      last_ts: (map(.timestamp // "") | map(select(length > 0)) | sort | last // "")
    } |
    .total_input = (.input_tokens + .cache_creation)
  ' "$file" 2>/dev/null)" && echo "$result" && return 0

  # Slow path: line-by-line (tolerates corrupted lines)
  while IFS= read -r line; do
    echo "$line" | jq 'select(.type == "assistant" and .message.usage != null) | {
      input_tokens: (.message.usage.input_tokens // 0),
      cache_creation: (.message.usage.cache_creation_input_tokens // 0),
      output_tokens: (.message.usage.output_tokens // 0),
      model: (.message.model // ""),
      ts: (.timestamp // "")
    }' 2>/dev/null
  done < "$file" | jq -s '{
    input_tokens: (map(.input_tokens) | add // 0),
    cache_creation: (map(.cache_creation) | add // 0),
    output_tokens: (map(.output_tokens) | add // 0),
    models: [.[].model | select(length > 0)],
    first_ts: ([.[].ts | select(length > 0)] | sort | first // ""),
    last_ts: ([.[].ts | select(length > 0)] | sort | last // "")
  } | .total_input = (.input_tokens + .cache_creation)' 2>/dev/null
}

# Helper: resolve model family from model string
resolve_family() {
  local model="$1"
  if echo "$model" | grep -qi "opus"; then echo "opus"
  elif echo "$model" | grep -qi "haiku"; then echo "haiku"
  else echo "sonnet"
  fi
}

# Helper: get factors and pricing for a model family
get_factor_in() {
  case "$1" in
    opus) echo "$FACTOR_OPUS_IN" ;; haiku) echo "$FACTOR_HAIKU_IN" ;; *) echo "$FACTOR_SONNET_IN" ;;
  esac
}
get_factor_out() {
  case "$1" in
    opus) echo "$FACTOR_OPUS_OUT" ;; haiku) echo "$FACTOR_HAIKU_OUT" ;; *) echo "$FACTOR_SONNET_OUT" ;;
  esac
}
get_price_in() {
  case "$1" in
    opus) echo "$PRICE_OPUS_IN" ;; haiku) echo "$PRICE_HAIKU_IN" ;; *) echo "$PRICE_SONNET_IN" ;;
  esac
}
get_price_out() {
  case "$1" in
    opus) echo "$PRICE_OPUS_OUT" ;; haiku) echo "$PRICE_HAIKU_OUT" ;; *) echo "$PRICE_SONNET_OUT" ;;
  esac
}

# Helper: compute CO2 and cost for a JSONL file with its own model
compute_co2_cost() {
  local aggregated="$1"
  local total_in out family fin fout pin pout co2 cost

  total_in="$(echo "$aggregated" | jq -r '.total_input // 0')"
  out="$(echo "$aggregated" | jq -r '.output_tokens // 0')"

  local model_raw
  model_raw="$(echo "$aggregated" | jq -r '
    .models |
    if length == 0 then "claude-sonnet"
    else group_by(.) | sort_by(-length) | first | first
    end
  ')"

  family="$(resolve_family "$model_raw")"
  fin="$(get_factor_in "$family")"
  fout="$(get_factor_out "$family")"
  pin="$(get_price_in "$family")"
  pout="$(get_price_out "$family")"

  co2="$(echo "$total_in $fin $out $fout" | LC_ALL=C awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}')"
  cost="$(echo "$total_in $pin $out $pout" | LC_ALL=C awk '{printf "%.6f", ($1 * $2 + $3 * $4) / 1000000}')"

  echo "$total_in $out $co2 $cost"
}

# Scan all JSONL files under ~/.claude/projects/, max 2 levels deep
# Exclude subagents/ and vercel-plugin/ directories (subagents are handled per session)
while IFS= read -r JSONL_FILE; do
  # Skip files in excluded directories
  if echo "$JSONL_FILE" | grep -qE '/(subagents|vercel-plugin)/'; then
    continue
  fi

  # Extract session_id from filename (basename without extension)
  FILENAME="$(basename "$JSONL_FILE" .jsonl)"

  # Must match UUID pattern
  if ! echo "$FILENAME" | grep -qiE "$UUID_PATTERN"; then
    continue
  fi

  SESSION_ID="$FILENAME"

  # Skip if already in DB (SESSION_ID is a validated UUID, safe for SQL)
  EXISTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}';")"
  if [ "$EXISTS" -gt 0 ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Extract project name from parent directory
  PROJECT_DIR="$(basename "$(dirname "$JSONL_FILE")")"
  PROJECT="$(echo "$PROJECT_DIR" | tr '-' '\n' | tail -1)"
  if [ -z "$PROJECT" ]; then
    PROJECT="unknown"
  fi

  # Aggregate main session JSONL
  AGGREGATED="$(aggregate_jsonl "$JSONL_FILE")" || { ERRORS=$((ERRORS + 1)); continue; }

  FIRST_TS="$(echo "$AGGREGATED" | jq -r '.first_ts // ""')"
  LAST_TS="$(echo "$AGGREGATED" | jq -r '.last_ts // ""')"

  # Compute CO2/cost for main session
  read -r TOTAL_INPUT OUTPUT_TOKENS CO2_G COST_USD <<< "$(compute_co2_cost "$AGGREGATED")"

  # Aggregate subagent JSONL files (each has its own model)
  SUBAGENT_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
  if [ -d "$SUBAGENT_DIR" ]; then
    for SUB_FILE in "$SUBAGENT_DIR"/*.jsonl; do
      [ -f "$SUB_FILE" ] || continue
      SUB_AGG="$(aggregate_jsonl "$SUB_FILE")" || continue

      read -r SUB_IN SUB_OUT SUB_CO2 SUB_COST <<< "$(compute_co2_cost "$SUB_AGG")"

      # Add to session totals
      TOTAL_INPUT="$(echo "$TOTAL_INPUT $SUB_IN" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      OUTPUT_TOKENS="$(echo "$OUTPUT_TOKENS $SUB_OUT" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      CO2_G="$(echo "$CO2_G $SUB_CO2" | LC_ALL=C awk '{printf "%.4f", $1 + $2}')"
      COST_USD="$(echo "$COST_USD $SUB_COST" | LC_ALL=C awk '{printf "%.6f", $1 + $2}')"

      # Update last timestamp if subagent ran later
      SUB_LAST="$(echo "$SUB_AGG" | jq -r '.last_ts // ""')"
      if [ -n "$SUB_LAST" ] && [[ "$SUB_LAST" > "$LAST_TS" ]]; then
        LAST_TS="$SUB_LAST"
      fi
    done
  fi

  # Skip empty sessions
  if [ "$TOTAL_INPUT" -eq 0 ] 2>/dev/null && [ "$OUTPUT_TOKENS" -eq 0 ] 2>/dev/null; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get main model for display
  MODEL_RAW="$(echo "$AGGREGATED" | jq -r '
    .models |
    if length == 0 then "claude-sonnet"
    else group_by(.) | sort_by(-length) | first | first
    end
  ')"

  # Sanitize strings for SQL (escape single quotes)
  PROJECT="${PROJECT//\'/\'\'}"
  MODEL_RAW="${MODEL_RAW//\'/\'\'}"
  FIRST_TS="${FIRST_TS//\'/\'\'}"
  LAST_TS="${LAST_TS//\'/\'\'}"

  # Insert into DB
  sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${TOTAL_INPUT}, ${OUTPUT_TOKENS}, ${COST_USD}, ${CO2_G}, '${FIRST_TS}', '${LAST_TS}', 'backfill');" 2>/dev/null || { ERRORS=$((ERRORS + 1)); continue; }

  ADDED=$((ADDED + 1))

done < <(find "${HOME}/.claude/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null)

echo "  Backfill complete: ${ADDED} sessions added, ${SKIPPED} skipped, ${ERRORS} errors."
