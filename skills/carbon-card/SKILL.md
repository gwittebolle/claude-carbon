---
name: carbon-card
description: Generate shareable PNG report cards of your Claude Code carbon footprint
---

Run the following bash script and present the output to the user. Show the exported file paths so they can share the PNGs, and tell them the folder has been opened in their file manager. When no browser could draw them there are no PNGs: see the last paragraph.

```bash
#!/usr/bin/env bash
# Locate the install wired into the status line (honours CLAUDE_CONFIG_DIR),
# then fall back to CLAUDE_PLUGIN_ROOT / CLAUDE_CARBON_DIR / the default path.
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
CFG="$(ccp "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
# A jq the installer fetched into the data folder (a Mac older than macOS 15 has none)
if ! command -v jq >/dev/null 2>&1 && [ -x "$CFG/claude-carbon/bin/jq" ]; then PATH="$CFG/claude-carbon/bin:$PATH"; fi
REPO_DIR=""
if command -v jq >/dev/null 2>&1 && [ -f "$CFG/settings.json" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$CFG/settings.json" 2>/dev/null)"
  # statusLine.command stores a path, shell-escaped, or in double quotes on Windows:
  # unquote, expand ~ and unescape spaces
  SL_CMD="${SL_CMD#\"}"; SL_CMD="${SL_CMD%\"}"
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"; SL_CMD="$(ccp "$SL_CMD")"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$(ccp "$CLAUDE_PLUGIN_ROOT")"
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_CARBON_DIR:-}" ] && REPO_DIR="$(ccp "$CLAUDE_CARBON_DIR")"
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

The script prints the export directory on its final line (`Done. <dir>/`) and a `Totals since ...` line before the exported paths. When a line starting with `Note:` comes just before the `Totals since ...` line, relay it first, in the user's working language and in one sentence: the token count on the card now includes cache reads, which is why it is much higher than on their earlier cards, and the CO2 and the API-price cost have not changed. It appears once. The directory is the user's Downloads folder (`~/Downloads/claude-carbon/`, or `CLAUDE_CARBON_EXPORT_DIR` when set), and the script has already opened it in the file manager: Finder with the summary card selected on macOS, Explorer on Windows, the default file manager on Linux (skipped when `CLAUDE_CARBON_NO_OPEN` is set or no display is available). Show the export path exactly as printed, it is already in the platform's native spelling, and say the folder should now be open in front of them.

Then, in one or two short sentences in the user's working language, encourage them to post the card (LinkedIn works well), and say you can help write the post if they want. Do not write a draft unless they ask. If they do, build it ONLY from the numbers on the `Totals since ...` line, quoted as printed with unit and factor (the car figure follows the detected locale and names its factor after "by car"), in a strictly factual register: no self-congratulation, no green-virtue framing, two hashtags at most, no credit line for the tool (the card's footer already carries it). Iterate on the wording, never on the numbers.

The PNGs come from Playwright's Chromium when it is installed, otherwise from a Google Chrome, Microsoft Edge, Chromium or Brave already on the machine, run headless (the `Exporting PNGs via ...` line names it). With none of them, or when the browser draws nothing, the script still exits 0 and makes no PNG. Its last line then starts with `No PNG:` and comes right after the `Totals since ...` line. The summary card has been saved as an HTML page in the export folder and opened in the default browser instead (or, when nothing could be opened, the line gives the page's path), scaled to fit the window, and a screenshot of it is the card. Tell the user exactly that, in their language: the card is in their browser, a screenshot is enough to share it, and installing Google Chrome or Microsoft Edge gets PNGs next time. Do not present it as an error and do not run the install yourself. The offer to help with a post stands the same way.
