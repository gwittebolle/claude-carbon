#!/usr/bin/env bash
set -euo pipefail

# backfill.sh — Parse all historical Claude Code JSONL transcripts and insert into carbon.db.

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

ADDED=0
SKIPPED=0
ERRORS=0

# UUID regex pattern
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Scan all JSONL files under ~/.claude/projects/, max 2 levels deep
# Exclude subagents/ and vercel-plugin/ directories
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

  # Skip if already in DB
  EXISTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}';")"
  if [ "$EXISTS" -gt 0 ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Extract project name from parent directory
  # Dir structure: ~/.claude/projects/<project-dir>/<session>.jsonl
  # project-dir is like: -Users-username-path-to-project
  PROJECT_DIR="$(basename "$(dirname "$JSONL_FILE")")"
  # Strip leading dashes and get last segment (after last -)
  # Replace all - with / then take last segment
  PROJECT="$(echo "$PROJECT_DIR" | tr '-' '\n' | tail -1)"
  if [ -z "$PROJECT" ]; then
    PROJECT="unknown"
  fi

  # Parse the JSONL file to aggregate tokens
  # Use jq to process the file: only select assistant messages with usage data
  AGGREGATED="$(jq -s '
    [.[] | select(.type == "assistant" and .message.usage != null)] |
    {
      input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
      cache_creation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      cache_read: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
      output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
      models: ([.[] | .message.model // ""] | map(select(length > 0))),
      first_ts: (map(.timestamp // "") | map(select(length > 0)) | sort | first // ""),
      last_ts: (map(.timestamp // "") | map(select(length > 0)) | sort | last // "")
    } |
    .total_input = (.input_tokens + .cache_creation + .cache_read)
  ' "$JSONL_FILE" 2>/dev/null)" || { ERRORS=$((ERRORS + 1)); continue; }

  TOTAL_INPUT="$(echo "$AGGREGATED" | jq -r '.total_input // 0')"
  OUTPUT_TOKENS="$(echo "$AGGREGATED" | jq -r '.output_tokens // 0')"
  FIRST_TS="$(echo "$AGGREGATED" | jq -r '.first_ts // ""')"
  LAST_TS="$(echo "$AGGREGATED" | jq -r '.last_ts // ""')"

  # Skip empty sessions
  if [ "$TOTAL_INPUT" -eq 0 ] && [ "$OUTPUT_TOKENS" -eq 0 ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get most common model
  MODEL_RAW="$(echo "$AGGREGATED" | jq -r '
    .models |
    if length == 0 then "claude-sonnet"
    else
      group_by(.) | sort_by(-length) | first | first
    end
  ')"

  # Resolve model family
  MODEL_FAMILY="sonnet"
  if echo "$MODEL_RAW" | grep -qi "opus"; then
    MODEL_FAMILY="opus"
  elif echo "$MODEL_RAW" | grep -qi "haiku"; then
    MODEL_FAMILY="haiku"
  fi

  # Assign pricing and factors based on family
  case "$MODEL_FAMILY" in
    opus)
      PRICE_IN="15"
      PRICE_OUT="75"
      FACTOR_IN="$FACTOR_OPUS_IN"
      FACTOR_OUT="$FACTOR_OPUS_OUT"
      ;;
    haiku)
      PRICE_IN="0.80"
      PRICE_OUT="4"
      FACTOR_IN="$FACTOR_HAIKU_IN"
      FACTOR_OUT="$FACTOR_HAIKU_OUT"
      ;;
    *)
      PRICE_IN="3"
      PRICE_OUT="15"
      FACTOR_IN="$FACTOR_SONNET_IN"
      FACTOR_OUT="$FACTOR_SONNET_OUT"
      ;;
  esac

  # Estimate cost (per million tokens)
  COST_USD="$(echo "$TOTAL_INPUT $PRICE_IN $OUTPUT_TOKENS $PRICE_OUT" | awk '{printf "%.6f", ($1 * $2 + $3 * $4) / 1000000}')"

  # Calculate CO2
  CO2_G="$(echo "$TOTAL_INPUT $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}')"

  # Insert into DB
  sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${TOTAL_INPUT}, ${OUTPUT_TOKENS}, ${COST_USD}, ${CO2_G}, '${FIRST_TS}', '${LAST_TS}', 'backfill');" 2>/dev/null || { ERRORS=$((ERRORS + 1)); continue; }

  ADDED=$((ADDED + 1))

done < <(find "${HOME}/.claude/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null)

echo "  Backfill complete: ${ADDED} sessions added, ${SKIPPED} skipped, ${ERRORS} errors."
