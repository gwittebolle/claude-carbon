#!/usr/bin/env bash
# generate-report.sh — Generate Claude Carbon Report PNGs from DB stats.
# Usage: generate-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--all]
# Default: since January 1st of current year, up to now.
# --until takes an exclusive upper bound, so --until 2026-07-01 stops at June 30th.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_DIR/templates"
# Cards go to the user's Downloads, not to the clone: on a marketplace install the
# clone is a hidden, per-version cache directory (see cc_downloads_dir).
EXPORT_DIR="$(cc_path "${CLAUDE_CARBON_EXPORT_DIR:-$(cc_downloads_dir)/claude-carbon}")"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}")"
# One scratch dir for the temp pages and the logo the local server serves.
CC_TMP="$(cc_tmpdir)"
TODAY="$(date +%Y-%m-%d)"
YEAR="$(date +%Y)"

# ── Parse args ──────────────────────────────────────────────
SINCE="${YEAR}-01-01"
SINCE_LABEL_FR="janvier ${YEAR}"
SINCE_LABEL_EN="January ${YEAR}"
UNTIL="" # exclusive upper bound; empty = up to now
LANG_FILTER="" # empty = both
LABEL_AUTO=1   # default mode: derive the "since" label from the earliest real session

# Full month names for the auto-derived label (index 1-12)
MONTHS_FR=("" "janvier" "février" "mars" "avril" "mai" "juin" "juillet" "août" "septembre" "octobre" "novembre" "décembre")
MONTHS_EN=("" "January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="$2"
      SINCE_LABEL_FR="$2"
      SINCE_LABEL_EN="$2"
      LABEL_AUTO=0
      shift 2
      ;;
    --until)
      UNTIL="$2"
      shift 2
      ;;
    --all)
      SINCE=""
      SINCE_LABEL_FR="le début"
      SINCE_LABEL_EN="the beginning"
      LABEL_AUTO=0
      shift
      ;;
    --lang)
      LANG_FILTER="$2"
      shift 2
      ;;
    *)
      echo "Usage: generate-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--all] [--lang fr|en]" >&2
      exit 1
      ;;
  esac
done

SINCE_LABEL="$SINCE_LABEL_FR"

# Build SQL WHERE clause (always filters out excluded sessions, e.g. non-Anthropic models)
WHERE="WHERE COALESCE(excluded, 0) = 0"
if [ -n "$SINCE" ]; then
  WHERE="${WHERE} AND started_at >= '${SINCE}'"
fi
if [ -n "$UNTIL" ]; then
  WHERE="${WHERE} AND started_at < '${UNTIL}'"
fi

# Anchor date for every "how long has this been running" computation: the upper
# bound when the period is closed, today otherwise.
if [ -n "$UNTIL" ]; then
  PERIOD_END_SQL="$UNTIL"
  LAST_DAY="$(date -j -v-1d -f "%Y-%m-%d" "$UNTIL" +%Y-%m-%d 2>/dev/null || date -d "${UNTIL} -1 day" +%Y-%m-%d 2>/dev/null || echo "$UNTIL")"
else
  PERIOD_END_SQL="now"
  LAST_DAY="$TODAY"
fi
PERIOD_END_EPOCH="$(date -j -f "%Y-%m-%d" "$LAST_DAY" +%s 2>/dev/null || date -d "$LAST_DAY" +%s 2>/dev/null || date +%s)"

# Filename carries the window when it is closed, so two runs of the same period
# don't overwrite each other with different numbers.
if [ -n "$UNTIL" ]; then
  FILE_TAG="${SINCE:-start}_${LAST_DAY}"
else
  FILE_TAG="$TODAY"
fi

# On a closed period, the generation date says nothing useful and contradicts the
# window shown under the headline. The period itself is the timestamp.
if [ -n "$UNTIL" ]; then
  DATE_STAMP=""
else
  DATE_STAMP="$TODAY"
fi

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 node jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found. Run setup.sh first." >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"

# Ensure the excluded column exists on pre-existing DBs (idempotent)
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true

# ── Query DB ────────────────────────────────────────────────
echo "Querying carbon.db (since ${SINCE_LABEL})..."

read -r TOTAL_SESSIONS TOTAL_CO2_RAW TOTAL_COST_RAW FIRST_DATE_RAW <<< \
  "$(sqlite3 "$DB_PATH" "SELECT COUNT(*), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0), COALESCE(MIN(started_at), '') FROM sessions ${WHERE};" | tr '|' ' ')"

# Top 5 projects
TOP_PROJECTS="$(sqlite3 -separator '|' "$DB_PATH" "SELECT project, SUM(co2_grams), COUNT(*) FROM sessions ${WHERE} GROUP BY project ORDER BY SUM(co2_grams) DESC LIMIT 5;")"

TOP_MODEL="$(sqlite3 "$DB_PATH" "SELECT model FROM sessions ${WHERE} GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1;")"

# Total tokens
TOTAL_TOKENS_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0) FROM sessions ${WHERE};")"

# ── Format values ───────────────────────────────────────────
# shellcheck source=scripts/format-lib.sh
. "$SCRIPT_DIR/format-lib.sh"

read -r TOTAL_CO2_VALUE TOTAL_CO2_UNIT <<< "$(format_co2 "$TOTAL_CO2_RAW")"
TOTAL_COST="$(echo "$TOTAL_COST_RAW" | LC_ALL=C awk '{printf "%.0f", $1}')"
FIRST_DATE="$(echo "$FIRST_DATE_RAW" | cut -c1-10)"
# Car equivalence factors: data/factors.json "equivalences", derivations in
# METHODOLOGY.md "Equivalences used in reports". The FR card always uses the ADEME
# factor in km; the EN card follows the locale (ADEME on a French or undetected
# locale, EPA in miles on a US one, world average otherwise), so the same factor
# family /carbon-report selects also drives the card.
# shellcheck source=scripts/equiv-lib.sh
. "$SCRIPT_DIR/equiv-lib.sh"
FACTORS_FILE="$PROJECT_DIR/data/factors.json"
EQUIV_SET="$(detect_equiv_set)"
# `|| true` so a jq failure lands in the guard below with a clear message instead of
# aborting mid-assignment under set -e (here-string read would swallow it anyway).
read -r EQUIV_FACTOR_EN EQUIV_UNIT_EN <<< \
  "$(jq -r --arg set "$EQUIV_SET" '.equivalences[$set][] | select(.id == "car") | "\(.divisor) \(.unit)"' "$FACTORS_FILE" || true)"
EQUIV_FACTOR_FR="$(jq -r '.equivalences.fr[] | select(.id == "car") | .divisor' "$FACTORS_FILE" || true)"
if [ -z "${EQUIV_FACTOR_EN:-}" ] || [ -z "${EQUIV_FACTOR_FR:-}" ]; then
  echo "Error: no car equivalence for set '$EQUIV_SET' in $FACTORS_FILE" >&2
  exit 1
fi
# The factor is named on the card and on the Totals line: the PNG travels alone,
# so the same "car equivalent" would otherwise mean three different things.
# Cards get the short tag (fits under the figure), the Totals line the full source.
EQUIV_SRC_EN="$(jq -r --arg set "$EQUIV_SET" '.equivalences[$set][] | select(.id == "car") | .source' "$FACTORS_FILE" || true)"
EQUIV_SRC_FR="$(jq -r '.equivalences.fr[] | select(.id == "car") | .source' "$FACTORS_FILE" || true)"
EQUIV_TAG_EN="$(jq -r --arg set "$EQUIV_SET" '.equivalences[$set][] | select(.id == "car") | .tag // .source' "$FACTORS_FILE" || true)"
EQUIV_TAG_FR="$(jq -r '.equivalences.fr[] | select(.id == "car") | .tag // .source' "$FACTORS_FILE" || true)"
# Whole units: a decimal on thousands of km reads as precision the factors don't
# carry, and /carbon-report already prints its car row without one.
EQUIV_KM_FR="$(echo "$TOTAL_CO2_RAW" | LC_ALL=C awk -v f="$EQUIV_FACTOR_FR" '{printf "%.0f", $1/f}')"
EQUIV_KM_EN="$(echo "$TOTAL_CO2_RAW" | LC_ALL=C awk -v f="$EQUIV_FACTOR_EN" '{printf "%.0f", $1/f}')"

# In default mode, label the report with the actual earliest session month, not Jan 1st
# (transcripts older than ~30 days are purged, so the real data rarely starts in January).
if [ "$LABEL_AUTO" = "1" ] && [ -n "$FIRST_DATE" ]; then
  _lm="$(echo "$FIRST_DATE" | cut -c6-7 | sed 's/^0//')"
  _ly="$(echo "$FIRST_DATE" | cut -c1-4)"
  if [ -n "$_lm" ] && [ "$_lm" -ge 1 ] 2>/dev/null && [ "$_lm" -le 12 ] 2>/dev/null; then
    SINCE_LABEL_FR="${MONTHS_FR[$_lm]} ${_ly}"
    SINCE_LABEL_EN="${MONTHS_EN[$_lm]} ${_ly}"
  fi
fi

# A closed period must say so, otherwise "823 sessions depuis janvier" reads as
# "up to today" and the headline number no longer matches the window.
if [ -n "$UNTIL" ]; then
  _um="$(echo "$LAST_DAY" | cut -c6-7 | sed 's/^0//')"
  _ud="$(echo "$LAST_DAY" | cut -c9-10 | sed 's/^0//')"
  _uy="$(echo "$LAST_DAY" | cut -c1-4)"
  SINCE_LABEL_FR="${SINCE_LABEL_FR}, jusqu'au ${_ud} ${MONTHS_FR[$_um]} ${_uy}"
  SINCE_LABEL_EN="${SINCE_LABEL_EN}, up to ${MONTHS_EN[$_um]} ${_ud}, ${_uy}"
fi

# Format tokens (M)
TOTAL_TOKENS="$(echo "$TOTAL_TOKENS_RAW" | LC_ALL=C awk '{printf "%.0f", $1/1000000}')"

# Projection annuelle (fourchette)
# Use actual first session date, not --since filter
ACTUAL_FIRST="$(echo "$FIRST_DATE" | cut -c1-10)"
_FIRST_EPOCH="$(date -j -f "%Y-%m-%d" "${ACTUAL_FIRST}" +%s 2>/dev/null || date -d "${ACTUAL_FIRST}" +%s 2>/dev/null || echo "")"
if [ -n "$_FIRST_EPOCH" ]; then
  DAYS_ELAPSED="$(( ( PERIOD_END_EPOCH - _FIRST_EPOCH ) / 86400 ))"
else
  DAYS_ELAPSED=0
fi
if [ "$DAYS_ELAPSED" -gt 0 ]; then
  # Linear: average daily rate extrapolated. Kept in GRAMS so the range can pick
  # its unit with the same rule as every other figure (see format-lib.sh).
  PROJ_LINEAR="$(echo "$TOTAL_CO2_RAW $DAYS_ELAPSED" | LC_ALL=C awk '{printf "%.4f", ($1 / $2) * 365}')"

  # Trend: last 30 days daily rate extrapolated
  if [ -n "$WHERE" ]; then
    LAST_MONTH_DATA="$(sqlite3 "$DB_PATH" "SELECT SUM(co2_grams), MIN(started_at), MAX(started_at) FROM sessions ${WHERE} AND started_at >= date('${PERIOD_END_SQL}', '-30 days');" | tr '|' ' ')"
  else
    LAST_MONTH_DATA="$(sqlite3 "$DB_PATH" "SELECT SUM(co2_grams), MIN(started_at), MAX(started_at) FROM sessions WHERE started_at >= date('${PERIOD_END_SQL}', '-30 days');" | tr '|' ' ')"
  fi
  LAST_MONTH_CO2="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $1}')"
  LAST_MONTH_START="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $2}' | cut -c1-10)"
  LAST_MONTH_END="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $3}' | cut -c1-10)"
  LAST_MONTH_DAYS="$(( ( $(date -j -f "%Y-%m-%d" "${LAST_MONTH_END}" +%s 2>/dev/null || date -d "${LAST_MONTH_END}" +%s 2>/dev/null) - $(date -j -f "%Y-%m-%d" "${LAST_MONTH_START}" +%s 2>/dev/null || date -d "${LAST_MONTH_START}" +%s 2>/dev/null) ) / 86400 ))"
  if [ "$LAST_MONTH_DAYS" -gt 0 ]; then
    PROJ_TREND="$(echo "$LAST_MONTH_CO2 $LAST_MONTH_DAYS" | LC_ALL=C awk '{printf "%.4f", ($1 / $2) * 365}')"
  else
    PROJ_TREND="$PROJ_LINEAR"
  fi

  # Sort low-high for display (compare as floats)
  LOW="$(echo "$PROJ_LINEAR $PROJ_TREND" | LC_ALL=C awk '{if ($1 <= $2) print $1; else print $2}')"
  HIGH="$(echo "$PROJ_LINEAR $PROJ_TREND" | LC_ALL=C awk '{if ($1 >= $2) print $1; else print $2}')"
  # The projection does NOT follow the 10 t rule the totals use. A total is a
  # measurement and reads better as a four-digit kilogram figure; a projection is an
  # extrapolation from a daily average, and "1414 - 1686 kg" claims a precision it
  # simply does not have. Tonnes with one decimal state the same range at the
  # resolution the method actually supports.
  #
  # Below 0.1 t the tonne tier would collapse to "0.0 - 0.1", so light users fall
  # back to whole kilograms. Both bounds always share the unit, picked on HIGH.
  if cc_num_ge "$HIGH" 100000; then
    PROJECTION_UNIT="tCO₂"
    _PROJ_LO_VAL="$(echo "$LOW"  | LC_ALL=C awk '{printf "%.1f", $1/1000000}')"
    _PROJ_HI_VAL="$(echo "$HIGH" | LC_ALL=C awk '{printf "%.1f", $1/1000000}')"
  else
    PROJECTION_UNIT="kgCO₂"
    _PROJ_LO_VAL="$(echo "$LOW"  | LC_ALL=C awk '{printf "%.0f", $1/1000}')"
    _PROJ_HI_VAL="$(echo "$HIGH" | LC_ALL=C awk '{printf "%.0f", $1/1000}')"
  fi
  PROJECTION="${_PROJ_LO_VAL} - ${_PROJ_HI_VAL}"
else
  PROJECTION="0"
  PROJECTION_UNIT="kgCO₂"
fi

# Format model
TOP_MODEL_DISPLAY="$(echo "$TOP_MODEL" | sed 's/claude-//' | sed 's/-4-6//' | sed 's/-4-5.*//')"

# ── Monthly bars HTML ───────────────────────────────────────
MONTHLY_DATA="$(sqlite3 -separator '|' "$DB_PATH" "SELECT substr(started_at, 1, 7), SUM(co2_grams) FROM sessions ${WHERE} GROUP BY substr(started_at, 1, 7) ORDER BY substr(started_at, 1, 7);")"
MAX_MONTH_CO2="$(echo "$MONTHLY_DATA" | LC_ALL=C awk -F'|' 'BEGIN{m=0} {if($2>m)m=$2} END{print m}')"

MONTHLY_BARS=""
MONTH_NAMES="Jan Fév Mar Avr Mai Jun Jul Aoû Sep Oct Nov Déc"
while IFS='|' read -r month_key month_co2; do
  [ -z "$month_key" ] && continue
  month_num="${month_key:5:2}"
  month_num_clean="$(echo "$month_num" | sed 's/^0//')"
  month_label="$(echo "$MONTH_NAMES" | LC_ALL=C awk -v n="$month_num_clean" '{print $n}')"
  if [ "$MAX_MONTH_CO2" -gt 0 ] 2>/dev/null; then
    pct="$(echo "$month_co2 $MAX_MONTH_CO2" | LC_ALL=C awk '{printf "%.0f", ($1/$2)*100}')"
  else
    pct="10"
  fi
  co2_display="$(format_co2 "$month_co2")"
  MONTHLY_BARS="${MONTHLY_BARS}<div class=\"bar-row\"><span class=\"bar-label\">${month_label}</span><div class=\"bar-track\"><div class=\"bar-fill\" style=\"width: ${pct}%\"></div></div><span class=\"bar-value\">${co2_display}</span></div>"
done <<< "$MONTHLY_DATA"

# ── Parse top 5 projects ───────────────────────────────────
declare -a P_NAME P_CO2 P_SESSIONS
i=0
while IFS='|' read -r pname pco2 psessions; do
  [ -z "$pname" ] && continue
  P_NAME[$i]="$pname"
  P_CO2[$i]="$(format_co2 "$pco2")"
  P_SESSIONS[$i]="$psessions"
  i=$((i+1))
done <<< "$TOP_PROJECTS"

for ((j=i; j<5; j++)); do
  P_NAME[$j]="-"
  P_CO2[$j]="-"
  P_SESSIONS[$j]="0"
done

# ── Generate HTML files ─────────────────────────────────────
echo "Generating HTML variants..."

inject_common() {
  local src="$1" dst="$2"
  sed \
    -e "s|{{TODAY}}|${DATE_STAMP}|g" \
    -e "s|{{SINCE_LABEL}}|${SINCE_LABEL}|g" \
    -e "s|{{TOTAL_CO2_VALUE}}|${TOTAL_CO2_VALUE}|g" \
    -e "s|{{TOTAL_CO2_UNIT}}|${TOTAL_CO2_UNIT}|g" \
    -e "s|{{TOTAL_SESSIONS}}|${TOTAL_SESSIONS}|g" \
    -e "s|{{FIRST_DATE}}|${FIRST_DATE}|g" \
    -e "s|{{TOTAL_COST}}|${TOTAL_COST}|g" \
    -e "s|{{EQUIV_KM}}|${EQUIV_KM}|g" \
    -e "s|{{EQUIV_UNIT}}|${EQUIV_UNIT}|g" \
    -e "s|{{EQUIV_SRC}}|${EQUIV_SRC}|g" \
    -e "s|{{TOP_MODEL}}|${TOP_MODEL_DISPLAY}|g" \
    -e "s|{{TOTAL_TOKENS}}|${TOTAL_TOKENS}|g" \
    -e "s|{{PROJECTION}}|${PROJECTION}|g" \
  -e "s|{{PROJECTION_UNIT}}|${PROJECTION_UNIT}|g" \
    -e "s|{{P1_NAME}}|${P_NAME[0]}|g" \
    -e "s|{{P1_CO2}}|${P_CO2[0]}|g" \
    -e "s|{{P1_SESSIONS}}|${P_SESSIONS[0]}|g" \
    -e "s|{{P2_NAME}}|${P_NAME[1]}|g" \
    -e "s|{{P2_CO2}}|${P_CO2[1]}|g" \
    -e "s|{{P2_SESSIONS}}|${P_SESSIONS[1]}|g" \
    -e "s|{{P3_NAME}}|${P_NAME[2]}|g" \
    -e "s|{{P3_CO2}}|${P_CO2[2]}|g" \
    -e "s|{{P3_SESSIONS}}|${P_SESSIONS[2]}|g" \
    -e "s|{{P4_NAME}}|${P_NAME[3]}|g" \
    -e "s|{{P4_CO2}}|${P_CO2[3]}|g" \
    -e "s|{{P4_SESSIONS}}|${P_SESSIONS[3]}|g" \
    -e "s|{{P5_NAME}}|${P_NAME[4]}|g" \
    -e "s|{{P5_CO2}}|${P_CO2[4]}|g" \
    -e "s|{{P5_SESSIONS}}|${P_SESSIONS[4]}|g" \
    "$src" > "$dst"
}

# Generate FR templates
SINCE_LABEL="$SINCE_LABEL_FR"
EQUIV_KM="$EQUIV_KM_FR"
EQUIV_UNIT="km"
EQUIV_SRC="$EQUIV_TAG_FR"
_t=$(mktemp "${CC_TMP}/claude-carbon-summary-fr-XXXXXX"); TMP_SUMMARY_FR="${_t}.html"; mv "$_t" "$TMP_SUMMARY_FR"
_t=$(mktemp "${CC_TMP}/claude-carbon-detailed-fr-XXXXXX"); TMP_DETAILED_FR="${_t}.html"; mv "$_t" "$TMP_DETAILED_FR"
inject_common "$TEMPLATE_DIR/report-summary.html" "$TMP_SUMMARY_FR"
inject_common "$TEMPLATE_DIR/report-detailed.html" "$TMP_DETAILED_FR"

# Generate EN templates
SINCE_LABEL="$SINCE_LABEL_EN"
EQUIV_KM="$EQUIV_KM_EN"
EQUIV_UNIT="$EQUIV_UNIT_EN"
EQUIV_SRC="$EQUIV_TAG_EN"
_t=$(mktemp "${CC_TMP}/claude-carbon-summary-en-XXXXXX"); TMP_SUMMARY_EN="${_t}.html"; mv "$_t" "$TMP_SUMMARY_EN"
_t=$(mktemp "${CC_TMP}/claude-carbon-detailed-en-XXXXXX"); TMP_DETAILED_EN="${_t}.html"; mv "$_t" "$TMP_DETAILED_EN"
inject_common "$TEMPLATE_DIR/report-summary-en.html" "$TMP_SUMMARY_EN"
inject_common "$TEMPLATE_DIR/report-detailed-en.html" "$TMP_DETAILED_EN"

# Inject monthly bars into all summary files
TMP_SUMMARY="$TMP_SUMMARY_FR"

# Inject monthly bars via node (bash/sed can't handle % in style attrs). node is
# already required below for the Playwright lookup, so this costs no new dependency
# and it drops python3, which a stock Windows does not ship.
_t=$(mktemp "${CC_TMP}/claude-carbon-monthly-XXXXXX"); TMP_MONTHLY="${_t}.txt"; mv "$_t" "$TMP_MONTHLY"
echo "$MONTHLY_DATA" > "$TMP_MONTHLY"

export TMP_SUMMARY TMP_SUMMARY_EN TMP_MONTHLY
node << 'NODEEOF'
const fs = require("fs");

const MONTHS_FR = ["Jan", "Fév", "Mar", "Avr", "Mai", "Jun", "Jul", "Aoû", "Sep", "Oct", "Nov", "Déc"];
const MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const summaryFr = process.env.TMP_SUMMARY || "";
const summaryEn = process.env.TMP_SUMMARY_EN || "";
const monthlyFile = process.env.TMP_MONTHLY || "";

const rows = [];
for (const line of fs.readFileSync(monthlyFile, "utf8").split("\n")) {
  const trimmed = line.trim();
  const sep = trimmed.indexOf("|");
  if (!trimmed || sep === -1) continue;
  rows.push({
    monthIndex: parseInt(trimmed.slice(0, sep).split("-")[1], 10) - 1,
    co2: parseFloat(trimmed.slice(sep + 1)),
  });
}

const maxCo2 = rows.length ? Math.max(...rows.map((r) => r.co2)) : 1;

// Each language gets its own bars, rather than building the French ones and
// translating the finished page afterwards: a blind ">Mai<" → ">May<" pass over
// the English file would also rewrite any other three-letter match it found.
const barsFor = (months) =>
  rows
    .map((r) => {
      const display = r.co2 >= 1000 ? (r.co2 / 1000).toFixed(1) + " kg" : r.co2.toFixed(0) + " g";
      const pct = Math.round((r.co2 / maxCo2) * 100);
      return (
        '<div class="bar-row">' +
        '<span class="bar-label">' + months[r.monthIndex] + "</span>" +
        '<div class="bar-track"><div class="bar-fill" style="width: ' + pct + '%"></div></div>' +
        '<span class="bar-value">' + display + "</span>" +
        "</div>\n"
      );
    })
    .join("");

for (const [file, months] of [[summaryFr, MONTHS_FR], [summaryEn, MONTHS_EN]]) {
  if (!file || !fs.existsSync(file)) continue;
  fs.writeFileSync(file, fs.readFileSync(file, "utf8").replace("{{MONTHLY_BARS}}", barsFor(months)));
}
NODEEOF

rm -f "$TMP_MONTHLY"

# ── Find Playwright ─────────────────────────────────────────
PW_PATH="$(node -e "try { console.log(require.resolve('playwright-core').replace(/\/index\.js$/, '')); } catch(e) { process.exit(1); }" 2>/dev/null)" || true

if [ -z "$PW_PATH" ]; then
  _npm_global_root="$(npm root -g 2>/dev/null || true)"
  # Check both flattened (playwright-core installed directly) and nested (installed as a
  # dependency of the full "playwright" package) locations.
  for candidate in \
    "${_npm_global_root}/playwright-core" \
    "${_npm_global_root}/playwright/node_modules/playwright-core" \
    "${HOME}/node_modules/playwright-core" \
    "${HOME}/node_modules/playwright/node_modules/playwright-core" \
    "${HOME}/claude cowork/node_modules/playwright-core" \
    "/opt/homebrew/lib/node_modules/playwright-core" \
    "/opt/homebrew/lib/node_modules/playwright/node_modules/playwright-core"; do
    if [ -d "$candidate" ]; then
      PW_PATH="$candidate"
      break
    fi
  done
fi

if [ -z "$PW_PATH" ]; then
  echo "Error: playwright-core not found." >&2
  echo "Install: npm install -g playwright-core && npx playwright install chromium" >&2
  rm -f "$TMP_SUMMARY_FR" "$TMP_SUMMARY_EN" "$TMP_DETAILED_FR" "$TMP_DETAILED_EN"
  exit 1
fi

# ── Export PNGs ──────────────────────────────────────────────
echo "Exporting PNGs via Playwright..."

PORT=8799
# Copy the logo next to the pages so the server can serve it
cp -f "$TEMPLATE_DIR/logo.png" "${CC_TMP}/logo.png" 2>/dev/null || true
# Static file server in node rather than `python3 -m http.server`: a stock Windows
# has no python3, and node is already required just above for Playwright. It also
# binds the loopback interface only, where http.server defaulted to 0.0.0.0 and
# briefly published these pages to the local network.
CC_SERVE_DIR="$CC_TMP" CC_SERVE_PORT="$PORT" node -e '
const http = require("http"), fs = require("fs"), path = require("path");
const root = process.env.CC_SERVE_DIR;
const types = { ".html": "text/html; charset=utf-8", ".png": "image/png", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml" };
http
  .createServer((req, res) => {
    // basename(): the only files ever requested sit directly in the scratch dir,
    // and it forecloses any "../" walk out of it.
    const name = path.basename(decodeURIComponent(req.url.split("?")[0]));
    fs.readFile(path.join(root, name), (err, buf) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { "Content-Type": types[path.extname(name).toLowerCase()] || "application/octet-stream" });
      res.end(buf);
    });
  })
  .listen(Number(process.env.CC_SERVE_PORT), "127.0.0.1");
' >/dev/null 2>&1 &
SERVER_PID=$!
# Out of the job table: bash would otherwise announce the kill in cleanup_server
# with a "Terminated" notice that quotes this whole node command back, burying
# the Done line under twenty lines of JavaScript.
disown "$SERVER_PID" 2>/dev/null || true
# A function rather than a quoted trap string: the paths stay quoted, so a temp dir containing
# a space cannot split them into separate arguments to rm.
cleanup_server() {
  # `|| true`: the script runs under `set -e`, and a server that already exited would abort
  # the handler before the temp files are removed.
  kill "$SERVER_PID" 2>/dev/null || true
  rm -f "$TMP_SUMMARY_FR" "$TMP_DETAILED_FR" "$TMP_SUMMARY_EN" "$TMP_DETAILED_EN"
}
trap cleanup_server EXIT
sleep 0.5

export_png() {
  local html_file="$1" output="$2" label="$3"
  local filename url
  filename="$(basename "$html_file")"
  url="http://127.0.0.1:${PORT}/${filename}"

  # node is a native binary: a "/c/Users/…" MSYS path means nothing to it, so both
  # the module path and the screenshot target go through cc_native_path first.
  node -e "
const { chromium } = require('$(cc_native_path "$PW_PATH")');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1080, height: 1080 },
    deviceScaleFactor: 2
  });
  await page.goto('${url}', { waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  await page.screenshot({
    path: '$(cc_native_path "$output")',
    clip: { x: 0, y: 0, width: 1080, height: 1080 }
  });
  await browser.close();
})();
" 2>&1

  if [ -f "$output" ]; then
    local size
    size="$(du -h "$output" | cut -f1 | tr -d ' ')"
    echo "  ${label}: $(cc_native_path "$output") (${size})"
  else
    echo "  ${label}: FAILED" >&2
  fi
}

if [ -z "$LANG_FILTER" ] || [ "$LANG_FILTER" = "fr" ]; then
  export_png "$TMP_SUMMARY_FR" "$EXPORT_DIR/claude-carbon-summary-fr-${FILE_TAG}.png" "Summary FR"
  export_png "$TMP_DETAILED_FR" "$EXPORT_DIR/claude-carbon-detailed-fr-${FILE_TAG}.png" "Detailed FR"
fi

if [ -z "$LANG_FILTER" ] || [ "$LANG_FILTER" = "en" ]; then
  export_png "$TMP_SUMMARY_EN" "$EXPORT_DIR/claude-carbon-summary-en-${FILE_TAG}.png" "Summary EN"
  export_png "$TMP_DETAILED_EN" "$EXPORT_DIR/claude-carbon-detailed-en-${FILE_TAG}.png" "Detailed EN"
fi

echo ""
# The Totals line is quoted by the social draft, so its car figure must match a card
# that was exported: the locale set (the EN card) by default, the French set when
# only the FR card was. The label stays English: the line itself is English.
if [ "$LANG_FILTER" = "fr" ]; then
  EQUIV_KM="$EQUIV_KM_FR"
  EQUIV_UNIT="km"
  EQUIV_SRC="$EQUIV_SRC_FR"
else
  EQUIV_KM="$EQUIV_KM_EN"
  EQUIV_UNIT="$EQUIV_UNIT_EN"
  EQUIV_SRC="$EQUIV_SRC_EN"
fi
echo "Totals since ${SINCE_LABEL_EN}: ${TOTAL_CO2_VALUE} ${TOTAL_CO2_UNIT} CO2e · \$${TOTAL_COST} · ${EQUIV_KM} ${EQUIV_UNIT} by car (${EQUIV_SRC}) · ${TOTAL_SESSIONS} sessions"

# Stamp the month so the statusline's monthly share nudge clears
STATE_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")/claude-carbon"
mkdir -p "$STATE_DIR" 2>/dev/null || true
date +%Y-%m > "${STATE_DIR}/last-card-month" 2>/dev/null || true

# Put the card in front of the user: the folder opens in the file manager, with
# the summary card selected where the platform allows it. CLAUDE_CARBON_NO_OPEN
# skips this. The French card leads on the French (or undetected) locale, which
# is also the set whose figure the Totals line quotes.
if [ "$LANG_FILTER" = "fr" ] || { [ -z "$LANG_FILTER" ] && [ "$EQUIV_SET" = "fr" ]; }; then
  cc_reveal "$EXPORT_DIR/claude-carbon-summary-fr-${FILE_TAG}.png"
else
  cc_reveal "$EXPORT_DIR/claude-carbon-summary-en-${FILE_TAG}.png"
fi

echo "Done. $(cc_native_path "$EXPORT_DIR")/"
