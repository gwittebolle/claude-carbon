#!/usr/bin/env bash
# persist-on-exit.sh: SessionEnd hook, records the session one last time as it closes.
# The Stop hook only fires when a turn completes normally, so a turn interrupted with Esc
# and then a /exit, a /clear or a closed window would leave the session's tail out of the
# DB, and backfill.sh would only pick it up on a later day.
#
# SessionEnd hooks share a 1.5 s budget and are killed past it, and closing the window
# hangs up the process group; persist-session.sh can take longer than that on a long
# session with subagents. So the payload is saved to a file and the parse runs detached,
# after a short wait for the transcript's last asynchronous writes to land.
# Must exit 0 immediately in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"

PAYLOAD="$(mktemp "$(cc_tmpdir)/claude-carbon-end.XXXXXX" 2>/dev/null)" || {
  cat >/dev/null 2>&1
  exit 0
}
cat > "$PAYLOAD" 2>/dev/null || true

# Plugin hooks also run inside subagents, and the docs do not say which session_id and
# transcript a SessionEnd fired there would carry. A subagent's tokens are already summed
# into its parent's row from the subagents/ directory, so recording one on its own would
# count them twice. agent_id is only present inside a subagent: such a payload is dropped.
if jq -e 'has("agent_id")' "$PAYLOAD" >/dev/null 2>&1; then
  rm -f "$PAYLOAD"
  exit 0
fi

cc_detach bash -c 'sleep 2; bash "$1" < "$2"; rm -f "$2"' _ "${SCRIPT_DIR}/persist-session.sh" "$PAYLOAD"

exit 0
