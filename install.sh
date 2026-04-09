#!/usr/bin/env bash
set -euo pipefail

# install.sh — One-line installer for claude-carbon.
# Usage: curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash

INSTALL_DIR="${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}"
SETTINGS_FILE="${HOME}/.claude/settings.json"

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

# 2. Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet
else
  echo "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet https://github.com/gwittebolle/claude-carbon.git "$INSTALL_DIR"
fi

# 3. Run setup (creates DB, backfills history)
echo ""
CLAUDE_CARBON_INSTALLER=1 bash "$INSTALL_DIR/scripts/setup.sh"

# 4. Configure Claude Code settings
echo ""
echo "Configuring Claude Code..."

mkdir -p "${HOME}/.claude"

STATUSLINE_CMD="${INSTALL_DIR}/scripts/statusline.sh"
HOOK_CMD="${INSTALL_DIR}/scripts/persist-session.sh"

if [ -f "$SETTINGS_FILE" ]; then
  # Merge into existing settings
  EXISTING="$(cat "$SETTINGS_FILE")"

  # Add statusLine if not present
  HAS_STATUSLINE="$(echo "$EXISTING" | jq 'has("statusLine")' 2>/dev/null)" || HAS_STATUSLINE="false"
  if [ "$HAS_STATUSLINE" = "true" ]; then
    CURRENT_SL="$(echo "$EXISTING" | jq -r '.statusLine.command // ""' 2>/dev/null)"
    if echo "$CURRENT_SL" | grep -q "claude-carbon"; then
      echo "  statusLine: already configured (skipped)"
    else
      echo "  statusLine: skipped (already set to another tool)"
      echo "    To switch, replace the command in ~/.claude/settings.json with:"
      echo "    $STATUSLINE_CMD"
    fi
  else
    EXISTING="$(echo "$EXISTING" | jq --arg cmd "$STATUSLINE_CMD" '. + {statusLine: {type: "command", command: $cmd}}')"
    echo "  statusLine: added"
  fi

  # Add Stop hook if not present
  HAS_HOOK="$(echo "$EXISTING" | jq --arg cmd "$HOOK_CMD" '
    .hooks.Stop // [] |
    map(.hooks // []) | flatten |
    any(.command == $cmd)
  ' 2>/dev/null)" || HAS_HOOK="false"

  if [ "$HAS_HOOK" = "true" ]; then
    echo "  Stop hook: already configured (skipped)"
  else
    EXISTING="$(echo "$EXISTING" | jq --arg cmd "$HOOK_CMD" '
      .hooks = (.hooks // {}) |
      .hooks.Stop = ((.hooks.Stop // []) + [{
        matcher: "",
        hooks: [{type: "command", command: $cmd}]
      }])
    ')"
    echo "  Stop hook: added"
  fi

  echo "$EXISTING" | jq '.' > "$SETTINGS_FILE"
else
  # Create new settings file
  jq -n --arg sl "$STATUSLINE_CMD" --arg hk "$HOOK_CMD" '{
    statusLine: {type: "command", command: $sl},
    hooks: {
      Stop: [{
        matcher: "",
        hooks: [{type: "command", command: $hk}]
      }]
    }
  }' > "$SETTINGS_FILE"
  echo "  Created $SETTINGS_FILE"
fi

# 5. Install /carbon-report slash command
COMMANDS_DIR="${HOME}/.claude/commands"
SKILL_SOURCE="${INSTALL_DIR}/skills/carbon-report/SKILL.md"
SKILL_LINK="${COMMANDS_DIR}/carbon-report.md"

mkdir -p "$COMMANDS_DIR"
if [ -L "$SKILL_LINK" ] || [ -f "$SKILL_LINK" ]; then
  echo "  /carbon-report: already installed (skipped)"
else
  ln -s "$SKILL_SOURCE" "$SKILL_LINK"
  echo "  /carbon-report: installed"
fi

echo ""
echo "Done. Restart Claude Code to see your CO2 in the status line."
echo ""
