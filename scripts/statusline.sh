#!/usr/bin/env bash
set -euo pipefail

# statusline.sh — Reads Claude Code status JSON from stdin, outputs formatted CO2 status line.
# Usage: echo '{"session_id":...}' | statusline.sh
#        ... | statusline.sh --segment   (cost + CO2 only, for embedding in
#        another status line, e.g. a ccstatusline custom command widget)

SEGMENT_MODE=0
[ "${1:-}" = "--segment" ] && SEGMENT_MODE=1

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
if echo "$MODEL_ID" | grep -qiE "fable|mythos"; then
  MODEL_FAMILY="fable"
elif echo "$MODEL_ID" | grep -qi "opus"; then
  MODEL_FAMILY="opus"
elif echo "$MODEL_ID" | grep -qi "haiku"; then
  MODEL_FAMILY="haiku"
fi

# Load emission factors (zero for non-Anthropic models, e.g. local models
# behind ANTHROPIC_BASE_URL — a datacenter factor doesn't apply to them)
if echo "$MODEL_ID" | grep -qi "claude"; then
  FACTOR_IN="$(jq -r ".models.${MODEL_FAMILY}.input // 39" "$FACTORS_FILE")"
  FACTOR_OUT="$(jq -r ".models.${MODEL_FAMILY}.output // 826" "$FACTORS_FILE")"
else
  FACTOR_IN="0"
  FACTOR_OUT="0"
fi

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

# Segment mode stops here: no progress bar, no quota lookup (and so no
# network fallback), no git call. The host status line owns the rest.
if [ "$SEGMENT_MODE" = "1" ]; then
  echo "\$${COST_DISPLAY} · ${CO2_DISPLAY}"
  exit 0
fi

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

# 5-hour block usage via stdin (preferred) or Anthropic OAuth API (fallback).
# Canonical source: same data as `/usage` in Claude Code. Replaces ccusage heuristic.
USAGE_SEGMENT=""
if command -v jq &>/dev/null; then
  FIVE_PCT=""
  FIVE_RESET_ISO=""

  # Priority 1: Claude Code injects rate_limits in the statusline stdin JSON.
  FIVE_PCT="$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty')"
  FIVE_RESET_ISO="$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty')"

  # Priority 2: fallback to GET /api/oauth/usage with 60s cache.
  if [ -z "$FIVE_PCT" ]; then
    USAGE_CACHE_DIR="${HOME}/.claude/claude-carbon"
    USAGE_CACHE_FILE="${USAGE_CACHE_DIR}/oauth-usage.json"
    USAGE_CACHE_TTL=60
    mkdir -p "$USAGE_CACHE_DIR"

    NEEDS_REFRESH=1
    if [ -f "$USAGE_CACHE_FILE" ]; then
      CACHE_MTIME="$(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$USAGE_CACHE_FILE" 2>/dev/null || echo 0)"
      CACHE_AGE=$(( $(date +%s) - CACHE_MTIME ))
      [ "$CACHE_AGE" -lt "$USAGE_CACHE_TTL" ] && NEEDS_REFRESH=0
    fi

    if [ "$NEEDS_REFRESH" = "1" ]; then
      TOKEN=""
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
      elif command -v security &>/dev/null; then
        BLOB="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
        [ -n "$BLOB" ] && TOKEN="$(echo "$BLOB" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
      fi
      if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        CREDS="${HOME}/.claude/.credentials.json"
        [ -f "$CREDS" ] && TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)"
      fi

      if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        RESPONSE="$(curl -s --max-time 5 \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "User-Agent: claude-code/2.1.34" \
          "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)"
        if [ -n "$RESPONSE" ] && echo "$RESPONSE" | jq -e '.five_hour' >/dev/null 2>&1; then
          echo "$RESPONSE" > "$USAGE_CACHE_FILE"
        fi
      fi
    fi

    if [ -f "$USAGE_CACHE_FILE" ]; then
      FIVE_PCT="$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
      FIVE_RESET_ISO="$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
    fi
  fi

  if [ -n "$FIVE_PCT" ]; then
    USAGE_PCT_INT="$(echo "$FIVE_PCT" | LC_ALL=C awk '{printf "%.0f", $1}')"
    [ "$USAGE_PCT_INT" -gt 100 ] 2>/dev/null && USAGE_PCT_INT=100

    END_EPOCH=""
    RESET_LOCAL=""
    if [ -n "$FIVE_RESET_ISO" ]; then
      # Claude Code stdin passes resets_at as epoch (number); API returns ISO-8601 with fractional
      # seconds + tz offset (e.g. 2026-04-21T08:00:00.608966+00:00). Handle both.
      if [[ "$FIVE_RESET_ISO" =~ ^[0-9]+$ ]]; then
        END_EPOCH="$FIVE_RESET_ISO"
      else
        ISO_TRIM="${FIVE_RESET_ISO%%.*}"     # strip fractional seconds
        ISO_TRIM="${ISO_TRIM%%Z}"            # strip trailing Z
        ISO_TRIM="${ISO_TRIM%%+*}"           # strip +HH:MM offset
        END_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ISO_TRIM" "+%s" 2>/dev/null \
          || date -d "$FIVE_RESET_ISO" "+%s" 2>/dev/null || echo "")"
      fi
      if [ -n "$END_EPOCH" ]; then
        RESET_LOCAL="$(date -r "$END_EPOCH" "+%H:%M" 2>/dev/null \
          || date -d "@$END_EPOCH" "+%H:%M" 2>/dev/null || echo "")"
      fi
    fi

    # 🔥 when sustained burn rate over elapsed time would finish the 5h block
    # above 100% of the limit. 15 min grace + 15% floor to absorb bursty starts.
    # Block start derived as end - 5h (18000s).
    WARN=""
    if [ -n "$END_EPOCH" ] && [ "$USAGE_PCT_INT" -ge 15 ] 2>/dev/null; then
      NOW_EPOCH="$(date +%s)"
      START_EPOCH=$(( END_EPOCH - 18000 ))
      ELAPSED_SEC=$(( NOW_EPOCH - START_EPOCH ))
      if [ "$ELAPSED_SEC" -gt 900 ]; then
        HOT="$(echo "$FIVE_PCT $ELAPSED_SEC" | LC_ALL=C awk '{print (($1 * 18000 / $2) >= 100) ? "1" : "0"}')"
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

# Git branch (if in a git repo)
BRANCH_SUFFIX=""
if [ -n "$CURRENT_DIR" ] && command -v git &>/dev/null; then
  BRANCH="$(git -C "$CURRENT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] && BRANCH_SUFFIX=" ⌥ ${BRANCH}"
fi

# "Update available" notice — read-only, network-free. The remote check runs in the background
# (SessionStart hook → check-update.sh) and writes a cached flag; here we only read it. A 7-day
# staleness gate means an abandoned flag (background check stopped) self-clears.
UPDATE_SEGMENT=""
UPD_FILE="${HOME}/.claude/claude-carbon/update-check.json"
if [ -z "${CLAUDE_CARBON_NO_UPDATE_NOTIFIER:-}" ] && [ -f "$UPD_FILE" ] && command -v jq &>/dev/null; then
  if [ "$(jq -r '.behind // false' "$UPD_FILE" 2>/dev/null)" = "true" ]; then
    UPD_AT="$(jq -r '.checked_at // 0' "$UPD_FILE" 2>/dev/null || echo 0)"
    if [ "$UPD_AT" -gt 0 ] 2>/dev/null && [ "$(( $(date +%s) - UPD_AT ))" -lt 604800 ] 2>/dev/null; then
      UPDATE_SEGMENT=" | ⬆ /carbon-update"
    fi
  fi
fi

echo "${PROJECT}${BRANCH_SUFFIX} | ${DOT} ${DISPLAY_NAME} ${PROGRESS_BAR} ${PCT_DISPLAY} | \$${COST_DISPLAY} · ${CO2_DISPLAY}${USAGE_SEGMENT}${UPDATE_SEGMENT}"
