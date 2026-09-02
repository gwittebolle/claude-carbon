#!/usr/bin/env bash
set -euo pipefail

# configure-settings.sh — Wire claude-carbon into Claude Code's settings.json and install the
# /carbon-* slash commands. Idempotent and additive: it never overwrites a statusLine set by
# another tool and never drops hooks belonging to anything else.
#
# Called by install.sh (fresh install) and by update.sh, so an install made before a hook was
# introduced gets repaired on the next /carbon-update instead of staying silently half-wired.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"

# Marketplace installs declare their hooks in hooks/hooks.json (see plugin.json); writing them
# into settings.json as well would run every hook twice.
case "$INSTALL_DIR" in */.claude/plugins/*) exit 0 ;; esac

if ! command -v jq &>/dev/null; then
  echo "  jq not found; settings left untouched." >&2
  exit 0
fi

mkdir -p "$CONFIG_DIR"

# Claude Code is a native binary on Windows and may resolve these paths itself
# before handing them to Git Bash, so settings.json gets the "mixed" spelling
# ("C:/Users/me/…"): valid for the Windows side, and openable by bash as written.
# Identity on macOS and Linux, so nothing changes there.
CMD_DIR="$(cc_native_path "$INSTALL_DIR")"
STATUSLINE_CMD="${CMD_DIR}/scripts/statusline.sh"
STOP_CMD="${CMD_DIR}/scripts/persist-session.sh"
SESSIONSTART_CMD="${CMD_DIR}/scripts/safety-rescan.sh"

# Resolve a hook command to a comparable form. The same script reaches settings.json spelled
# several ways: the README's manual block uses `~/code/claude-carbon/...`, this script writes
# the expanded absolute path, and Claude Code accepts shell-escaped spaces (`~/Claude\ OS/...`).
# Comparing the raw strings would register a second copy of a hook that is already there.
# Commands whose directory does not exist (a third-party hook) are left as written.
normalize_cmd() {
  local c="$1" dir base
  # Strip a trailing carriage return. Under Git Bash, command substitution drops the
  # CR from a single-line capture but keeps the interior ones, so reading N commands
  # back out of jq yields a bare CR on every line but the last. Without this, our own
  # hook fails to match itself whenever another tool's hook sits after it in the same
  # event, and every install or update registers a second copy of ours.
  c="${c%$'\r'}"
  c="${c//\\ / }"
  # SC2088: the tilde here is data, not a path being expanded — we are matching a literal "~/"
  # prefix inside a string read from settings.json and expanding it ourselves.
  # shellcheck disable=SC2088
  case "$c" in "~/"*) c="${HOME}/${c#\~/}" ;; esac
  case "$c" in
    */*)
      dir="${c%/*}"
      base="${c##*/}"
      if [ -d "$dir" ]; then
        dir="$(cd "$dir" 2>/dev/null && pwd -P)" || dir="${c%/*}"
        c="${dir}/${base}"
      fi
      ;;
  esac
  printf '%s' "$c"
}

# Append a hook to an event array, unless that command is already registered under any
# spelling. Mutates $EXISTING (the settings JSON held in memory).
add_hook() {
  local event="$1" cmd="$2" has="false" target existing
  target="$(normalize_cmd "$cmd")"

  # Here-doc rather than a pipe: `while read` must run in this shell to keep `has`.
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    if [ "$(normalize_cmd "$existing")" = "$target" ]; then has="true"; break; fi
  done <<EOF
$(echo "$EXISTING" | jq -r --arg e "$event" '[.hooks[$e][]?.hooks[]?.command] | .[]' 2>/dev/null)
EOF

  if [ "$has" = "true" ]; then
    echo "  ${event} hook: already configured (skipped)"
  else
    EXISTING="$(echo "$EXISTING" | jq --arg e "$event" --arg c "$cmd" '
      .hooks = (.hooks // {}) |
      .hooks[$e] = ((.hooks[$e] // []) + [{
        matcher: "",
        hooks: [{type: "command", command: $c}]
      }])
    ')"
    echo "  ${event} hook: added"
  fi
}

if [ -f "$SETTINGS_FILE" ]; then
  EXISTING="$(cat "$SETTINGS_FILE")"

  HAS_STATUSLINE="$(echo "$EXISTING" | jq 'has("statusLine")' 2>/dev/null)" || HAS_STATUSLINE="false"
  if [ "$HAS_STATUSLINE" = "true" ]; then
    CURRENT_SL="$(echo "$EXISTING" | jq -r '.statusLine.command // ""' 2>/dev/null)"
    if echo "$CURRENT_SL" | grep -q "claude-carbon"; then
      echo "  statusLine: already configured (skipped)"
    else
      echo "  statusLine: skipped (already set to another tool)"
      echo "    To switch, replace the command in ${SETTINGS_FILE} with:"
      echo "    $STATUSLINE_CMD"
    fi
  else
    EXISTING="$(echo "$EXISTING" | jq --arg cmd "$STATUSLINE_CMD" '. + {statusLine: {type: "command", command: $cmd}}')"
    echo "  statusLine: added"
  fi

  # Stop: persist the session that just ended. SessionStart: throttled safety rescan, which
  # also drives the daily update check the status line reads.
  add_hook Stop "$STOP_CMD"
  add_hook SessionStart "$SESSIONSTART_CMD"

  # Write via tmp + mv: a truncating redirect would destroy the user's settings if jq failed.
  TMP="${SETTINGS_FILE}.tmp.$$"
  if echo "$EXISTING" | jq '.' > "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$SETTINGS_FILE"
  else
    rm -f "$TMP"
    echo "  WARNING: could not write ${SETTINGS_FILE}; it was left unchanged." >&2
  fi
else
  jq -n --arg sl "$STATUSLINE_CMD" --arg stop "$STOP_CMD" --arg start "$SESSIONSTART_CMD" '{
    statusLine: {type: "command", command: $sl},
    hooks: {
      Stop: [{
        matcher: "",
        hooks: [{type: "command", command: $stop}]
      }],
      SessionStart: [{
        matcher: "",
        hooks: [{type: "command", command: $start}]
      }]
    }
  }' > "$SETTINGS_FILE"
  echo "  Created $SETTINGS_FILE"
fi

# /carbon-* slash commands. Symlinked so they follow the clone on update — except
# on Windows, where Git Bash cannot create a real symlink without Developer Mode
# and silently makes a copy instead. There we copy on purpose, and refresh the
# copy on every run so an update still reaches the commands.
COMMANDS_DIR="${CONFIG_DIR}/commands"
mkdir -p "$COMMANDS_DIR"
for SKILL_NAME in carbon-report carbon-card carbon-update carbon-badge carbon-pr; do
  SKILL_SRC="${INSTALL_DIR}/skills/${SKILL_NAME}/SKILL.md"
  SKILL_LNK="${COMMANDS_DIR}/${SKILL_NAME}.md"
  if [ -L "$SKILL_LNK" ]; then
    echo "  /${SKILL_NAME}: already installed (skipped)"
  elif [ -f "$SKILL_LNK" ]; then
    # A plain file where a symlink was expected: either a Windows copy of ours,
    # which must be refreshed, or a command the user wrote, which must not be
    # touched. Ours always names the project; a hand-written one would not.
    if cc_is_windows && grep -q "claude-carbon" "$SKILL_LNK" 2>/dev/null; then
      if cmp -s "$SKILL_SRC" "$SKILL_LNK"; then
        echo "  /${SKILL_NAME}: already installed (skipped)"
      else
        cp -f "$SKILL_SRC" "$SKILL_LNK"
        echo "  /${SKILL_NAME}: refreshed"
      fi
    else
      echo "  /${SKILL_NAME}: already installed (skipped)"
    fi
  else
    cc_link_or_copy "$SKILL_SRC" "$SKILL_LNK"
    echo "  /${SKILL_NAME}: installed"
  fi
done
