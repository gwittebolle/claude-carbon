#!/usr/bin/env bash
# post-upgrade.sh — what a Homebrew install does once after `brew upgrade` put a new
# version in place, since nobody runs an updater there: refresh the copy of the mod (it
# carries its own factors and prices) and bring the stored history to this version's
# factors (CO2 only, as update.sh does for a clone).
#
# Launched detached by the SessionStart hook (safety-rescan.sh), once per version. Never
# touches settings.json. What it did goes to post-upgrade.log next to the database;
# `claude-carbon setup` does the same by hand if this run failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"
STATE_DIR="${CONFIG_DIR}/claude-carbon"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${STATE_DIR}/carbon.db}")"
LOG="${STATE_DIR}/post-upgrade.log"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
{
  echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) claude-carbon $(cc_version "$(dirname "$SCRIPT_DIR")")"
  # Only a copy this install made: someone who took the mod out keeps it out.
  if [ -f "${CONFIG_DIR}/skills/claude-carbon/.claude-carbon-managed" ]; then
    bash "${SCRIPT_DIR}/install-mod.sh"
  fi
  if [ -f "$DB_PATH" ]; then
    bash "${SCRIPT_DIR}/recompute.sh" || echo "history not re-priced"
  fi
  echo "done"
} >"$LOG" 2>&1
exit 0
