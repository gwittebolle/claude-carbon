#!/usr/bin/env bash
# generate-report.sh — Generate Claude Carbon Report PNGs from DB stats.
# Exports 2 variants: summary (stats only) + detailed (with projects).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_DIR/templates"
EXPORT_DIR="$PROJECT_DIR/exports"
DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"
TODAY="$(date +%Y-%m-%d)"

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
echo "Querying carbon.db..."

read -r TOTAL_SESSIONS TOTAL_CO2_RAW TOTAL_COST_RAW FIRST_DATE_RAW <<< \
  "$(sqlite3 "$DB_PATH" "SELECT COUNT(*), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0), MIN(started_at) FROM sessions;" | tr '|' ' ')"

CO2_2026_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE started_at >= '2026-01-01';")"

# Top 5 projects (name, co2, session count)
TOP_PROJECTS="$(sqlite3 -separator '|' "$DB_PATH" "SELECT project, SUM(co2_grams), COUNT(*) FROM sessions GROUP BY project ORDER BY SUM(co2_grams) DESC LIMIT 5;")"

TOP_MODEL="$(sqlite3 "$DB_PATH" "SELECT model FROM sessions GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1;")"

# ── Format values ───────────────────────────────────────────
format_co2() {
  local grams="$1"
  if (( $(echo "$grams >= 1000" | bc -l) )); then
    echo "$(echo "$grams" | awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | awk '{printf "%.0f", $1}') g"
  fi
}

format_co2_parts() {
  local grams="$1"
  if (( $(echo "$grams >= 1000" | bc -l) )); then
    echo "$(echo "$grams" | awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | awk '{printf "%.0f", $1}') g"
  fi
}

read -r TOTAL_CO2_VALUE TOTAL_CO2_UNIT <<< "$(format_co2_parts "$TOTAL_CO2_RAW")"
read -r CO2_2026_VALUE CO2_2026_UNIT <<< "$(format_co2_parts "$CO2_2026_RAW")"
TOTAL_COST="$(echo "$TOTAL_COST_RAW" | awk '{printf "%.0f", $1}')"
FIRST_DATE="$(echo "$FIRST_DATE_RAW" | cut -c1-10)"
EQUIV_KM="$(echo "$TOTAL_CO2_RAW" | awk '{printf "%.1f", $1/120}')"

# Format model
TOP_MODEL_DISPLAY="$(echo "$TOP_MODEL" | sed 's/claude-//' | sed 's/-4-6//' | sed 's/-4-5.*//')"

# ── Parse top 5 projects ───────────────────────────────────
declare -a P_NAME P_CO2 P_SESSIONS
i=0
while IFS='|' read -r pname pco2 psessions; do
  P_NAME[$i]="$pname"
  P_CO2[$i]="$(format_co2 "$pco2")"
  P_SESSIONS[$i]="$psessions"
  i=$((i+1))
done <<< "$TOP_PROJECTS"

# Pad to 5 entries
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
    -e "s|{{TOTAL_CO2_VALUE}}|${TOTAL_CO2_VALUE}|g" \
    -e "s|{{TOTAL_CO2_UNIT}}|${TOTAL_CO2_UNIT}|g" \
    -e "s|{{TOTAL_SESSIONS}}|${TOTAL_SESSIONS}|g" \
    -e "s|{{FIRST_DATE}}|${FIRST_DATE}|g" \
    -e "s|{{CO2_2026_VALUE}}|${CO2_2026_VALUE}|g" \
    -e "s|{{CO2_2026_UNIT}}|${CO2_2026_UNIT}|g" \
    -e "s|{{TOTAL_COST}}|${TOTAL_COST}|g" \
    -e "s|{{EQUIV_KM}}|${EQUIV_KM}|g" \
    -e "s|{{TOP_MODEL}}|${TOP_MODEL_DISPLAY}|g" \
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

TMP_SUMMARY="$(mktemp /tmp/claude-carbon-summary-XXXXXX.html)"
TMP_DETAILED="$(mktemp /tmp/claude-carbon-detailed-XXXXXX.html)"

inject_common "$TEMPLATE_DIR/report-summary.html" "$TMP_SUMMARY"
inject_common "$TEMPLATE_DIR/report-detailed.html" "$TMP_DETAILED"

# ── Find Playwright ─────────────────────────────────────────
PW_PATH="$(node -e "try { console.log(require.resolve('playwright-core').replace(/\/index\.js$/, '')); } catch(e) { process.exit(1); }" 2>/dev/null)" || true

if [ -z "$PW_PATH" ]; then
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
  echo "Install: npm install -g playwright-core && npx playwright install chromium" >&2
  rm -f "$TMP_SUMMARY" "$TMP_DETAILED"
  exit 1
fi

# ── Export PNGs ──────────────────────────────────────────────
echo "Exporting PNGs via Playwright..."

PORT=8799
python3 -m http.server "$PORT" --directory /tmp &>/dev/null &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null; rm -f $TMP_SUMMARY $TMP_DETAILED" EXIT
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

OUT_SUMMARY="$EXPORT_DIR/claude-carbon-summary-${TODAY}.png"
OUT_DETAILED="$EXPORT_DIR/claude-carbon-detailed-${TODAY}.png"

export_png "$TMP_SUMMARY" "$OUT_SUMMARY" "Summary"
export_png "$TMP_DETAILED" "$OUT_DETAILED" "Detailed"

echo ""
echo "Done. ${EXPORT_DIR}/"
