#!/usr/bin/env bash
# run-brew-tests.sh — a Homebrew install, without Homebrew: a throwaway prefix laid out the
# way a formula leaves it (Cellar/<name>/<version>/libexec, the opt/<name> link, the
# INSTALL_METHOD marker, a bin wrapper that execs the Cellar path), then `claude-carbon
# setup`, an upgrade to another version, and `claude-carbon uninstall`.
#
# What is at stake: settings.json must name the opt/ path, which survives an upgrade, never
# the Cellar one the wrapper runs; and with no updater to run, the SessionStart hook is what
# brings the mod and the history to a new version.
#
# Every case runs under its own throwaway CLAUDE_CONFIG_DIR and HOME; the real ~/.claude is
# never read or written. No network.
#
# bash 3.2 compatible. Dependencies: jq, sqlite3. Skips on Windows, where Git Bash has no
# real symlink to make the opt/ link from.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"

if cc_is_windows; then
  echo "SKIP: no Homebrew on Windows."
  exit 0
fi
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 is required" >&2; exit 1; }

TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-brew.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-brew.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap '[ -f "${TMPROOT}/log-kept" ] && [ -n "${SHOW_LOG:-}" ] && cat "${TMPROOT}/log-kept"; cleanup' EXIT

PASSED=0
FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  echo "       expected: $2"
  echo "       actual:   $3"
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
said()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output containing '$2'" "$3" ;; esac; }
has()   { [ -e "$1" ] && echo yes || echo no; }

PREFIX="${TMPROOT}/prefix"
OPT="${PREFIX}/opt/claude-carbon/libexec"
BREW_BIN="${PREFIX}/bin/claude-carbon"
export HOME="${TMPROOT}/home"
mkdir -p "$HOME" "${PREFIX}/bin" "${PREFIX}/opt"

# What the formula installs, as version $1, and the opt/ link moved onto it.
brew_install() {
  local v="$1" keg="${PREFIX}/Cellar/claude-carbon/$1"
  mkdir -p "${keg}/libexec"
  for d in .claude-plugin data hooks scripts skills templates types; do
    cp -R "${REPO_DIR}/${d}" "${keg}/libexec/${d}"
  done
  jq --arg v "$v" '.version = $v' "${REPO_DIR}/.claude-plugin/plugin.json" \
    > "${keg}/libexec/.claude-plugin/plugin.json"
  printf 'homebrew\n' > "${keg}/libexec/INSTALL_METHOD"
  rm -f "${PREFIX}/opt/claude-carbon"
  ln -s "../Cellar/claude-carbon/${v}" "${PREFIX}/opt/claude-carbon"
  # bin.write_exec_script: a wrapper that execs the versioned path
  printf '#!/bin/bash\nexec "%s" "$@"\n' "${keg}/libexec/scripts/claude-carbon" > "$BREW_BIN"
  chmod +x "$BREW_BIN"
}

# ---------------------------------------------------------------- the files a formula needs

if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # Homebrew keeps the modes of the tarball for what goes into libexec: a script the
  # wrapper or settings.json runs directly must be executable in git itself.
  for f in claude-carbon statusline.sh persist-session.sh persist-on-exit.sh safety-rescan.sh agent-stop.sh; do
    MODE="$(git -C "$REPO_DIR" ls-files -s "scripts/${f}" | cut -d' ' -f1)"
    # Not committed yet (a new file in a working tree): fall back to the file on disk.
    [ -n "$MODE" ] || { [ -x "${REPO_DIR}/scripts/${f}" ] && MODE=100755; }
    check "modes: scripts/${f} is executable in git" "100755" "$MODE"
  done
fi

# ---------------------------------------------------------------- setup

brew_install 1.0.0
CFG="${TMPROOT}/cfg"
S="${CFG}/settings.json"
check "cli: --version reads the installed version" "claude-carbon 1.0.0" "$("$BREW_BIN" --version)"

# A notice a clone left before the switch to Homebrew
mkdir -p "${CFG}/claude-carbon"
echo '{"behind":true,"local":"0.9.0","remote":"1.0.0","checked_at":1}' > "${CFG}/claude-carbon/update-check.json"

OUT="$(CLAUDE_CONFIG_DIR="$CFG" "$BREW_BIN" setup 2>&1)"; RC=$?
check "setup: succeeds" "0" "$RC"
check "setup: the status line names the opt path" "${OPT}/scripts/statusline.sh" "$(jq -r '.statusLine.command' "$S")"
check "setup: the hooks name the opt path" \
  "${OPT}/scripts/persist-session.sh ${OPT}/scripts/persist-on-exit.sh ${OPT}/scripts/safety-rescan.sh ${OPT}/scripts/agent-stop.sh" \
  "$(jq -r '[.hooks.Stop[].hooks[].command, .hooks.SessionEnd[].hooks[].command, .hooks.SessionStart[].hooks[].command, .hooks.SubagentStop[].hooks[].command] | join(" ")' "$S")"
check "setup: settings.json never names the Cellar" "0" "$(grep -c Cellar "$S")"
check "setup: the commands link into the opt path" "${OPT}/skills/carbon-report/SKILL.md" "$(readlink "${CFG}/commands/carbon-report.md")"
check "setup: the mod's marker names the opt path" "0" "$(grep -c Cellar "${CFG}/skills/claude-carbon/.claude-carbon-managed")"
said  "setup: the mod's marker names the opt path (2)" "$OPT" "$(cat "${CFG}/skills/claude-carbon/.claude-carbon-managed")"
check "setup: the database is created" "yes" "$(has "${CFG}/claude-carbon/carbon.db")"
check "setup: a clone's update notice is dropped" "no" "$(has "${CFG}/claude-carbon/update-check.json")"
check "setup: this version is marked as in place" "yes" "$(has "${CFG}/claude-carbon/.version-1.0.0")"

SIZE="$(wc -c < "$S" | tr -d ' ')"
printf '\n' >> "$S"
CLAUDE_CONFIG_DIR="$CFG" "$BREW_BIN" setup >/dev/null 2>&1; RC=$?
check "setup again: succeeds" "0" "$RC"
check "setup again: one Stop hook" "1" "$(jq '[.hooks.Stop[].hooks[]] | length' "$S")"
check "setup again: settings.json is not rewritten" "$((SIZE + 1))" "$(wc -c < "$S" | tr -d ' ')"

# ---------------------------------------------------------------- update.sh and the daily check

# No updater under Homebrew: update.sh names brew and runs no git; the SessionStart hook
# starts no version check.
FAKEBIN="${TMPROOT}/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "${TMPROOT}/git-calls" > "${FAKEBIN}/git"
chmod +x "${FAKEBIN}/git"
OUT="$(PATH="${FAKEBIN}:${PATH}" CLAUDE_CONFIG_DIR="$CFG" bash "${OPT}/scripts/update.sh" 2>&1)"; RC=$?
check "update.sh: exits cleanly" "0" "$RC"
said  "update.sh: names brew upgrade" "brew upgrade claude-carbon" "$OUT"
check "update.sh: runs no git" "no" "$(has "${TMPROOT}/git-calls")"

echo '{}' | PATH="${FAKEBIN}:${PATH}" CLAUDE_CONFIG_DIR="$CFG" bash "${OPT}/scripts/safety-rescan.sh"
sleep 1
check "session start: no version check under Homebrew" "no" "$(has "${CFG}/claude-carbon/update-check.json")"
check "session start: no git either" "no" "$(has "${TMPROOT}/git-calls")"
check "session start: the same version brings nothing up to date" "no" "$(has "${CFG}/claude-carbon/post-upgrade.log")"

# ---------------------------------------------------------------- brew upgrade

# The new version replaces the old one in the Cellar and opt/ moves onto it. Nothing in the
# config folder was told. The next session start is what notices.
brew_install 2.0.0
rm -rf "${PREFIX}/Cellar/claude-carbon/1.0.0"
check "upgrade: the status line of settings.json still exists" "yes" "$(has "$(jq -r '.statusLine.command' "$S")")"
check "upgrade: the commands still resolve" "yes" "$(has "${CFG}/commands/carbon-report.md")"
check "upgrade: the mod is still the old version's" "1.0.0" "$(jq -r '.version' "${CFG}/skills/claude-carbon/.claude-plugin/plugin.json")"

SUM_BEFORE="$(cksum < "$S")"
echo '{}' | CLAUDE_CONFIG_DIR="$CFG" bash "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$S")"
LOG="${CFG}/claude-carbon/post-upgrade.log"
# The step is detached: wait for it to finish (it logs the re-pricing last).
i=0
while [ "$i" -lt 100 ]; do
  [ -f "$LOG" ] && grep -q "^done" "$LOG" 2>/dev/null && break
  sleep 0.2; i=$((i + 1))
done
sleep 0.5
check "upgrade: the next session start runs the post-upgrade step" "yes" "$(has "$LOG")"
said  "upgrade: its log names the new version" "claude-carbon 2.0.0" "$(head -n 1 "$LOG" 2>/dev/null)"
check "upgrade: the mod is brought to the new version" "2.0.0" "$(jq -r '.version' "${CFG}/skills/claude-carbon/.claude-plugin/plugin.json")"
check "upgrade: the new version is marked" "yes" "$(has "${CFG}/claude-carbon/.version-2.0.0")"
check "upgrade: the old mark is dropped" "no" "$(has "${CFG}/claude-carbon/.version-1.0.0")"
check "upgrade: settings.json is not touched" "$SUM_BEFORE" "$(cksum < "$S")"

# Once per version: a second session start does not run it again.
cat "$LOG" > "${TMPROOT}/log-kept"; echo "sentinel" > "$LOG"
echo '{}' | CLAUDE_CONFIG_DIR="$CFG" bash "${OPT}/scripts/safety-rescan.sh"
sleep 1
check "upgrade: a second session start does not run it again" "sentinel" "$(cat "$LOG")"

# Someone who took the mod out keeps it out across an upgrade.
CFG2="${TMPROOT}/cfg-nomod"
CLAUDE_CARBON_NO_MOD=1 CLAUDE_CONFIG_DIR="$CFG2" "$BREW_BIN" setup >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$CFG2" bash "${OPT}/scripts/post-upgrade.sh"
check "upgrade: a mod taken out stays out" "no" "$(has "${CFG2}/skills/claude-carbon")"

# ---------------------------------------------------------------- another install

# A clone wired first: setup refuses and says so, --replace takes its place.
CLONE="${TMPROOT}/clone"
mkdir -p "${CLONE}/scripts" "${CLONE}/.claude-plugin"
echo '#!/usr/bin/env bash' > "${CLONE}/scripts/statusline.sh"
echo '#!/usr/bin/env bash' > "${CLONE}/scripts/persist-session.sh"
echo '{"name": "claude-carbon", "version": "0.9.0"}' > "${CLONE}/.claude-plugin/plugin.json"
CFG3="${TMPROOT}/cfg-clone"
mkdir -p "$CFG3"
S3="${CFG3}/settings.json"
jq -n --arg sl "${CLONE}/scripts/statusline.sh" --arg stop "${CLONE}/scripts/persist-session.sh" '{
  statusLine: {type: "command", command: $sl},
  hooks: {Stop: [{matcher: "", hooks: [{type: "command", command: $stop}]}]}
}' > "$S3"
OUT="$(CLAUDE_CONFIG_DIR="$CFG3" "$BREW_BIN" setup 2>&1)"; RC=$?
check "clone wired: setup refuses" "1" "$RC"
said  "clone wired: names the clone" "$CLONE" "$OUT"
check "clone wired: nothing is read before the refusal" "no" "$(has "${CFG3}/claude-carbon/carbon.db")"
CLAUDE_CONFIG_DIR="$CFG3" "$BREW_BIN" setup --replace >/dev/null 2>&1; RC=$?
check "clone wired: --replace succeeds" "0" "$RC"
check "clone wired: --replace moves the status line" "${OPT}/scripts/statusline.sh" "$(jq -r '.statusLine.command' "$S3")"
check "clone wired: --replace leaves one Stop hook, ours" "${OPT}/scripts/persist-session.sh" "$(jq -r '[.hooks.Stop[].hooks[].command] | join(" ")' "$S3")"

# ---------------------------------------------------------------- uninstall

OUT="$(CLAUDE_CONFIG_DIR="$CFG" "$BREW_BIN" uninstall 2>&1)"; RC=$?
check "uninstall: succeeds" "0" "$RC"
check "uninstall: no status line" "false" "$(jq 'has("statusLine")' "$S")"
check "uninstall: no hooks" "false" "$(jq 'has("hooks")' "$S")"
check "uninstall: no commands" "" "$(ls "${CFG}/commands")"
check "uninstall: no copy of the mod" "no" "$(has "${CFG}/skills/claude-carbon")"
check "uninstall: the history stays" "yes" "$(has "${CFG}/claude-carbon/carbon.db")"
said  "uninstall: names brew uninstall" "brew uninstall claude-carbon" "$OUT"

OUT="$("$BREW_BIN" frobnicate 2>&1)"; RC=$?
check "cli: an unknown command fails" "2" "$RC"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} Homebrew install assertions passed."
