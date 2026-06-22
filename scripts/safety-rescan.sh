#!/usr/bin/env bash
# safety-rescan.sh — SessionStart hook: a throttled, backgrounded backfill that catches
# sessions the Stop hook missed (crash, kill, hook temporarily disabled), as long as their
# JSONL is still on disk (within Anthropic's ~30-day retention). backfill.sh uses
# INSERT OR IGNORE, so already-captured sessions are skipped cheaply.
# Must exit 0 immediately and never block session start.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${HOME}/.claude/claude-carbon"
DB_PATH="${CLAUDE_CARBON_DB:-${DB_DIR}/carbon.db}"
STAMP="${DB_DIR}/.last-rescan"

# Portable detach: fully background a command so it survives session-start exit. setsid is
# absent on macOS, so probe it. (The old `( setsid … & ) || ( … & )` idiom never reached its
# fallback, because backgrounding always makes the subshell exit 0 — so on macOS nothing ran.)
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 </dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" >/dev/null 2>&1 </dev/null &
  else
    "$@" >/dev/null 2>&1 </dev/null &
  fi
}

# Drain stdin so the hook never blocks on an unread pipe
cat >/dev/null 2>&1 || true

# Only if the plugin is set up
[ -f "$DB_PATH" ] || exit 0

# Daily "update available" check, fully detached. Its own throttle (keyed on the flag file's
# own age) so a failed/offline run self-heals next SessionStart, and it runs even on days the
# backfill below is throttled. The statusline only ever reads the flag this writes.
UPD_FILE="${DB_DIR}/update-check.json"
NEED_CHECK=1
if [ -f "$UPD_FILE" ] && command -v jq >/dev/null 2>&1; then
  CA="$(jq -r '.checked_at // 0' "$UPD_FILE" 2>/dev/null || echo 0)"
  [ "$(( $(date +%s) - CA ))" -lt 86400 ] 2>/dev/null && NEED_CHECK=0
fi
if [ "$NEED_CHECK" = "1" ]; then
  detach bash "${SCRIPT_DIR}/check-update.sh"
fi

# Throttle: skip if a rescan ran in the last 24h
if [ -f "$STAMP" ]; then
  MTIME="$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
  AGE=$(( $(date +%s) - MTIME ))
  [ "$AGE" -lt 86400 ] && exit 0
fi

# Mark now, then run backfill fully detached so session start is never delayed
touch "$STAMP" 2>/dev/null || true
detach bash "${SCRIPT_DIR}/backfill.sh"

exit 0
