#!/usr/bin/env bash
# run-export-tests.sh: assert cc_export_sessions (scripts/portable-lib.sh), which writes
# sessions-history.tsv next to carbon.db for the mod's /carbon-panel pane: sessions not
# excluded and with CO2, legacy (v1) ones included, oldest first, as
# id<TAB>epoch seconds<TAB>grams<TAB>methodology version<TAB>project<TAB>cost; an empty
# file for no rows; the
# DB left untouched; no temp file left behind; a failed query keeping the previous file.
#
# Runs against a throwaway DB under a temp root; the real ~/.claude is never read.
# bash 3.2 compatible (macOS default). Dependencies: sqlite3.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 is required" >&2; exit 1; }

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-export-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

cleanup() {
  case "$TMPROOT" in
    */claude-carbon-export-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"
  fi
}

DB="${TMPROOT}/carbon.db"
OUT="${TMPROOT}/sessions-history.tsv"
sqlite3 "$DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, co2_grams REAL, started_at TEXT, methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, project TEXT, cost_usd REAL, model TEXT, output_tokens INTEGER);
INSERT INTO sessions VALUES
  ('v2-late', 12.3456, '2026-10-12T19:09:55Z', 2, 0, 'my' || char(9) || 'app', 0.45678, 'claude-opus-5-5', 1234),
  ('v2-early', 7, '2026-09-01T08:00:00.123Z', 2, 0, 'site', NULL, NULL, NULL),
  ('v1', 99, '2026-08-01T08:00:00Z', 1, 0, NULL, NULL, NULL, NULL),
  ('excluded', 50, '2026-09-02T08:00:00Z', 2, 1, 'x', NULL, NULL, NULL),
  ('null-excluded', 5, '2026-09-03T08:00:00Z', 2, NULL, 'x', NULL, NULL, NULL),
  ('no-co2', 0, '2026-09-04T08:00:00Z', 2, 0, 'x', NULL, NULL, NULL),
  ('bad-date', 3, 'not a date', 2, 0, 'x', NULL, NULL, NULL);
ALTER TABLE sessions ADD COLUMN input_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER;
UPDATE sessions SET input_tokens = 5000, cache_creation_tokens = 1000, cache_read_tokens = 200000 WHERE session_id = 'v2-late';"
BEFORE="$(cksum <"$DB")"

# The temp files the export may leave next to the DB (none expected)
temp_files() {
  local n=0 f
  for f in "$TMPROOT"/*tmp*; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}

cc_export_sessions "$DB"
TAB="$(printf '\t')"
check "file written" "$([ -f "$OUT" ] && echo yes)" "yes"
check "rows kept, oldest first" "$(cut -f1 "$OUT" | tr '\n' ' ')" "v1 v2-early null-excluded v2-late "
check "methodology version" "$(cut -f4 "$OUT" | tr '\n' ' ')" "1 2 2 2 "
check "epoch seconds" "$(grep '^v2-late' "$OUT" | cut -f2)" "1791832195"
check "milliseconds in the date" "$(grep '^v2-early' "$OUT" | cut -f2)" "1788249600"
check "grams to the milligram" "$(grep '^v2-late' "$OUT" | cut -f3)" "12.346"
check "tab-separated, eleven fields" "$(awk -F"$TAB" 'NF != 11' "$OUT" | wc -l | tr -d ' ')" "0"
check "tokens by kind: uncached input, cache write, cache read, output" "$(grep '^v2-late' "$OUT" | cut -f8-11 | tr "$TAB" ' ')" "4000 1000 200000 1234"
check "tokens unknown: zeros" "$(grep '^v1' "$OUT" | cut -f8-11 | tr "$TAB" ' ')" "0 0 0 0"
check "model" "$(grep '^v2-late' "$OUT" | cut -f7)" "claude-opus-5-5"
check "cost to four decimals" "$(grep '^v2-late' "$OUT" | cut -f6)" "0.4568"
check "no cost: empty field" "$(grep '^v1' "$OUT" | cut -f6)" ""
check "project, a tab in its name made a space" "$(grep '^v2-late' "$OUT" | cut -f5)" "my app"
check "no project: empty field" "$(grep '^v1' "$OUT" | cut -f5)" ""
check "database untouched" "$(cksum <"$DB")" "$BEFORE"
check "no temp file left" "$(temp_files)" "0"

# No rows: an empty file, which the pane reads as an empty history
sqlite3 "$DB" "UPDATE sessions SET excluded = 1;"
cc_export_sessions "$DB"
check "no rows: empty file" "$(wc -c <"$OUT" | tr -d ' ')" "0"

# A query that fails keeps the previous file
printf 'previous\t1\t2\n' >"$OUT"
cc_export_sessions "${TMPROOT}/missing.db"
check "missing DB: no file next to it" "$([ -f "${TMPROOT}/missing.db" ] && echo created)" ""
check "failed query keeps the previous file" "$(cat "$OUT")" "previous${TAB}1${TAB}2"
check "failed query: no temp file left" "$(temp_files)" "0"

# The SessionStart hook writes it too, detached, so the pane has a history before the
# session's first answer
# the rows back as they were
sqlite3 "$DB" "UPDATE sessions SET excluded = 0 WHERE session_id <> 'excluded';"
rm -f "$OUT"
printf '{}' | CLAUDE_CONFIG_DIR="${TMPROOT}/config" CLAUDE_CARBON_DB="$DB" \
  bash "${REPO_DIR}/scripts/safety-rescan.sh"
i=0
while [ ! -s "$OUT" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
check "session start writes the history" "$(cut -f1 "$OUT" | tr '\n' ' ')" "v1 v2-early null-excluded v2-late "

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
