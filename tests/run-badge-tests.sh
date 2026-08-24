#!/usr/bin/env bash
# run-badge-tests.sh — assert scripts/generate-badge.sh output against fixture DBs:
# unit tiers (g/kg/t), shields escaping (double dash, %20, %2C), FR decimal comma,
# excluded-session filtering, the clickable snippet, and the missing-DB failure.
# Also unit-checks scripts/format-lib.sh directly: generate-report.sh sources it,
# and the golden vectors do not cover display formatting.
#
# Every case runs against a throwaway sqlite DB via CLAUDE_CARBON_DB; the real
# ~/.claude is never read or written.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: sqlite3, bc.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BADGE="${REPO_DIR}/scripts/generate-badge.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 is required" >&2; exit 1; }
command -v bc      >/dev/null 2>&1 || { echo "FAIL: bc is required" >&2; exit 1; }
[ -f "$BADGE" ] || { echo "FAIL: missing $BADGE" >&2; exit 1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-badge-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-badge-tests.*) rm -rf "$TMPROOT" ;;
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

# make_db <path> <co2_grams>... — one session row per amount, all v2/live.
make_db() {
  local db="$1"; shift
  sqlite3 "$db" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0);"
  local i=0 g
  for g in "$@"; do
    i=$((i + 1))
    sqlite3 "$db" "INSERT INTO sessions (session_id, project, model, co2_grams, cost_usd, started_at, methodology_version) VALUES ('s${i}', 'proj', 'claude-sonnet-4-5', ${g}, 0.5, '2026-01-0${i}T00:00:00Z', 2);"
  done
}

# run_badge <db> <locale> — full stdout; url_of / snippet_of extract one line each.
run_badge()  { CLAUDE_CARBON_DB="$1" CLAUDE_CARBON_LOCALE="$2" bash "$BADGE" 2>/dev/null; }
url_of()     { echo "$1" | grep '^https://img.shields.io/'; }
snippet_of() { echo "$1" | grep '^\[!\['; }

# ---------------------------------------------------------------- 1. gram tier

DB="${TMPROOT}/grams.db"
make_db "$DB" 431.7
OUT="$(run_badge "$DB" en_US)"
check "gram tier: URL" "https://img.shields.io/badge/claude--carbon-432%20g%20CO2e-2f6f4f" "$(url_of "$OUT")"

# ---------------------------------------------------------------- 2. kg tier

DB="${TMPROOT}/kg.db"
make_db "$DB" 12000 400
OUT="$(run_badge "$DB" en_US)"
check "kg tier: URL" "https://img.shields.io/badge/claude--carbon-12.4%20kg%20CO2e-2f6f4f" "$(url_of "$OUT")"

# ---------------------------------------------------------------- 3. tonne tier

# The tonne tier starts at 10 t. A one-tonne total, which is what a year of heavy
# personal use looks like, stays in kilograms so the badge keeps a figure with
# some weight to it rather than collapsing to "1.2 t".
DB="${TMPROOT}/below-tonne-tier.db"
make_db "$DB" 1234000
OUT="$(run_badge "$DB" en_US)"
check "below tonne tier: still kg" "https://img.shields.io/badge/claude--carbon-1234.0%20kg%20CO2e-2f6f4f" "$(url_of "$OUT")"

DB="${TMPROOT}/tonne.db"
make_db "$DB" 12340000
OUT="$(run_badge "$DB" en_US)"
check "tonne tier: URL" "https://img.shields.io/badge/claude--carbon-12.3%20t%20CO2e-2f6f4f" "$(url_of "$OUT")"

# ---------------------------------------------------------------- 4. FR comma, escaped

DB="${TMPROOT}/fr.db"
make_db "$DB" 12400
OUT="$(run_badge "$DB" fr_FR)"
check "fr locale: decimal comma escaped" "https://img.shields.io/badge/claude--carbon-12%2C4%20kg%20CO2e-2f6f4f" "$(url_of "$OUT")"

# ---------------------------------------------------------------- 5. excluded sessions ignored

DB="${TMPROOT}/excluded.db"
make_db "$DB" 500
sqlite3 "$DB" "INSERT INTO sessions (session_id, model, co2_grams, excluded) VALUES ('sx', 'glm-4.7-flash', 99000, 1);"
OUT="$(run_badge "$DB" en_US)"
check "excluded rows: not counted" "https://img.shields.io/badge/claude--carbon-500%20g%20CO2e-2f6f4f" "$(url_of "$OUT")"

# ---------------------------------------------------------------- 6. snippet is clickable

DB="${TMPROOT}/snippet.db"
make_db "$DB" 12400
OUT="$(run_badge "$DB" en_US)"
check "snippet: clickable to the repo" \
  "[![Claude Code carbon footprint](https://img.shields.io/badge/claude--carbon-12.4%20kg%20CO2e-2f6f4f)](https://github.com/gwittebolle/claude-carbon)" \
  "$(snippet_of "$OUT")"

# ---------------------------------------------------------------- 7. missing DB fails loudly

ERR="$(CLAUDE_CARBON_DB="${TMPROOT}/does-not-exist.db" bash "$BADGE" 2>&1)"
RC=$?
check "missing DB: exit code"  "1" "$RC"
check "missing DB: message"    "Error: carbon.db not found. Run setup.sh first." "$ERR"

# ---------------------------------------------------------------- 8. format-lib unit checks

# shellcheck source=../scripts/format-lib.sh
. "${REPO_DIR}/scripts/format-lib.sh"
check "format_co2 999"      "999 g"      "$(format_co2 999)"
check "format_co2 1000"     "1.0 kg"     "$(format_co2 1000)"
check "format_co2 999999"   "1000.0 kg"  "$(format_co2 999999)"
# The tonne tier starts at 10 t, not 1 t: a one-tonne total reads as "1016.3 kg",
# not "1.0 t", so the figure keeps its weight instead of collapsing to a rounding
# artefact. These four pin the boundary from both sides.
check "format_co2 1000000"  "1000.0 kg"  "$(format_co2 1000000)"
check "format_co2 1016300"  "1016.3 kg"  "$(format_co2 1016300)"
check "format_co2 9999999"  "10000.0 kg" "$(format_co2 9999999)"
check "format_co2 10000000" "10.0 t"     "$(format_co2 10000000)"
check "format_co2 25400000" "25.4 t"     "$(format_co2 25400000)"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} badge assertions passed."
