#!/usr/bin/env bash
# run-per-model-tests.sh: assert that a session's tokens are split by the model that
# produced each message and that the split stays consistent with the session row:
#   1. the Stop hook writes one session_models row per model (main transcript and
#      subagents merged, message by message, each at its own price), and the invariant
#      SUM(session_models.x) = sessions.x holds for every token column, co2 and cost;
#   2. recompute.sh re-derives child rows at their own model, sets the session to their
#      sum, is idempotent, and still leaves legacy (v1) and excluded rows alone, and
#      re-prices a row without children at its own model;
#   3. backfill.sh writes the same split for a new session, gives an existing row its
#      split only when the transcript yields the row's stored totals, and keeps the split
#      on a refresh;
#   4. two writers on the same session (SessionEnd's detached run overlapping a Stop hook)
#      leave a consistent pair of tables;
#   5. /carbon-pr's per-model table reads the split, and falls back to the row model;
#   6. a model id carrying a quote is stored, not injected.
#
# Every case runs against throwaway dirs (CLAUDE_CONFIG_DIR, CLAUDE_CARBON_DB); the real
# ~/.claude is never read or written.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: sqlite3, jq, awk, git.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"
BACKFILL="${REPO_DIR}/scripts/backfill.sh"
RECOMPUTE="${REPO_DIR}/scripts/recompute.sh"
PR_REPORT="${REPO_DIR}/scripts/generate-pr-report.sh"

for c in sqlite3 jq awk git; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-model-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-model-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
# near <name> <expected> <actual> [tolerance]: absolute float comparison.
near() {
  if LC_ALL=C awk -v e="$2" -v a="$3" -v t="${4:-0.0001}" 'BEGIN { d = e - a; if (d < 0) d = -d; exit !(a != "" && d <= t) }'; then
    ok "$1"
  else
    bad "$1" "$2 (within ${4:-0.0001})" "$3"
  fi
}

q() { sqlite3 "$DB" "$1" 2>/dev/null; }

# Sessions whose row disagrees with the sum of its child rows, on any column. Counts
# only sessions that have children; must be 0.
INVARIANT="SELECT COUNT(*) FROM sessions s JOIN (SELECT session_id, SUM(input_tokens) i, SUM(cache_creation_tokens) cw, SUM(cache_creation_1h_tokens) cw1h, SUM(cache_read_tokens) cr, SUM(output_tokens) o, SUM(co2_grams) co2, SUM(cost_usd) cost FROM session_models GROUP BY session_id) m ON m.session_id = s.session_id WHERE s.input_tokens != m.i OR s.cache_creation_tokens != m.cw OR s.cache_creation_1h_tokens != m.cw1h OR s.cache_read_tokens != m.cr OR s.output_tokens != m.o OR ABS(s.co2_grams - m.co2) > 0.00005 OR ABS(s.cost_usd - m.cost) > 0.0000005;"

# ---------------------------------------------------------------- fixture

CFG="${TMPROOT}/cfg"
DB="${CFG}/claude-carbon/carbon.db"
PROJ_DIR="${CFG}/projects/-tmp-modelproj"
SESSION="aaaaaaaa-1111-2222-3333-444444444444"
MAIN="${PROJ_DIR}/${SESSION}.jsonl"
SUBS="${PROJ_DIR}/${SESSION}/subagents"
mkdir -p "${CFG}/claude-carbon" "$SUBS"
# A DB as setup.sh created it before session_models existed: the writers add the table.
sqlite3 "$DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0);"

# Main transcript: Opus 5.5, then a /model switch to Sonnet 4.6 for one message; one
# message without a model string (attributed to the file's dominant model, Opus 5.5);
# a streaming snapshot of m1 (the last occurrence wins); a <synthetic> marker with no
# tokens (no child row).
cat > "$MAIN" <<'EOF'
{"type":"user","cwd":"/tmp/modelproj","gitBranch":"feat/models","timestamp":"2026-09-22T10:00:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","requestId":"r1","timestamp":"2026-09-22T10:00:01Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":20000,"cache_creation":{"ephemeral_1h_input_tokens":20000},"cache_read_input_tokens":100000,"output_tokens":100}}}
{"type":"assistant","requestId":"r1","timestamp":"2026-09-22T10:00:02Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":20000,"cache_creation":{"ephemeral_1h_input_tokens":20000},"cache_read_input_tokens":100000,"output_tokens":500}}}
{"type":"assistant","requestId":"r2","timestamp":"2026-09-22T10:00:03Z","message":{"id":"m2","usage":{"input_tokens":100,"output_tokens":10}}}
{"type":"assistant","requestId":"r3","timestamp":"2026-09-22T10:00:04Z","message":{"id":"m3","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":200000,"output_tokens":1000}}}
{"type":"assistant","requestId":"r4","timestamp":"2026-09-22T10:00:05Z","message":{"id":"m4","model":"claude-sonnet-4-6","usage":{"input_tokens":50,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000},"cache_read_input_tokens":30000,"output_tokens":200}}}
{"type":"assistant","requestId":"r5","timestamp":"2026-09-22T10:00:06Z","message":{"id":"m5","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
EOF
# Three subagents on three other models; one Opus 5.5 message in a subagent merges with
# the main transcript's Opus 5.5 row; a non-Claude subagent keeps its tokens at 0 CO2.
cat > "${SUBS}/agent-haiku.jsonl" <<'EOF'
{"type":"assistant","requestId":"s1","timestamp":"2026-09-22T10:00:07Z","message":{"id":"ms1","model":"claude-haiku-4-5","usage":{"input_tokens":500,"cache_creation_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":5000},"cache_read_input_tokens":0,"output_tokens":300}}}
{"type":"assistant","requestId":"s2","timestamp":"2026-09-22T10:00:08Z","message":{"id":"ms2","model":"claude-haiku-4-5","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000,"output_tokens":40}}}
EOF
cat > "${SUBS}/agent-fable.jsonl" <<'EOF'
{"type":"assistant","requestId":"f1","timestamp":"2026-09-22T10:00:09Z","message":{"id":"mf1","model":"claude-fable-5-1","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_1h_input_tokens":2000},"cache_read_input_tokens":50000,"output_tokens":100}}}
{"type":"assistant","requestId":"f2","timestamp":"2026-09-22T10:00:10Z","message":{"id":"mf2","model":"claude-opus-5-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}
EOF
cat > "${SUBS}/agent-local.jsonl" <<'EOF'
{"type":"assistant","requestId":"g1","timestamp":"2026-09-22T10:00:11Z","message":{"id":"mg1","model":"glm-4.7-flash","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
EOF

payload() { jq -n --arg s "$1" --arg t "$2" '{session_id: $s, transcript_path: $t, cwd: "/tmp/modelproj"}'; }

# ---------------------------------------------------------------- 1. Stop hook

payload "$SESSION" "$MAIN" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"

check "stop hook: session_models table created on an old DB" "1" "$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_models';")"
check "stop hook: one child row per model with tokens" \
  "claude-fable-5-1,claude-haiku-4-5,claude-opus-5-5,claude-sonnet-4-6,glm-4.7-flash" \
  "$(q "SELECT group_concat(model, ',') FROM (SELECT model FROM session_models WHERE session_id='${SESSION}' ORDER BY model);")"
# Opus 5.5: m1 (last snapshot) + m2 (no model, file's dominant) + m3 + the subagent's mf2.
check "stop hook: Opus 5.5 tokens merged across main and subagent" "21107|20000|20000|300000|1513" \
  "$(q "SELECT input_tokens||'|'||cache_creation_tokens||'|'||cache_creation_1h_tokens||'|'||cache_read_tokens||'|'||output_tokens FROM session_models WHERE session_id='${SESSION}' AND model='claude-opus-5-5';")"
check "stop hook: the /model switch message is Sonnet 4.6's" "1050|1000|30000|200" \
  "$(q "SELECT input_tokens||'|'||cache_creation_tokens||'|'||cache_read_tokens||'|'||output_tokens FROM session_models WHERE session_id='${SESSION}' AND model='claude-sonnet-4-6';")"
# Opus 5.5 at 4/20, cache write 1h 2x, cache read 0.05x:
#   (1107*4 + 20000*8 + 300000*0.2 + 1513*20) / 1e6 = 0.254688
#   co2 (Opus family factors) = (21107*78 + 300000*78*0.08 + 1513*1652) / 1e6 = 6.017822
near "stop hook: Opus 5.5 cost at its own price"  "0.254688" "$(q "SELECT cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='claude-opus-5-5';")" 0.0000005
near "stop hook: Opus 5.5 CO2 at the Opus factors" "6.017822" "$(q "SELECT co2_grams FROM session_models WHERE session_id='${SESSION}' AND model='claude-opus-5-5';")"
# Sonnet 4.6 at 3/15: (50*3 + 1000*6 + 30000*0.3 + 200*15) / 1e6 = 0.01815
near "stop hook: Sonnet 4.6 cost at 3/15"           "0.01815"  "$(q "SELECT cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='claude-sonnet-4-6';")" 0.0000005
# Haiku 4.5 at 1/5: (520 + 5000*2 + 10000*0.1 + 340*5) / 1e6 = 0.01322; co2 = 0.26682
near "stop hook: Haiku 4.5 cost"                    "0.01322"  "$(q "SELECT cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='claude-haiku-4-5';")" 0.0000005
near "stop hook: Haiku 4.5 CO2"                     "0.26682"  "$(q "SELECT co2_grams FROM session_models WHERE session_id='${SESSION}' AND model='claude-haiku-4-5';")"
# Fable 5.1, cache read 0.025x: (100 + 2000*20 + 50000*0.25 + 100*50) / 1e6 = 0.0576; co2 = 1.26796
near "stop hook: Fable 5.1 cost, cache read 0.025x" "0.0576"   "$(q "SELECT cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='claude-fable-5-1';")" 0.0000005
near "stop hook: Fable 5.1 CO2"                     "1.26796"  "$(q "SELECT co2_grams FROM session_models WHERE session_id='${SESSION}' AND model='claude-fable-5-1';")"
check "stop hook: non-Claude subagent keeps tokens, no CO2 or cost" "1100|0.0|0.0" \
  "$(q "SELECT (input_tokens + output_tokens)||'|'||co2_grams||'|'||cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='glm-4.7-flash';")"
check "stop hook: session row keeps the main dominant model" "claude-opus-5-5" "$(q "SELECT model FROM sessions WHERE session_id='${SESSION}';")"
check "stop hook: session totals (input incl. cache write, cw, cw1h, cr, out)" "30687|28000|28000|390000|2253" \
  "$(q "SELECT input_tokens||'|'||cache_creation_tokens||'|'||cache_creation_1h_tokens||'|'||cache_read_tokens||'|'||output_tokens FROM sessions WHERE session_id='${SESSION}';")"
near "stop hook: session cost = sum over models" "0.343658" "$(q "SELECT cost_usd FROM sessions WHERE session_id='${SESSION}';")" 0.0000005
check "stop hook: git branch still captured" "feat/models" "$(q "SELECT git_branch FROM sessions WHERE session_id='${SESSION}';")"
check "invariant after the Stop hook: SUM(children) = session, every column" "0" "$(q "$INVARIANT")"

# A second turn re-records the session: children are replaced, not accumulated.
payload "$SESSION" "$MAIN" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "stop hook again: still one row per model" "5" "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "invariant after a second Stop hook" "0" "$(q "$INVARIANT")"

LIVE_CO2="$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${SESSION}';")"
LIVE_COST="$(q "SELECT printf('%.6f', cost_usd) FROM sessions WHERE session_id='${SESSION}';")"

# ---------------------------------------------------------------- 2. recompute

# Rows recompute must treat differently: a v2 row without children (recorded before the
# table existed), a legacy v1 row, and an excluded session.
q "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, cost_usd, co2_grams, methodology_version, excluded) VALUES
  ('nochild-sonnet46', 'p', 'claude-sonnet-4-6', 1050, 200, 30000, 1000, 1000, 0.7, 0.07, 2, 0),
  ('legacy-v1', 'p', 'claude-opus-4-6', 1000, 100, 0, 0, 0, 9.5, 9.5, 1, 0),
  ('excluded-local', 'p', 'glm-4.7', 1000, 100, 0, 0, 0, 0, 0, 2, 1);"

CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" --with-cost >/dev/null 2>&1
check "recompute: exits 0" "0" "$?"
check "invariant after recompute --with-cost" "0" "$(q "$INVARIANT")"
near "recompute: split session CO2 unchanged vs the Stop hook"  "$LIVE_CO2"  "$(q "SELECT co2_grams FROM sessions WHERE session_id='${SESSION}';")"
near "recompute: split session cost unchanged vs the Stop hook" "$LIVE_COST" "$(q "SELECT cost_usd FROM sessions WHERE session_id='${SESSION}';")" 0.000005
check "recompute: row without children keeps its stored CO2 and cost by default" "0.7|0.07" "$(q "SELECT cost_usd||'|'||co2_grams FROM sessions WHERE session_id='nochild-sonnet46';")"
check "recompute: legacy v1 row untouched" "9.5|9.5" "$(q "SELECT co2_grams||'|'||cost_usd FROM sessions WHERE session_id='legacy-v1';")"
check "recompute: excluded session untouched" "0.0|0.0" "$(q "SELECT co2_grams||'|'||cost_usd FROM sessions WHERE session_id='excluded-local';")"
check "recompute: excluded model child stays at 0" "0.0|0.0" "$(q "SELECT co2_grams||'|'||cost_usd FROM session_models WHERE session_id='${SESSION}' AND model='glm-4.7-flash';")"

SNAP="SELECT group_concat(v, ';') FROM (SELECT session_id||':'||printf('%.12f', co2_grams)||':'||printf('%.12f', cost_usd) AS v FROM sessions UNION ALL SELECT session_id||'/'||model||':'||printf('%.12f', co2_grams)||':'||printf('%.12f', cost_usd) FROM session_models ORDER BY v);"
BEFORE="$(q "$SNAP")"
CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" --with-cost >/dev/null 2>&1
check "recompute: idempotent (second run changes nothing)" "$BEFORE" "$(q "$SNAP")"
CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" >/dev/null 2>&1
check "recompute: CO2-only run changes nothing either" "$BEFORE" "$(q "$SNAP")"

# --include-unsplit opts rows without children in: re-derived at their own model.
OUT="$(CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" --with-cost --include-unsplit 2>&1)"
near "recompute --include-unsplit: row without children re-priced at its model (Sonnet 4.6, 3/15)" "0.01815" "$(q "SELECT cost_usd FROM sessions WHERE session_id='nochild-sonnet46';")" 0.0000005
# co2 = (1050*39 + 30000*39*0.08 + 200*826) / 1e6 = 0.29975
near "recompute --include-unsplit: its CO2 too" "0.29975" "$(q "SELECT co2_grams FROM sessions WHERE session_id='nochild-sonnet46';")" 0.0000005
case "$OUT" in
  *"approximated at their dominant model (--include-unsplit)"*) ok "recompute --include-unsplit: summary says so" ;;
  *) bad "recompute --include-unsplit: summary says so" "the --include-unsplit summary" "$OUT" ;;
esac
check "recompute --include-unsplit: legacy v1 row still untouched" "9.5|9.5" "$(q "SELECT co2_grams||'|'||cost_usd FROM sessions WHERE session_id='legacy-v1';")"
check "invariant after --include-unsplit" "0" "$(q "$INVARIANT")"
CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" --bogus >/dev/null 2>&1
check "recompute: unknown flag refused" "2" "$?"
BEFORE="$(q "$SNAP")"
# The auto-runs on install and update must never approximate unsplit rows.
check "install.sh and update.sh never pass --include-unsplit" "0" "$(grep -c -- '--include-unsplit' "${REPO_DIR}/install.sh" "${REPO_DIR}/scripts/update.sh" | awk -F: '{ n += $NF } END { print n + 0 }')"

# A hostile prices file is refused before any SQL runs.
EVIL="${TMPROOT}/evil-prices.json"
jq '.model_overrides["claude-opus-5-5"].input = "4); DROP TABLE sessions; --"' "${REPO_DIR}/data/prices.json" > "$EVIL"
CLAUDE_CARBON_DB="$DB" CLAUDE_CARBON_PRICES="$EVIL" bash "$RECOMPUTE" --with-cost >/dev/null 2>&1
check "recompute: non-numeric override refused" "1" "$?"
check "recompute: the DB survived it" "$BEFORE" "$(q "$SNAP")"

# ---------------------------------------------------------------- 3. backfill

# New session: backfill writes the same split and totals as the Stop hook.
q "DELETE FROM sessions WHERE session_id='${SESSION}'; DELETE FROM session_models WHERE session_id='${SESSION}';"
CLAUDE_CONFIG_DIR="$CFG" bash "$BACKFILL" >/dev/null 2>&1
check "backfill: same child rows as the Stop hook" "5" "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "backfill: same CO2 as the Stop hook"  "$LIVE_CO2"  "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${SESSION}';")"
check "backfill: same cost as the Stop hook" "$LIVE_COST" "$(q "SELECT printf('%.6f', cost_usd) FROM sessions WHERE session_id='${SESSION}';")"
check "invariant after backfill" "0" "$(q "$INVARIANT")"

# Split pass: the row as a pre-session_models Stop hook left it (same totals, CO2 and cost
# computed per file at the file's dominant model, no children, up to date).
q "DELETE FROM session_models WHERE session_id='${SESSION}'; UPDATE sessions SET co2_grams = 1.0, cost_usd = 1.0, ended_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE session_id='${SESSION}';"
BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "$BACKFILL" 2>/dev/null)"
check "backfill split: children written for an existing row" "5" "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "backfill split: CO2 becomes the per-model sum"  "$LIVE_CO2"  "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${SESSION}';")"
check "backfill split: cost becomes the per-model sum" "$LIVE_COST" "$(q "SELECT printf('%.6f', cost_usd) FROM sessions WHERE session_id='${SESSION}';")"
check "backfill split: token columns kept" "30687|2253" "$(q "SELECT input_tokens||'|'||output_tokens FROM sessions WHERE session_id='${SESSION}';")"
check "invariant after the split pass" "0" "$(q "$INVARIANT")"
case "$BF_OUT" in
  *"Split 1 existing session(s) by model"*) ok "backfill split: reported" ;;
  *) bad "backfill split: reported" "a 'Split 1 existing session(s)' line" "$BF_OUT" ;;
esac
BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "$BACKFILL" 2>/dev/null)"
case "$BF_OUT" in
  *"Split"*) bad "backfill split: a split row is not split again" "no 'Split' line" "$BF_OUT" ;;
  *) ok "backfill split: a split row is not split again" ;;
esac

# A row whose totals disagree with its transcript is left alone: no children, no change.
q "DELETE FROM session_models WHERE session_id='${SESSION}'; UPDATE sessions SET output_tokens = 99, co2_grams = 1.0, cost_usd = 1.0 WHERE session_id='${SESSION}';"
CLAUDE_CONFIG_DIR="$CFG" bash "$BACKFILL" >/dev/null 2>&1
check "backfill split: mismatching row keeps no children" "0" "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "backfill split: mismatching row unchanged" "99|1.0|1.0" "$(q "SELECT output_tokens||'|'||co2_grams||'|'||cost_usd FROM sessions WHERE session_id='${SESSION}';")"

# A stale row (transcript written after ended_at) is refreshed with its split.
q "UPDATE sessions SET ended_at = '2026-01-01T00:00:00Z' WHERE session_id='${SESSION}';"
CLAUDE_CONFIG_DIR="$CFG" bash "$BACKFILL" >/dev/null 2>&1
check "backfill refresh: tokens re-read"          "2253" "$(q "SELECT output_tokens FROM sessions WHERE session_id='${SESSION}';")"
check "backfill refresh: children written"        "5"    "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "invariant after the refresh"               "0"    "$(q "$INVARIANT")"

# ---------------------------------------------------------------- 4. overlapping writers

# The SessionEnd hook's detached run and a Stop hook can land together: the busy timeout
# and the transaction must leave one consistent state.
for _ in 1 2 3 4; do
  payload "$SESSION" "$MAIN" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST" &
done
wait
check "overlapping writers: one row per model" "5" "$(q "SELECT COUNT(*) FROM session_models WHERE session_id='${SESSION}';")"
check "overlapping writers: session recorded"  "$LIVE_CO2" "$(q "SELECT printf('%.4f', co2_grams) FROM sessions WHERE session_id='${SESSION}';")"
check "invariant after overlapping writers"    "0" "$(q "$INVARIANT")"

# ---------------------------------------------------------------- 5. /carbon-pr per-model table

REPO="${TMPROOT}/modelproj"
mkdir -p "$REPO"
git -C "$REPO" init -q -b feat/models 2>/dev/null || { git -C "$REPO" init -q && git -C "$REPO" checkout -q -b feat/models; }
q "UPDATE sessions SET project = 'modelproj' WHERE session_id='${SESSION}';
   INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, methodology_version, excluded, git_branch) VALUES
   ('old-row', 'modelproj', 'claude-opus-4-7', 5000, 500, 0, 0, 0.05, 1.5, 2, 0, 'feat/models');"
PR_OUT="$(cd "$REPO" && CLAUDE_CARBON_DB="$DB" bash "$PR_REPORT" --dry-run 2>&1)"
for m in claude-opus-5-5 claude-sonnet-4-6 claude-haiku-4-5 claude-fable-5-1 claude-opus-4-7; do
  case "$PR_OUT" in
    *"| \`${m}\` | 1 |"*) ok "carbon-pr: per-model row for ${m}" ;;
    *) bad "carbon-pr: per-model row for ${m}" "a '| \`${m}\` | 1 |' row" "$PR_OUT" ;;
  esac
done
case "$PR_OUT" in
  *"| 2 |"*) ok "carbon-pr: headline still counts 2 sessions" ;;
  *) bad "carbon-pr: headline still counts 2 sessions" "'| 2 |' in the headline table" "$PR_OUT" ;;
esac

# ---------------------------------------------------------------- 6. SQL safety

S6="bbbbbbbb-1111-2222-3333-444444444444"
T6="${PROJ_DIR}/${S6}.jsonl"
cat > "$T6" <<'EOF'
{"type":"assistant","requestId":"x1","timestamp":"2026-09-22T11:00:00Z","message":{"id":"mx1","model":"claude-o'pus-5'); DROP TABLE sessions; --","usage":{"input_tokens":10,"output_tokens":1}}}
EOF
payload "$S6" "$T6" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "quoted model id: stored verbatim in session_models" "claude-o'pus-5'); DROP TABLE sessions; --" "$(q "SELECT model FROM session_models WHERE session_id='${S6}';")"
check "quoted model id: sessions table intact" "1" "$(q "SELECT COUNT(*) FROM sessions WHERE session_id='${S6}';")"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} per-model assertions passed."
