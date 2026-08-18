---
name: carbon-report
description: Display CO2 emissions report for Claude Code sessions
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash

# Locate the install (equivalence factors + shared locale lib live in the repo),
# mirroring /carbon-card: status line wiring first, then plugin root, then default.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REPO_DIR=""
if command -v jq >/dev/null 2>&1 && [ -f "$CFG/settings.json" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$CFG/settings.json" 2>/dev/null)"
  # statusLine.command stores a shell-escaped path: expand ~ and unescape spaces
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$CLAUDE_PLUGIN_ROOT"
[ -z "$REPO_DIR" ] && REPO_DIR="${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}"
FACTORS_FILE="$REPO_DIR/data/factors.json"

if ! command -v jq >/dev/null 2>&1 || [ ! -f "$FACTORS_FILE" ] || [ ! -f "$REPO_DIR/scripts/equiv-lib.sh" ]; then
  echo "Error: jq and $REPO_DIR/data/factors.json are required (equivalence factors)." >&2
  exit 1
fi

# Pick the equivalence set from the user locale BEFORE LC_ALL=C below masks it:
# the factors are country-specific (a French car and a US car differ by ~1.7x).
. "$REPO_DIR/scripts/equiv-lib.sh"
EQUIV_SET="$(detect_equiv_set)"

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
# Factors: data/factors.json "equivalences" (single source, shared with the cards);
# derivations and sources: METHODOLOGY.md "Equivalences used in reports". France and
# undetected locales get the ADEME/SNCF set, a US locale the EPA one, everyone else
# the world average: a car, a kWh and a kilo of beef each differ by 2x+ between
# countries, so a single set would be wrong for most readers.
EQUIV_ROWS="$(jq -r --arg set "$EQUIV_SET" \
  '.equivalences[$set][] | "\(.divisor)|\(.decimals)|\(.label)|\(.source)"' "$FACTORS_FILE" \
  | while IFS='|' read -r divisor decimals label source; do
      count="$(echo "$ALL_CO2" | awk -v d="$divisor" -v p="$decimals" '{ fmt = "%." p "f"; printf fmt, $1 / d }')"
      printf '%s|%s|%s\n' "$count" "$label" "$source"
    done)"

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
