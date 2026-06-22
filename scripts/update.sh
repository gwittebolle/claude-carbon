#!/usr/bin/env bash
# update.sh — dirty-safe self-update for git-clone installs of claude-carbon.
# Survives a working tree where the user edited data/factors.json or data/prices.json (the
# README invites it), which would otherwise break `git pull --ff-only`. Re-runs setup and a
# CO2-only recompute, then clears the "update available" notice. NOT for marketplace installs.
set -uo pipefail   # NOT -e: each git step is handled explicitly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${HOME}/.claude/claude-carbon"

[ -d "${REPO_DIR}/.git" ] || { echo "Not a git-clone install; nothing to update." >&2; exit 0; }
case "$REPO_DIR" in
  */.claude/plugins/*)
    echo "Installed via the Claude Code plugin marketplace."
    echo "Update with Claude Code's built-in:  /plugin update claude-carbon"
    exit 0 ;;
esac
command -v git >/dev/null 2>&1 || { echo "git not found." >&2; exit 1; }
export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20

# Stash ONLY the two user-editable tracked files (never -u: leaves untracked notes/images alone).
STASHED=0
if [ -n "$(git -C "$REPO_DIR" status --porcelain -- data/factors.json data/prices.json 2>/dev/null || true)" ]; then
  if git -C "$REPO_DIR" stash push --quiet -m "claude-carbon-update" -- data/factors.json data/prices.json 2>/dev/null; then
    STASHED=1
  fi
fi

# Fast-forward pull.
if git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
  PULL_OK=1
else
  PULL_OK=0
fi

# Restore the user's edits; on conflict, preserve them to *.local.bak and keep upstream clean.
if [ "$STASHED" = "1" ]; then
  if ! git -C "$REPO_DIR" stash pop --quiet 2>/dev/null; then
    for f in data/factors.json data/prices.json; do
      git -C "$REPO_DIR" show "stash@{0}:$f" > "${REPO_DIR}/${f}.local.bak" 2>/dev/null || true
    done
    git -C "$REPO_DIR" checkout --quiet HEAD -- data/factors.json data/prices.json 2>/dev/null || true
    git -C "$REPO_DIR" stash drop --quiet 2>/dev/null || true
    echo "Your local factors/prices edits conflicted with the update."
    echo "They were saved to data/factors.json.local.bak / data/prices.json.local.bak — re-apply manually."
  fi
fi

if [ "$PULL_OK" != "1" ]; then
  echo "Update could not fast-forward (diverged history or network)." >&2
  echo "Resolve manually:  cd \"${REPO_DIR}\" && git status" >&2
  exit 1
fi

# Refresh symlinks/settings, then re-price history (CO2-only by default: cheap, idempotent,
# no mixed-model cost drift).
CLAUDE_CARBON_INSTALLER=1 bash "${SCRIPT_DIR}/setup.sh" >/dev/null 2>&1 || true
DB_PATH="${CLAUDE_CARBON_DB:-${STATE_DIR}/carbon.db}"
if [ -f "$DB_PATH" ]; then
  bash "${SCRIPT_DIR}/recompute.sh" || echo "history not re-priced; see message above."
fi

# Clear the notice immediately so the statusline self-heals before the next daily check.
NEW_V="$(jq -r '.version // empty' "${REPO_DIR}/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
if command -v jq >/dev/null 2>&1 && [ -n "$NEW_V" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  TMP="${STATE_DIR}/update-check.json.tmp.$$"
  printf '{"behind":false,"local":"%s","remote":"%s","checked_at":%s}\n' \
    "$NEW_V" "$NEW_V" "$(date +%s)" > "$TMP" 2>/dev/null && mv -f "$TMP" "${STATE_DIR}/update-check.json"
fi

echo "claude-carbon updated to ${NEW_V:-latest}."
