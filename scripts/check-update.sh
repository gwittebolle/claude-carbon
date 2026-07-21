#!/usr/bin/env bash
# check-update.sh — backgrounded, throttled remote version check. Writes a cached flag
# (~/.claude/claude-carbon/update-check.json) that statusline.sh reads locally. NEVER run
# this from the statusline: it does network I/O. It is launched detached by the SessionStart
# hook (safety-rescan.sh), at most once/day. Swallows every error; safe to kill anytime.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon"
OUT="${STATE_DIR}/update-check.json"

# Opt-out (mirrors npm/gh NO_UPDATE_NOTIFIER convention)
[ -n "${CLAUDE_CARBON_NO_UPDATE_NOTIFIER:-}" ] && exit 0

# Only a real git-clone install, and NOT Claude Code's managed marketplace cache clone
# (marketplace users get native auto-update; we must never mutate or false-nag that clone).
[ -d "${REPO_DIR}/.git" ] || exit 0
case "$REPO_DIR" in */.claude/plugins/*) exit 0 ;; esac
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
# Version-sort is required to compare semver; ancient BusyBox lacks `sort -V` and would
# mis-rank (e.g. 1.10.0 < 1.9.0). Bail rather than emit a wrong notice.
printf '1.0\n1.0.1\n' | sort -V >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

LOCAL_V="$(jq -r '.version // empty' "${REPO_DIR}/.claude-plugin/plugin.json" 2>/dev/null)"
[ -n "$LOCAL_V" ] || exit 0

# Native git timeouts (portable, work even where coreutils `timeout` is absent, e.g. stock macOS).
export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20
# Belt-and-suspenders hard timeout if available (gtimeout on macOS via coreutils).
TO=""
if command -v timeout  >/dev/null 2>&1; then TO="timeout 25"
elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 25"; fi

# Detect origin's default branch; fall back to main.
DEF_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -n "$DEF_BRANCH" ] || DEF_BRANCH=main

# Fetch the ref only (no checkout, no merge, no working-tree change).
$TO git -C "$REPO_DIR" fetch --quiet origin "$DEF_BRANCH" 2>/dev/null || exit 0

# Compare versions (a string field), not raw HEAD SHA — so docs/CI commits never nag.
REMOTE_V="$(git -C "$REPO_DIR" show "origin/${DEF_BRANCH}:.claude-plugin/plugin.json" 2>/dev/null \
            | jq -r '.version // empty' 2>/dev/null)"
[ -n "$REMOTE_V" ] || exit 0

# behind = remote is strictly newer (semver via sort -V).
BEHIND=false
if [ "$LOCAL_V" != "$REMOTE_V" ] && \
   [ "$(printf '%s\n%s\n' "$LOCAL_V" "$REMOTE_V" | sort -V | tail -1)" = "$REMOTE_V" ]; then
  BEHIND=true
fi

# Atomic write (tmp + mv) so the per-turn statusline never reads a torn file.
TMP="${OUT}.tmp.$$"
printf '{"behind":%s,"local":"%s","remote":"%s","checked_at":%s}\n' \
  "$BEHIND" "$LOCAL_V" "$REMOTE_V" "$(date +%s)" > "$TMP" 2>/dev/null && mv -f "$TMP" "$OUT"
exit 0
