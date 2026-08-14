---
name: carbon-report
description: Display CO2 emissions report for Claude Code sessions
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash

# Read the user locale before LC_ALL=C below masks it: the equivalence factors are
# country-specific (a French car and a US car differ by a factor of ~1.7).
USER_LOCALE="${CLAUDE_CARBON_LOCALE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
if [ -z "$USER_LOCALE" ] && [ "$(uname)" = "Darwin" ]; then
  USER_LOCALE="$(defaults read -g AppleLocale 2>/dev/null || true)"
fi

# Force C locale: comma-decimal locales (de_DE, fr_FR) make awk mis-parse
# "431.7045" as 431 and print "431,0" instead of "431.7"
export LC_ALL=C

DB_PATH="${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-carbon/carbon.db}"

if [ ! -f "$DB_PATH" ]; then
  echo "Database not found. Run setup.sh first:"
  echo "  bash ${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}/scripts/setup.sh"
  exit 1
fi

CURRENT_YEAR="$(date +%Y)"
TODAY="$(date +%Y-%m-%d)"

# Ensure the excluded column exists on pre-existing DBs (idempotent).
# Excluded sessions (non-Anthropic models, e.g. local models) are left out of all aggregates.
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true
NOT_EXCLUDED="COALESCE(excluded, 0) = 0"

# --- Aggregates ---
TODAY_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE ${NOT_EXCLUDED} AND started_at LIKE '${TODAY}%';" | awk '{printf "%.1f", $1}')"
TODAY_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE ${NOT_EXCLUDED} AND started_at LIKE '${TODAY}%';")"

YEAR_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE ${NOT_EXCLUDED} AND started_at LIKE '${CURRENT_YEAR}%';" | awk '{printf "%.1f", $1}')"
YEAR_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE ${NOT_EXCLUDED} AND started_at LIKE '${CURRENT_YEAR}%';")"

ALL_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE ${NOT_EXCLUDED};" | awk '{printf "%.1f", $1}')"
ALL_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE ${NOT_EXCLUDED};")"
ALL_COST="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(cost_usd), 0) FROM sessions WHERE ${NOT_EXCLUDED};" | awk '{printf "%.2f", $1}')"

# --- Equivalences (all-time total) ---
# Factors and sources: METHODOLOGY.md "Equivalences used in reports".
# France gets the ADEME/SNCF factors, a US locale the EPA ones, everyone else the
# world-average set. A car, a kWh and a kilo of beef each differ by a factor of 2 or
# more between countries, so a single set would be wrong for most readers.
case "$USER_LOCALE" in
  fr | fr.* | fr_FR* | fr-FR*)
    EQUIV_ROWS="$(echo "$ALL_CO2" | awk '{
      printf "%.0f|km en voiture|142 gCO2e/km, ADEME 2025\n", $1 / 142
      printf "%.0f|prompts Gemini|0.03 gCO2e, Google 2025\n", $1 / 0.03
      printf "%.0f|km en TGV|3.5 gCO2e/km, SNCF 2024\n", $1 / 3.5
      printf "%.1f|steak(s) de boeuf|4200 gCO2e/steak 150g, ADEME Impact CO2 2025\n", $1 / 4200
    }')"
    ;;
  *_US* | *-US*)
    EQUIV_ROWS="$(echo "$ALL_CO2" | awk '{
      printf "%.0f|miles driven by car|393 gCO2e/mile, EPA, US average\n", $1 / 393
      printf "%.0f|Gemini prompts|0.03 gCO2e, Google 2025\n", $1 / 0.03
      printf "%.0f|smartphone charges|12.4 gCO2, EPA, US grid\n", $1 / 12.4
      printf "%.1f|beef steaks|6400 gCO2e/steak 150g, Putman et al. 2023, US\n", $1 / 6400
    }')"
    ;;
  *)
    EQUIV_ROWS="$(echo "$ALL_CO2" | awk '{
      printf "%.0f|km driven by car|200 gCO2/km, world average\n", $1 / 200
      printf "%.0f|Gemini prompts|0.03 gCO2e, Google 2025\n", $1 / 0.03
      printf "%.0f|smartphone charges|8.7 gCO2e, world grid\n", $1 / 8.7
      printf "%.1f|beef steaks|14900 gCO2e/steak 150g, Poore & Nemecek 2018\n", $1 / 14900
    }')"
    ;;
esac

# --- Top 5 sessions by CO2 ---
TOP5="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT DATE(started_at), project, ROUND(co2_grams, 2), model, ROUND(cost_usd, 4)
   FROM sessions
   WHERE ${NOT_EXCLUDED}
   ORDER BY co2_grams DESC
   LIMIT 5;")"

# --- By project ---
BY_PROJECT="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT project, ROUND(SUM(co2_grams), 2), COUNT(*), ROUND(SUM(cost_usd), 4)
   FROM sessions
   WHERE ${NOT_EXCLUDED}
   GROUP BY project
   ORDER BY SUM(co2_grams) DESC;")"

echo "==============================="
echo "  claude-carbon report"
echo "==============================="
echo ""
echo "Today (${TODAY})"
echo "  CO2       : ${TODAY_CO2}g"
echo "  Sessions  : ${TODAY_SESSIONS}"
echo ""
echo "${CURRENT_YEAR}"
echo "  CO2       : ${YEAR_CO2}g"
echo "  Sessions  : ${YEAR_SESSIONS}"
echo ""
echo "All time"
echo "  CO2       : ${ALL_CO2}g"
echo "  Sessions  : ${ALL_SESSIONS}"
echo "  Cost      : \$${ALL_COST}"
echo ""
echo "--- Equivalences (all-time) ---"
while IFS='|' read -r count label source; do
  [ -z "$count" ] && continue
  printf "  %10s %-20s (%s)\n" "$count" "$label" "$source"
done <<< "$EQUIV_ROWS"
echo ""
echo "--- Top 5 sessions by CO2 ---"
echo "Date        | Project                 | CO2 (g) | Model                          | Cost"
echo "------------|-------------------------|---------|--------------------------------|--------"
while IFS='|' read -r date project co2 model cost; do
  printf "%-11s | %-23s | %-7s | %-30s | \$%s\n" "$date" "$project" "$co2" "$model" "$cost"
done <<< "$TOP5"
echo ""
echo "--- By project ---"
echo "Project                  | CO2 (g)  | Sessions | Cost"
echo "-------------------------|----------|----------|--------"
while IFS='|' read -r project co2 sessions cost; do
  printf "%-25s | %-8s | %-8s | \$%s\n" "$project" "$co2" "$sessions" "$cost"
done <<< "$BY_PROJECT"
echo ""
echo "Team view (same methodology): tokenclimate.com"
echo ""
```
