#!/usr/bin/env bash
set -euo pipefail

# backfill.sh — Parse all historical Claude Code JSONL transcripts and insert into carbon.db.
# Includes subagent JSONL files in the calculation (each with its own model/factor).
# Deduplicates assistant messages by (message.id, requestId) so resumed/compacted sessions
# that replay prior messages within a file are not double-counted (matches ccusage).
# Stores raw token counts (input, cache_write, cache_read, output) per session so cost and
# CO2 can be re-derived later via recompute.sh without the (30-day-purged) JSONL.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
DB_PATH="${CLAUDE_CARBON_DB:-${HOME}/.claude/claude-carbon/carbon.db}"

# Rows written by this version of the methodology (raw-token columns populated).
METHODOLOGY_VERSION=2

# Ensure schema exists and is migrated (idempotent; safe on fresh or pre-existing DBs).
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true

# Load emission factors once (gCO2e per million tokens)
FACTOR_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE")"
FACTOR_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE")"
FACTOR_SONNET_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE")"
FACTOR_SONNET_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE")"
FACTOR_HAIKU_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE")"
FACTOR_HAIKU_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE")"
# Energy of a cache_read token as a fraction of an uncached input token (see METHODOLOGY.md).
CACHE_READ_FACTOR="$(jq -r '.cache_read_factor // 0.08' "$FACTORS_FILE")"

# Load pricing once (USD per million tokens, current Anthropic list price)
PRICE_OPUS_IN="$(jq -r '.models.opus.input' "$PRICES_FILE")";     PRICE_OPUS_OUT="$(jq -r '.models.opus.output' "$PRICES_FILE")"
PRICE_SONNET_IN="$(jq -r '.models.sonnet.input' "$PRICES_FILE")"; PRICE_SONNET_OUT="$(jq -r '.models.sonnet.output' "$PRICES_FILE")"
PRICE_HAIKU_IN="$(jq -r '.models.haiku.input' "$PRICES_FILE")";   PRICE_HAIKU_OUT="$(jq -r '.models.haiku.output' "$PRICES_FILE")"
CACHE_WRITE_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$PRICES_FILE")"
CACHE_READ_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$PRICES_FILE")"

ADDED=0
SKIPPED=0
ERRORS=0

# UUID regex pattern
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Helper: aggregate tokens from a JSONL file.
# Deduplicates assistant messages by (message.id|requestId), keeping the LAST occurrence
# (streaming snapshots grow output_tokens; the last carries the final value). Tracks
# input, cache_creation (write), cache_read, and output separately.
# Tries fast jq -s first, falls back to line-by-line for corrupted files.
aggregate_jsonl() {
  local file="$1"
  local result
  # Fast path: slurp entire file
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
        models:         ($d | map(.message.model // "") | map(select(length > 0))),
        first_ts:       ($d | map(.timestamp // "") | map(select(length > 0)) | sort | first // ""),
        last_ts:        ($d | map(.timestamp // "") | map(select(length > 0)) | sort | last // "")
      }
  ' "$file" 2>/dev/null)" && echo "$result" && return 0

  # Slow path: line-by-line (tolerates corrupted lines), same dedup applied at the end.
  while IFS= read -r line; do
    echo "$line" | jq -c 'select(.type == "assistant" and .message.usage != null) | {
      input_tokens: (.message.usage.input_tokens // 0),
      cache_creation: (.message.usage.cache_creation_input_tokens // 0),
      cache_read: (.message.usage.cache_read_input_tokens // 0),
      output_tokens: (.message.usage.output_tokens // 0),
      model: (.message.model // ""),
      id: (.message.id // null),
      rid: (.requestId // null),
      ts: (.timestamp // "")
    }' 2>/dev/null
  done < "$file" | jq -s '
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
        models:         ($d | map(.model) | map(select(length > 0))),
        first_ts:       ($d | map(.ts) | map(select(length > 0)) | sort | first // ""),
        last_ts:        ($d | map(.ts) | map(select(length > 0)) | sort | last // "")
      }
  ' 2>/dev/null
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

# Helper: compute CO2 and theoretical API cost for a JSONL file with its own model.
# CO2  = (input + cache_write) * factor_in + cache_read * (factor_in * CACHE_READ_FACTOR) + output * factor_out
# Cost = input * pin + cache_write * (CACHE_WRITE_MULT*pin) + cache_read * (CACHE_READ_MULT*pin) + output * pout
# Returns: total_input(=input+cache_write) cache_creation cache_read output co2 cost
compute_co2_cost() {
  local aggregated="$1"
  local it cw cr out family fin fout pin pout co2 cost total_input model_raw

  it="$(echo "$aggregated" | jq -r '.input_tokens // 0')"
  cw="$(echo "$aggregated" | jq -r '.cache_creation // 0')"
  cr="$(echo "$aggregated" | jq -r '.cache_read // 0')"
  out="$(echo "$aggregated" | jq -r '.output_tokens // 0')"

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

  co2="$(echo "$it $cw $cr $out $fin $fout $CACHE_READ_FACTOR" | LC_ALL=C awk \
    '{printf "%.4f", (($1 + $2) * $5 + $3 * ($5 * $7) + $4 * $6) / 1000000}')"
  cost="$(echo "$it $cw $cr $out $pin $pout $CACHE_WRITE_MULT $CACHE_READ_MULT" | LC_ALL=C awk \
    '{printf "%.6f", ($1 * $5 + $2 * ($5 * $7) + $3 * ($5 * $8) + $4 * $6) / 1000000}')"

  total_input="$(echo "$it $cw" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
  echo "$total_input $cw $cr $out $co2 $cost"
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

  # Project name = basename of the session's cwd, matching persist-session.sh.
  # The transcript directory name encodes the full path with hyphens, so real
  # hyphens in project names cannot be recovered from it.
  PROJECT_CWD="$(jq -rn 'first(inputs | .cwd? // empty)' "$JSONL_FILE" 2>/dev/null || true)"
  if [ -n "$PROJECT_CWD" ]; then
    PROJECT="$(basename "$PROJECT_CWD")"
  else
    PROJECT="unknown"
  fi

  # Aggregate main session JSONL
  AGGREGATED="$(aggregate_jsonl "$JSONL_FILE")" || { ERRORS=$((ERRORS + 1)); continue; }

  FIRST_TS="$(echo "$AGGREGATED" | jq -r '.first_ts // ""')"
  LAST_TS="$(echo "$AGGREGATED" | jq -r '.last_ts // ""')"

  # Compute CO2/cost for main session
  read -r TOTAL_INPUT CACHE_CREATION CACHE_READ OUTPUT_TOKENS CO2_G COST_USD <<< "$(compute_co2_cost "$AGGREGATED")"

  # Aggregate subagent JSONL files (each has its own model)
  SUBAGENT_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
  if [ -d "$SUBAGENT_DIR" ]; then
    for SUB_FILE in "$SUBAGENT_DIR"/*.jsonl; do
      [ -f "$SUB_FILE" ] || continue
      SUB_AGG="$(aggregate_jsonl "$SUB_FILE")" || continue

      read -r SUB_IN SUB_CW SUB_CR SUB_OUT SUB_CO2 SUB_COST <<< "$(compute_co2_cost "$SUB_AGG")"

      # Add to session totals
      TOTAL_INPUT="$(echo "$TOTAL_INPUT $SUB_IN" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      CACHE_CREATION="$(echo "$CACHE_CREATION $SUB_CW" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
      CACHE_READ="$(echo "$CACHE_READ $SUB_CR" | LC_ALL=C awk '{printf "%d", $1 + $2}')"
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
  sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, started_at, ended_at, source, methodology_version) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${TOTAL_INPUT}, ${OUTPUT_TOKENS}, ${CACHE_READ}, ${CACHE_CREATION}, ${COST_USD}, ${CO2_G}, '${FIRST_TS}', '${LAST_TS}', 'backfill', ${METHODOLOGY_VERSION});" 2>/dev/null || { ERRORS=$((ERRORS + 1)); continue; }

  ADDED=$((ADDED + 1))

done < <(find "${HOME}/.claude/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null)

echo "  Backfill complete: ${ADDED} sessions added, ${SKIPPED} skipped, ${ERRORS} errors."
