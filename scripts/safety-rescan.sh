#!/usr/bin/env bash
# safety-rescan.sh — SessionStart hook: a throttled, backgrounded backfill that catches
# sessions the Stop hook missed (crash, kill, hook temporarily disabled), as long as their
# JSONL is still on disk (within Anthropic's ~30-day retention). backfill.sh uses
# INSERT OR IGNORE, so already-captured sessions are skipped cheaply.
# It is also where a plugin installed alone gets its database, once (see below).
# Must exit 0 immediately and never block session start.

# stdin is a terminal, not Claude Code's JSON: the Git Bash window case in statusline.sh.
[ -t 0 ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
DB_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")/claude-carbon"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${DB_DIR}/carbon.db}")"
STAMP="${DB_DIR}/.last-rescan"

# Drain stdin so the hook never blocks on an unread pipe
cat >/dev/null 2>&1 || true

# No database yet: the plugin installed alone, with no installer run. Create it once,
# with the history backfill.sh finds on disk, so the Stop hook records from then on.
#  - never when CLAUDE_CARBON_DB is set: a missing file there can be a synced folder not
#    yet downloaded or an unmounted volume, and a new database would shadow the real one;
#  - never twice: the `auto-setup` sentinel stays, so a database deleted on purpose is not
#    brought back (and two sessions starting together launch one backfill, not two). A
#    creation that failed is not retried either: deleting `auto-setup` asks for another;
#  - CLAUDE_CARBON_NO_AUTOSETUP turns it off;
#  - jq or sqlite3 missing: nothing is created, their names go to `setup-needed` for the
#    mod's pane to show, and the next session start tries again.
if [ ! -f "$DB_PATH" ]; then
  [ -z "${CLAUDE_CARBON_DB:-}" ] || exit 0
  [ -z "${CLAUDE_CARBON_NO_AUTOSETUP:-}" ] || exit 0
  [ -f "${DB_DIR}/auto-setup" ] && exit 0
  mkdir -p "$DB_DIR" 2>/dev/null || exit 0
  MISSING=""
  for CMD in jq sqlite3; do
    command -v "$CMD" >/dev/null 2>&1 || MISSING="${MISSING}${MISSING:+ }${CMD}"
  done
  if [ -n "$MISSING" ]; then
    printf '%s\n' "$MISSING" >"${DB_DIR}/setup-needed" 2>/dev/null
    exit 0
  fi
  rm -f "${DB_DIR}/setup-needed" 2>/dev/null
  # noclobber: only the first of two concurrent starts gets to create the sentinel
  ( set -C; echo 1 >"${DB_DIR}/auto-setup" ) 2>/dev/null || exit 0
  touch "$STAMP" 2>/dev/null || true
  cc_detach bash "${SCRIPT_DIR}/backfill.sh"
  exit 0
fi
rm -f "${DB_DIR}/setup-needed" 2>/dev/null

# The history the mod's /carbon-panel pane draws, ready before the session's first answer
# (the Stop hook refreshes it after each one). Detached: a database another session is
# writing could hold the read-only query for its busy timeout.
cc_detach bash -c '. "$1/portable-lib.sh" && cc_export_sessions "$2"' _ "$SCRIPT_DIR" "$DB_PATH"

# Daily "update available" check, fully detached. Its own throttle (keyed on the flag file's
# own age) so a failed/offline run self-heals next SessionStart, and it runs even on days the
# backfill below is throttled. A clone's flag is read by the statusline, a marketplace
# install's by the mod's pane.
UPD_FILE="${DB_DIR}/update-check.json"
cc_is_plugin_cache "$SCRIPT_DIR" && UPD_FILE="${DB_DIR}/plugin-update-check.json"
NEED_CHECK=1
if [ -f "$UPD_FILE" ] && command -v jq >/dev/null 2>&1; then
  CA="$(jq -r '.checked_at // 0' "$UPD_FILE" 2>/dev/null || echo 0)"
  [ "$(( $(date +%s) - CA ))" -lt 86400 ] 2>/dev/null && NEED_CHECK=0
fi
if [ "$NEED_CHECK" = "1" ]; then
  cc_detach bash "${SCRIPT_DIR}/check-update.sh"
fi

# Throttle: skip if a rescan ran in the last 24h
if [ -f "$STAMP" ]; then
  MTIME="$(cc_mtime "$STAMP")"
  AGE=$(( $(date +%s) - MTIME ))
  [ "$AGE" -lt 86400 ] && exit 0
fi

# Mark now, then run backfill fully detached so session start is never delayed
touch "$STAMP" 2>/dev/null || true
cc_detach bash "${SCRIPT_DIR}/backfill.sh"

exit 0
