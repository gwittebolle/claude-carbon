#!/usr/bin/env bash
# run-pr-tests.sh — assert the /carbon-pr pipeline end to end without touching
# the network: (a) persist-session.sh captures git_branch from a transcript's
# envelope fields, (b) backfill's repair pass fills the branch on pre-existing
# rows, (c) generate-pr-report.sh --dry-run sums exactly the current branch's
# sessions and renders the comment contract (marker, Estimated, turn off, no
# em-dash), (d) the posting path, through a stub gh that keeps the body it is sent.
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

# ---------------------------------------------------------------- 4b. --pr reports the PR's branch
# Run from another branch: a stub gh says PR 42's head is feat/x, so the report sums
# feat/x, not the branch the command runs on.
STUBS="${TMPROOT}/stubs"
mkdir -p "$STUBS"
cat > "${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view 42 --json headRefName,isCrossRepository --jq "*) echo "feat/x false" ;;
  # A PR from a fork, opened from the contributor's main
  "pr view 43 --json headRefName,isCrossRepository --jq "*) echo "main true" ;;
  # An older gh without the field
  "pr view 44 --json headRefName,isCrossRepository --jq "*) echo 'Unknown JSON field: "isCrossRepository"' >&2; exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${STUBS}/gh"
git -C "$WORKDIR" checkout -q -b main-like 2>/dev/null
OUT="$(cd "$WORKDIR" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB2" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" --dry-run --pr 42)"
check "--pr: the PR's branch, not the current one" "yes" "$(echo "$OUT" | grep -qF 'sessions on `feat/x`' && echo "$OUT" | grep -q '| 2 |' && echo yes || echo no)"
ERR="$(cd "$WORKDIR" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB2" bash "$PR_SCRIPT" --dry-run --pr 7 2>&1)"
RC=$?
check "--pr: an unreadable PR stops, nothing posted" "1|yes" "$RC|$(echo "$ERR" | grep -q 'could not read the branch of PR #7' && echo yes || echo no)"
ERR="$(cd "$WORKDIR" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB2" bash "$PR_SCRIPT" --dry-run --pr 43 2>&1)"
RC=$?
check "--pr: a PR from a fork is refused, main not summed" "1|yes|no" \
  "$RC|$(echo "$ERR" | grep -q 'comes from a fork' && echo yes || echo no)|$(echo "$ERR" | grep -q 'developing this PR' && echo yes || echo no)"
ERR="$(cd "$WORKDIR" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB2" bash "$PR_SCRIPT" --dry-run --pr 44 2>&1)"
RC=$?
check "--pr: gh's own message shown when it fails" "1|yes" "$RC|$(echo "$ERR" | grep -q 'Unknown JSON field' && echo yes || echo no)"
for BAD in "feat/x" "https://github.com/o/r/pull/42" ""; do
  ERR="$(cd "$WORKDIR" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB2" bash "$PR_SCRIPT" --dry-run --pr "$BAD" 2>&1)"
  RC=$?
  check "--pr: '${BAD}' is not a PR number" "2|yes" "$RC|$(echo "$ERR" | grep -q 'takes a PR number' && echo yes || echo no)"
done
OUT="$(cd "$WORKDIR" && CLAUDE_CARBON_DB="$DB3" bash "$PR_SCRIPT" --dry-run)"
check "no sessions: nothing posted, worktree hint" "yes" "$(echo "$OUT" | grep -q 'nothing posted' && echo "$OUT" | grep -q 'worktree' && echo yes || echo no)"
git -C "$WORKDIR" checkout -q feat/x 2>/dev/null

# ---------------------------------------------------------------- 4c. posting
# The real path without the network: the stub finds no earlier comment and keeps the body
# it is sent. TMPDIR holds a native Windows path, as Git Bash can hand down: mktemp cannot
# use it, so the body file has to come from cc_tmpdir or nothing is posted.
POST_STUBS="${TMPROOT}/post-stubs"
mkdir -p "$POST_STUBS"
cat > "${POST_STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
for LAST; do :; done
case "$*" in
  "pr view 42 --json headRefName,isCrossRepository --jq "*) echo "feat/x false" ;;
  "api repos/{owner}/{repo}/issues/42/comments?per_page=100 --jq "*) ;;
  "api -X POST repos/{owner}/{repo}/issues/42/comments --input "*) cp "$LAST" "$GH_STUB_POSTED" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${POST_STUBS}/gh"
POSTED="${TMPROOT}/posted.json"
OUT="$(cd "$WORKDIR" && PATH="${POST_STUBS}:$PATH" GH_STUB_POSTED="$POSTED" TMPDIR='C:\Users\nobody\AppData\Local\Temp' \
  CLAUDE_CARBON_DB="$DB2" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" --pr 42 2>&1)"
RC=$?
check "post: a Windows TMPDIR still posts" "0|yes" "$RC|$(echo "$OUT" | grep -q 'Posted the dev carbon report on PR #42' && echo yes || echo no)"
check "post: the body sent is the report" "yes" \
  "$(jq -r '.body' "$POSTED" 2>/dev/null | grep -qF '<!-- claude-carbon-dev-report -->' && jq -r '.body' "$POSTED" | grep -qF 'sessions on `feat/x`' && echo yes || echo no)"

# The automatic run (--auto, started by the Stop hook) refuses a PR whose branch lives in
# a fork; asked by hand, the same PR is posted
AUTO_STUBS="${TMPROOT}/auto-stubs"
mkdir -p "$AUTO_STUBS"
cat > "${AUTO_STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
for LAST; do :; done
case "$*" in
  "repo view --json url --jq "*) [ -z "${GH_REPO:-}" ] || exit 1; echo "${GH_STUB_URL}" ;;
  "pr view --json number,isCrossRepository --jq "*) echo "42 ${GH_STUB_CROSS}" ;;
  "api repos/{owner}/{repo}/issues/42/comments?per_page=100 --jq "*) ;;
  "api -X POST repos/{owner}/{repo}/issues/42/comments --input "*) cp "$LAST" "$GH_STUB_POSTED" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${AUTO_STUBS}/gh"
auto_run() { # $1 = isCrossRepository, rest = options
  local cross="$1"
  shift
  rm -f "$POSTED"
  (cd "$WORKDIR" && git checkout -q feat/x 2>/dev/null; git symbolic-ref HEAD refs/heads/feat/x &&
    git config remote.origin.url "git@github.com:Acme/MyProj.git" && PATH="${AUTO_STUBS}:$PATH" GH_STUB_POSTED="$POSTED" GH_STUB_CROSS="$cross" GH_STUB_URL="${GH_STUB_URL-https://github.com/acme/myproj}" \
    CLAUDE_CARBON_DB="$DB2" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" "$@" >/dev/null 2>&1)
  echo "$?|$([ -f "$POSTED" ] && echo posted || echo nothing)"
}
check "auto: a PR of the repository is posted" "0|posted" "$(auto_run false --auto)"
check "auto: a PR from a fork is refused" "1|nothing" "$(auto_run true --auto)"
check "auto: an unreadable origin is refused" "1|nothing" "$(auto_run '' --auto)"
check "by hand: a PR from a fork is posted" "0|posted" "$(auto_run true)"
check "auto: gh aiming at another repository is refused" "1|nothing" "$(GH_STUB_URL=https://github.com/victim/other auto_run false --auto)"
check "auto: a repository gh cannot name is refused" "1|nothing" "$(GH_STUB_URL='' auto_run false --auto)"
check "auto: GH_REPO from the environment is dropped" "0|posted" "$(GH_REPO=victim/other auto_run false --auto)"
git -C "$WORKDIR" config --unset remote.origin.url

# ---------------------------------------------------------------- 4d. --summary
# The reports already posted on merged PRs, read back through a stub gh: three PRs by two
# authors over two months, one comment in the older one-line form (unread), one PR whose
# comment is someone's hand-written text with the marker and an odd login.
SUM_STUBS="${TMPROOT}/sum-stubs"
mkdir -p "$SUM_STUBS"
cat > "${SUM_STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "repo view --json nameWithOwner --jq "*) echo "acme/app" ;;
  "api -X GET search/issues -f q=repo:acme/app is:pr is:merged in:comments \"claude-carbon-dev-report\""*)
    case "$*" in *"merged:>=2026-10-01"*) printf '2\n12\t2026-10-03T09:00:00Z\n13\t2026-10-20T09:00:00Z\n' ;;
      *"merged:>=2026-11-01"*) printf '2\n15\t2026-11-02T09:00:00Z\n16\t2026-11-03T09:00:00Z\n' ;;
      *) printf '5\n10\t2026-09-12T09:00:00Z\n11\t2026-09-30T23:00:00Z\n12\t2026-10-03T09:00:00Z\n13\t2026-10-20T09:00:00Z\n14\t2026-10-21T09:00:00Z\n' ;;
    esac ;;
  "api repos/acme/app/issues/10/comments?per_page=100 --jq "*) printf 'alice\t| **575 g** | $17.26 | 1.6M | 90.9M | 1 |\n' ;;
  "api repos/acme/app/issues/11/comments?per_page=100 --jq "*) printf 'bob-dev\t| **1.2 kg** | $40.00 | 3.0M | 200M | 3 |\n' ;;
  "api repos/acme/app/issues/12/comments?per_page=100 --jq "*) printf 'alice\t| **69 g** | $1.92 | 184k | 9.3M | 1 |\n' ;;
  "api repos/acme/app/issues/13/comments?per_page=100 --jq "*) printf 'alice\t\n' ;;
  "api repos/acme/app/issues/14/comments?per_page=100 --jq "*) printf 'mal$(id)\t| **5 g** | $0.10 | 1k | 1k | 1 |\n' ;;
  "api repos/acme/app/issues/15/comments?per_page=100 --jq "*) printf 'carol_acme\t| **31 g** | $1.00 | 1k | 1k | 2 |\n' ;;
  "api repos/acme/app/issues/16/comments?per_page=100 --jq "*) echo "HTTP 502" >&2; exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${SUM_STUBS}/gh"
SUM="$(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" CLAUDE_CARBON_DB="${TMPROOT}/absent.db" bash "$PR_SCRIPT" --summary 2>&1)"
check "summary: exit 0 without a database" "0" "$?"
check "summary: September, two PRs"   "2026-09 2 4 1.8 kg \$57.26" "$(echo "$SUM" | awk '$1 == "2026-09" { print $1, $2, $3, $4, $5, $6 }')"
check "summary: October, one PR read" "2026-10 1 1 69 g \$1.92"    "$(echo "$SUM" | awk '$1 == "2026-10" { print $1, $2, $3, $4, $5, $6 }')"
check "summary: per author"           "alice 2 2 644 g \$19.18"    "$(echo "$SUM" | awk '$1 == "alice" { print $1, $2, $3, $4, $5, $6 }')"
check "summary: the total"            "Total: 3 PRs, 5 sessions, 1.8 kg CO2e, \$59.18 at API list price." "$(echo "$SUM" | grep '^Total:')"
check "summary: unread comments are counted, not guessed" "2 comment(s) could not be read (an older format, edited, or posted by a bot) and are left out." "$(echo "$SUM" | grep 'could not be read')"
check "summary: an odd login is not printed" "0" "$(echo "$SUM" | grep -c 'mal')"
SUM="$(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" bash "$PR_SCRIPT" --summary --since 2026-10-01 2>&1)"
check "summary --since: only what was merged from then on" "Total: 1 PRs, 1 sessions, 69 g CO2e, \$1.92 at API list price." "$(echo "$SUM" | grep '^Total:')"
SUM="$(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" bash "$PR_SCRIPT" --summary --since 2026-11-01 2>&1)"
check "summary: a login with an underscore is read" "carol_acme 1 2 31 g \$1.00" "$(echo "$SUM" | awk '$1 == "carol_acme" { print $1, $2, $3, $4, $5, $6 }')"
check "summary: a PR gh could not fetch is said, apart from the unread ones" "1 pull request(s) could not be fetched (gh api failed) and are left out: the totals are partial, run it again." "$(echo "$SUM" | grep 'could not be fetched')"
(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" bash "$PR_SCRIPT" --since 2026-11-01 >/dev/null 2>&1)
check "--since without --summary: refused" "2" "$?"
(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" bash "$PR_SCRIPT" --consent yes --pr 42 >/dev/null 2>&1)
check "--consent with --pr: refused" "2" "$?"
(cd "$WORKDIR" && PATH="${SUM_STUBS}:$PATH" bash "$PR_SCRIPT" --summary --since yesterday >/dev/null 2>&1)
check "summary --since: a date only" "2" "$?"

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
