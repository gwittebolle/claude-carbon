---
name: carbon-pr
description: Post the development footprint of the current branch as a sticky PR comment
---

Run the following bash script from the repository the PR belongs to, and present the output to the user.

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
REPO_DIR=""
if command -v jq >/dev/null 2>&1 && [ -f "$CFG/settings.json" ]; then
  SL_CMD="$(jq -r '.statusLine.command // empty' "$CFG/settings.json" 2>/dev/null)"
  # statusLine.command stores a shell-escaped path: expand ~ and unescape spaces
  SL_CMD="${SL_CMD//\\ / }"; SL_CMD="${SL_CMD/#\~/$HOME}"; SL_CMD="$(ccp "$SL_CMD")"
  [ -n "$SL_CMD" ] && [ -f "$SL_CMD" ] && REPO_DIR="$(cd "$(dirname "$SL_CMD")/.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && REPO_DIR="$(ccp "$CLAUDE_PLUGIN_ROOT")"
[ -z "$REPO_DIR" ] && [ -n "${CLAUDE_CARBON_DIR:-}" ] && REPO_DIR="$(ccp "$CLAUDE_CARBON_DIR")"
if [ -z "$REPO_DIR" ]; then
  # Pure marketplace installs reach here: no statusLine.command in settings.json and
  # no CLAUDE_PLUGIN_ROOT in a skill's bash env. Pick the newest cached plugin copy,
  # keeping only candidates that ship the PR report script.
  CACHE_LATEST=""
  for D in "$CFG/plugins/cache"/*/claude-carbon/*/; do
    [ -f "${D}scripts/generate-pr-report.sh" ] || continue
    if [ -z "$CACHE_LATEST" ] || [ "$(printf '%s\n%s\n' "$CACHE_LATEST" "$D" | sort -V | tail -1)" = "$D" ]; then
      CACHE_LATEST="$D"
    fi
  done
  [ -n "$CACHE_LATEST" ] && REPO_DIR="${CACHE_LATEST%/}"
fi
[ -z "$REPO_DIR" ] && REPO_DIR="$HOME/code/claude-carbon"

bash "$REPO_DIR/scripts/generate-pr-report.sh"
```

The script sums the local Claude Code sessions recorded for the current branch of the current project and posts (or updates in place) one sticky comment on the branch's open PR, through the user's own `gh` auth. Report its final line to the user as printed; never recompute or reformat the numbers.

If it reports no sessions for the branch, tell the user that only sessions recorded since the `git_branch` column exists carry a branch, and that `scripts/backfill.sh` repairs older rows while their transcripts are still on disk. If it reports no open PR, suggest pushing the branch and opening one first, or passing `--pr <number>`. If the script itself is missing (an install that predates it), suggest `/carbon-update`.
