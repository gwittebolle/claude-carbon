#!/usr/bin/env bash
set -euo pipefail

# configure-settings.sh — Wire claude-carbon into Claude Code's settings.json and install the
# /carbon-* slash commands. Idempotent and additive: it never overwrites a statusLine set by
# another tool and never drops hooks belonging to anything else.
#
# Called by install.sh (fresh install) and by update.sh, so an install made before a hook was
# introduced gets repaired on the next /carbon-update instead of staying silently half-wired.
#
#   configure-settings.sh            wire this install (stops when another one is wired)
#   configure-settings.sh --replace  wire this install in place of another one
#   configure-settings.sh --remove   take this install's wiring out again
#
# --remove takes out only what this script writes from this folder: the status line and the
# hooks whose command is exactly one of ours, the /carbon-* links that point here, and the
# copy of the mod. The data in claude-carbon/ under the config folder stays.

MODE="add"
case "${1:-}" in
  "") ;;
  --replace) MODE="replace" ;;
  --remove) MODE="remove" ;;
  *) echo "usage: configure-settings.sh [--replace|--remove]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
# Under Homebrew this script is reached through the versioned Cellar folder, which the next
# upgrade deletes: what gets written is the opt/ path, the one that stays.
INSTALL_DIR="$(cc_stable_root "$(dirname "$SCRIPT_DIR")")"
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
# On Windows these paths go in double quotes, as hooks/hooks.json writes them. Claude Code
# runs the status line and hooks in PowerShell when it found no Git Bash as the session
# started (Git installed during that session, the usual case on a first install from the
# desktop app). PowerShell takes a quoted path for a string and only prints it; a bare one
# it opens through the .sh file association, a Git Bash window each time that stays open.
# Git Bash runs both alike. The skills strip the quotes when they read the status line
# back to find this folder.
hook_cmd() {
  if cc_is_windows; then printf '"%s"' "$1"; else printf '%s' "$1"; fi
}
STATUSLINE_CMD="$(hook_cmd "${CMD_DIR}/scripts/statusline.sh")"
STOP_CMD="$(hook_cmd "${CMD_DIR}/scripts/persist-session.sh")"
SESSIONSTART_CMD="$(hook_cmd "${CMD_DIR}/scripts/safety-rescan.sh")"
SESSIONEND_CMD="$(hook_cmd "${CMD_DIR}/scripts/persist-on-exit.sh")"
AGENTSTOP_CMD="$(hook_cmd "${CMD_DIR}/scripts/agent-stop.sh")"
# The events this script writes a hook for, and the script each one runs.
HOOK_EVENTS="Stop SessionEnd SessionStart SubagentStop"
event_script() {
  case "$1" in
    Stop) echo persist-session.sh ;;
    SessionEnd) echo persist-on-exit.sh ;;
    SessionStart) echo safety-rescan.sh ;;
    SubagentStop) echo agent-stop.sh ;;
  esac
}

# plain_cmd: a command as the path it names, without quotes, escapes or "~", not resolved.
plain_cmd() {
  local c="$1"
  # Strip a trailing carriage return. Under Git Bash, command substitution drops the
  # CR from a single-line capture but keeps the interior ones, so reading N commands
  # back out of jq yields a bare CR on every line but the last. Without this, our own
  # hook fails to match itself whenever another tool's hook sits after it in the same
  # event, and every install or update registers a second copy of ours.
  c="${c%$'\r'}"
  # A path in double quotes (Windows installs, hooks/hooks.json) is the same path bare
  case "$c" in \"*\") c="${c#\"}"; c="${c%\"}" ;; esac
  c="${c//\\ / }"
  # SC2088: the tilde here is data, not a path being expanded — we are matching a literal "~/"
  # prefix inside a string read from settings.json and expanding it ourselves.
  # shellcheck disable=SC2088
  case "$c" in "~/"*) c="${HOME}/${c#\~/}" ;; esac
  printf '%s' "$c"
}

# Resolve a hook command to a comparable form. The same script reaches settings.json spelled
# several ways: the README's manual block uses `~/code/claude-carbon/...`, this script writes
# the expanded absolute path, and Claude Code accepts shell-escaped spaces (`~/Claude\ OS/...`).
# Comparing the raw strings would register a second copy of a hook that is already there.
# Commands whose directory does not exist (a third-party hook) are left as written.
normalize_cmd() {
  local c dir base
  c="$(plain_cmd "$1")"
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

# Commands registered for an event, one per line, as written in settings.json.
event_commands() {
  # jq.exe ends every line with CRLF under Git Bash; a command never holds a CR itself.
  echo "$EXISTING" | jq -r --arg e "$1" '[.hooks[$e][]?.hooks[]?.command // empty] | .[]' 2>/dev/null | tr -d '\r'
}

# Append a hook to an event array, unless that command is already registered under any
# spelling. Mutates $EXISTING (the settings JSON held in memory). The matcher defaults to
# "" (every event).
add_hook() {
  local event="$1" cmd="$2" matcher="${3:-}" has="false" target existing
  target="$(normalize_cmd "$cmd")"

  # Here-doc rather than a pipe: `while read` must run in this shell to keep `has`.
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    if [ "$(normalize_cmd "$existing")" = "$target" ]; then has="true"; break; fi
  done <<EOF
$(event_commands "$event")
EOF

  if [ "$has" = "true" ]; then
    echo "  ${event} hook: already configured (skipped)"
  else
    EXISTING="$(echo "$EXISTING" | jq --arg e "$event" --arg c "$cmd" --arg m "$matcher" '
      .hooks = (.hooks // {}) |
      .hooks[$e] = ((.hooks[$e] // []) + [{
        matcher: $m,
        hooks: [{type: "command", command: $c}]
      }])
    ')"
    CHANGED=1
    echo "  ${event} hook: added"
  fi
}

# Take one command out of an event, as it is written. Only the hook itself goes: the group
# it sat in stays when it holds another hook, and so does the event when it holds another
# group. Mutates $EXISTING.
drop_hook_raw() {
  local c
  # A CR read back from jq.exe would make the comparison below miss the hook (Windows).
  c="$(printf '%s' "$2" | tr -d '\r')"
  EXISTING="$(echo "$EXISTING" | jq --arg e "$1" --arg c "$c" '
    .hooks[$e] = [ .hooks[$e][] |
      if any(.hooks[]?; .command == $c)
      then (.hooks |= map(select(.command != $c))) | select((.hooks | length) > 0)
      else . end ] |
    if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end |
    if (.hooks | length) == 0 then del(.hooks) else . end
  ')"
  CHANGED=1
}

# Take out the wiring that runs the scripts of one install folder: its status line, its
# hooks, its /carbon-* links. A command with arguments (`statusline.sh --segment` inside
# another status line) is never equal to a bare script, and stays. Mutates $EXISTING.
remove_wiring_of() {
  local root="$1" label="$2" event target existing removed wired=0
  target="$(normalize_cmd "${root}/scripts/statusline.sh")"
  existing="$(echo "$EXISTING" | jq -r '(.statusLine | objects | .command) // ""' 2>/dev/null)"
  if [ -n "$existing" ] && [ "$(normalize_cmd "$existing")" = "$target" ]; then
    EXISTING="$(echo "$EXISTING" | jq 'del(.statusLine)')"
    CHANGED=1
    wired=1
    echo "  statusLine: removed${label}"
  fi
  for event in $HOOK_EVENTS; do
    target="$(normalize_cmd "${root}/scripts/$(event_script "$event")")"
    removed=0
    while IFS= read -r existing; do
      [ -n "$existing" ] || continue
      if [ "$(normalize_cmd "$existing")" = "$target" ]; then
        drop_hook_raw "$event" "$existing"
        removed=1
      fi
    done <<EOF
$(event_commands "$event")
EOF
    [ "$removed" = "1" ] && { wired=1; echo "  ${event} hook: removed${label}"; }
  done
  remove_links_of "$root" "$label" "$wired"
}

# The /carbon-* commands that come from one install folder: a link into its skills/, or on
# Windows (where they are copies) a file identical to its skill. Anything else is the
# user's own command and stays. A Windows copy says nothing about which install made it
# (two copies of claude-carbon ship the same file), so it goes only when settings.json ran
# this install ($3 = 1, the default when there is no settings.json to tell).
remove_links_of() {
  local root="$1" label="$2" wired="${3:-1}" name lnk src dest
  for name in $SKILL_NAMES; do
    lnk="${CONFIG_DIR}/commands/${name}.md"
    src="${root}/skills/${name}/SKILL.md"
    if [ -L "$lnk" ]; then
      dest="$(readlink "$lnk" 2>/dev/null || true)"
      case "$dest" in
        "${root}/skills/"*) rm -f "$lnk"; echo "  /${name}: removed${label}" ;;
        *)
          # The same folder under another spelling (a symlinked parent, Homebrew's opt/)
          if [ -f "$src" ] && [ -e "$lnk" ] && [ "$lnk" -ef "$src" ]; then
            rm -f "$lnk"; echo "  /${name}: removed${label}"
          fi ;;
      esac
    elif [ "$wired" = "1" ] && [ -f "$lnk" ] && cc_is_windows && [ -f "$src" ] && cmp -s "$src" "$lnk"; then
      rm -f "$lnk"; echo "  /${name}: removed${label}"
    fi
  done
}

# Write $EXISTING back, only when something changed: Claude Code edits this file too, and a
# rewrite that changes nothing can still lose what it wrote in between.
# Via tmp + mv: a truncating redirect would destroy the user's settings if jq failed.
write_settings() {
  [ "$CHANGED" = "1" ] || return 0
  local tmp="${SETTINGS_FILE}.tmp.$$"
  if echo "$EXISTING" | jq -e 'if type == "object" then . else error("not an object") end' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$SETTINGS_FILE"
  else
    rm -f "$tmp"
    echo "  WARNING: could not write ${SETTINGS_FILE}; it was left unchanged." >&2
  fi
}

SKILL_NAMES="carbon-report carbon-card carbon-update carbon-badge carbon-pr carbon-panel"
CHANGED=0

# ── Remove ──────────────────────────────────────────────────────────────────
# Read settings.json into $EXISTING. An empty file is an empty object; anything that is not
# a JSON object stops the script before a single change, with the file as it was.
read_settings() {
  if ! grep -q '[^[:space:]]' "$SETTINGS_FILE" 2>/dev/null; then
    EXISTING="{}"
    CHANGED=1
  elif ! EXISTING="$(jq -e 'if type == "object" then . else error("not an object") end' "$SETTINGS_FILE" 2>/dev/null)"; then
    echo "  ${SETTINGS_FILE} is not a JSON object; it was left unchanged." >&2
    exit 1
  fi
}

if [ "$MODE" = "remove" ]; then
  if [ -f "$SETTINGS_FILE" ]; then
    read_settings
    remove_wiring_of "$INSTALL_DIR" ""
    write_settings
    if [ "$(echo "$EXISTING" | cc_carbon_plugin_on)" = "true" ]; then
      echo "  The claude-carbon plugin is still enabled. To remove it as well:"
      echo "    claude plugin uninstall claude-carbon"
    fi
  else
    remove_links_of "$INSTALL_DIR" ""
  fi
  CLAUDE_CARBON_NO_MOD=1 CLAUDE_CARBON_MOD_OURS_ONLY=1 bash "${SCRIPT_DIR}/install-mod.sh" || true
  echo "  Your history stays in ${CONFIG_DIR}/claude-carbon/."
  exit 0
fi

# ── Add ─────────────────────────────────────────────────────────────────────
if [ -f "$SETTINGS_FILE" ]; then
  read_settings

  # Another install already wired here would run every hook twice, each with its own
  # factors, and keep the status line and the commands for itself. Look for commands that
  # name one of our scripts in another folder: a folder that still holds claude-carbon is
  # another install (stop, or take its place with --replace); a folder that is gone is a
  # leftover of one (replaced). A script of that name in anything else is not ours.
  OTHER_ROOTS=""
  DEAD_STATUSLINE=0
  DEAD_HOOKS=""
  scan_cmd() {
    local event="$1" raw="$2" p dir root name
    p="$(plain_cmd "$raw")"
    name="${p##*/}"
    if [ "$event" = "statusLine" ]; then
      [ "$name" = "statusline.sh" ] || return 0
    else
      [ "$name" = "$(event_script "$event")" ] || return 0
    fi
    # Only a bare absolute path can be judged. `bash /x/scripts/agent-stop.sh`, a path
    # behind "$CLAUDE_PROJECT_DIR" or a relative one is a live command this script cannot
    # resolve: testing it as a file would call it gone, and take another tool's hook out.
    case "$p" in /*|[A-Za-z]:/*) ;; *) return 0 ;; esac
    case "$p" in *'$'*|*'`'*) return 0 ;; esac
    dir="${p%/*}"
    [ "${dir##*/}" = "scripts" ] || return 0
    root="${dir%/*}"
    [ "$(normalize_cmd "$raw")" = "$(normalize_cmd "${INSTALL_DIR}/scripts/${name}")" ] && return 0
    # The same file under another spelling (letter case on macOS and Windows)
    [ "$p" -ef "${INSTALL_DIR}/scripts/${name}" ] && return 0
    # The plugin's own folder: Claude Code manages it, and the plugin check below covers it.
    cc_is_plugin_cache "$root" && return 0
    if [ "$(jq -r '.name // empty' "${root}/.claude-plugin/plugin.json" 2>/dev/null | tr -d '\r')" = "claude-carbon" ]; then
      case "
${OTHER_ROOTS}" in
        *"
${root}
"*) ;;
        *) OTHER_ROOTS="${OTHER_ROOTS}${root}
" ;;
      esac
    elif [ ! -e "$p" ]; then
      # Gone, and named after the project: a leftover of ours. Without the name it could
      # be anyone's script on a volume that is not mounted.
      case "$p" in *claude-carbon*) ;; *) return 0 ;; esac
      if [ "$event" = "statusLine" ]; then
        DEAD_STATUSLINE=1
      else
        DEAD_HOOKS="${DEAD_HOOKS}${event}	${raw}
"
      fi
    fi
  }
  scan_cmd statusLine "$(echo "$EXISTING" | jq -r '(.statusLine | objects | .command) // ""' 2>/dev/null)"
  for EVENT in $HOOK_EVENTS; do
    while IFS= read -r RAW; do
      [ -n "$RAW" ] && scan_cmd "$EVENT" "$RAW"
    done <<EOF
$(event_commands "$EVENT")
EOF
  done

  if [ -n "$OTHER_ROOTS" ] && [ "$MODE" != "replace" ]; then
    echo "  Another claude-carbon install is already wired into ${SETTINGS_FILE}:" >&2
    printf '%s' "$OTHER_ROOTS" | sed 's/^/    /' >&2
    echo "  Nothing was changed. To use this one instead (${INSTALL_DIR}):" >&2
    if cc_is_homebrew "$INSTALL_DIR"; then
      echo "    claude-carbon setup --replace" >&2
    else
      echo "    bash \"${SCRIPT_DIR}/configure-settings.sh\" --replace" >&2
    fi
    echo "  Your history is kept either way." >&2
    exit 1
  fi
  while IFS= read -r ROOT; do
    [ -n "$ROOT" ] && remove_wiring_of "$ROOT" " (was ${ROOT})"
  done <<EOF
${OTHER_ROOTS}
EOF
  if [ "$DEAD_STATUSLINE" = "1" ]; then
    EXISTING="$(echo "$EXISTING" | jq 'del(.statusLine)')"
    CHANGED=1
    echo "  statusLine: removed (its install is gone)"
  fi
  while IFS='	' read -r EVENT RAW; do
    [ -n "$RAW" ] || continue
    drop_hook_raw "$EVENT" "$RAW"
    echo "  ${EVENT} hook: removed (its install is gone)"
  done <<EOF
${DEAD_HOOKS}
EOF

  HAS_STATUSLINE="$(echo "$EXISTING" | jq 'has("statusLine")' 2>/dev/null)" || HAS_STATUSLINE="false"
  if [ "$HAS_STATUSLINE" = "true" ]; then
    CURRENT_SL="$(echo "$EXISTING" | jq -r '(.statusLine | objects | .command) // ""' 2>/dev/null)"
    # The script the plugin sets as its status line (see cc_plugin_statusline). It runs the
    # plugin's copy: with the plugin off or uninstalled, it draws an old copy or nothing, so
    # this install's status line takes its place. With the plugin on, it stays.
    PLUGIN_ON="$(echo "$EXISTING" | jq -r '[(.enabledPlugins // {}) | to_entries[] | select(.value == true)
        | .key | select(test("^(claude-carbon|co2-tracker)@")) | select(. != "claude-carbon@skills-dir")]
        | length' 2>/dev/null | tr -d '\r')"
    if [ "$(cc_path "$(plain_cmd "$CURRENT_SL")")" = "${CONFIG_DIR}/claude-carbon/statusline.sh" ] \
       && [ "${PLUGIN_ON:-0}" = "0" ]; then
      EXISTING="$(echo "$EXISTING" | jq --arg cmd "$STATUSLINE_CMD" '. + {statusLine: {type: "command", command: $cmd}}')"
      CHANGED=1
      echo "  statusLine: replaced (the plugin's, which is off or uninstalled)"
    elif echo "$CURRENT_SL" | grep -q "claude-carbon"; then
      echo "  statusLine: already configured (skipped)"
    else
      echo "  statusLine: skipped (already set to another tool)"
      echo "    To switch, replace the command in ${SETTINGS_FILE} with:"
      echo "    $STATUSLINE_CMD"
    fi
  else
    EXISTING="$(echo "$EXISTING" | jq --arg cmd "$STATUSLINE_CMD" '. + {statusLine: {type: "command", command: $cmd}}')"
    CHANGED=1
    echo "  statusLine: added"
  fi

  # Stop: persist the session after each turn. SessionEnd: persist it once more as it closes,
  # which catches a last turn interrupted before Stop fired. SessionStart: throttled safety
  # rescan, which also drives the daily update check the status line reads.
  # The claude-carbon plugin, when it is on, brings these four itself (hooks/hooks.json):
  # written here as well, each would run twice. The status line above it does not bring.
  # Its clone then has no hook to run check-update.sh, and /carbon-update gives its git pull.
  if [ "$(echo "$EXISTING" | cc_carbon_plugin_on)" = "true" ]; then
    echo "  hooks: brought by the claude-carbon plugin (skipped)"
  else
    add_hook Stop "$STOP_CMD"
    add_hook SessionEnd "$SESSIONEND_CMD"
    add_hook SessionStart "$SESSIONSTART_CMD"
    # SubagentStop: the branch an agent worked on, for /carbon-pr. ".+" leaves out the events
    # of Claude Code's own agents, whose type is empty (from Claude Code 2.1.275; before, the
    # script leaves them out itself).
    add_hook SubagentStop "$AGENTSTOP_CMD" ".+"
  fi

  write_settings
else
  # `$end` would be a syntax error in jq 1.6 (`end` is a keyword there): the variable is
  # $session_end. Same tmp + mv as above, so a failing jq never leaves an empty file.
  TMP="${SETTINGS_FILE}.tmp.$$"
  if jq -n --arg sl "$STATUSLINE_CMD" --arg stop "$STOP_CMD" --arg session_end "$SESSIONEND_CMD" --arg start "$SESSIONSTART_CMD" --arg agent "$AGENTSTOP_CMD" '{
    statusLine: {type: "command", command: $sl},
    hooks: {
      Stop: [{
        matcher: "",
        hooks: [{type: "command", command: $stop}]
      }],
      SessionEnd: [{
        matcher: "",
        hooks: [{type: "command", command: $session_end}]
      }],
      SessionStart: [{
        matcher: "",
        hooks: [{type: "command", command: $start}]
      }],
      SubagentStop: [{
        matcher: ".+",
        hooks: [{type: "command", command: $agent}]
      }]
    }
  }' > "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$SETTINGS_FILE"
    echo "  Created $SETTINGS_FILE"
  else
    rm -f "$TMP"
    echo "  WARNING: could not create ${SETTINGS_FILE}." >&2
  fi
fi

# /carbon-* slash commands. Symlinked so they follow the clone on update — except
# on Windows, where Git Bash cannot create a real symlink without Developer Mode
# and silently makes a copy instead. There we copy on purpose, and refresh the
# copy on every run so an update still reaches the commands.
COMMANDS_DIR="${CONFIG_DIR}/commands"
mkdir -p "$COMMANDS_DIR"
for SKILL_NAME in $SKILL_NAMES; do
  SKILL_SRC="${INSTALL_DIR}/skills/${SKILL_NAME}/SKILL.md"
  SKILL_LNK="${COMMANDS_DIR}/${SKILL_NAME}.md"
  # A link whose target is gone is a leftover of an install that was deleted.
  if [ -L "$SKILL_LNK" ] && [ ! -e "$SKILL_LNK" ]; then
    rm -f "$SKILL_LNK"
  fi
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

# The mod (hooks/mod), as a copy Claude Code loads from skills/ that carries no command hook,
# so the hooks above never run twice. See install-mod.sh; it never fails the install.
bash "${SCRIPT_DIR}/install-mod.sh" || true
