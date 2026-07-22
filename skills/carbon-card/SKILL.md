---
name: carbon-card
description: Generate shareable PNG report cards of your Claude Code carbon footprint
---

Run the following bash script and present the output to the user. Show the exported file paths so they can share the PNGs.

```bash
#!/usr/bin/env bash
# Locate the install wired into the status line (honours CLAUDE_CONFIG_DIR),
# then fall back to CLAUDE_PLUGIN_ROOT / CLAUDE_CARBON_DIR / the default path.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REPO_DIR=""
if command -v jq >/dev/null 2>&1 && [ -f "$CFG/settings.json" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$CFG/settings.json" 2>/dev/null)"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$CLAUDE_PLUGIN_ROOT"
[ -z "$REPO_DIR" ] && REPO_DIR="${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}"

bash "$REPO_DIR/scripts/generate-report.sh"
```

The script prints the export directory on its final line (`Done. <dir>/`). Show that path to the user so they can share the PNGs.
