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
  # statusLine.command stores a shell-escaped path: expand ~ and unescape spaces
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$CLAUDE_PLUGIN_ROOT"
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_CARBON_DIR:-}" ] && REPO_DIR="$CLAUDE_CARBON_DIR"
if [ -z "$REPO_DIR" ]; then
  # Pure marketplace installs reach here: no statusLine.command in settings.json and
  # no CLAUDE_PLUGIN_ROOT in a skill's bash env. Pick the newest cached plugin copy,
  # the same scan as statusline.sh CACHE_LATEST.
  CACHE_LATEST=""
  for D in "$CFG/plugins/cache"/*/claude-carbon/*/; do
    [ -f "${D}scripts/generate-report.sh" ] || continue
    if [ -z "$CACHE_LATEST" ] || [ "$(printf '%s\n%s\n' "$CACHE_LATEST" "$D" | sort -V | tail -1)" = "$D" ]; then
      CACHE_LATEST="$D"
    fi
  done
  [ -n "$CACHE_LATEST" ] && REPO_DIR="${CACHE_LATEST%/}"
fi
[ -z "$REPO_DIR" ] && REPO_DIR="$HOME/code/claude-carbon"

bash "$REPO_DIR/scripts/generate-report.sh"
```

The script prints the export directory on its final line (`Done. <dir>/`) and a `Totals since ...` line just above it. Show the export path to the user so they can share the PNGs.

Then offer a ready-to-paste social post draft (LinkedIn or X) built ONLY from the numbers on the `Totals since ...` line: CO2e total, cost, the car-km equivalence, session count. The car figure on that line follows the detected locale (ADEME km on a French or undetected locale, EPA miles on a US one, world-average km otherwise) and matches the EN card; the FR card always shows the ADEME figure. Quote the line as printed, unit included, rather than recomputing it. Write it in the user's working language. Keep the register strictly factual: numbers and equivalences, no self-congratulation, no green-virtue framing, no hashtag pile (two at most). Do not add a credit line for the tool in the draft; the card's footer already carries the repo and tokenclimate.com attribution. If the user asks for changes, iterate on the draft, never on the numbers.
