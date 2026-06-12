#!/usr/bin/env bash
# run-vectors.sh — Replay tests/methodology-vectors.json against the plugin's
# cost/CO2 formulas (the exact math of scripts/persist-session.sh compute_co2
# and scripts/recompute.sh) using the CURRENT data/factors.json + data/prices.json.
# Exits 1 on the first relative deviation above the tolerance.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: jq, awk (same as the rest of the plugin).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
VECTORS_FILE="${SCRIPT_DIR}/methodology-vectors.json"
REL_TOL="0.000001" # 1e-6

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$FACTORS_FILE" ] || { echo "FAIL: missing $FACTORS_FILE" >&2; exit 1; }
[ -f "$PRICES_FILE" ] || { echo "FAIL: missing $PRICES_FILE" >&2; exit 1; }
[ -f "$VECTORS_FILE" ] || { echo "FAIL: missing $VECTORS_FILE" >&2; exit 1; }

# Emission factors (gCO2e per Mtok) + cache_read energy fraction
F_FAB_IN="$(jq -r '.models.fable.input' "$FACTORS_FILE")";  F_FAB_OUT="$(jq -r '.models.fable.output' "$FACTORS_FILE")"
F_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE")";  F_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE")"
F_SON_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE")"; F_SON_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE")"
F_HAI_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE")";  F_HAI_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE")"
CRF="$(jq -r '.cache_read_factor // 0.08' "$FACTORS_FILE")"

# Prices (USD per Mtok) + cache multipliers
P_FAB_IN="$(jq -r '.models.fable.input' "$PRICES_FILE")";  P_FAB_OUT="$(jq -r '.models.fable.output' "$PRICES_FILE")"
P_OPUS_IN="$(jq -r '.models.opus.input' "$PRICES_FILE")";  P_OPUS_OUT="$(jq -r '.models.opus.output' "$PRICES_FILE")"
P_SON_IN="$(jq -r '.models.sonnet.input' "$PRICES_FILE")"; P_SON_OUT="$(jq -r '.models.sonnet.output' "$PRICES_FILE")"
P_HAI_IN="$(jq -r '.models.haiku.input' "$PRICES_FILE")";  P_HAI_OUT="$(jq -r '.models.haiku.output' "$PRICES_FILE")"
CW_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$PRICES_FILE")"
CR_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$PRICES_FILE")"

EXCLUDE_MODELS="$(jq -r '(.exclude_models // []) | join("|")' "$FACTORS_FILE")"

# Same exclusion rule as persist-session.sh is_excluded_model()
is_excluded_model() {
  local model="$1"
  if ! echo "$model" | grep -qi "claude"; then return 0; fi
  if [ -n "$EXCLUDE_MODELS" ] && echo "$model" | grep -qiE "$EXCLUDE_MODELS"; then return 0; fi
  return 1
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

N="$(jq '.vectors | length' "$VECTORS_FILE")"
FAILURES=0
PASSED=0
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

  # Mirror persist-session.sh compute_co2: exclusion first, then family pick.
  if is_excluded_model "$MODEL"; then
    CO2="0"; COST="0"
    if [ "$EXCLUDED" != "1" ]; then
      echo "FAIL ${ID}: model '${MODEL}' is excluded by the plugin but the vector is not marked excluded"
      FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
    fi
    # Excluded vectors expect 0/0 from the plugin (expected_* is null upstream).
    EXP_CO2="0"; EXP_COST="0"
  else
    if [ "$EXCLUDED" = "1" ]; then
      echo "FAIL ${ID}: vector marked excluded but model '${MODEL}' is not excluded by the plugin"
      FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
    fi
    FAMILY="sonnet"
    echo "$MODEL" | grep -qiE "fable|mythos" && FAMILY="fable"
    echo "$MODEL" | grep -qi "opus" && FAMILY="opus"
    echo "$MODEL" | grep -qi "haiku" && FAMILY="haiku"
    case "$FAMILY" in
      fable) FIN="$F_FAB_IN";  FOUT="$F_FAB_OUT";  PIN="$P_FAB_IN";  POUT="$P_FAB_OUT" ;;
      opus)  FIN="$F_OPUS_IN"; FOUT="$F_OPUS_OUT"; PIN="$P_OPUS_IN"; POUT="$P_OPUS_OUT" ;;
      haiku) FIN="$F_HAI_IN";  FOUT="$F_HAI_OUT";  PIN="$P_HAI_IN";  POUT="$P_HAI_OUT" ;;
      *)     FIN="$F_SON_IN";  FOUT="$F_SON_OUT";  PIN="$P_SON_IN";  POUT="$P_SON_OUT" ;;
    esac
    # Same awk expressions and printf precision as persist-session.sh
    CO2="$(echo "$IN $CW $CR $OUT $FIN $FOUT $CRF" | LC_ALL=C awk \
      '{printf "%.4f", (($1 + $2) * $5 + $3 * ($5 * $7) + $4 * $6) / 1000000}')"
    COST="$(echo "$IN $CW $CR $OUT $PIN $POUT $CW_MULT $CR_MULT" | LC_ALL=C awk \
      '{printf "%.6f", ($1 * $5 + $2 * ($5 * $7) + $3 * ($5 * $8) + $4 * $6) / 1000000}')"
  fi

  OK=1
  if ! close_enough "$CO2" "$EXP_CO2"; then
    echo "FAIL ${ID}: co2_grams ${CO2} != expected ${EXP_CO2} (model ${MODEL})"
    OK=0
  fi
  if ! close_enough "$COST" "$EXP_COST"; then
    echo "FAIL ${ID}: cost_usd ${COST} != expected ${EXP_COST} (model ${MODEL})"
    OK=0
  fi
  if [ "$OK" = "1" ]; then
    echo "PASS ${ID}: co2=${CO2} g, cost=\$${COST}"
    PASSED=$((PASSED + 1))
  else
    FAILURES=$((FAILURES + 1))
  fi
  i=$((i + 1))
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES}/${N} vector(s) FAILED (${PASSED} passed)."
  exit 1
fi
echo "All ${N} methodology vectors passed."
