---
name: carbon-report
description: Display CO2 emissions report for Claude Code sessions
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash

# Force C locale: comma-decimal locales (de_DE, fr_FR) make awk mis-parse
# "431.7045" as 431 and print "431,0" instead of "431.7"
export LC_ALL=C

DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

if [ ! -f "$DB_PATH" ]; then
  echo "Database not found. Run setup.sh first:"
  echo "  bash ~/code/claude-carbon/scripts/setup.sh"
  exit 1
fi

CURRENT_YEAR="$(date +%Y)"
TODAY="$(date +%Y-%m-%d)"

# --- Aggregates ---
TODAY_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE started_at LIKE '${TODAY}%';" | awk '{printf "%.1f", $1}')"
TODAY_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE started_at LIKE '${TODAY}%';")"

YEAR_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE started_at LIKE '${CURRENT_YEAR}%';" | awk '{printf "%.1f", $1}')"
YEAR_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE started_at LIKE '${CURRENT_YEAR}%';")"

ALL_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions;" | awk '{printf "%.1f", $1}')"
ALL_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions;")"
ALL_COST="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(cost_usd), 0) FROM sessions;" | awk '{printf "%.2f", $1}')"

# --- Equivalences (all-time total) ---
KM_CAR="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 120}')"
GOOGLE="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 0.2}')"
KM_TGV="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 2.4}')"

# --- Top 5 sessions by CO2 ---
TOP5="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT DATE(started_at), project, ROUND(co2_grams, 2), model, ROUND(cost_usd, 4)
   FROM sessions
   ORDER BY co2_grams DESC
   LIMIT 5;")"

# --- By project ---
BY_PROJECT="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT project, ROUND(SUM(co2_grams), 2), COUNT(*), ROUND(SUM(cost_usd), 4)
   FROM sessions
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
echo "  ${KM_CAR} km en voiture        (120 gCO2e/km)"
echo "  ${GOOGLE} recherches Google     (0.2 gCO2e)"
echo "  ${KM_TGV} km en TGV             (2.4 gCO2e/km)"
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
```
