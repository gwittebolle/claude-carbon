#!/usr/bin/env bash
# generate-report.sh — Generate a Claude Carbon Report PNG card from DB stats.
# Queries carbon.db, injects data into HTML template, exports via Playwright.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$PROJECT_DIR/templates/report-card.html"
EXPORT_DIR="$PROJECT_DIR/exports"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"
TODAY="$(date +%Y-%m-%d)"
OUTPUT="$EXPORT_DIR/claude-carbon-report-${TODAY}.png"

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 jq node; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found at $DB_PATH" >&2
  echo "Run setup.sh first." >&2
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "Error: template not found at $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"

# ── Query DB ────────────────────────────────────────────────
echo "Querying carbon.db..."

# Total sessions + CO2 + cost + first date
read -r TOTAL_SESSIONS TOTAL_CO2_RAW TOTAL_COST_RAW FIRST_DATE_RAW <<< \
  "$(sqlite3 "$DB_PATH" "SELECT COUNT(*), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0), MIN(started_at) FROM sessions;" | tr '|' ' ')"

# 2026 CO2
CO2_2026_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE started_at >= '2026-01-01';")"

# Top 3 projects
TOP_PROJECTS="$(sqlite3 -separator '|' "$DB_PATH" "SELECT project, SUM(co2_grams) as co2 FROM sessions GROUP BY project ORDER BY co2 DESC LIMIT 3;")"

# Most used model
TOP_MODEL="$(sqlite3 "$DB_PATH" "SELECT model FROM sessions GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1;")"

# ── Format values ───────────────────────────────────────────
format_co2() {
  local grams="$1"
  local val unit
  if (( $(echo "$grams >= 1000" | bc -l) )); then
    val="$(echo "$grams" | awk '{printf "%.1f", $1/1000}')"
    unit="kg"
  else
    val="$(echo "$grams" | awk '{printf "%.0f", $1}')"
    unit="g"
  fi
  echo "$val $unit"
}

# Total CO2
read -r TOTAL_CO2_VALUE TOTAL_CO2_UNIT <<< "$(format_co2 "$TOTAL_CO2_RAW")"

# 2026 CO2
read -r CO2_2026_VALUE CO2_2026_UNIT <<< "$(format_co2 "$CO2_2026_RAW")"

# Total cost (rounded)
TOTAL_COST="$(echo "$TOTAL_COST_RAW" | awk '{printf "%.0f", $1}')"

# First date (extract YYYY-MM-DD from ISO)
FIRST_DATE="$(echo "$FIRST_DATE_RAW" | cut -c1-10)"

# Car km equiv (120g CO2/km)
EQUIV_KM="$(echo "$TOTAL_CO2_RAW" | awk '{printf "%.1f", $1/120}')"

# Format model name for display
format_model() {
  local m="$1"
  m="${m/claude-/}"
  m="${m/-4-6/}"
  echo "$m"
}
TOP_MODEL_DISPLAY="$(format_model "$TOP_MODEL")"

# ── Parse top 3 projects ───────────────────────────────────
P1_NAME="" P1_CO2_RAW=0 P1_CO2=""
P2_NAME="" P2_CO2_RAW=0 P2_CO2=""
P3_NAME="" P3_CO2_RAW=0 P3_CO2=""

i=0
while IFS='|' read -r pname pco2; do
  i=$((i+1))
  formatted="$(format_co2 "$pco2")"
  case $i in
    1) P1_NAME="$pname"; P1_CO2_RAW="$pco2"; P1_CO2="$formatted" ;;
    2) P2_NAME="$pname"; P2_CO2_RAW="$pco2"; P2_CO2="$formatted" ;;
    3) P3_NAME="$pname"; P3_CO2_RAW="$pco2"; P3_CO2="$formatted" ;;
  esac
done <<< "$TOP_PROJECTS"

# Percentage bars (relative to P1 = 100%)
if (( $(echo "$P1_CO2_RAW > 0" | bc -l) )); then
  P1_PCT="100"
  P2_PCT="$(echo "$P2_CO2_RAW $P1_CO2_RAW" | awk '{printf "%.0f", ($1/$2)*100}')"
  P3_PCT="$(echo "$P3_CO2_RAW $P1_CO2_RAW" | awk '{printf "%.0f", ($1/$2)*100}')"
else
  P1_PCT="100"; P2_PCT="50"; P3_PCT="25"
fi

# ── Generate HTML ───────────────────────────────────────────
echo "Generating HTML..."

TMP_HTML="$(mktemp /tmp/claude-carbon-report-XXXXXX.html)"

sed \
  -e "s|{{TOTAL_CO2_VALUE}}|${TOTAL_CO2_VALUE}|g" \
  -e "s|{{TOTAL_CO2_UNIT}}|${TOTAL_CO2_UNIT}|g" \
  -e "s|{{TOTAL_SESSIONS}}|${TOTAL_SESSIONS}|g" \
  -e "s|{{FIRST_DATE}}|${FIRST_DATE}|g" \
  -e "s|{{CO2_2026_VALUE}}|${CO2_2026_VALUE}|g" \
  -e "s|{{CO2_2026_UNIT}}|${CO2_2026_UNIT}|g" \
  -e "s|{{TOTAL_COST}}|${TOTAL_COST}|g" \
  -e "s|{{EQUIV_KM}}|${EQUIV_KM}|g" \
  -e "s|{{P1_NAME}}|${P1_NAME}|g" \
  -e "s|{{P1_CO2}}|${P1_CO2}|g" \
  -e "s|{{P1_PCT}}|${P1_PCT}|g" \
  -e "s|{{P2_NAME}}|${P2_NAME}|g" \
  -e "s|{{P2_CO2}}|${P2_CO2}|g" \
  -e "s|{{P2_PCT}}|${P2_PCT}|g" \
  -e "s|{{P3_NAME}}|${P3_NAME}|g" \
  -e "s|{{P3_CO2}}|${P3_CO2}|g" \
  -e "s|{{P3_PCT}}|${P3_PCT}|g" \
  -e "s|{{TOP_MODEL}}|${TOP_MODEL_DISPLAY}|g" \
  "$TEMPLATE" > "$TMP_HTML"

echo "HTML ready: $TMP_HTML"

# ── Export PNG via Playwright ───────────────────────────────
echo "Exporting PNG via Playwright..."

# Start a temp HTTP server
PORT=8799
python3 -m http.server "$PORT" --directory /tmp &>/dev/null &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null; rm -f $TMP_HTML" EXIT
sleep 0.5

HTML_FILENAME="$(basename "$TMP_HTML")"
URL="http://localhost:${PORT}/${HTML_FILENAME}"

# Find playwright-core module path
PW_PATH="$(node -e "try { console.log(require.resolve('playwright-core').replace(/\/index\.js$/, '')); } catch(e) { process.exit(1); }" 2>/dev/null)" || true

if [ -z "$PW_PATH" ]; then
  # Try common locations
  for candidate in \
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
  echo "Install it: npm install -g playwright-core && npx playwright install chromium" >&2
  kill "$SERVER_PID" 2>/dev/null
  rm -f "$TMP_HTML"
  exit 1
fi

# Use Playwright via Node.js
node -e "
const { chromium } = require('${PW_PATH}');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1080, height: 1080 },
    deviceScaleFactor: 2
  });
  await page.goto('${URL}', { waitUntil: 'networkidle' });
  // Wait for fonts to load
  await page.waitForTimeout(2000);
  await page.screenshot({
    path: '${OUTPUT}',
    clip: { x: 0, y: 0, width: 1080, height: 1080 }
  });
  await browser.close();
  console.log('Screenshot saved.');
})();
" 2>&1

if [ -f "$OUTPUT" ]; then
  echo ""
  echo "Report generated: $OUTPUT"
  echo "Dimensions: 2160x2160 (retina 2x)"
  # Show file size
  FILE_SIZE="$(du -h "$OUTPUT" | cut -f1 | tr -d ' ')"
  echo "Size: $FILE_SIZE"
else
  echo "Error: PNG export failed." >&2
  echo "Make sure Playwright is installed: npx playwright install chromium" >&2
  exit 1
fi
