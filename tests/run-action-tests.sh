#!/usr/bin/env bash
# run-action-tests.sh — three suites over the GitHub Action's compute path:
#   1. scripts/compute-lib.sh replayed against every methodology golden vector
#      (proves the action shares the plugin's math, not a fork of it);
#   2. scripts/action-report.sh end-to-end on tests/fixtures/execution-output.json
#      (aggregation, dedup, exclusion, outputs, summary);
#   3. the never-fail contract: every malformed input must exit 0 with an
#      honest status, never a plausible-looking zero report.
# The sticky-comment path needs a live API and is covered by the dogfood
# workflow plus a documented manual check, not here.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: jq, awk.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VECTORS_FILE="${SCRIPT_DIR}/methodology-vectors.json"
FIXTURE="${SCRIPT_DIR}/fixtures/execution-output.json"
ACTION_SCRIPT="${REPO_DIR}/scripts/action-report.sh"
REL_TOL="0.000001" # 1e-6, same as run-vectors.sh

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$VECTORS_FILE" ] || { echo "FAIL: missing $VECTORS_FILE" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FAIL: missing $FIXTURE" >&2; exit 1; }
[ -f "$ACTION_SCRIPT" ] || { echo "FAIL: missing $ACTION_SCRIPT" >&2; exit 1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-action-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-action-tests.*) rm -rf "$TMPROOT" ;;
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

# Relative-tolerance comparison (absolute when expected == 0). Returns 0 on match.
close_enough() {
  echo "$1 $2 $REL_TOL" | LC_ALL=C awk '{
    actual = $1; expected = $2; tol = $3;
    diff = actual - expected; if (diff < 0) diff = -diff;
    ref = expected; if (ref < 0) ref = -ref;
    if (ref == 0) { exit (diff <= tol) ? 0 : 1 }
    exit (diff / ref <= tol) ? 0 : 1
  }'
}

# ---------------------------------------------------------------- 1. compute-lib vs golden vectors

# shellcheck source=../scripts/compute-lib.sh
. "${REPO_DIR}/scripts/compute-lib.sh"
if ! carbon_load_rates "${REPO_DIR}/data/factors.json" "${REPO_DIR}/data/prices.json"; then
  echo "FAIL: carbon_load_rates could not read data/factors.json + data/prices.json" >&2
  exit 1
fi

N="$(jq '.vectors | length' "$VECTORS_FILE")"
i=0
while [ "$i" -lt "$N" ]; do
  ROW="$(jq -r --argjson i "$i" '.vectors[$i] | [
    .id, .model,
    (.input_tokens // 0), (.cache_creation_tokens // 0),
    (.cache_read_tokens // 0), (.output_tokens // 0),
    (if .excluded == true then "1" else "0" end),
    (.expected_co2_grams // 0), (.expected_cost_usd // 0)
  ] | @tsv' "$VECTORS_FILE")"
  IFS="$(printf '\t')" read -r ID MODEL IN CW CR OUT EXCLUDED EXP_CO2 EXP_COST <<EOF
$ROW
EOF
  # Excluded vectors expect the lib's "0 0" (expected_* is null upstream).
  if [ "$EXCLUDED" = "1" ]; then EXP_CO2="0"; EXP_COST="0"; fi
  read -r CO2 COST <<EOF
$(carbon_compute "$MODEL" "$IN" "$CW" "$CR" "$OUT")
EOF
  if close_enough "$CO2" "$EXP_CO2" && close_enough "$COST" "$EXP_COST"; then
    ok "vector ${ID}: carbon_compute matches"
  else
    bad "vector ${ID}: carbon_compute" "co2=${EXP_CO2} cost=${EXP_COST}" "co2=${CO2} cost=${COST}"
  fi
  i=$((i + 1))
done

check "carbon_family alias forms" "fable opus sonnet haiku" \
  "$(carbon_family claude-mythos-5) $(carbon_family claude-opus-5) $(carbon_family claude-sonnet-4-5) $(carbon_family claude-3-5-haiku)"
check "carbon_is_excluded_model non-claude" "excluded" \
  "$(carbon_is_excluded_model glm-4.7-flash && echo excluded || echo kept)"

# ---------------------------------------------------------------- 2. fixture end-to-end

# run_action <execution_file> [extra env assignments...] — runs the entrypoint
# with GITHUB_OUTPUT/GITHUB_STEP_SUMMARY on fresh temp files. Sets RC/OUT_FILE/
# SUM_FILE in the caller's shell (no command substitution: a subshell would
# swallow the variable assignments).
OUT_FILE=""
SUM_FILE=""
RC=""
CASE_N=0
run_action() {
  local exec_file="$1"; shift
  CASE_N=$((CASE_N + 1))
  OUT_FILE="${TMPROOT}/gh-output.${CASE_N}"
  SUM_FILE="${TMPROOT}/gh-summary.${CASE_N}"
  : > "$OUT_FILE"; : > "$SUM_FILE"
  env -u GH_TOKEN -u GITHUB_EVENT_PATH -u GITHUB_REPOSITORY \
    INPUT_EXECUTION_FILE="$exec_file" GITHUB_OUTPUT="$OUT_FILE" GITHUB_STEP_SUMMARY="$SUM_FILE" \
    "$@" bash "$ACTION_SCRIPT" >/dev/null 2>&1
  RC=$?
}

# output_of <name> — last value written for an output (heredoc outputs excluded).
output_of() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2-; }

run_action "$FIXTURE"
check "fixture: exit code"          "0"        "$RC"
check "fixture: status"             "ok"       "$(output_of status)"
check "fixture: total_tokens"       "150000"   "$(output_of total_tokens)"
check "fixture: cache_read_tokens"  "350000"   "$(output_of cache_read_tokens)"
if close_enough "$(output_of co2_grams)" "33.2460"; then
  ok "fixture: co2_grams"
else
  bad "fixture: co2_grams" "33.2460" "$(output_of co2_grams)"
fi
if close_enough "$(output_of cost_usd)" "0.882500"; then
  ok "fixture: cost_usd"
else
  bad "fixture: cost_usd" "0.882500" "$(output_of cost_usd)"
fi
check "fixture: comment carries the marker" "yes" \
  "$(grep -q '<!-- claude-carbon-report -->' "$OUT_FILE" && echo yes || echo no)"
check "fixture: comment says Estimated by claude-carbon" "yes" \
  "$(grep -q 'Estimated by \[claude-carbon\]' "$OUT_FILE" && echo yes || echo no)"
check "fixture: comment links methodology and turn off" "yes" \
  "$(grep -q '\[methodology\]' "$OUT_FILE" && grep -q '\[turn off\]' "$OUT_FILE" && echo yes || echo no)"
check "fixture: comment carries the token detail table" "yes" \
  "$(grep -q '| Model | Input | Cache write | Cache read | Output | CO2e | Cost |' "$OUT_FILE" && echo yes || echo no)"
# House writing rule: no em-dash in anything the action renders.
check "fixture: no em-dash in the rendered report" "0" \
  "$(grep -c '—' "$OUT_FILE" "$SUM_FILE" | awk -F: '{s += $NF} END {print s}')"
check "fixture: summary written" "yes" \
  "$(grep -q 'Claude Code carbon report' "$SUM_FILE" && echo yes || echo no)"
check "fixture: summary lists the excluded model" "yes" \
  "$(grep -q 'glm-4.7-flash.*excluded' "$SUM_FILE" && echo yes || echo no)"
check "fixture: world car equivalence" "yes" \
  "$(grep -q 'driven by car (200 g/km, world avg)' "$SUM_FILE" && echo yes || echo no)"

# fr locale input swaps the factor set
run_action "$FIXTURE" INPUT_LOCALE=fr
check "fixture fr locale: ADEME factor" "yes" \
  "$(grep -q 'ADEME' "$SUM_FILE" && echo yes || echo no)"

# comment: false still computes and writes the summary
run_action "$FIXTURE" INPUT_COMMENT=false
check "comment=false: exit code" "0" "$RC"
check "comment=false: status"    "ok" "$(output_of status)"
check "comment=false: summary still written" "yes" \
  "$(grep -q 'Claude Code carbon report' "$SUM_FILE" && echo yes || echo no)"

# opt-out label short-circuits before any API call (no token needed)
EVENT="${TMPROOT}/event-labeled.json"
printf '{"pull_request": {"number": 7, "labels": [{"name": "no-carbon-report"}]}}' > "$EVENT"
run_action "$FIXTURE" GITHUB_EVENT_PATH="$EVENT"
check "opt-out label: exit code" "0" "$RC"
check "opt-out label: status"    "ok" "$(output_of status)"

# ---------------------------------------------------------------- 3. never-fail contract

run_action "${TMPROOT}/does-not-exist.json"
check "missing file: exit code" "0" "$RC"
check "missing file: status"    "skipped" "$(output_of status)"

: > "${TMPROOT}/empty.json"
run_action "${TMPROOT}/empty.json"
check "empty file: exit code" "0" "$RC"
check "empty file: status"    "skipped" "$(output_of status)"

printf 'this is not json' > "${TMPROOT}/invalid.json"
run_action "${TMPROOT}/invalid.json"
check "invalid JSON: exit code" "0" "$RC"
check "invalid JSON: status"    "skipped" "$(output_of status)"

printf '{}' > "${TMPROOT}/object.json"
run_action "${TMPROOT}/object.json"
check "non-array JSON: exit code" "0" "$RC"
check "non-array JSON: status"    "skipped" "$(output_of status)"

# Assistant messages whose usage aggregates to zero: schema drift smell, must
# refuse to report a plausible zero.
printf '[{"type":"assistant","requestId":"r","message":{"id":"m","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}]' > "${TMPROOT}/zeros.json"
run_action "${TMPROOT}/zeros.json"
check "all-zero usage: exit code" "0" "$RC"
check "all-zero usage: status"    "error" "$(output_of status)"

# Assistant messages without any usage object at all: same drift guard.
printf '[{"type":"assistant","message":{"id":"m","model":"claude-sonnet-4-5"}}]' > "${TMPROOT}/no-usage.json"
run_action "${TMPROOT}/no-usage.json"
check "usage-less assistants: exit code" "0" "$RC"
check "usage-less assistants: status"    "error" "$(output_of status)"

# Unreadable rates: copy the scripts to a root without data/ so
# carbon_load_rates fails, the honest way to simulate a broken checkout.
mkdir -p "${TMPROOT}/broken-root/scripts"
cp "${REPO_DIR}/scripts/action-report.sh" "${REPO_DIR}/scripts/compute-lib.sh" "${REPO_DIR}/scripts/format-lib.sh" "${TMPROOT}/broken-root/scripts/"
OUT_FILE="${TMPROOT}/gh-output-broken"
SUM_FILE="${TMPROOT}/gh-summary-broken"
: > "$OUT_FILE"; : > "$SUM_FILE"
env -u GH_TOKEN -u GITHUB_EVENT_PATH -u GITHUB_REPOSITORY \
  INPUT_EXECUTION_FILE="$FIXTURE" GITHUB_OUTPUT="$OUT_FILE" GITHUB_STEP_SUMMARY="$SUM_FILE" \
  bash "${TMPROOT}/broken-root/scripts/action-report.sh" >/dev/null 2>&1
RC=$?
check "missing rates: exit code" "0" "$RC"
check "missing rates: status"    "error" "$(output_of status)"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} action assertions passed."
