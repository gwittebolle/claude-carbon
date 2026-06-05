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

# Drain stdin so the hook never blocks on an unread pipe
cat >/dev/null 2>&1 || true

# Only if the plugin is set up
[ -f "$DB_PATH" ] || exit 0

# Throttle: skip if a rescan ran in the last 24h
if [ -f "$STAMP" ]; then
  MTIME="$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
  AGE=$(( $(date +%s) - MTIME ))
  [ "$AGE" -lt 86400 ] && exit 0
fi

# Mark now, then run backfill fully detached so session start is never delayed
touch "$STAMP" 2>/dev/null || true
( setsid bash "${SCRIPT_DIR}/backfill.sh" >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1 || \
  ( bash "${SCRIPT_DIR}/backfill.sh" >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1

exit 0
