#!/usr/bin/env bash
# generate-badge.sh — Print a shields.io badge of the all-time footprint.
# Output: a ready-to-paste markdown snippet plus the raw badge URL. The badge is
# static: re-run this script (or /carbon-badge) to refresh the number. The
# message carries the month the snapshot was taken, so a reader can tell how
# old the figure is, and the badge links to the methodology so the reader can
# tell how it was produced.
# No flags: the badge is a cumulative personal figure; a windowed one would go
# stale silently in a README.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}")"
METHODOLOGY_URL="https://github.com/gwittebolle/claude-carbon/blob/main/METHODOLOGY.md"
BADGE_COLOR="2f6f4f"
# Month of the snapshot, YYYY-MM. Overridable so tests get a stable URL.
SNAPSHOT_MONTH="${CLAUDE_CARBON_BADGE_MONTH:-$(date +%Y-%m)}"

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
MESSAGE="$(badge_escape "${CO2_VALUE} ${CO2_UNIT} CO2e, ${SNAPSHOT_MONTH}")"
BADGE_URL="https://img.shields.io/badge/${LABEL}-${MESSAGE}-${BADGE_COLOR}"

echo "Markdown (paste into your README):"
echo ""
echo "[![Claude Code carbon footprint](${BADGE_URL})](${METHODOLOGY_URL})"
echo ""
echo "Badge URL:"
echo ""
echo "${BADGE_URL}"
echo ""
echo "This is one developer's all-time total as of ${SNAPSHOT_MONTH}, not a project's."
echo "Put it in your profile README or a personal project. In a team or organisation"
echo "repository, reviewers will ask what produced the number and why it points elsewhere."
echo "The figure is static: re-run /carbon-badge to refresh it and its month."
