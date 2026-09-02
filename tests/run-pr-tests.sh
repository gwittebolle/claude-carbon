#!/usr/bin/env bash
# run-pr-tests.sh — assert the /carbon-pr pipeline end to end without touching
# the network: (a) persist-session.sh captures git_branch from a transcript's
# envelope fields, (b) backfill's repair pass fills the branch on pre-existing
# rows, (c) generate-pr-report.sh --dry-run sums exactly the current branch's
# sessions and renders the comment contract (marker, Estimated, turn off, no
# em-dash). The gh posting path needs a live PR and is verified manually.
#
# Every case runs against throwaway dirs (CLAUDE_CARBON_DB, CLAUDE_CONFIG_DIR,
# a scratch git repo); the real ~/.claude is never read or written.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: sqlite3, jq, awk, git.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PR_SCRIPT="${REPO_DIR}/scripts/generate-pr-report.sh"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"

for c in sqlite3 jq awk git; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done
[ -f "$PR_SCRIPT" ] || { echo "FAIL: missing $PR_SCRIPT" >&2; exit 1; }

# cc_tmpdir rather than $TMPDIR directly: under Git Bash on Windows TMPDIR can
# hold a native "C:\Users\..." path, which mktemp cannot use as a template.
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-pr-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-pr-tests.*) rm -rf "$TMPROOT" ;;
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

SCHEMA="CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"

# A scratch git repo named "myproj" on branch feat/x: the attribution key the
# report script derives from its cwd.
WORKDIR="${TMPROOT}/myproj"
mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q -b feat/x 2>/dev/null || { git -C "$WORKDIR" init -q; git -C "$WORKDIR" checkout -q -b feat/x; }

# ---------------------------------------------------------------- 1. the Stop hook captures git_branch

CFG="${TMPROOT}/cfg"
DB="${CFG}/claude-carbon/carbon.db"
mkdir -p "${CFG}/claude-carbon" "${CFG}/projects/-tmp-myproj"
sqlite3 "$DB" "$SCHEMA"
TRANSCRIPT="${CFG}/projects/-tmp-myproj/11111111-2222-3333-4444-555555555555.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","cwd":"/tmp/myproj","gitBranch":"main","sessionId":"11111111-2222-3333-4444-555555555555","message":{"role":"user","content":"start"}}
{"type":"assistant","cwd":"/tmp/myproj","gitBranch":"feat/x","requestId":"req_a","message":{"id":"msg_a","model":"claude-fable-5","usage":{"input_tokens":10000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100000,"output_tokens":10000}}}
EOF
printf '{"session_id": "11111111-2222-3333-4444-555555555555", "transcript_path": "%s", "cwd": "/tmp/myproj"}' "$TRANSCRIPT" \
  | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$PERSIST"

check "persist: row written"        "1"       "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;")"
check "persist: last branch wins"   "feat/x"  "$(sqlite3 "$DB" "SELECT git_branch FROM sessions;")"
check "persist: model captured"     "claude-fable-5" "$(sqlite3 "$DB" "SELECT model FROM sessions;")"

# ---------------------------------------------------------------- 2. legacy DB migrated on the fly

LEGACY_DB="${TMPROOT}/legacy.db"
sqlite3 "$LEGACY_DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live');"
printf '{"session_id": "11111111-2222-3333-4444-555555555555", "transcript_path": "%s", "cwd": "/tmp/myproj"}' "$TRANSCRIPT" \
  | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$LEGACY_DB" bash "$PERSIST"
check "persist migrates legacy DB: git_branch column filled" "feat/x" \
  "$(sqlite3 "$LEGACY_DB" "SELECT git_branch FROM sessions;" 2>/dev/null)"

# ---------------------------------------------------------------- 3. dry-run report sums only this branch

DB2="${TMPROOT}/report.db"
sqlite3 "$DB2" "$SCHEMA"
# Two sessions on the branch (fable + sonnet), one on another branch, one on
# another project, one excluded, one legacy row without a branch.
sqlite3 "$DB2" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, started_at, methodology_version, git_branch) VALUES
  ('s1', 'myproj', 'claude-fable-5',  100000, 20000, 1000000, 40000, 2.50, 100.0, '2026-08-01T00:00:00Z', 2, 'feat/x'),
  ('s2', 'myproj', 'claude-sonnet-4-5', 50000, 10000,  500000, 0, 0.50,  24.4, '2026-08-02T00:00:00Z', 2, 'feat/x'),
  ('s3', 'myproj', 'claude-fable-5',  999999, 99999, 9999999, 0, 9.99, 999.0, '2026-08-03T00:00:00Z', 2, 'other-branch'),
  ('s4', 'otherproj', 'claude-fable-5', 88888, 8888,  888888, 0, 8.88, 888.0, '2026-08-04T00:00:00Z', 2, 'feat/x'),
  ('s6', 'myproj', 'claude-fable-5',  77777,  7777,  777777, 0, 0.77,  77.0, '2026-08-06T00:00:00Z', 2, '');"
sqlite3 "$DB2" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, excluded, git_branch) VALUES
  ('s5', 'myproj', 'glm-4.7-flash', 55555, 5555, 0, 0, '2026-08-05T00:00:00Z', 1, 'feat/x');"

OUT="$(cd "$WORKDIR" && CLAUDE_CARBON_DB="$DB2" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" --dry-run)"
RC=$?

check "dry-run: exit code"           "0"   "$RC"
check "dry-run: marker"              "yes" "$(echo "$OUT" | grep -q '<!-- claude-carbon-dev-report -->' && echo yes || echo no)"
check "dry-run: title"               "yes" "$(echo "$OUT" | grep -q 'developing this PR' && echo yes || echo no)"
# 100.0 + 24.4 g from s1+s2 only (gram tier displays whole grams): other
# branch, other project, excluded and branchless rows all stay out.
check "dry-run: CO2 total"           "yes" "$(echo "$OUT" | grep -q '\*\*124 g\*\*' && echo yes || echo no)"
check "dry-run: cost total"          "yes" "$(echo "$OUT" | grep -q '\$3.00' && echo yes || echo no)"
check "dry-run: tokens total (180k)" "yes" "$(echo "$OUT" | grep -q '| 180k |' && echo yes || echo no)"
check "dry-run: cache reads (1.5M)"  "yes" "$(echo "$OUT" | grep -q '| 1.5M |' && echo yes || echo no)"
check "dry-run: 2 sessions"          "yes" "$(echo "$OUT" | grep -q '| 2 |' && echo yes || echo no)"
# s1 folded input is 100k with 40k of cache write inside: pure input 60k.
check "dry-run: per-model detail"    "yes" "$(echo "$OUT" | grep -qF '`claude-fable-5` | 1 | 60k | 40k | 1.0M | 20k |' && echo yes || echo no)"
# No backslash before the backticks: GNU grep reads \` as a buffer anchor
# (BSD grep as a literal), so the escaped form passes on macOS and fails on CI.
check "dry-run: branch named"        "yes" "$(echo "$OUT" | grep -qF 'sessions on `feat/x`' && echo yes || echo no)"
check "dry-run: Estimated + turn off" "yes" "$(echo "$OUT" | grep -q 'Estimated by \[claude-carbon\]' && echo "$OUT" | grep -q '\[turn off\]' && echo yes || echo no)"
check "dry-run: cost footnote"       "yes" "$(echo "$OUT" | grep -qF 'Cost*' && echo "$OUT" | grep -qF '*API list price of the equivalent usage' && echo yes || echo no)"
check "dry-run: world car factor"    "yes" "$(echo "$OUT" | grep -q '200 g/km, world avg' && echo yes || echo no)"
check "dry-run: no em-dash"          "0"   "$(echo "$OUT" | grep -c '—')"

# ---------------------------------------------------------------- 4. no sessions for the branch

DB3="${TMPROOT}/empty.db"
sqlite3 "$DB3" "$SCHEMA"
OUT="$(cd "$WORKDIR" && CLAUDE_CARBON_DB="$DB3" bash "$PR_SCRIPT" --dry-run)"
RC=$?
check "no sessions: exit code"       "0"   "$RC"
check "no sessions: says so"         "yes" "$(echo "$OUT" | grep -q "No sessions recorded for branch 'feat/x'" && echo yes || echo no)"
check "no sessions: backfill hint"   "yes" "$(echo "$OUT" | grep -q 'backfill.sh' && echo yes || echo no)"

# ---------------------------------------------------------------- 5. guards

ERR="$(cd "$WORKDIR" && CLAUDE_CARBON_DB="${TMPROOT}/absent.db" bash "$PR_SCRIPT" --dry-run 2>&1)"
RC=$?
check "missing DB: exit code" "1" "$RC"
check "missing DB: message"   "Error: carbon.db not found. Run setup.sh first." "$ERR"

NOGIT="${TMPROOT}/nogit"
mkdir -p "$NOGIT"
ERR="$(cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$TMPROOT" CLAUDE_CARBON_DB="$DB2" bash "$PR_SCRIPT" --dry-run 2>&1)"
RC=$?
check "outside a git repo: exit code" "1" "$RC"
check "outside a git repo: message"   "Error: not inside a git repository." "$ERR"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} PR-report assertions passed."
