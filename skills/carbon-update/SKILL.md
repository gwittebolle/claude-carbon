---
name: carbon-update
description: Update claude-carbon to the latest version and re-price history (CO2-only)
---

Run the following bash script exactly as written and present its output to the user. Do not paraphrase. It updates the user's claude-carbon install, whichever way it was installed: the plugin through Claude Code's own plugin commands, or the installer's git clone (dirty-safe `git pull`, setup refreshed, stored sessions re-priced with the new factors).

```bash
#!/usr/bin/env bash
# Locate the install that is actually wired into the status line, then run its updater.
REPO_DIR=""
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
SETTINGS="$(ccp "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/settings.json"
# A jq the installer fetched into the data folder (a Mac older than macOS 15 has none)
JQ_DIR="$(ccp "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/claude-carbon/bin"
if ! command -v jq >/dev/null 2>&1 && [ -x "$JQ_DIR/jq" ]; then PATH="$JQ_DIR:$PATH"; fi
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
  # statusLine.command stores a path, shell-escaped, or in double quotes on Windows:
  # unquote, expand ~ and unescape spaces
  SL_CMD="${SL_CMD#\"}"; SL_CMD="${SL_CMD%\"}"
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"; SL_CMD="$(ccp "$SL_CMD")"
  if [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ]; then
    REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
  fi
fi
# The install the status line runs from, before any guess below
SL_REPO="$REPO_DIR"
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$(ccp "$CLAUDE_PLUGIN_ROOT")"
[ -z "$REPO_DIR" ] && REPO_DIR="$(ccp "${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}")"

# Installed as a plugin and turned on: Claude Code updates it from its marketplace
PLUGIN_ON=""
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  PLUGIN_ON="$(jq -r '.enabledPlugins["claude-carbon@claude-carbon"] // empty' "$SETTINGS" 2>/dev/null)"
fi

if [ "$PLUGIN_ON" = "true" ]; then
  # The claude command, else the one the desktop app keeps for itself on a Mac
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  if [ -z "$CLAUDE_BIN" ]; then
    for C in "$HOME/Library/Application Support/Claude/claude-code"/*/claude.app/Contents/MacOS/claude; do
      [ -x "$C" ] && CLAUDE_BIN="$C"
    done
  fi
  if [ -n "$CLAUDE_BIN" ] && "$CLAUDE_BIN" plugin marketplace update claude-carbon \
     && "$CLAUDE_BIN" plugin update claude-carbon@claude-carbon; then
    echo "Restart Claude Code (quit the desktop app completely) to load the new version."
  else
    echo "claude-carbon is installed as a plugin. Update it from a terminal:"
    echo "  claude plugin marketplace update claude-carbon"
    echo "  claude plugin update claude-carbon@claude-carbon"
    echo "then restart Claude Code."
  fi
  # A clone next to the plugin, for the status line: its updater would wire the hooks a
  # second time (the plugin brings its own) and re-price the stored history, so it is
  # left to the person.
  if [ -n "$SL_REPO" ] && [ -d "${SL_REPO}/.git" ]; then
    echo ""
    echo "The status line runs from the clone at ${SL_REPO}. To update it: git -C \"${SL_REPO}\" pull"
  fi
elif [ -f "${REPO_DIR}/scripts/update.sh" ]; then
  bash "${REPO_DIR}/scripts/update.sh"
else
  echo "claude-carbon updater not found at ${REPO_DIR}/scripts/update.sh"
  echo "Re-run the installer to update:"
  echo "  curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash"
fi
```
