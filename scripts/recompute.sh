#!/usr/bin/env bash
set -euo pipefail

# recompute.sh — Re-derive cost_usd and co2_grams for stored sessions from their raw token
# counts and the CURRENT data/factors.json + data/prices.json, without reading any JSONL.
# Run this after changing CO2 factors or the cache_read_factor. By DEFAULT it recomputes
# co2_grams ONLY (safe and idempotent). Pass --with-cost (alias --prices) to ALSO re-derive
# cost_usd — only do that after editing prices.json, because cost re-pricing collapses
# mixed-model (subagent) sessions to the row's dominant model, inflating their cost by ~6%.
#
# This is the answer to Anthropic's 30-day transcript purge: the raw token breakdown is
# captured once (by the Stop hook, within the 30-day window) and frozen; everything derived
# from it (cost, CO2) stays regenerable forever. Only rows with methodology_version >= 2
# carry the full breakdown (regular input, cache_write, cache_read, output); earlier "legacy"
# rows lack cache_read and are left untouched.
#
# Mixed-model sessions (subagents on a different model) are recomputed at the row's dominant
# model, a small approximation; the original insert was model-accurate per subagent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${CLAUDE_CARBON_FACTORS:-${SCRIPT_DIR}/../data/factors.json}"
PRICES_FILE="${CLAUDE_CARBON_PRICES:-${SCRIPT_DIR}/../data/prices.json}"
DB_PATH="${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}"

[ -f "$DB_PATH" ] || { echo "No database at ${DB_PATH}" >&2; exit 1; }

# Default: CO2 only. --with-cost / --prices also re-derives cost_usd (see header caveat).
WITH_COST=0
case "${1:-}" in --with-cost|--prices) WITH_COST=1 ;; esac

# Emission factors (gCO2e per million tokens) + cache_read energy fraction
F_FAB_IN="$(jq -r '.models.fable.input // 156' "$FACTORS_FILE")"; F_FAB_OUT="$(jq -r '.models.fable.output // 3304' "$FACTORS_FILE")"
F_OPUS_IN="$(jq -r '.models.opus.input' "$FACTORS_FILE")";    F_OPUS_OUT="$(jq -r '.models.opus.output' "$FACTORS_FILE")"
F_SON_IN="$(jq -r '.models.sonnet.input' "$FACTORS_FILE")";   F_SON_OUT="$(jq -r '.models.sonnet.output' "$FACTORS_FILE")"
F_HAI_IN="$(jq -r '.models.haiku.input' "$FACTORS_FILE")";    F_HAI_OUT="$(jq -r '.models.haiku.output' "$FACTORS_FILE")"
CRF="$(jq -r '.cache_read_factor // 0.08' "$FACTORS_FILE")"

# Prices (USD per million tokens) + cache multipliers
P_FAB_IN="$(jq -r '.models.fable.input // 10' "$PRICES_FILE")"; P_FAB_OUT="$(jq -r '.models.fable.output // 50' "$PRICES_FILE")"
P_OPUS_IN="$(jq -r '.models.opus.input' "$PRICES_FILE")";     P_OPUS_OUT="$(jq -r '.models.opus.output' "$PRICES_FILE")"
P_SON_IN="$(jq -r '.models.sonnet.input' "$PRICES_FILE")";    P_SON_OUT="$(jq -r '.models.sonnet.output' "$PRICES_FILE")"
P_HAI_IN="$(jq -r '.models.haiku.input' "$PRICES_FILE")";     P_HAI_OUT="$(jq -r '.models.haiku.output' "$PRICES_FILE")"
CW_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$PRICES_FILE")"
CR_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$PRICES_FILE")"

# These values are interpolated directly into the UPDATE SQL below, and the installers auto-run
# this script against freshly-pulled data files. Refuse anything that isn't a plain number so a
# malformed or hostile factors.json/prices.json can never inject SQL.
for _v in "$F_FAB_IN" "$F_FAB_OUT" "$F_OPUS_IN" "$F_OPUS_OUT" "$F_SON_IN" "$F_SON_OUT" \
          "$F_HAI_IN" "$F_HAI_OUT" "$CRF" \
          "$P_FAB_IN" "$P_FAB_OUT" "$P_OPUS_IN" "$P_OPUS_OUT" "$P_SON_IN" "$P_SON_OUT" \
          "$P_HAI_IN" "$P_HAI_OUT" "$CW_MULT" "$CR_MULT"; do
  case "$_v" in
    ''|*[!0-9.eE+-]*)
      echo "recompute: non-numeric value in factors/prices ('${_v}'); refusing to run." >&2
      exit 1 ;;
  esac
done

# co2  = (input_tokens * fin + cache_read_tokens * (fin*CRF) + output_tokens * fout) / 1e6
#        (input_tokens already = regular_input + cache_write, both at the input factor)
# cost = ((input_tokens - cache_creation_tokens) * pin              -- regular input
#         + cache_creation_tokens * (pin*CW_MULT)                   -- cache write
#         + cache_read_tokens * (pin*CR_MULT)                       -- cache read
#         + output_tokens * pout) / 1e6
update_family() {
  local where="$1" fin="$2" fout="$3" pin="$4" pout="$5"
  if [ "$WITH_COST" = "1" ]; then
    sqlite3 -cmd ".timeout 5000" "$DB_PATH" "
      UPDATE sessions SET
        co2_grams = (input_tokens*${fin} + cache_read_tokens*(${fin}*${CRF}) + output_tokens*${fout}) / 1000000.0,
        cost_usd  = ((input_tokens - cache_creation_tokens)*${pin} + cache_creation_tokens*(${pin}*${CW_MULT}) + cache_read_tokens*(${pin}*${CR_MULT}) + output_tokens*${pout}) / 1000000.0
      WHERE methodology_version >= 2 AND COALESCE(excluded, 0) = 0 AND ${where};
    "
  else
    sqlite3 -cmd ".timeout 5000" "$DB_PATH" "
      UPDATE sessions SET
        co2_grams = (input_tokens*${fin} + cache_read_tokens*(${fin}*${CRF}) + output_tokens*${fout}) / 1000000.0
      WHERE methodology_version >= 2 AND COALESCE(excluded, 0) = 0 AND ${where};
    "
  fi
}

update_family "(model LIKE '%fable%' OR model LIKE '%mythos%')" "$F_FAB_IN" "$F_FAB_OUT" "$P_FAB_IN" "$P_FAB_OUT"
update_family "model LIKE '%opus%'"  "$F_OPUS_IN" "$F_OPUS_OUT" "$P_OPUS_IN" "$P_OPUS_OUT"
update_family "model LIKE '%haiku%'" "$F_HAI_IN"  "$F_HAI_OUT"  "$P_HAI_IN"  "$P_HAI_OUT"
update_family "model NOT LIKE '%fable%' AND model NOT LIKE '%mythos%' AND model NOT LIKE '%opus%' AND model NOT LIKE '%haiku%'" "$F_SON_IN" "$F_SON_OUT" "$P_SON_IN" "$P_SON_OUT"

RECOMPUTED="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE methodology_version >= 2 AND COALESCE(excluded, 0) = 0;")"
LEGACY="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE methodology_version IS NULL OR methodology_version < 2;")"
TOTAL_COST="$(sqlite3 "$DB_PATH" "SELECT printf('%.0f', COALESCE(SUM(cost_usd),0)) FROM sessions;")"
TOTAL_CO2_KG="$(sqlite3 "$DB_PATH" "SELECT printf('%.0f', COALESCE(SUM(co2_grams),0)/1000.0) FROM sessions;")"

if [ "$WITH_COST" = "1" ]; then
  echo "Re-priced cost at the dominant model for mixed-model rows (~6% high on subagent sessions)."
  echo "Recomputed CO2 + cost for ${RECOMPUTED} rows (left ${LEGACY} legacy rows untouched)."
else
  echo "Recomputed CO2 for ${RECOMPUTED} rows (cost unchanged; left ${LEGACY} legacy rows untouched)."
fi
echo "DB totals now: \$${TOTAL_COST} / ${TOTAL_CO2_KG} kg CO2."
