#!/usr/bin/env bash
# run-session-end-tests.sh: assert that a session's tail reaches the DB when its last turn
# never completed (Esc, then /exit, /clear or a closed window), so the Stop hook never ran
# for it: (a) the SessionEnd hook returns at once and records the session from a detached
# process, (b) backfill.sh refreshes a row whose transcript grew after it was written, and
# leaves an up-to-date row alone, (c) the plugin manifest wires SessionEnd.
#
# Every case runs against throwaway dirs (CLAUDE_CONFIG_DIR, TMPDIR); the real ~/.claude is
# never read or written. Whether Claude Code runs SessionEnd when the window closes is
# Claude Code's own behaviour and is not asserted here.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: sqlite3, jq, awk.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"
ON_EXIT="${REPO_DIR}/scripts/persist-on-exit.sh"
BACKFILL="${REPO_DIR}/scripts/backfill.sh"

for c in sqlite3 jq awk; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done
[ -f "$ON_EXIT" ] || { echo "FAIL: missing $ON_EXIT" >&2; exit 1; }

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-end-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-end-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0

ok() {   PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() {  FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; }

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

SCHEMA="CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0);"

# write_turn <transcript> <n> <output_tokens>: one user prompt and the API call that answered it.
write_turn() {
  cat >> "$1" <<EOF
{"type":"user","cwd":"/tmp/endproj","timestamp":"2026-09-10T10:0${2}:00Z","message":{"role":"user","content":"turn ${2}"}}
{"type":"assistant","cwd":"/tmp/endproj","requestId":"req_${2}","timestamp":"2026-09-10T10:0${2}:05Z","message":{"id":"msg_${2}","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":${3}}}}
EOF
}

# ---------------------------------------------------------------- 1. SessionEnd hook

CFG="${TMPROOT}/cfg"
DB="${CFG}/claude-carbon/carbon.db"
SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="${CFG}/projects/-tmp-endproj/${SESSION}.jsonl"
# The hook keeps its payload under TMPDIR until the detached run is done with it.
HOOK_TMP="${TMPROOT}/hooktmp"
mkdir -p "${CFG}/claude-carbon" "$(dirname "$TRANSCRIPT")" "$HOOK_TMP"
sqlite3 "$DB" "$SCHEMA"
PAYLOAD="$(jq -n --arg s "$SESSION" --arg t "$TRANSCRIPT" '{session_id: $s, transcript_path: $t, cwd: "/tmp/endproj", hook_event_name: "SessionEnd", reason: "other"}')"
out_tokens() { sqlite3 "$1" "SELECT output_tokens FROM sessions WHERE session_id='$2';" 2>/dev/null; }

# Turn 1 completes and the Stop hook records it.
write_turn "$TRANSCRIPT" 1 100
echo "$PAYLOAD" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "Stop hook: first turn recorded" "100" "$(out_tokens "$DB" "$SESSION")"

# Turn 2 is interrupted: its API call reaches the transcript, the Stop hook never runs.
write_turn "$TRANSCRIPT" 2 2000

START=$SECONDS
echo "$PAYLOAD" | CLAUDE_CONFIG_DIR="$CFG" TMPDIR="$HOOK_TMP" bash "$ON_EXIT"
RC=$?
ELAPSED=$((SECONDS - START))
check "SessionEnd: exits 0" "0" "$RC"
# Whole-second clock: <= 1 means it returned well before the parse, which sleeps 2 s first.
check "SessionEnd: returns without waiting for the parse" "yes" "$([ "$ELAPSED" -le 1 ] && echo yes || echo no)"

payload_left() { find "$HOOK_TMP" -name 'claude-carbon-end.*' 2>/dev/null | head -1; }
WAITED=0
while { [ "$(out_tokens "$DB" "$SESSION")" != "2100" ] || [ -n "$(payload_left)" ]; } && [ "$WAITED" -lt 20 ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done
check "SessionEnd: detached run records the interrupted turn" "2100" "$(out_tokens "$DB" "$SESSION")"
check "SessionEnd: payload file removed afterwards"           ""     "$(payload_left)"

# Stop and SessionEnd both running on one session rewrite the same row with the same totals.
echo "$PAYLOAD" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "Stop after SessionEnd: same totals, one row" "2100|1" \
  "$(sqlite3 "$DB" "SELECT output_tokens || '|' || (SELECT COUNT(*) FROM sessions) FROM sessions WHERE session_id='${SESSION}';")"

# A SessionEnd fired inside a subagent (agent_id present) records nothing: the subagent's
# tokens already count in its parent's row. Waits past the detached run's 2 s delay.
SUB_ID="cccccccc-dddd-eeee-ffff-000000000000"
SUB_T="${TMPROOT}/agent-x.jsonl"
write_turn "$SUB_T" 3 500
jq -n --arg s "$SUB_ID" --arg t "$SUB_T" '{session_id: $s, transcript_path: $t, cwd: "/tmp/endproj", hook_event_name: "SessionEnd", reason: "other", agent_id: "agent-x", agent_type: "Explore"}' \
  | CLAUDE_CONFIG_DIR="$CFG" TMPDIR="$HOOK_TMP" bash "$ON_EXIT"
sleep 4
check "SessionEnd inside a subagent: no row of its own" "0|2100" \
  "$(sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM sessions WHERE session_id='${SUB_ID}') || '|' || output_tokens FROM sessions WHERE session_id='${SESSION}';")"
check "SessionEnd inside a subagent: payload file removed" "" "$(payload_left)"

# No database yet (plugin not set up): still exits 0 at once, writes nothing.
START=$SECONDS
echo "$PAYLOAD" | CLAUDE_CONFIG_DIR="${TMPROOT}/nodb" TMPDIR="$HOOK_TMP" bash "$ON_EXIT"
RC=$?
check "SessionEnd without a DB: exits 0 at once" "0|yes" "${RC}|$([ $((SECONDS - START)) -le 1 ] && echo yes || echo no)"

# ---------------------------------------------------------------- 2. backfill refreshes a stale row

CFG2="${TMPROOT}/cfg2"
DB2="${CFG2}/claude-carbon/carbon.db"
S2="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
T2="${CFG2}/projects/-tmp-endproj/${S2}.jsonl"
mkdir -p "${CFG2}/claude-carbon" "$(dirname "$T2")"
sqlite3 "$DB2" "$SCHEMA"
write_turn "$T2" 1 100
write_turn "$T2" 2 2000
# The row as the Stop hook left it after turn 1, long before the transcript's last write
# (the window was closed without SessionEnd running, or the process was killed).
sqlite3 "$DB2" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, ended_at, source, methodology_version) VALUES ('${S2}', 'endproj', 'claude-opus-5', 1000, 100, 0.01, 0.5, '2026-01-01T00:00:00Z', '2026-01-01T00:01:00Z', 'live', 2);"

BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG2" bash "$BACKFILL" 2>/dev/null)"
EXPECT_END="$(sqlite3 "$DB2" "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', $(cc_mtime "$T2"), 'unixepoch');")"
check "refresh: tokens re-aggregated from the transcript" "2100|2000" "$(sqlite3 "$DB2" "SELECT output_tokens || '|' || input_tokens FROM sessions WHERE session_id='${S2}';")"
check "refresh: started_at kept"                          "2026-01-01T00:00:00Z" "$(sqlite3 "$DB2" "SELECT started_at FROM sessions WHERE session_id='${S2}';")"
check "refresh: source kept"                              "live" "$(sqlite3 "$DB2" "SELECT source FROM sessions WHERE session_id='${S2}';")"
check "refresh: ended_at is the transcript's last write"  "$EXPECT_END" "$(sqlite3 "$DB2" "SELECT ended_at FROM sessions WHERE session_id='${S2}';")"
check "refresh: one row, not a duplicate"                 "1" "$(sqlite3 "$DB2" "SELECT COUNT(*) FROM sessions;")"
case "$BF_OUT" in
  *"Refreshed 1 session(s)"*) ok "refresh: reported" ;;
  *) bad "refresh: reported" "a 'Refreshed 1 session(s)' line" "$BF_OUT" ;;
esac

BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG2" bash "$BACKFILL" 2>/dev/null)"
case "$BF_OUT" in
  *"Refreshed"*) bad "refresh: a refreshed row is not parsed again" "no 'Refreshed' line" "$BF_OUT" ;;
  *) ok "refresh: a refreshed row is not parsed again" ;;
esac

# ---------------------------------------------------------------- 3. an up-to-date row is left alone

# Recorded after the transcript's last write: backfill must skip it on the stat alone, even
# though its tokens disagree with the transcript (a parse would have "corrected" them).
sqlite3 "$DB2" "UPDATE sessions SET output_tokens = 100, ended_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE session_id='${S2}';"
CLAUDE_CONFIG_DIR="$CFG2" bash "$BACKFILL" >/dev/null 2>&1
check "up-to-date row: not re-parsed" "100" "$(out_tokens "$DB2" "$S2")"

# A legacy row (methodology_version 1) is never refreshed, stale or not.
sqlite3 "$DB2" "UPDATE sessions SET ended_at = '2026-01-01T00:01:00Z', methodology_version = 1 WHERE session_id='${S2}';"
CLAUDE_CONFIG_DIR="$CFG2" bash "$BACKFILL" >/dev/null 2>&1
check "legacy row: left untouched" "100" "$(out_tokens "$DB2" "$S2")"

# ---------------------------------------------------------------- 4. plugin manifest

check "hooks.json: SessionEnd runs persist-on-exit.sh" \
  "\"\${CLAUDE_PLUGIN_ROOT}/scripts/persist-on-exit.sh\"" \
  "$(jq -r '.hooks.SessionEnd[0].hooks[0].command // ""' "${REPO_DIR}/hooks/hooks.json")"
check "persist-on-exit.sh is executable" "yes" "$([ -x "$ON_EXIT" ] && echo yes || echo no)"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} session-end assertions passed."
