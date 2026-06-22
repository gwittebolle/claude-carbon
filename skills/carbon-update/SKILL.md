---
name: carbon-update
description: Update claude-carbon to the latest version and re-price history (CO2-only)
---

Run the following bash script exactly as written and present its output to the user. Do not paraphrase. It updates the user's claude-carbon install (dirty-safe `git pull`), refreshes setup, and re-prices stored sessions with the new factors.

```bash
#!/usr/bin/env bash
# Locate the install that is actually wired into the status line, then run its updater.
REPO_DIR=""
SETTINGS="${HOME}/.claude/settings.json"
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
  if [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ]; then
    REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
  fi
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$CLAUDE_PLUGIN_ROOT"
[ -z "$REPO_DIR" ] && REPO_DIR="${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}"

if [ -f "${REPO_DIR}/scripts/update.sh" ]; then
  bash "${REPO_DIR}/scripts/update.sh"
else
  echo "claude-carbon updater not found at ${REPO_DIR}/scripts/update.sh"
  echo "Re-run the installer to update:"
  echo "  curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash"
fi
```
