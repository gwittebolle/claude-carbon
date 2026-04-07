#!/usr/bin/env bash
# generate-report.sh — Generate Claude Carbon Report PNGs from DB stats.
# Usage: generate-report.sh [--since YYYY-MM-DD] [--all]
# Default: since January 1st of current year.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_DIR/templates"
EXPORT_DIR="$PROJECT_DIR/exports"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"
TODAY="$(date +%Y-%m-%d)"
YEAR="$(date +%Y)"

# ── Parse args ──────────────────────────────────────────────
SINCE="${YEAR}-01-01"
SINCE_LABEL_FR="janvier ${YEAR}"
SINCE_LABEL_EN="January ${YEAR}"
LANG_FILTER="" # empty = both

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="$2"
      SINCE_LABEL_FR="$2"
      SINCE_LABEL_EN="$2"
      shift 2
      ;;
    --all)
      SINCE=""
      SINCE_LABEL_FR="le début"
      SINCE_LABEL_EN="the beginning"
      shift
      ;;
    --lang)
      LANG_FILTER="$2"
      shift 2
      ;;
    *)
      echo "Usage: generate-report.sh [--since YYYY-MM-DD] [--all] [--lang fr|en]" >&2
      exit 1
      ;;
  esac
done

SINCE_LABEL="$SINCE_LABEL_FR"

# Build SQL WHERE clause
if [ -n "$SINCE" ]; then
  WHERE="WHERE started_at >= '${SINCE}'"
else
  WHERE=""
fi

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 node; do
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
format_co2() {
  local grams="$1"
  if (( $(echo "$grams >= 1000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.0f", $1}') g"
  fi
}

read -r TOTAL_CO2_VALUE TOTAL_CO2_UNIT <<< "$(format_co2 "$TOTAL_CO2_RAW")"
TOTAL_COST="$(echo "$TOTAL_COST_RAW" | LC_ALL=C awk '{printf "%.0f", $1}')"
FIRST_DATE="$(echo "$FIRST_DATE_RAW" | cut -c1-10)"
EQUIV_KM="$(echo "$TOTAL_CO2_RAW" | LC_ALL=C awk '{printf "%.1f", $1/120}')"

# Format tokens (M)
TOTAL_TOKENS="$(echo "$TOTAL_TOKENS_RAW" | LC_ALL=C awk '{printf "%.0f", $1/1000000}')"

# Projection annuelle (fourchette)
# Use actual first session date, not --since filter
ACTUAL_FIRST="$(echo "$FIRST_DATE" | cut -c1-10)"
_FIRST_EPOCH="$(date -j -f "%Y-%m-%d" "${ACTUAL_FIRST}" +%s 2>/dev/null || date -d "${ACTUAL_FIRST}" +%s 2>/dev/null || echo "")"
if [ -n "$_FIRST_EPOCH" ]; then
  DAYS_ELAPSED="$(( ( $(date +%s) - _FIRST_EPOCH ) / 86400 ))"
else
  DAYS_ELAPSED=0
fi
if [ "$DAYS_ELAPSED" -gt 0 ]; then
  # Linear: average daily rate extrapolated (in tCO2 with 1 decimal)
  PROJ_LINEAR="$(echo "$TOTAL_CO2_RAW $DAYS_ELAPSED" | LC_ALL=C awk '{printf "%.1f", ($1 / $2) * 365 / 1000000}')"

  # Trend: last 30 days daily rate extrapolated
  LAST_MONTH_DATA="$(sqlite3 "$DB_PATH" "SELECT SUM(co2_grams), MIN(started_at), MAX(started_at) FROM sessions ${WHERE} AND started_at >= date('now', '-30 days');" | tr '|' ' ')"
  LAST_MONTH_CO2="$(echo "$LAST_MONTH_DATA" | awk '{print $1}')"
  LAST_MONTH_START="$(echo "$LAST_MONTH_DATA" | awk '{print $2}' | cut -c1-10)"
  LAST_MONTH_END="$(echo "$LAST_MONTH_DATA" | awk '{print $3}' | cut -c1-10)"
  LAST_MONTH_DAYS="$(( ( $(date -j -f "%Y-%m-%d" "${LAST_MONTH_END}" +%s 2>/dev/null || date -d "${LAST_MONTH_END}" +%s 2>/dev/null) - $(date -j -f "%Y-%m-%d" "${LAST_MONTH_START}" +%s 2>/dev/null || date -d "${LAST_MONTH_START}" +%s 2>/dev/null) ) / 86400 ))"
  if [ "$LAST_MONTH_DAYS" -gt 0 ]; then
    PROJ_TREND="$(echo "$LAST_MONTH_CO2 $LAST_MONTH_DAYS" | LC_ALL=C awk '{printf "%.1f", ($1 / $2) * 365 / 1000000}')"
  else
    PROJ_TREND="$PROJ_LINEAR"
  fi

  # Sort low-high for display (compare as floats)
  LOW="$(echo "$PROJ_LINEAR $PROJ_TREND" | awk '{if ($1 <= $2) print $1; else print $2}')"
  HIGH="$(echo "$PROJ_LINEAR $PROJ_TREND" | awk '{if ($1 >= $2) print $1; else print $2}')"
  PROJECTION="${LOW} - ${HIGH}"
else
  PROJECTION="0"
fi

# Format model
TOP_MODEL_DISPLAY="$(echo "$TOP_MODEL" | sed 's/claude-//' | sed 's/-4-6//' | sed 's/-4-5.*//')"

# ── Monthly bars HTML ───────────────────────────────────────
MONTHLY_DATA="$(sqlite3 -separator '|' "$DB_PATH" "SELECT substr(started_at, 1, 7), SUM(co2_grams) FROM sessions ${WHERE} GROUP BY substr(started_at, 1, 7) ORDER BY substr(started_at, 1, 7);")"
MAX_MONTH_CO2="$(echo "$MONTHLY_DATA" | awk -F'|' 'BEGIN{m=0} {if($2>m)m=$2} END{print m}')"

MONTHLY_BARS=""
MONTH_NAMES="Jan Fév Mar Avr Mai Jun Jul Aoû Sep Oct Nov Déc"
while IFS='|' read -r month_key month_co2; do
  [ -z "$month_key" ] && continue
  month_num="${month_key:5:2}"
  month_num_clean="$(echo "$month_num" | sed 's/^0//')"
  month_label="$(echo "$MONTH_NAMES" | awk -v n="$month_num_clean" '{print $n}')"
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
    -e "s|{{TODAY}}|${TODAY}|g" \
    -e "s|{{SINCE_LABEL}}|${SINCE_LABEL}|g" \
    -e "s|{{TOTAL_CO2_VALUE}}|${TOTAL_CO2_VALUE}|g" \
    -e "s|{{TOTAL_CO2_UNIT}}|${TOTAL_CO2_UNIT}|g" \
    -e "s|{{TOTAL_SESSIONS}}|${TOTAL_SESSIONS}|g" \
    -e "s|{{FIRST_DATE}}|${FIRST_DATE}|g" \
    -e "s|{{TOTAL_COST}}|${TOTAL_COST}|g" \
    -e "s|{{EQUIV_KM}}|${EQUIV_KM}|g" \
    -e "s|{{TOP_MODEL}}|${TOP_MODEL_DISPLAY}|g" \
    -e "s|{{TOTAL_TOKENS}}|${TOTAL_TOKENS}|g" \
    -e "s|{{PROJECTION}}|${PROJECTION}|g" \
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
_t=$(mktemp /tmp/claude-carbon-summary-fr-XXXXXX); TMP_SUMMARY_FR="${_t}.html"; mv "$_t" "$TMP_SUMMARY_FR"
_t=$(mktemp /tmp/claude-carbon-detailed-fr-XXXXXX); TMP_DETAILED_FR="${_t}.html"; mv "$_t" "$TMP_DETAILED_FR"
inject_common "$TEMPLATE_DIR/report-summary.html" "$TMP_SUMMARY_FR"
inject_common "$TEMPLATE_DIR/report-detailed.html" "$TMP_DETAILED_FR"

# Generate EN templates
SINCE_LABEL="$SINCE_LABEL_EN"
_t=$(mktemp /tmp/claude-carbon-summary-en-XXXXXX); TMP_SUMMARY_EN="${_t}.html"; mv "$_t" "$TMP_SUMMARY_EN"
_t=$(mktemp /tmp/claude-carbon-detailed-en-XXXXXX); TMP_DETAILED_EN="${_t}.html"; mv "$_t" "$TMP_DETAILED_EN"
inject_common "$TEMPLATE_DIR/report-summary-en.html" "$TMP_SUMMARY_EN"
inject_common "$TEMPLATE_DIR/report-detailed-en.html" "$TMP_DETAILED_EN"

# Inject monthly bars into all summary files
TMP_SUMMARY="$TMP_SUMMARY_FR"

# Inject monthly bars via python (bash/sed can't handle % in style attrs)
_t=$(mktemp /tmp/claude-carbon-monthly-XXXXXX); TMP_MONTHLY="${_t}.txt"; mv "$_t" "$TMP_MONTHLY"
echo "$MONTHLY_DATA" > "$TMP_MONTHLY"

export TMP_SUMMARY TMP_MONTHLY
python3 << 'PYEOF'
import sys, os

months_fr = ["Jan", "Fév", "Mar", "Avr", "Mai", "Jun", "Jul", "Aoû", "Sep", "Oct", "Nov", "Déc"]
summary_file = os.environ["TMP_SUMMARY"]
monthly_file = os.environ["TMP_MONTHLY"]

# Parse monthly data
rows = []
with open(monthly_file) as f:
    for line in f:
        line = line.strip()
        if not line or "|" not in line:
            continue
        month_key, co2_str = line.split("|", 1)
        co2 = float(co2_str)
        month_num = int(month_key.split("-")[1])
        label = months_fr[month_num - 1]
        if co2 >= 1000:
            display = f"{co2/1000:.1f} kg"
        else:
            display = f"{co2:.0f} g"
        rows.append((label, co2, display))

# Calculate percentages
max_co2 = max(r[1] for r in rows) if rows else 1
bars_html = ""
for label, co2, display in rows:
    pct = int(round(co2 / max_co2 * 100))
    bars_html += (
        f'<div class="bar-row">'
        f'<span class="bar-label">{label}</span>'
        f'<div class="bar-track"><div class="bar-fill" style="width: {pct}%"></div></div>'
        f'<span class="bar-value">{display}</span>'
        f'</div>\n'
    )

# Inject into all summary files
for sf in [summary_file, summary_file.replace("-fr-", "-en-")]:
    if os.path.exists(sf):
        with open(sf) as f:
            content = f.read()
        content = content.replace("{{MONTHLY_BARS}}", bars_html)
        with open(sf, "w") as f:
            f.write(content)
PYEOF

export TMP_SUMMARY_EN
python3 -c "
import os
sf = os.environ.get('TMP_SUMMARY_EN', '')
if sf and os.path.exists(sf):
    months_en = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
    months_fr = ['Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Jun', 'Jul', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc']
    with open(sf) as f:
        c = f.read()
    for fr, en in zip(months_fr, months_en):
        c = c.replace(f'>{fr}<', f'>{en}<')
    with open(sf, 'w') as f:
        f.write(c)
"

rm -f "$TMP_MONTHLY"

# ── Find Playwright ─────────────────────────────────────────
PW_PATH="$(node -e "try { console.log(require.resolve('playwright-core').replace(/\/index\.js$/, '')); } catch(e) { process.exit(1); }" 2>/dev/null)" || true

if [ -z "$PW_PATH" ]; then
  _npm_global_root="$(npm root -g 2>/dev/null || true)"
  for candidate in \
    "${_npm_global_root}/playwright-core" \
    "${HOME}/node_modules/playwright-core" \
    "${HOME}/claude cowork/node_modules/playwright-core" \
    "/opt/homebrew/lib/node_modules/playwright-core"; do
    if [ -d "$candidate" ]; then
      PW_PATH="$candidate"
      break
    fi
  done
fi

if [ -z "$PW_PATH" ]; then
  echo "Error: playwright-core not found." >&2
  echo "Install: npm install -g playwright-core && npx playwright install chromium" >&2
  rm -f "$TMP_SUMMARY_FR" "$TMP_SUMMARY_EN"
  exit 1
fi

# ── Export PNGs ──────────────────────────────────────────────
echo "Exporting PNGs via Playwright..."

PORT=8799
# Copy logo to /tmp so the HTTP server can serve it
cp -f "$TEMPLATE_DIR/logo.png" /tmp/logo.png 2>/dev/null || true
python3 -m http.server "$PORT" --directory /tmp &>/dev/null &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null; rm -f $TMP_SUMMARY_FR $TMP_DETAILED_FR $TMP_SUMMARY_EN $TMP_DETAILED_EN" EXIT
sleep 0.5

export_png() {
  local html_file="$1" output="$2" label="$3"
  local filename="$(basename "$html_file")"
  local url="http://localhost:${PORT}/${filename}"

  node -e "
const { chromium } = require('${PW_PATH}');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1080, height: 1080 },
    deviceScaleFactor: 2
  });
  await page.goto('${url}', { waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  await page.screenshot({
    path: '${output}',
    clip: { x: 0, y: 0, width: 1080, height: 1080 }
  });
  await browser.close();
})();
" 2>&1

  if [ -f "$output" ]; then
    local size="$(du -h "$output" | cut -f1 | tr -d ' ')"
    echo "  ${label}: ${output} (${size})"
  else
    echo "  ${label}: FAILED" >&2
  fi
}

if [ -z "$LANG_FILTER" ] || [ "$LANG_FILTER" = "fr" ]; then
  export_png "$TMP_SUMMARY_FR" "$EXPORT_DIR/claude-carbon-summary-fr-${TODAY}.png" "Summary FR"
  export_png "$TMP_DETAILED_FR" "$EXPORT_DIR/claude-carbon-detailed-fr-${TODAY}.png" "Detailed FR"
fi

if [ -z "$LANG_FILTER" ] || [ "$LANG_FILTER" = "en" ]; then
  export_png "$TMP_SUMMARY_EN" "$EXPORT_DIR/claude-carbon-summary-en-${TODAY}.png" "Summary EN"
  export_png "$TMP_DETAILED_EN" "$EXPORT_DIR/claude-carbon-detailed-en-${TODAY}.png" "Detailed EN"
fi

echo ""
echo "Done. ${EXPORT_DIR}/"
