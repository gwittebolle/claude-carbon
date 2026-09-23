#!/usr/bin/env bash
# run-vectors.sh: Replay the golden vectors against the plugin's own cost/CO2 code, using
# the CURRENT data/factors.json + data/prices.json. The model resolution is the shared
# cc_model_params and the formulas are the shared CC_AWK_PRICE (scripts/portable-lib.sh),
# the exact code the Stop hook and backfill run, so a vector cannot pass against a copy of
# the math that has drifted from it. Exits 1 if any vector deviates beyond the tolerance.
#
# Two files:
#   tests/methodology-vectors.json            the family-level contract, byte-identical to
#                                             the copy downstream consumers keep. Replayed
#                                             with prices.json's model_overrides removed:
#                                             its expected values are family prices, and some
#                                             of its ids (claude-sonnet-4, a dated Sonnet 4.5)
#                                             now carry an override in the plugin.
#   tests/methodology-vectors-per-model.json  the per-model resolution, full prices.json.
#
# Cache writes are priced per TTL tier: cache_creation_1h_tokens (optional, default 0)
# is billed at cache_write_multiplier_1h, the remainder at cache_write_multiplier.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: jq, awk (same as the rest of the plugin).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
FACTORS_FILE="${REPO_DIR}/data/factors.json"
PRICES_FILE="${REPO_DIR}/data/prices.json"
FAMILY_VECTORS="${SCRIPT_DIR}/methodology-vectors.json"
MODEL_VECTORS="${SCRIPT_DIR}/methodology-vectors-per-model.json"
REL_TOL="0.000001" # 1e-6

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
for f in "$FACTORS_FILE" "$PRICES_FILE" "$FAMILY_VECTORS" "$MODEL_VECTORS"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

FAMILY_PRICES="$(mktemp "$(cc_tmpdir)/claude-carbon-family-prices.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -f "$FAMILY_PRICES"' EXIT
jq 'del(.model_overrides)' "$PRICES_FILE" > "$FAMILY_PRICES" || { echo "FAIL: cannot read $PRICES_FILE" >&2; exit 1; }

EXCLUDE_MODELS="$(cc_exclude_regex "$FACTORS_FILE")"

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

TOTAL=0
FAILURES=0
PASSED=0

# replay <vectors.json> <prices.json> <label>
replay() {
  local vectors="$1" prices="$2" label="$3"
  local n i row id model in cw cw1h cr out excluded exp_co2 exp_cost params excl_flag res co2 cost ok
  n="$(jq '.vectors | length' "$vectors")"
  echo "── ${label} (${n} vectors)"
  i=0
  while [ "$i" -lt "$n" ]; do
    row="$(jq -r --argjson i "$i" '.vectors[$i] | [
      .id, .model,
      (.input_tokens // 0), (.cache_creation_tokens // 0),
      (.cache_creation_1h_tokens // 0),
      (.cache_read_tokens // 0), (.output_tokens // 0),
      (if .excluded == true then "1" else "0" end),
      (.expected_co2_grams // 0), (.expected_cost_usd // 0)
    ] | @tsv' "$vectors")"
    IFS="$(printf '\t')" read -r id model in cw cw1h cr out excluded exp_co2 exp_cost <<EOF
$row
EOF
    TOTAL=$((TOTAL + 1))

    if cc_is_excluded_model "$model" "$EXCLUDE_MODELS"; then
      excl_flag=1
      if [ "$excluded" != "1" ]; then
        echo "FAIL ${id}: model '${model}' is excluded by the plugin but the vector is not marked excluded"
        FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
      fi
      # Excluded vectors expect 0/0 from the plugin (expected_* is null upstream).
      exp_co2="0"; exp_cost="0"
    else
      excl_flag=0
      if [ "$excluded" = "1" ]; then
        echo "FAIL ${id}: vector marked excluded but model '${model}' is not excluded by the plugin"
        FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
      fi
    fi

    # The Stop hook's own pipeline: shared resolution, then the shared awk.
    params="$(printf '%s\n' "$model" | cc_model_params "$FACTORS_FILE" "$prices" | cut -f3-)"
    res="$(printf 'M\t%s\t%s\t%s\t%s\t%s\t%s\t0\t%s\t%s\n' "$model" "$in" "$cw" "$cw1h" "$cr" "$out" "$params" "$excl_flag" \
             | LC_ALL=C awk "$CC_AWK_PRICE" | awk -F '\t' '$1 == "R" { print $8 " " $9 }')"
    co2="${res% *}"; cost="${res#* }"

    ok=1
    if ! close_enough "$co2" "$exp_co2"; then
      echo "FAIL ${id}: co2_grams ${co2} != expected ${exp_co2} (model ${model})"
      ok=0
    fi
    if ! close_enough "$cost" "$exp_cost"; then
      echo "FAIL ${id}: cost_usd ${cost} != expected ${exp_cost} (model ${model})"
      ok=0
    fi
    if [ "$ok" = "1" ]; then
      echo "PASS ${id}: co2=${co2} g, cost=\$${cost}"
      PASSED=$((PASSED + 1))
    else
      FAILURES=$((FAILURES + 1))
    fi
    i=$((i + 1))
  done
}

replay "$FAMILY_VECTORS" "$FAMILY_PRICES" "family contract: methodology-vectors.json (model_overrides off)"
echo ""
replay "$MODEL_VECTORS" "$PRICES_FILE" "per-model prices: methodology-vectors-per-model.json"

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES}/${TOTAL} vector(s) FAILED (${PASSED} passed)."
  exit 1
fi
echo "All ${TOTAL} methodology vectors passed."
