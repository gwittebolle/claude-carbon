#!/usr/bin/env bash
set -uo pipefail   # NOT -e: every failure below ends in a message, never in a half-done install

# install-mod.sh: give a git-clone install the claude-carbon mod (hooks/mod). Claude Code
# loads a plugin found in $CONFIG_DIR/skills/<name>/ as <name>@skills-dir, so the mod goes
# into a copy at skills/claude-carbon/ holding the module and nothing else: no command hook,
# no status line, no skill. The bash hooks configure-settings.sh wires into settings.json
# therefore cannot run twice, by construction.
#
# Called at the end of configure-settings.sh, so install.sh and /carbon-update both reach it,
# including an update.sh from before this script existed (it runs the configure it just
# pulled). Idempotent, and never fails the install: every problem is a message and exit 0.
#
# CLAUDE_CARBON_NO_MOD=1 skips it, and removes the copy this script made.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
SKILLS_DIR="${CONFIG_DIR}/skills"
TARGET="${SKILLS_DIR}/claude-carbon"
# A copy this script made carries this file. A skills/claude-carbon/ without it belongs to
# the user and is never touched.
MARKER=".claude-carbon-managed"
# Work directories sit next to the target, on the same filesystem, so each swap is a rename.
# Claude Code skips the dot-directories of skills/, so a leftover one never loads.
TMP="${SKILLS_DIR}/.claude-carbon.tmp.$$"
OLD="${SKILLS_DIR}/.claude-carbon.old.$$"

RESTART_LINE="    Restart Claude Code to load it (2.1.287 or later, 2.1.286 in the desktop app)."

# Only ever delete one of our own work directories, never an arbitrary variable.
drop_workdir() {
  case "$1" in
    "${SKILLS_DIR}"/.claude-carbon.tmp.*|"${SKILLS_DIR}"/.claude-carbon.old.*) rm -rf "$1" 2>/dev/null ;;
    *) echo "  mod: refusing to delete unexpected path: $1" >&2 ;;
  esac
}

# Take the managed copy away: rename it aside first, so it disappears at once or not at all.
# On Windows a file Claude Code holds open makes the rename fail; the copy then stays whole.
remove_managed() {
  if ! mv "$TARGET" "$OLD" 2>/dev/null; then
    echo "  mod: could not remove ${TARGET}, which stays in place."
    echo "    Restart Claude Code, then run the installer again."
    return 1
  fi
  drop_workdir "$OLD"
}

is_managed() { [ -f "${TARGET}/${MARKER}" ]; }

if [ "${CLAUDE_CARBON_NO_MOD:-}" = "1" ]; then
  if is_managed; then
    remove_managed && echo "  mod: removed (CLAUDE_CARBON_NO_MOD=1)"
  else
    echo "  mod: skipped (CLAUDE_CARBON_NO_MOD=1)"
  fi
  exit 0
fi

# A marketplace install already loads the mod from its own hooks/hooks.json. Its checkout
# sits under the config dir's plugins/, whatever CLAUDE_CONFIG_DIR names that dir.
case "$INSTALL_DIR" in */.claude/plugins/*|"${CONFIG_DIR}"/plugins/*) exit 0 ;; esac

[ -f "${INSTALL_DIR}/hooks/mod/register.tsx" ] || exit 0

if ! command -v jq &>/dev/null; then
  echo "  mod: skipped (jq not found)"
  exit 0
fi

# The claude-carbon plugin enabled from a marketplace (or the community listing's
# co2-tracker) brings the mod itself: a copy here would draw every figure twice. Our own
# entry, claude-carbon@skills-dir, is the copy: the user may have disabled it, which is
# their switch and not a reason to stop updating it.
PLUGIN_ON="false"
if [ -f "$SETTINGS_FILE" ]; then
  # Unreadable settings could hide an enabled plugin: better no copy than a doubled mod.
  if ! jq -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "  mod: skipped (${SETTINGS_FILE} is not valid JSON)"
    exit 0
  fi
  PLUGIN_ON="$(jq -r '[(.enabledPlugins // {}) | to_entries[]
      | select(.value == true)
      | select(.key | test("^(claude-carbon|co2-tracker)@"))
      | select(.key != "claude-carbon@skills-dir")] | length > 0' "$SETTINGS_FILE" 2>/dev/null)" || PLUGIN_ON="false"
fi
if [ "$PLUGIN_ON" = "true" ]; then
  if is_managed; then
    remove_managed && echo "  mod: removed the copy, the claude-carbon plugin enabled in ${SETTINGS_FILE} brings the mod"
  else
    echo "  mod: skipped, the claude-carbon plugin enabled in ${SETTINGS_FILE} brings it"
  fi
  exit 0
fi

if [ -e "$TARGET" ] && ! is_managed; then
  echo "  mod: ${TARGET} was not made by this installer; left as it is."
  exit 0
fi

# Work directories an interrupted run left behind.
for d in "${SKILLS_DIR}"/.claude-carbon.tmp.* "${SKILLS_DIR}"/.claude-carbon.old.*; do
  [ -d "$d" ] && drop_workdir "$d"
done

# Build the whole copy aside, then compare and swap: Claude Code never sees a half-written one.
build() {
  mkdir -p "$SKILLS_DIR" &&
  mkdir "$TMP" &&
  mkdir -p "${TMP}/.claude-plugin" "${TMP}/hooks" "${TMP}/types" "${TMP}/data" &&
  # The manifest without what this install already provides from the clone: the status line
  # (settings.json) and the skills (the /carbon-* commands).
  jq 'del(.statusLine, .skills)' "${INSTALL_DIR}/.claude-plugin/plugin.json" \
    > "${TMP}/.claude-plugin/plugin.json" &&
  # The module list only: the command hooks of hooks/hooks.json are the ones settings.json runs.
  jq '{modules: .modules}' "${INSTALL_DIR}/hooks/hooks.json" > "${TMP}/hooks/hooks.json" &&
  cp -R "${INSTALL_DIR}/hooks/mod" "${TMP}/hooks/mod" &&
  rm -f "${TMP}"/hooks/mod/*.test.tsx "${TMP}"/hooks/mod/*/*.test.tsx &&
  cp "${INSTALL_DIR}/types/index.d.ts" "${TMP}/types/index.d.ts" &&
  # The mod reads its factors from $.plugin.root, so they travel with it and follow updates.
  cp "${INSTALL_DIR}/data/factors.json" "${TMP}/data/factors.json" &&
  printf 'Made by the claude-carbon installer from %s.\nRemoved by running it again with CLAUDE_CARBON_NO_MOD=1.\n' \
    "$INSTALL_DIR" > "${TMP}/${MARKER}"
}

if ! build 2>/dev/null; then
  [ -d "$TMP" ] && drop_workdir "$TMP"
  echo "  mod: could not write to ${SKILLS_DIR}; nothing changed."
  exit 0
fi

if [ -d "$TARGET" ] && diff -r "$TARGET" "$TMP" >/dev/null 2>&1; then
  drop_workdir "$TMP"
  echo "  mod: already installed (skipped)"
  exit 0
fi

ACTION="installed"
if [ -d "$TARGET" ]; then
  ACTION="updated"
  # The copy in use can be locked on Windows while a session runs /carbon-update. Then the
  # previous copy stays whole and in place, and the new one is dropped.
  if ! mv "$TARGET" "$OLD" 2>/dev/null; then
    drop_workdir "$TMP"
    echo "  mod: the copy in use could not be replaced; the previous one stays."
    echo "    Restart Claude Code, then run the installer again."
    exit 0
  fi
fi
if ! mv "$TMP" "$TARGET" 2>/dev/null; then
  drop_workdir "$TMP"
  if [ -d "$OLD" ] && ! mv "$OLD" "$TARGET" 2>/dev/null; then
    echo "  mod: could not put a copy back in place; the previous one is in ${OLD}."
  else
    echo "  mod: could not put the new copy in place; nothing changed."
  fi
  echo "    Restart Claude Code, then run the installer again."
  exit 0
fi
[ -d "$OLD" ] && drop_workdir "$OLD"

echo "  mod: ${ACTION} in ${TARGET} (claude-carbon@skills-dir)"
echo "$RESTART_LINE"
