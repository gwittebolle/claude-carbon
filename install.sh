#!/usr/bin/env bash
set -euo pipefail

# install.sh — One-line installer for claude-carbon.
# Usage: curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash

INSTALL_DIR="${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}"
# Honour Claude Code's own CLAUDE_CONFIG_DIR so a second environment
# (e.g. CLAUDE_CONFIG_DIR=~/.claude-work claude) installs into its own dir.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

echo ""
echo "  claude-carbon installer"
echo "  Track the carbon footprint of your Claude Code sessions."
echo ""

# 1. Check dependencies
for cmd in jq sqlite3 git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." >&2
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "  Install with: brew install $cmd" >&2
    else
      echo "  Install with: apt install $cmd" >&2
    fi
    exit 1
  fi
done

# 2. Clone (fresh) or update (existing, dirty-safe against locally-edited data files)
WAS_UPDATE=0
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  WAS_UPDATE=1
  export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20
  # The README invites editing data/factors.json, which breaks `git pull --ff-only`.
  # Stash just those two tracked files, pull, restore; on conflict keep upstream + back up theirs.
  STASHED=0
  if [ -n "$(git -C "$INSTALL_DIR" status --porcelain -- data/factors.json data/prices.json 2>/dev/null || true)" ]; then
    if git -C "$INSTALL_DIR" stash push --quiet -m "claude-carbon-install" -- data/factors.json data/prices.json 2>/dev/null; then
      STASHED=1
    fi
  fi
  git -C "$INSTALL_DIR" pull --ff-only --quiet \
    || echo "  WARNING: could not fast-forward. Resolve with: cd $INSTALL_DIR && git status"
  if [ "$STASHED" = "1" ]; then
    if ! git -C "$INSTALL_DIR" stash pop --quiet 2>/dev/null; then
      for f in data/factors.json data/prices.json; do
        git -C "$INSTALL_DIR" show "stash@{0}:$f" > "${INSTALL_DIR}/${f}.local.bak" 2>/dev/null || true
      done
      git -C "$INSTALL_DIR" checkout --quiet HEAD -- data/factors.json data/prices.json 2>/dev/null || true
      git -C "$INSTALL_DIR" stash drop --quiet 2>/dev/null || true
      echo "  Your local factors/prices edits were saved to *.local.bak (re-apply manually)."
    fi
  fi
else
  echo "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet https://github.com/gwittebolle/claude-carbon.git "$INSTALL_DIR"
fi

# 3. Run setup (creates DB, backfills history)
echo ""
CLAUDE_CARBON_INSTALLER=1 bash "$INSTALL_DIR/scripts/setup.sh"

# 3b. On update, re-price stored history with the new factors (CO2-only; cost left intact).
if [ "$WAS_UPDATE" = "1" ]; then
  DB_PATH="${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}"
  if [ -f "$DB_PATH" ]; then
    bash "$INSTALL_DIR/scripts/recompute.sh" || echo "  (history not re-priced; see message above)"
  fi
fi

# 4. Configure Claude Code settings and install the /carbon-* commands
echo ""
echo "Configuring Claude Code..."

bash "$INSTALL_DIR/scripts/configure-settings.sh"

echo ""
echo "Done. Restart Claude Code to see your CO2 in the status line."
echo ""
