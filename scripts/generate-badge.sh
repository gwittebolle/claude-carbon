#!/usr/bin/env bash
# generate-badge.sh — Print a shields.io badge of the all-time footprint.
# Output: a ready-to-paste markdown snippet plus the raw badge URL. The badge is
# static: re-run this script (or /carbon-badge) to refresh the number.
# No flags: the badge is a cumulative personal figure; a windowed one would go
# stale silently in a README.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}")"
REPO_URL="https://github.com/gwittebolle/claude-carbon"
BADGE_COLOR="2f6f4f"

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 awk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found. Run setup.sh first." >&2
  exit 1
fi

# Pick the locale set before LC_ALL=C below masks it (only the decimal separator
# depends on it here; script messages stay English like everywhere else).
# shellcheck source=scripts/equiv-lib.sh
. "$SCRIPT_DIR/equiv-lib.sh"
EQUIV_SET="$(detect_equiv_set)"
export LC_ALL=C
# shellcheck source=scripts/format-lib.sh
. "$SCRIPT_DIR/format-lib.sh"

# All-time total from the stored column — same aggregate as the report's Totals
# line, never re-derived from the token columns.
TOTAL_CO2_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE COALESCE(excluded, 0) = 0;")"

read -r CO2_VALUE CO2_UNIT <<< "$(format_co2 "$TOTAL_CO2_RAW")"
if [ "$EQUIV_SET" = "fr" ]; then
  CO2_VALUE="${CO2_VALUE/./,}"
fi

# shields.io static-badge escaping: literal dash doubles, literal underscore
# doubles, then percent-encode what markdown or URLs would mangle.
badge_escape() {
  local s="$1"
  s="${s//-/--}"
  s="${s//_/__}"
  s="${s// /%20}"
  s="${s//,/%2C}"
  echo "$s"
}

LABEL="$(badge_escape "claude-carbon")"
MESSAGE="$(badge_escape "${CO2_VALUE} ${CO2_UNIT} CO2e")"
BADGE_URL="https://img.shields.io/badge/${LABEL}-${MESSAGE}-${BADGE_COLOR}"

echo "Markdown (paste into your README):"
echo ""
echo "[![Claude Code carbon footprint](${BADGE_URL})](${REPO_URL})"
echo ""
echo "Badge URL:"
echo ""
echo "${BADGE_URL}"
