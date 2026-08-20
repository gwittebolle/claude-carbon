#!/usr/bin/env bash
# compute-lib.sh — the plugin's cost/CO2 methodology as a sourceable library:
# rate loading, model exclusion, family resolution and the canonical formulas
# (the exact awk expressions and printf precision of persist-session.sh
# compute_co2). Sourced by scripts/action-report.sh; persist-session.sh keeps
# its own inlined copy on purpose (it is the production Stop hook, and the
# golden vectors pin both implementations to identical outputs).
# No `set -e`, no side effects beyond CARBON_* globals. bash 3.2 compatible.

# carbon_load_rates <factors.json> <prices.json>
# Loads factors (gCO2e/Mtok), prices (USD/Mtok), cache multipliers and the
# exclusion patterns into CARBON_* globals. Returns 1 on unreadable files.
carbon_load_rates() {
  local factors="$1" prices="$2"
  [ -f "$factors" ] && [ -f "$prices" ] || return 1
  CARBON_FACTOR_FABLE_IN="$(jq -r '.models.fable.input // 156' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_FABLE_OUT="$(jq -r '.models.fable.output // 3304' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_OPUS_IN="$(jq -r '.models.opus.input' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_OPUS_OUT="$(jq -r '.models.opus.output' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_SONNET_IN="$(jq -r '.models.sonnet.input' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_SONNET_OUT="$(jq -r '.models.sonnet.output' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_HAIKU_IN="$(jq -r '.models.haiku.input' "$factors" 2>/dev/null)" || return 1
  CARBON_FACTOR_HAIKU_OUT="$(jq -r '.models.haiku.output' "$factors" 2>/dev/null)" || return 1
  CARBON_CACHE_READ_FACTOR="$(jq -r '.cache_read_factor // 0.08' "$factors" 2>/dev/null)" || return 1
  CARBON_PRICE_FABLE_IN="$(jq -r '.models.fable.input // 10' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_FABLE_OUT="$(jq -r '.models.fable.output // 50' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_OPUS_IN="$(jq -r '.models.opus.input' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_OPUS_OUT="$(jq -r '.models.opus.output' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_SONNET_IN="$(jq -r '.models.sonnet.input' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_SONNET_OUT="$(jq -r '.models.sonnet.output' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_HAIKU_IN="$(jq -r '.models.haiku.input' "$prices" 2>/dev/null)" || return 1
  CARBON_PRICE_HAIKU_OUT="$(jq -r '.models.haiku.output' "$prices" 2>/dev/null)" || return 1
  CARBON_CACHE_WRITE_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$prices" 2>/dev/null)" || return 1
  CARBON_CACHE_READ_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$prices" 2>/dev/null)" || return 1
  CARBON_EXCLUDE_MODELS="$(jq -r '(.exclude_models // []) | join("|")' "$factors" 2>/dev/null)" || return 1
  return 0
}

# Same rule as persist-session.sh is_excluded_model(): not a Claude model, or
# matching a user pattern in exclude_models. Returns 0 when excluded.
carbon_is_excluded_model() {
  local model="$1"
  if ! echo "$model" | grep -qi "claude"; then return 0; fi
  if [ -n "${CARBON_EXCLUDE_MODELS:-}" ] && echo "$model" | grep -qiE "$CARBON_EXCLUDE_MODELS"; then return 0; fi
  return 1
}

# Echoes the factor family for a model id (sonnet is the fallback family).
carbon_family() {
  local model="$1" family="sonnet"
  echo "$model" | grep -qiE "fable|mythos" && family="fable"
  echo "$model" | grep -qi "opus" && family="opus"
  echo "$model" | grep -qi "haiku" && family="haiku"
  echo "$family"
}

# carbon_compute <model> <input> <cache_write> <cache_read> <output>
# input is the UNCACHED input (Anthropic usage.input_tokens), cache write kept
# separate — the split the execution logs and the golden vectors carry, not the
# folded DB column. Echoes "co2_grams cost_usd"; excluded models echo "0 0".
carbon_compute() {
  local model="$1" it="$2" cw="$3" cr="$4" out="$5"
  local family fin fout pin pout co2 cost

  if carbon_is_excluded_model "$model"; then
    echo "0 0"
    return 0
  fi

  family="$(carbon_family "$model")"
  case "$family" in
    fable) fin="$CARBON_FACTOR_FABLE_IN"; fout="$CARBON_FACTOR_FABLE_OUT"; pin="$CARBON_PRICE_FABLE_IN"; pout="$CARBON_PRICE_FABLE_OUT" ;;
    opus)  fin="$CARBON_FACTOR_OPUS_IN"; fout="$CARBON_FACTOR_OPUS_OUT"; pin="$CARBON_PRICE_OPUS_IN"; pout="$CARBON_PRICE_OPUS_OUT" ;;
    haiku) fin="$CARBON_FACTOR_HAIKU_IN"; fout="$CARBON_FACTOR_HAIKU_OUT"; pin="$CARBON_PRICE_HAIKU_IN"; pout="$CARBON_PRICE_HAIKU_OUT" ;;
    *)     fin="$CARBON_FACTOR_SONNET_IN"; fout="$CARBON_FACTOR_SONNET_OUT"; pin="$CARBON_PRICE_SONNET_IN"; pout="$CARBON_PRICE_SONNET_OUT" ;;
  esac

  co2="$(echo "$it $cw $cr $out $fin $fout $CARBON_CACHE_READ_FACTOR" | LC_ALL=C awk \
    '{printf "%.4f", (($1 + $2) * $5 + $3 * ($5 * $7) + $4 * $6) / 1000000}')"
  cost="$(echo "$it $cw $cr $out $pin $pout $CARBON_CACHE_WRITE_MULT $CARBON_CACHE_READ_MULT" | LC_ALL=C awk \
    '{printf "%.6f", ($1 * $5 + $2 * ($5 * $7) + $3 * ($5 * $8) + $4 * $6) / 1000000}')"
  echo "$co2 $cost"
}
