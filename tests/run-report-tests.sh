#!/usr/bin/env bash
# run-report-tests.sh: run the /carbon-report skill's bash block against fixture
# DBs and assert its two closing lines: the car equivalent of the all-time total
# (the detected set's car row, the only equivalence printed) and the share of a
# 2 t per-person annual budget, computed on the current calendar year only.
#
# Every case runs under a throwaway HOME / CLAUDE_CONFIG_DIR with the DB passed
# through CLAUDE_CARBON_DB; the real ~/.claude is never read or written.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: sqlite3, jq, awk.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SKILL="${REPO_DIR}/skills/carbon-report/SKILL.md"

command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 is required" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "FAIL: missing $SKILL" >&2; exit 1; }

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-report-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-report-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# The skill's bash block, extracted the way a user's Claude runs it.
REPORT="${TMPROOT}/report.sh"
awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$SKILL" > "$REPORT"

YEAR="$(date +%Y)"
LAST_YEAR=$((YEAR - 1))

# make_db <path> <rows>...: each row "<co2_grams>:<year>[:excluded]".
make_db() {
  local db="$1"; shift
  sqlite3 "$db" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 2, excluded INTEGER DEFAULT 0);"
  local i=0 row g y x
  for row in "$@"; do
    i=$((i + 1))
    g="${row%%:*}"; y="${row#*:}"; x=0
    case "$y" in *:1) y="${y%:1}"; x=1 ;; esac
    sqlite3 "$db" "INSERT INTO sessions (session_id, project, model, co2_grams, cost_usd, started_at, excluded) VALUES ('s${i}', 'proj', 'claude-sonnet-4-5', ${g}, 0.5, '${y}-01-02T10:00:00Z', ${x});"
  done
}

# run_report <db> <locale>: full stdout of the skill under a throwaway home.
run_report() (
  home="${TMPROOT}/home"
  mkdir -p "${home}/cfg"
  unset CLAUDE_PLUGIN_ROOT
  export HOME="$home" CLAUDE_CONFIG_DIR="${home}/cfg" CLAUDE_CARBON_DIR="$REPO_DIR" \
    CLAUDE_CARBON_DB="$1" CLAUDE_CARBON_LOCALE="$2"
  bash "$REPORT" 2>&1
)
line_after() { echo "$1" | grep -A1 -F -- "$2" | sed -n 2p; }

# ---------------------------------------------------------------- 1. French set

# This year: 1,000 kg + 214 kg, plus an excluded session that must not count.
# Last year: 500 kg, in the all-time car figure but not in the budget share.
DB="${TMPROOT}/main.db"
make_db "$DB" "1000000:${YEAR}" "214000:${YEAR}" "500000:${LAST_YEAR}" "9000000:${YEAR}:1"

OUT="$(run_report "$DB" fr_FR)"
# All-time 1,714,000 g / 142 g/km = 12,070 km.
check "fr: car row, all-time total" \
  "       12070 km en voiture        (142 gCO2e/km, ADEME 2025)" \
  "$(line_after "$OUT" "--- Car equivalent (all-time) ---")"
check "fr: budget line on the calendar year" \
  "  Depuis le 1er janvier : 1 214 kg, soit 61 % du budget annuel de 2 t par personne" \
  "$(line_after "$OUT" "--- Annual budget (${YEAR}) ---")"
check "fr: budget note" "yes" \
  "$(echo "$OUT" | grep -qF "(cible 2050 pour l'empreinte totale d'une personne, Carbone 4 2019)" && echo yes || echo no)"
check "fr: no other equivalence" "no" \
  "$(echo "$OUT" | grep -qiE 'gemini|steak|tgv|smartphone' && echo yes || echo no)"

# ---------------------------------------------------------------- 2. US and world sets

OUT="$(run_report "$DB" en_US)"
check "us: car row in miles" \
  "        4361 miles driven by car  (393 gCO2e/mile, EPA, US average)" \
  "$(line_after "$OUT" "--- Car equivalent (all-time) ---")"
check "us: budget line in English" \
  "  Since January 1: 1,214 kg, 61% of a 2 t per-person annual budget" \
  "$(line_after "$OUT" "--- Annual budget (${YEAR}) ---")"
check "us: budget note" "yes" \
  "$(echo "$OUT" | grep -qF "(2050 target for a person's whole footprint, Carbone 4 2019)" && echo yes || echo no)"
check "us: no other equivalence" "no" \
  "$(echo "$OUT" | grep -qiE 'gemini|steak|tgv|smartphone' && echo yes || echo no)"

OUT="$(run_report "$DB" de_DE)"
check "world: car row" \
  "        8570 km driven by car     (200 gCO2/km, world average)" \
  "$(line_after "$OUT" "--- Car equivalent (all-time) ---")"

# ---------------------------------------------------------------- 3. small totals

DB="${TMPROOT}/small.db"
make_db "$DB" "3400:${YEAR}"
check "fr: one decimal under 10 kg" \
  "  Depuis le 1er janvier : 3,4 kg, soit 0,2 % du budget annuel de 2 t par personne" \
  "$(line_after "$(run_report "$DB" fr_FR)" "--- Annual budget (${YEAR}) ---")"
check "en: one decimal under 10 kg" \
  "  Since January 1: 3.4 kg, 0.2% of a 2 t per-person annual budget" \
  "$(line_after "$(run_report "$DB" en_GB)" "--- Annual budget (${YEAR}) ---")"

DB="${TMPROOT}/tiny.db"
make_db "$DB" "40:${YEAR}"
check "fr: grams and a floor under 0.1 %" \
  "  Depuis le 1er janvier : 40 g, soit < 0,1 % du budget annuel de 2 t par personne" \
  "$(line_after "$(run_report "$DB" fr_FR)" "--- Annual budget (${YEAR}) ---")"

# Rounding boundaries: 9.98 kg and 9.975 % round up to 10, printed whole.
DB="${TMPROOT}/edge-kg.db"
make_db "$DB" "9980:${YEAR}"
check "fr: 9.98 kg rounds to whole kg" \
  "  Depuis le 1er janvier : 10 kg, soit 0,5 % du budget annuel de 2 t par personne" \
  "$(line_after "$(run_report "$DB" fr_FR)" "--- Annual budget (${YEAR}) ---")"
DB="${TMPROOT}/edge-pct.db"
make_db "$DB" "199500:${YEAR}"
check "fr: 9.975 % rounds to a whole percent" \
  "  Depuis le 1er janvier : 200 kg, soit 10 % du budget annuel de 2 t par personne" \
  "$(line_after "$(run_report "$DB" fr_FR)" "--- Annual budget (${YEAR}) ---")"

# Sessions only in earlier years: the budget share starts again at zero.
DB="${TMPROOT}/old.db"
make_db "$DB" "500000:${LAST_YEAR}"
check "fr: nothing this year" \
  "  Depuis le 1er janvier : 0 g, soit 0 % du budget annuel de 2 t par personne" \
  "$(line_after "$(run_report "$DB" fr_FR)" "--- Annual budget (${YEAR}) ---")"

# Over the budget, whole kg grouped by thousands.
DB="${TMPROOT}/big.db"
make_db "$DB" "2468000:${YEAR}"
check "en: over the budget" \
  "  Since January 1: 2,468 kg, 123% of a 2 t per-person annual budget" \
  "$(line_after "$(run_report "$DB" en_US)" "--- Annual budget (${YEAR}) ---")"

echo ""
echo "passed: ${PASSED}   failed: ${FAILED}"
[ "$FAILED" -eq 0 ] || exit 1
