#!/usr/bin/env bash
set -euo pipefail

# recompute.sh — Re-derive cost_usd and co2_grams for stored sessions from their raw token
# counts and the CURRENT data/factors.json + data/prices.json, without reading any JSONL.
# Run this after changing CO2 factors or the cache_read_factor. By DEFAULT it recomputes
# co2_grams ONLY. Pass --with-cost (alias --prices) to ALSO re-derive cost_usd — only do
# that after editing prices.json.
#
# Per model where the DB knows the split. A session recorded since session_models exists
# carries one child row per model (main transcript and subagents, message by message):
# each child row is re-derived at its own model, and the session's co2_grams and cost_usd
# become the sum over its children. That is exact, and matches what the Stop hook stores.
#
# At the row's model otherwise. A session recorded before session_models existed only
# knows its main transcript's dominant model, and is re-derived entirely at that model.
# That is NOT free on mixed-model rows: the original insert was model-accurate per
# subagent, so a session whose subagents ran on a cheaper model moves to the expensive
# one. Measured on 226 such rows of heavy multi-agent use (2026-08-24): cost +44%, CO2
# +16%. backfill.sh gives those rows their per-model split while their transcript is
# still on disk (30 days); past that, the split is lost.
#
# This is the answer to Anthropic's 30-day transcript purge: the raw token breakdown is
# captured once (by the Stop hook, within the 30-day window) and frozen; everything derived
# from it (cost, CO2) stays regenerable forever. Only rows with methodology_version >= 2
# carry the full breakdown (regular input, cache_write, cache_read, output); earlier "legacy"
# rows lack cache_read and are left untouched. install.sh and update.sh run this script for
# every user, so that gate is what keeps legacy rows from being rewritten.
#
# Model resolution (family factors, per-model prices) is cc_model_params in portable-lib.sh,
# the same one the Stop hook uses.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${CLAUDE_CARBON_FACTORS:-${SCRIPT_DIR}/../data/factors.json}"
PRICES_FILE="${CLAUDE_CARBON_PRICES:-${SCRIPT_DIR}/../data/prices.json}"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}")"

[ -f "$DB_PATH" ] || { echo "No database at ${DB_PATH}" >&2; exit 1; }

# Columns and the session_models table may postdate this DB (idempotent).
cc_ensure_schema "$DB_PATH"

# Default: CO2 only. --with-cost / --prices also re-derives cost_usd.
WITH_COST=0
case "${1:-}" in --with-cost|--prices) WITH_COST=1 ;; esac

EXCLUDE_MODELS="$(cc_exclude_regex "$FACTORS_FILE")"

# Rows recompute may touch: raw-token rows (methodology_version >= 2) not excluded.
ELIGIBLE="methodology_version >= 2 AND COALESCE(excluded, 0) = 0"
HAS_CHILDREN="EXISTS (SELECT 1 FROM session_models m WHERE m.session_id = sessions.session_id)"

# co2  = (input_tokens * fin + cache_read_tokens * (fin*crf) + output_tokens * fout) / 1e6
#        (input_tokens already = regular_input + cache_write, both at the input factor)
# cost = ((input_tokens - cache_creation_tokens) * pin                        -- regular input
#         + cache_creation_1h_tokens * (pin*cwm1h)                             -- cache write, 1-hour TTL
#         + (cache_creation_tokens - cache_creation_1h_tokens) * (pin*cwm)     -- cache write, 5-minute TTL
#         + cache_read_tokens * (pin*crm)                                      -- cache read
#         + output_tokens * pout) / 1e6
# Same columns in sessions and session_models. Rows predating the TTL split carry
# cache_creation_1h_tokens = 0, so their whole cache write stays priced at the 5-minute
# tier until backfill.sh repairs the column from a still-on-disk transcript. The 1-hour
# subset is clamped to the total in SQL, so a malformed value can never produce a
# negative 5-minute remainder.
set_clause() {
  local fin="$1" fout="$2" crf="$3" pin="$4" pout="$5" cwm="$6" cwm1h="$7" crm="$8"
  printf 'co2_grams = (input_tokens*%s + cache_read_tokens*(%s*%s) + output_tokens*%s) / 1000000.0' \
    "$fin" "$fin" "$crf" "$fout"
  if [ "$WITH_COST" = "1" ]; then
    printf ', cost_usd = ((input_tokens - cache_creation_tokens)*%s + MIN(COALESCE(cache_creation_1h_tokens, 0), cache_creation_tokens)*(%s*%s) + (cache_creation_tokens - MIN(COALESCE(cache_creation_1h_tokens, 0), cache_creation_tokens))*(%s*%s) + cache_read_tokens*(%s*%s) + output_tokens*%s) / 1000000.0' \
      "$pin" "$pin" "$cwm1h" "$pin" "$cwm" "$pin" "$crm" "$pout"
  fi
}

# Every distinct model id the update can reach, resolved in one jq call.
MODELS="$(sqlite3 "$DB_PATH" "
  SELECT DISTINCT model FROM session_models
    WHERE session_id IN (SELECT session_id FROM sessions WHERE ${ELIGIBLE})
  UNION
  SELECT DISTINCT model FROM sessions WHERE ${ELIGIBLE} AND model IS NOT NULL AND NOT ${HAS_CHILDREN};")"
PARAMS=""
if [ -n "$MODELS" ]; then
  PARAMS="$(printf '%s\n' "$MODELS" | cc_model_params "$FACTORS_FILE" "$PRICES_FILE")"
fi

# Build one script, applied in one transaction.
SQL="BEGIN IMMEDIATE;
"
while IFS="	" read -r MODEL FAMILY FIN FOUT CRF PIN POUT CWM CWM1H CRM; do
  [ -n "${FAMILY:-}" ] || continue
  # These values are interpolated into the SQL, and the installers auto-run this script
  # against freshly-pulled data files. Refuse anything that isn't a plain number so a
  # malformed or hostile factors.json/prices.json can never inject SQL.
  for _v in "$FIN" "$FOUT" "$CRF" "$PIN" "$POUT" "$CWM" "$CWM1H" "$CRM"; do
    case "$_v" in
      ''|*[!0-9.eE+-]*)
        echo "recompute: non-numeric value in factors/prices ('${_v}' for ${FAMILY}); refusing to run." >&2
        exit 1 ;;
    esac
  done
  QMODEL="$(cc_sql_quote "$MODEL")"
  # Child rows: priced at their own model; an excluded model (not Claude, or matching
  # exclude_models) keeps its tokens at 0 CO2 and 0 cost, as the Stop hook stores it.
  if cc_is_excluded_model "$MODEL" "$EXCLUDE_MODELS"; then
    CHILD_SET="co2_grams = 0"
    [ "$WITH_COST" = "1" ] && CHILD_SET="${CHILD_SET}, cost_usd = 0"
  else
    CHILD_SET="$(set_clause "$FIN" "$FOUT" "$CRF" "$PIN" "$POUT" "$CWM" "$CWM1H" "$CRM")"
  fi
  SQL="${SQL}UPDATE session_models SET ${CHILD_SET} WHERE model = ${QMODEL} AND session_id IN (SELECT session_id FROM sessions WHERE ${ELIGIBLE});
"
  # Rows without children: the whole row at its own (dominant) model, as before.
  SQL="${SQL}UPDATE sessions SET $(set_clause "$FIN" "$FOUT" "$CRF" "$PIN" "$POUT" "$CWM" "$CWM1H" "$CRM") WHERE model = ${QMODEL} AND ${ELIGIBLE} AND NOT ${HAS_CHILDREN};
"
done <<EOF
$PARAMS
EOF

# Rows with children: the sum over them.
SUM_SET="co2_grams = (SELECT COALESCE(SUM(m.co2_grams), 0) FROM session_models m WHERE m.session_id = sessions.session_id)"
if [ "$WITH_COST" = "1" ]; then
  SUM_SET="${SUM_SET}, cost_usd = (SELECT COALESCE(SUM(m.cost_usd), 0) FROM session_models m WHERE m.session_id = sessions.session_id)"
fi
SQL="${SQL}UPDATE sessions SET ${SUM_SET} WHERE ${ELIGIBLE} AND ${HAS_CHILDREN};
COMMIT;"

sqlite3 -cmd ".timeout 5000" "$DB_PATH" "$SQL"

SPLIT_ROWS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE ${ELIGIBLE} AND ${HAS_CHILDREN};")"
WHOLE_ROWS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE ${ELIGIBLE} AND NOT ${HAS_CHILDREN};")"
LEGACY="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE methodology_version IS NULL OR methodology_version < 2;")"
TOTAL_COST="$(sqlite3 "$DB_PATH" "SELECT printf('%.0f', COALESCE(SUM(cost_usd),0)) FROM sessions;")"
TOTAL_CO2_KG="$(sqlite3 "$DB_PATH" "SELECT printf('%.0f', COALESCE(SUM(co2_grams),0)/1000.0) FROM sessions;")"

if [ "$WITH_COST" = "1" ]; then
  WHAT="CO2 + cost"
else
  WHAT="CO2 (cost unchanged)"
fi
echo "Recomputed ${WHAT}: ${SPLIT_ROWS} rows model by model, ${WHOLE_ROWS} rows at their dominant model (no per-model split recorded); left ${LEGACY} legacy rows untouched."
echo "DB totals now: \$${TOTAL_COST} / ${TOTAL_CO2_KG} kg CO2."
