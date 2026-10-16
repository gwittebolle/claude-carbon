#!/usr/bin/env bash
# run-workflow-agent-tests.sh: the agents a workflow starts write their transcripts to
# <session>/subagents/workflows/wf_*/agent-*.jsonl, beside the workflow's journal.jsonl.
# Assert that they count like any subagent:
#   1. the Stop hook folds them into the session (the journal is not read);
#   2. backfill.sh does the same for a session it records;
#   3. backfill.sh re-aggregates a v2 row recorded without them, once, and says so;
#   4. a legacy (v1) row, a frozen series, is never touched.
#
# Throwaway dirs only (CLAUDE_CONFIG_DIR, CLAUDE_CARBON_DB); the real ~/.claude is never
# read or written. bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"
BACKFILL="${REPO_DIR}/scripts/backfill.sh"

for c in sqlite3 jq awk; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-workflow-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-workflow-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
check() {
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1)); echo "PASS $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"
  fi
}

CFG="${TMPROOT}/cfg"
DB="${CFG}/claude-carbon/carbon.db"
PROJ="${CFG}/projects/-tmp-wfproj"
mkdir -p "${CFG}/claude-carbon" "$PROJ"
# A database as setup.sh creates it; the writers add the newer columns and tables
sqlite3 "$DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0);"
q() { sqlite3 "$DB" "$1" 2>/dev/null; }
tokens() { q "SELECT input_tokens||'|'||cache_read_tokens||'|'||output_tokens FROM sessions WHERE session_id='$1';"; }

# A session: one Sonnet message in the main transcript; a workflow agent on Opus with
# a streaming snapshot (deduplicated), and a journal that must not be read.
make_session() {
  local sid="$1" with_workflow="$2"
  cat > "${PROJ}/${sid}.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/wfproj","timestamp":"2026-10-15T10:00:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","requestId":"r1","timestamp":"2026-10-15T10:00:01Z","message":{"id":"m1","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
EOF
  [ "$with_workflow" = "yes" ] && add_workflow "$sid"
  return 0
}
add_workflow() {
  local wf="${PROJ}/$1/subagents/workflows/wf_abc123-def"
  mkdir -p "$wf"
  cat > "${wf}/agent-a1b2c3.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"requestId":"w1","timestamp":"2026-10-15T10:00:02Z","message":{"id":"mw1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":10000,"cache_creation":{"ephemeral_1h_input_tokens":10000},"cache_read_input_tokens":100000,"output_tokens":400}}}
{"type":"assistant","isSidechain":true,"requestId":"w1","timestamp":"2026-10-15T10:00:03Z","message":{"id":"mw1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":10000,"cache_creation":{"ephemeral_1h_input_tokens":10000},"cache_read_input_tokens":100000,"output_tokens":1000}}}
EOF
  cat > "${wf}/journal.jsonl" <<'EOF'
{"type":"assistant","requestId":"j1","message":{"id":"mj1","model":"claude-opus-5-5","usage":{"input_tokens":999999,"cache_read_input_tokens":0,"output_tokens":999999}}}
EOF
}
payload() { jq -n --arg s "$1" --arg t "${PROJ}/$1.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp/wfproj"}'; }

# Main 1000 in / 100 out; the workflow agent 10000 written, 100000 read, 1000 out (the
# last snapshot). Stored input folds the cache write in.
WITH="11000|100000|1100"
WITHOUT="1000|0|100"
# CO2: Sonnet (1000*39 + 100*826) + Opus (10000*78 + 100000*78*0.08 + 1000*1652), /1e6
CO2_WITH="3.1776"

# ---------------------------------------------------------------- 1. Stop hook
S1="11111111-aaaa-bbbb-cccc-000000000001"
make_session "$S1" yes
payload "$S1" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "stop hook: workflow agent counted, journal not read" "$WITH" "$(tokens "$S1")"
check "stop hook: CO2 with the workflow agent" "$CO2_WITH" "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${S1}';")"
check "stop hook: the agent's model in the split" "claude-opus-5-5,claude-sonnet-5-5" \
  "$(q "SELECT group_concat(model, ',') FROM (SELECT model FROM session_models WHERE session_id='${S1}' ORDER BY model);")"

# ---------------------------------------------------------------- 2. backfill, new row
S2="11111111-aaaa-bbbb-cccc-000000000002"
make_session "$S2" yes
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "backfill: a new session counts its workflow agent" "$WITH" "$(tokens "$S2")"

# ---------------------------------------------------------------- 3. backfill, repair
# A v2 row recorded before workflow agents were read: the Stop hook ran while the
# workflow directory did not exist yet.
S3="11111111-aaaa-bbbb-cccc-000000000003"
make_session "$S3" no
payload "$S3" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "repair: the row before" "$WITHOUT" "$(tokens "$S3")"
BEFORE_START="$(q "SELECT started_at||'|'||source FROM sessions WHERE session_id='${S3}';")"
add_workflow "$S3"
# As on an install updated to this version: no workflow pass has run yet
rm -f "${CFG}/claude-carbon/.workflow-agents-counted"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
check "repair: the row now counts the workflow agent" "$WITH" "$(tokens "$S3")"
check "repair: CO2 re-derived" "$CO2_WITH" "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${S3}';")"
check "repair: child rows match the row" "11000" "$(q "SELECT SUM(input_tokens) FROM session_models WHERE session_id='${S3}';")"
case "$OUT" in *"Counted the workflow agents of 1 session(s)"*) check "repair: said once" "yes" "yes" ;; *) check "repair: said once" "yes" "$OUT" ;; esac
check "repair: start and source kept" "$BEFORE_START" "$(q "SELECT started_at||'|'||source FROM sessions WHERE session_id='${S3}';")"
check "repair: the pass is marked done" "yes" "$([ -f "${CFG}/claude-carbon/.workflow-agents-counted" ] && echo yes || echo no)"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
case "$OUT" in *"Counted the workflow agents"*) check "repair: nothing on the next rescan" "no" "yes" ;; *) check "repair: nothing on the next rescan" "no" "no" ;; esac
check "repair: unchanged on the next rescan" "$WITH" "$(tokens "$S3")"

# ---------------------------------------------------------------- 3b. an agent that ends after the last Stop
# Once the pass is done, a session is looked at again only when an agent transcript is
# newer than its row: here the row ended long before the workflow agent wrote.
S5="11111111-aaaa-bbbb-cccc-000000000005"
make_session "$S5" no
payload "$S5" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
q "UPDATE sessions SET ended_at = '2026-10-15T10:00:01Z' WHERE session_id='${S5}';"
add_workflow "$S5"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "late agent: counted by the next rescan" "$WITH" "$(tokens "$S5")"

# ---------------------------------------------------------------- 4. frozen rows
S4="11111111-aaaa-bbbb-cccc-000000000004"
make_session "$S4" no
payload "$S4" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
q "UPDATE sessions SET methodology_version = 1, co2_grams = 42 WHERE session_id='${S4}';"
add_workflow "$S4"
rm -f "${CFG}/claude-carbon/.workflow-agents-counted"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "frozen (v1) row: tokens untouched" "$WITHOUT" "$(tokens "$S4")"
check "frozen (v1) row: CO2 untouched" "42.0" "$(q "SELECT co2_grams FROM sessions WHERE session_id='${S4}';")"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
