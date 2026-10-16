#!/usr/bin/env bash
# run-workflow-agent-tests.sh: the agents a workflow starts write their transcripts to
# <session>/subagents/workflows/wf_*/agent-*.jsonl, beside the workflow's journal.jsonl.
# Assert that they count like any subagent:
#   1. the Stop hook folds them into the session (the journal is not read);
#   2. backfill.sh does the same for a session it records;
#   3. backfill.sh re-aggregates a v2 row recorded without them, once, and says so;
#   4. a legacy (v1) row, a frozen series, is never touched;
#   5. a row an older Stop hook rewrites without them after that (a session opened before
#      the update) is repaired by the next rescan;
#   6. a write that fails leaves the row unstamped, and the next rescan retries it;
#   7. a rewritten row ends when its last transcript was written, agents included, so
#      the next rescan does not parse it again;
#   8. an agent transcript that cannot be read does not cost the session;
#   9. all of it holds when sqlite3 ends its lines in CRLF (an older sqlite3.exe);
#  10. a row holding more tokens than its transcripts now give is left as it is, its
#      child rows too, and only its end moves, so the next rescan does not parse it;
#  11. an older Stop hook recording one more turn while the rescan parses is not
#      overwritten by that parse, nor its child rows by the split pass; both land on the
#      next rescan;
#  12. a stamped row whose agent wrote a line without usage after it ended, and a row
#      with no tokens and no child rows, are parsed once, not at every rescan.
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
# has <text> <output>: yes when the output contains the text (a function: bash 3.2 reads
# the ) of a case pattern inside $( ) as the end of the substitution)
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
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
# old_writer <sid> <in> <out>: the row as a Stop hook up to 1.15.3 writes it, without the
# workflow agents: the same column list, so agents_collected goes back to its default.
old_writer() {
  q "INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch) VALUES ('$1', 'wfproj', 'claude-sonnet-5-5', $2, $3, 0, 0, 0, 0, 0.003, 0.1216, COALESCE((SELECT started_at FROM sessions WHERE session_id='$1'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'live', 2, 0, '');"
}
# A v2 row recorded by a version that did not read workflow agents
S3="11111111-aaaa-bbbb-cccc-000000000003"
make_session "$S3" no
payload "$S3" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "stop hook: the row is stamped" "2" "$(q "SELECT agents_collected FROM sessions WHERE session_id='${S3}';")"
add_workflow "$S3"
old_writer "$S3" 1000 100
check "repair: the row before" "$WITHOUT|0" "$(tokens "$S3")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S3}';")"
BEFORE_START="$(q "SELECT started_at||'|'||source FROM sessions WHERE session_id='${S3}';")"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
check "repair: the row now counts the workflow agent" "$WITH" "$(tokens "$S3")"
check "repair: CO2 re-derived" "$CO2_WITH" "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${S3}';")"
check "repair: child rows match the row" "11000" "$(q "SELECT SUM(input_tokens) FROM session_models WHERE session_id='${S3}';")"
case "$OUT" in *"Counted the workflow agents of 1 session(s)"*) check "repair: said once" "yes" "yes" ;; *) check "repair: said once" "yes" "$OUT" ;; esac
check "repair: start and source kept" "$BEFORE_START" "$(q "SELECT started_at||'|'||source FROM sessions WHERE session_id='${S3}';")"
check "repair: the row is stamped" "2" "$(q "SELECT agents_collected FROM sessions WHERE session_id='${S3}';")"
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
q "UPDATE sessions SET methodology_version = 1, co2_grams = 42, agents_collected = 0 WHERE session_id='${S4}';"
add_workflow "$S4"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "frozen (v1) row: tokens untouched" "$WITHOUT" "$(tokens "$S4")"
check "frozen (v1) row: CO2 untouched" "42.0" "$(q "SELECT co2_grams FROM sessions WHERE session_id='${S4}';")"

# ---------------------------------------------------------------- 5. an older Stop hook after the pass
# The session stays open under the older version: its Stop hook rewrites the repaired row
# without the workflow agent, after the rescan that repaired it. The next rescan repairs
# it again.
old_writer "$S3" 1000 100
check "older Stop hook: the row undone" "$WITHOUT" "$(tokens "$S3")"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
check "older Stop hook: repaired by the next rescan" "$WITH|2" "$(tokens "$S3")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S3}';")"
check "older Stop hook: said" "yes" "$(has "Counted the workflow agents of 1 session(s)" "$OUT")"

# ---------------------------------------------------------------- 6. a write that fails
# The rewrite fails (here a trigger aborts it, as a lock held past the timeout would):
# not counted, not stamped, the row as it was; the next rescan retries.
S6="11111111-aaaa-bbbb-cccc-000000000006"
make_session "$S6" no
payload "$S6" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
add_workflow "$S6"
old_writer "$S6" 1000 100
q "CREATE TRIGGER cc_test_fail BEFORE INSERT ON sessions WHEN NEW.session_id = '${S6}' BEGIN SELECT RAISE(ABORT, 'injected'); END;"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
check "failed write: row, stamp and child rows as they were" "$WITHOUT|0|1000" \
  "$(tokens "$S6")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S6}';")|$(q "SELECT SUM(input_tokens) FROM session_models WHERE session_id='${S6}';")"
check "failed write: counted as an error, not as repaired" "no|no" \
  "$(has "Counted the workflow agents" "$OUT")|$(has " 0 errors" "$OUT")"
q "DROP TRIGGER cc_test_fail;"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "failed write: retried by the next rescan" "$WITH|2" "$(tokens "$S6")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S6}';")"

# ---------------------------------------------------------------- 7. the end of a rewritten row
# The workflow agent wrote after the main transcript: the rewritten row ends at the agent's
# last write, and the next rescan does not parse the session again (a jq on PATH counts
# the usage passes, the only jq calls given --slurpfile).
S7="11111111-aaaa-bbbb-cccc-000000000007"
make_session "$S7" no
payload "$S7" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
add_workflow "$S7"
old_writer "$S7" 1000 100
touch -t 202610150900 "${PROJ}/${S7}.jsonl"
touch -t 202610150905 "${PROJ}/${S7}/subagents/workflows/wf_abc123-def/agent-a1b2c3.jsonl"
AGENT_END="$(q "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', $(cc_mtime "${PROJ}/${S7}/subagents/workflows/wf_abc123-def/agent-a1b2c3.jsonl"), 'unixepoch');")"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "end: the agent's last write" "$WITH|$AGENT_END" "$(tokens "$S7")|$(q "SELECT ended_at FROM sessions WHERE session_id='${S7}';")"
SHIM="${TMPROOT}/shim"
mkdir -p "$SHIM"
REAL_JQ="$(command -v jq)"
printf '#!/usr/bin/env bash
case "$*" in *--slurpfile*) echo x >> "%s" ;; esac
exec "%s" "$@"
' "${TMPROOT}/jq-calls" "$REAL_JQ" > "${SHIM}/jq"
chmod +x "${SHIM}/jq"
: > "${TMPROOT}/jq-calls"
PATH="${SHIM}:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "end: no parse on the next rescan" "0" "$(wc -l < "${TMPROOT}/jq-calls" | tr -d ' ')"

# ---------------------------------------------------------------- 8. an agent transcript that cannot be read
# One listed then gone (removed between the listing and the parse), one unreadable: the
# session is recorded from the others
S8="11111111-aaaa-bbbb-cccc-000000000008"
make_session "$S8" yes
check "unreadable agent: a vanished file is left out" "$WITH" \
  "$(cc_session_usage "${REPO_DIR}/data/factors.json" "${REPO_DIR}/data/prices.json" "${PROJ}/${S8}.jsonl" \
       "${PROJ}/${S8}/subagents/workflows/wf_abc123-def/agent-a1b2c3.jsonl" "${PROJ}/${S8}/subagents/gone.jsonl" \
     | awk -F '\t' '$1 == "T" { print $2 "|" $5 "|" $6 }')"
cp "${PROJ}/${S8}/subagents/workflows/wf_abc123-def/agent-a1b2c3.jsonl" "${PROJ}/${S8}/subagents/agent-locked.jsonl"
chmod 000 "${PROJ}/${S8}/subagents/agent-locked.jsonl"
if [ -r "${PROJ}/${S8}/subagents/agent-locked.jsonl" ]; then
  echo "SKIP unreadable agent: this system still reads a mode-000 file"
else
  payload "$S8" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
  check "unreadable agent: the session recorded from the others" "$WITH" "$(tokens "$S8")"
fi
chmod 644 "${PROJ}/${S8}/subagents/agent-locked.jsonl"

# ---------------------------------------------------------------- 9. CRLF from sqlite3
# A new session to add and a row an older Stop hook wrote, through a sqlite3 whose every
# line ends in CRLF: "0\r" must still read as 0
S9="11111111-aaaa-bbbb-cccc-000000000009"
make_session "$S9" yes
S10="11111111-aaaa-bbbb-cccc-000000000010"
make_session "$S10" no
payload "$S10" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
add_workflow "$S10"
old_writer "$S10" 1000 100
CRLF="${TMPROOT}/crlf"
mkdir -p "$CRLF"
REAL_SQLITE="$(command -v sqlite3)"
cat > "${CRLF}/sqlite3" <<EOF
#!/usr/bin/env bash
# sqlite3 as an older sqlite3.exe answers: every line ends in CRLF
set -o pipefail
"${REAL_SQLITE}" "\$@" | awk '{ printf "%s\\r\\n", \$0 }'
EOF
chmod +x "${CRLF}/sqlite3"
OUT="$(PATH="${CRLF}:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" 2>&1)"
check "CRLF: the new session added, the old row repaired" "$WITH|$WITH|2" "$(tokens "$S9")|$(tokens "$S10")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S10}';")"
check "CRLF: counted, no error" "yes|yes|yes" \
  "$(has "1 sessions added" "$OUT")|$(has "Counted the workflow agents of 1 session(s)" "$OUT")|$(has " 0 errors" "$OUT")"

# ---------------------------------------------------------------- 10. the monotone guard
# A row with 1,000 more tokens than its transcripts give (a Stop hook saw more) and an old
# end: the rescan leaves the row and its child rows, only moves the end
S11="11111111-aaaa-bbbb-cccc-000000000011"
make_session "$S11" yes
payload "$S11" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
q "UPDATE sessions SET input_tokens = input_tokens + 1000, ended_at = '2026-01-01T00:00:00Z' WHERE session_id='${S11}';"
CHILDREN="$(q "SELECT group_concat(model || ':' || input_tokens || ':' || co2_grams, ',') FROM session_models WHERE session_id='${S11}';")"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "guard: the row and its child rows as they were" "12000|100000|1100|$CHILDREN" \
  "$(tokens "$S11")|$(q "SELECT group_concat(model || ':' || input_tokens || ':' || co2_grams, ',') FROM session_models WHERE session_id='${S11}';")"
check "guard: the end moved forward" "yes" "$(q "SELECT CASE WHEN ended_at > '2026-01-02' THEN 'yes' ELSE ended_at END FROM sessions WHERE session_id='${S11}';")"
: > "${TMPROOT}/jq-calls"
PATH="${SHIM}:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "guard: no parse on the next rescan" "0" "$(wc -l < "${TMPROOT}/jq-calls" | tr -d ' ')"

# ---------------------------------------------------------------- 11. an older Stop hook mid-rescan
# race_shim <dir> <tool> <match>: <tool> on PATH that, the first time its arguments match,
# runs ${TMPROOT}/race.sh (one more turn, recorded by an older Stop hook): after the parse
# for jq, before the transaction for sqlite3
race_shim() {
  mkdir -p "$1"
  local real
  real="$(command -v "$2")"
  if [ "$2" = "jq" ]; then
    cat > "$1/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  $3) if [ ! -e "${TMPROOT}/race-done" ]; then
        out="\$("${real}" "\$@")"; rc=\$?
        : > "${TMPROOT}/race-done"; bash "${TMPROOT}/race.sh"
        printf '%s\\n' "\$out"; exit \$rc
      fi ;;
esac
exec "${real}" "\$@"
EOF
  else
    cat > "$1/$2" <<EOF
#!/usr/bin/env bash
case "\$*" in
  $3) if [ ! -e "${TMPROOT}/race-done" ]; then : > "${TMPROOT}/race-done"; bash "${TMPROOT}/race.sh"; fi ;;
esac
exec "${real}" "\$@"
EOF
  fi
  chmod +x "$1/$2"
}
# race_script <sid>: the turn (5000 in, 200 out) appended to the transcript, then the row
# as the older hook writes it from the main transcript alone: 6000|0|300, a new end
race_script() {
  cat > "${TMPROOT}/race.sh" <<EOF
printf '%s\\n' '{"type":"assistant","requestId":"r2","timestamp":"2026-10-15T10:05:00Z","message":{"id":"m2","model":"claude-sonnet-5-5","usage":{"input_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200}}}' >> "${PROJ}/$1.jsonl"
"$(command -v sqlite3)" "$DB" "DELETE FROM session_models WHERE session_id='$1'; INSERT INTO session_models (session_id, model, input_tokens, output_tokens) VALUES ('$1', 'claude-sonnet-5-5', 6000, 300); INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch) VALUES ('$1', 'wfproj', 'claude-sonnet-5-5', 6000, 300, 0, 0, 0.02, 0.4818, '2026-10-15T10:00:00Z', '2099-01-01T00:00:00Z', 'live', 2, 0, '');"
EOF
}
children() { q "SELECT SUM(input_tokens)||'|'||SUM(cache_read_tokens)||'|'||SUM(output_tokens) FROM session_models WHERE session_id='$1';"; }
MORE="16000|100000|1300"
# The workflow pass parses (agent included) while the turn is recorded without it
S12="11111111-aaaa-bbbb-cccc-000000000012"
make_session "$S12" yes
old_writer "$S12" 1000 100
race_script "$S12"
race_shim "${TMPROOT}/race-jq" jq "*--slurpfile*"
PATH="${TMPROOT}/race-jq:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "mid-rescan turn: the parse does not overwrite it" "6000|0|300|0" "$(tokens "$S12")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S12}';")"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "mid-rescan turn: the next rescan has both" "$MORE|2" "$(tokens "$S12")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S12}';")"
# The split pass: a row with no child rows, the turn recorded just before its transaction
rm -f "${TMPROOT}/race-done"
S13="11111111-aaaa-bbbb-cccc-000000000013"
make_session "$S13" yes
payload "$S13" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
q "DELETE FROM session_models WHERE session_id='${S13}'; UPDATE sessions SET agents_collected = 0 WHERE session_id='${S13}';"
race_script "$S13"
race_shim "${TMPROOT}/race-sql" sqlite3 "*BEGIN\ IMMEDIATE*output_context_sum\ =*"
PATH="${TMPROOT}/race-sql:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "split race: the row keeps its own child rows" "6000|0|300|6000|0|300|0" "$(tokens "$S13")|$(children "$S13")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S13}';")"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "split race: the next rescan has both" "$MORE|$MORE|2" "$(tokens "$S13")|$(children "$S13")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S13}';")"

# ---------------------------------------------------------------- 12. parsed once
# An agent's last line, without usage, written 2 minutes after the stamped row ended
S14="11111111-aaaa-bbbb-cccc-000000000014"
make_session "$S14" yes
payload "$S14" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
q "UPDATE sessions SET ended_at = '2026-10-15T08:00:00Z' WHERE session_id='${S14}';"
touch -t 202610150900 "${PROJ}/${S14}.jsonl"
A14="${PROJ}/${S14}/subagents/workflows/wf_abc123-def/agent-a1b2c3.jsonl"
echo '{"type":"user","isSidechain":true,"timestamp":"2026-10-15T10:02:00Z","message":{"role":"user","content":"done"}}' >> "$A14"
touch -t 202610151002 "$A14"
# A row with no tokens and no child rows, its transcript without usage
S15="11111111-aaaa-bbbb-cccc-000000000015"
echo '{"type":"user","cwd":"/tmp/wfproj","timestamp":"2026-10-15T10:00:00Z","message":{"role":"user","content":"go"}}' > "${PROJ}/${S15}.jsonl"
q "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, started_at, ended_at, source, methodology_version) VALUES ('${S15}', 'wfproj', 'claude-sonnet-5-5', 0, 0, 0, 0, 0, 0, '2026-10-15T10:00:00Z', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'live', 2);"
: > "${TMPROOT}/jq-calls"
PATH="${SHIM}:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "parsed once: this rescan reads both" "2" "$(wc -l < "${TMPROOT}/jq-calls" | tr -d ' ')"
: > "${TMPROOT}/jq-calls"
PATH="${SHIM}:$PATH" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "parsed once: not the next" "0|$WITH|2" "$(wc -l < "${TMPROOT}/jq-calls" | tr -d ' ')|$(tokens "$S14")|$(q "SELECT agents_collected FROM sessions WHERE session_id='${S15}';")"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
