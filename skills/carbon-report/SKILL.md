---
name: carbon-report
description: Display CO2 emissions report for Claude Code sessions
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash

# Locate the install (equivalence factors + shared locale lib live in the repo),
# mirroring /carbon-card: status line wiring first, then plugin root, then default.
# Windows (Git Bash): CLAUDE_* variables and the paths stored in settings.json can
# arrive in the native "C:\Users\..." spelling, which bash cannot open. cygpath
# ships with Git for Windows; everywhere else this is the identity function.
ccp() {
  case "${OSTYPE:-}" in msys*|cygwin*) ;; *) printf '%s' "$1"; return 0 ;; esac
  case "$1" in
    [A-Za-z]:[\\/]*|*\\*) cygpath -u "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
CFG="$(ccp "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
# A jq the installer fetched into the data folder (a Mac older than macOS 15 has none)
if ! command -v jq >/dev/null 2>&1 && [ -x "$CFG/claude-carbon/bin/jq" ]; then PATH="$CFG/claude-carbon/bin:$PATH"; fi
REPO_DIR=""
if command -v jq >/dev/null 2>&1 && [ -f "$CFG/settings.json" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$CFG/settings.json" 2>/dev/null)"
  # statusLine.command stores a shell-escaped path: expand ~ and unescape spaces
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"; SL_CMD="$(ccp "$SL_CMD")"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$(ccp "$CLAUDE_PLUGIN_ROOT")"
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_CARBON_DIR:-}" ] && REPO_DIR="$(ccp "$CLAUDE_CARBON_DIR")"
if [ -z "$REPO_DIR" ]; then
  # Pure marketplace installs reach here: settings.json carries no statusLine.command
  # (the status line is wired through plugin.json) and CLAUDE_PLUGIN_ROOT is not in the
  # env of a skill's bash. Pick the newest cached plugin copy, the same scan as
  # statusline.sh CACHE_LATEST, keeping only candidates that ship the equivalence lib.
  CACHE_LATEST=""
  for D in "$CFG/plugins/cache"/*/claude-carbon/*/; do
    [ -f "${D}scripts/equiv-lib.sh" ] || continue
    if [ -z "$CACHE_LATEST" ] || [ "$(printf '%s\n%s\n' "$CACHE_LATEST" "$D" | sort -V | tail -1)" = "$D" ]; then
      CACHE_LATEST="$D"
    fi
  done
  [ -n "$CACHE_LATEST" ] && REPO_DIR="${CACHE_LATEST%/}"
fi
[ -z "$REPO_DIR" ] && REPO_DIR="$HOME/code/claude-carbon"
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

DB_PATH="$(ccp "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-carbon/carbon.db}")"

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

# --- Car equivalent (all-time total) ---
# Factor: data/factors.json "equivalences", the car row of the detected set, the
# same factor, label and source the cards use; derivations in METHODOLOGY.md
# "Equivalences used in reports". France and undetected locales get ADEME, a US
# locale EPA in miles, everyone else the world average. The other rows of each
# set (Gemini prompt, TGV, steak, phone charge) stay in factors.json, unused here.
IFS='|' read -r CAR_DIVISOR CAR_DECIMALS CAR_LABEL CAR_SOURCE <<< \
  "$(jq -r --arg set "$EQUIV_SET" \
    '.equivalences[$set][] | select(.id == "car") | "\(.divisor)|\(.decimals)|\(.label)|\(.source)"' "$FACTORS_FILE" 2>/dev/null)"
# A malformed or hand-edited factors.json must fail loudly, not print an empty section
if [ -z "${CAR_DIVISOR:-}" ] || [ -z "${CAR_LABEL:-}" ]; then
  echo "Error: could not read the car row of the '$EQUIV_SET' equivalence set from $FACTORS_FILE" >&2
  exit 1
fi
CAR_COUNT="$(echo "$ALL_CO2" | awk -v d="$CAR_DIVISOR" -v p="${CAR_DECIMALS:-0}" '{ fmt = "%." p "f"; printf fmt, $1 / d }')"

# --- Share of a 2 t per-person annual budget (current calendar year) ---
# 2 tCO2e per person per year is the 2050 target for a person's whole footprint
# (Carbone 4 "Faire sa part ?", 2019; ADEME Nos Gestes Climat), used as a scale,
# not as an allowance for AI. It is compared with this calendar year's total only:
# an all-time total against an annual budget would mix two time spans.
# Sources: METHODOLOGY.md "Equivalences used in reports". Kept here rather than in
# data/factors.json: it is not an emission factor and no other script reads it.
BUDGET_GRAMS=2000000
# French layout on the French set (the one whose labels are in French), English otherwise.
BUDGET_LANG="en"; [ "$EQUIV_SET" = "fr" ] && BUDGET_LANG="fr"
BUDGET_FIGURES="$(echo "$YEAR_CO2" | awk -v b="$BUDGET_GRAMS" -v lang="$BUDGET_LANG" '
  # Thousands grouped (space in French, comma in English), decimal comma in French.
  function group(n,   ip, dec, out) {
    ip = n; dec = ""
    if (index(n, ".")) { ip = substr(n, 1, index(n, ".") - 1); dec = substr(n, index(n, ".") + 1) }
    out = ""
    while (length(ip) > 3) { out = (lang == "fr" ? " " : ",") substr(ip, length(ip) - 2) out; ip = substr(ip, 1, length(ip) - 3) }
    out = ip out
    if (dec != "") out = out (lang == "fr" ? "," : ".") dec
    return out
  }
  {
    # Grams under a kilo, then kg: one decimal under 10 kg, whole kg above.
    # Thresholds sit where the rounding crosses over, so 9.98 kg prints "10 kg", not "10.0 kg".
    if ($1 < 999.5) qty = sprintf("%.0f", $1) " g"
    else if ($1 < 9950) qty = group(sprintf("%.1f", $1 / 1000)) " kg"
    else qty = group(sprintf("%.0f", $1 / 1000)) " kg"
    pct = $1 / b * 100
    if (pct == 0) pcts = "0"
    else if (pct < 0.1) pcts = (lang == "fr") ? "< 0,1" : "< 0.1"
    else if (pct < 9.95) pcts = group(sprintf("%.1f", pct))
    else pcts = group(sprintf("%.0f", pct))
    printf "%s|%s", qty, pcts
  }')"
BUDGET_QTY="${BUDGET_FIGURES%%|*}"
BUDGET_PCT="${BUDGET_FIGURES#*|}"
if [ "$BUDGET_LANG" = "fr" ]; then
  BUDGET_LINE="Depuis le 1er janvier : ${BUDGET_QTY}, soit ${BUDGET_PCT} % du budget annuel de 2 t par personne"
  BUDGET_NOTE="(cible 2050 pour l'empreinte totale d'une personne, Carbone 4 2019)"
else
  BUDGET_LINE="Since January 1: ${BUDGET_QTY}, ${BUDGET_PCT}% of a 2 t per-person annual budget"
  BUDGET_NOTE="(2050 target for a person's whole footprint, Carbone 4 2019)"
fi

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
echo "--- Car equivalent (all-time) ---"
printf "  %10s %-20s (%s)\n" "$CAR_COUNT" "$CAR_LABEL" "$CAR_SOURCE"
echo ""
echo "--- Annual budget (${CURRENT_YEAR}) ---"
echo "  ${BUDGET_LINE}"
echo "  ${BUDGET_NOTE}"
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
