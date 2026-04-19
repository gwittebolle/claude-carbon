#!/usr/bin/env bash
set -euo pipefail

# statusline.sh — Reads Claude Code status JSON from stdin, outputs formatted CO2 status line.
# Usage: echo '{"session_id":...}' | statusline.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"

# Read stdin
INPUT="$(cat)"

# Extract fields with defaults to avoid failures on null
MODEL_ID="$(echo "$INPUT" | jq -r '.model.id // ""')"
DISPLAY_NAME="$(echo "$INPUT" | jq -r '.model.display_name // "Unknown model"' | sed -E 's/ *\((1M|200K) context\)//')"
INPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')"
OUTPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')"
COST_USD="$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')"
USED_PCT="$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')"
CURRENT_DIR="$(echo "$INPUT" | jq -r '.workspace.current_dir // ""')"

# Project name = last path segment
PROJECT="$(basename "$CURRENT_DIR")"

# Resolve model family
MODEL_FAMILY="sonnet"
if echo "$MODEL_ID" | grep -qi "opus"; then
  MODEL_FAMILY="opus"
elif echo "$MODEL_ID" | grep -qi "haiku"; then
  MODEL_FAMILY="haiku"
fi

# Load emission factors
FACTOR_IN="$(jq -r ".models.${MODEL_FAMILY}.input" "$FACTORS_FILE")"
FACTOR_OUT="$(jq -r ".models.${MODEL_FAMILY}.output" "$FACTORS_FILE")"

# Calculate CO2 in grams: (input * factor_in + output * factor_out) / 1_000_000
CO2_G="$(echo "$INPUT_TOKENS $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | LC_ALL=C awk '{printf "%.0f", ($1 * $2 + $3 * $4) / 1000000}')"

# Format CO2 with adaptive unit
if [ "$CO2_G" -ge 1000 ] 2>/dev/null; then
  CO2_DISPLAY="$(echo "$CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}') CO₂"
else
  CO2_DISPLAY="${CO2_G}g CO₂"
fi

# Round cost to 2 decimals
COST_DISPLAY="$(echo "$COST_USD" | LC_ALL=C awk '{printf "%.2f", $1}')"

# Build progress bar (10 blocks)
FILLED=$(( USED_PCT * 10 / 100 ))
EMPTY=$(( 10 - FILLED ))
PROGRESS_BAR=""
for ((i=0; i<FILLED; i++)); do PROGRESS_BAR="${PROGRESS_BAR}▓"; done
for ((i=0; i<EMPTY; i++)); do PROGRESS_BAR="${PROGRESS_BAR}░"; done

# Color dot and percentage display
if [ "$USED_PCT" -ge 80 ]; then
  DOT="🔴"
  PCT_DISPLAY="COMPACT!"
elif [ "$USED_PCT" -ge 60 ]; then
  DOT="🟡"
  PCT_DISPLAY="${USED_PCT}%"
else
  DOT="🟢"
  PCT_DISPLAY="${USED_PCT}%"
fi

# 5-hour block usage (ccusage) with background-refresh cache
USAGE_SEGMENT=""
if command -v jq &>/dev/null; then
  USAGE_CACHE_DIR="${HOME}/.claude/claude-carbon"
  USAGE_CACHE_FILE="${USAGE_CACHE_DIR}/block-usage.json"
  USAGE_CACHE_TTL="${CLAUDE_CARBON_USAGE_TTL:-30}"
  mkdir -p "$USAGE_CACHE_DIR"

  if [ -f "$USAGE_CACHE_FILE" ]; then
    CACHE_MTIME="$(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$USAGE_CACHE_FILE" 2>/dev/null || echo 0)"
    CACHE_AGE=$(( $(date +%s) - CACHE_MTIME ))
  else
    CACHE_AGE=999999
  fi

  # Trigger async refresh if stale. Uses npx -y ccusage@latest; first run ~15s, subsequent cached.
  if [ "$CACHE_AGE" -gt "$USAGE_CACHE_TTL" ]; then
    LOCK_FILE="${USAGE_CACHE_FILE}.lock"
    if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
      (
        trap 'rm -f "$LOCK_FILE"' EXIT
        if npx -y ccusage@latest blocks --active --json --token-limit max --offline > "${USAGE_CACHE_FILE}.tmp" 2>/dev/null; then
          mv "${USAGE_CACHE_FILE}.tmp" "$USAGE_CACHE_FILE"
        else
          rm -f "${USAGE_CACHE_FILE}.tmp"
        fi
      ) </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  fi

  # Render from cache if available (even if stale).
  # Effective token limit precedence:
  #   1. $USAGE_CACHE_DIR/token-limit (learned ceiling, auto-bumps when a block exceeds it)
  #   2. $CLAUDE_CARBON_TOKEN_LIMIT env var (seeds the learned file on first run)
  #   3. ccusage heuristic (highest observed block, inaccurate on Max 20x until saturated)
  # Discover the real number via /usage in Claude Code; the learned file will
  # grow automatically on any block that overshoots it.
  LIMIT_STATE_FILE="${USAGE_CACHE_DIR}/token-limit"
  if [ -f "$USAGE_CACHE_FILE" ]; then
    TOTAL_TOKENS="$(jq -r '.blocks[0].totalTokens // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
    CCUSAGE_LIMIT="$(jq -r '.blocks[0].tokenLimitStatus.limit // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
    END_TIME="$(jq -r '.blocks[0].endTime // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
    START_TIME="$(jq -r '.blocks[0].startTime // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"

    LEARNED_LIMIT=""
    [ -f "$LIMIT_STATE_FILE" ] && LEARNED_LIMIT="$(cat "$LIMIT_STATE_FILE" 2>/dev/null | tr -cd '0-9')"
    # First-run seed: if env var set and no learned file yet, seed it
    if [ -z "$LEARNED_LIMIT" ] && [ -n "${CLAUDE_CARBON_TOKEN_LIMIT:-}" ]; then
      LEARNED_LIMIT="$CLAUDE_CARBON_TOKEN_LIMIT"
      echo "$LEARNED_LIMIT" > "$LIMIT_STATE_FILE" 2>/dev/null || true
    fi
    TOKEN_LIMIT="${LEARNED_LIMIT:-$CCUSAGE_LIMIT}"

    # Auto-bump: if current block already exceeded the limit, raise the ceiling
    if [ -n "$TOTAL_TOKENS" ] && [ -n "$TOKEN_LIMIT" ]; then
      if [ "$TOTAL_TOKENS" -gt "$TOKEN_LIMIT" ] 2>/dev/null; then
        TOKEN_LIMIT="$TOTAL_TOKENS"
        echo "$TOKEN_LIMIT" > "$LIMIT_STATE_FILE" 2>/dev/null || true
      fi
    fi

    if [ -n "$TOTAL_TOKENS" ] && [ -n "$TOKEN_LIMIT" ] && [ -n "$END_TIME" ]; then
      USAGE_PCT="$(echo "$TOTAL_TOKENS $TOKEN_LIMIT" | LC_ALL=C awk '{printf "%.2f", ($2 > 0) ? ($1 / $2 * 100) : 0}')"
      USAGE_PCT_INT="$(echo "$USAGE_PCT" | LC_ALL=C awk '{printf "%.0f", $1}')"
      [ "$USAGE_PCT_INT" -gt 100 ] 2>/dev/null && USAGE_PCT_INT=100
      # Parse endTime (ISO-8601 UTC) to local HH:MM
      RESET_LOCAL="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${END_TIME%.*}" "+%H:%M" 2>/dev/null \
        || date -d "$END_TIME" "+%H:%M" 2>/dev/null || echo "")"
      # 🔥 when sustained burn rate over elapsed time would finish the 5h block
      # above 100% of the limit. 15 min grace to absorb bursty starts.
      WARN=""
      if [ -n "$START_TIME" ] && [ "$USAGE_PCT_INT" -ge 15 ] 2>/dev/null; then
        START_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${START_TIME%.*}" "+%s" 2>/dev/null \
          || date -d "$START_TIME" "+%s" 2>/dev/null || echo 0)"
        NOW_EPOCH="$(date +%s)"
        ELAPSED_SEC=$(( NOW_EPOCH - START_EPOCH ))
        if [ "$ELAPSED_SEC" -gt 900 ]; then
          HOT="$(echo "$USAGE_PCT $ELAPSED_SEC" | LC_ALL=C awk '{print (($1 * 18000 / $2) >= 100) ? "1" : "0"}')"
          [ "$HOT" = "1" ] && WARN="🔥 "
        fi
      fi
      if [ -n "$RESET_LOCAL" ]; then
        USAGE_SEGMENT=" | ${WARN}Use ${USAGE_PCT_INT}% ↻${RESET_LOCAL}"
      else
        USAGE_SEGMENT=" | ${WARN}Use ${USAGE_PCT_INT}%"
      fi
    fi
  fi
fi

# Git branch (if in a git repo)
BRANCH_SUFFIX=""
if [ -n "$CURRENT_DIR" ] && command -v git &>/dev/null; then
  BRANCH="$(git -C "$CURRENT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] && BRANCH_SUFFIX=" ⌥ ${BRANCH}"
fi

echo "${PROJECT}${BRANCH_SUFFIX} | ${DOT} ${DISPLAY_NAME} ${PROGRESS_BAR} ${PCT_DISPLAY} | \$${COST_DISPLAY} · ${CO2_DISPLAY}${USAGE_SEGMENT}"
