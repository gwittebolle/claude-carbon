#!/usr/bin/env bash
# run-install-tests.sh — exercise the wiring that puts claude-carbon into Claude Code:
# scripts/configure-settings.sh (settings.json merge + /carbon-* commands), the copy of the
# mod scripts/install-mod.sh makes under skills/, and the repair path scripts/update.sh
# takes on an install that predates a hook.
#
# Every case runs under its own throwaway CLAUDE_CONFIG_DIR; the real ~/.claude is never read
# or written. No network: the update case clones this repo from the local filesystem.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# Dependencies: jq, git (sqlite3 only for the update case, which skips without it).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIGURE="${REPO_DIR}/scripts/configure-settings.sh"

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required" >&2; exit 1; }
[ -f "$CONFIGURE" ] || { echo "FAIL: missing $CONFIGURE" >&2; exit 1; }

# cc_tmpdir rather than $TMPDIR directly: under Git Bash on Windows TMPDIR can
# hold a native "C:\Users\..." path, which mktemp cannot use as a template.
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-tests.XXXXXX")"
# Normalize: $TMPDIR often carries a trailing slash, and the scripts under test resolve their
# own paths with `cd && pwd`, so an unnormalized root makes assertions compare //-doubled
# strings against clean ones.
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0

ok() {   PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  echo "       expected: $2"
  echo "       actual:   $3"
  # Always dump the bytes. A carriage return from a Windows tool, a trailing space or
  # a stray separator renders as nothing in a CI log, turning a failure into "expected
  # X, got X" with no way to act on it.
  echo "       (${#2} vs ${#3} chars)"
  printf '       expected bytes: '; printf '%s' "$2" | od -An -c | tr -s ' ' | tr -d '\n'; echo
  printf '       actual bytes:   '; printf '%s' "$3" | od -An -c | tr -s ' ' | tr -d '\n'; echo
}

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# Commands registered for a hook event, newline-separated, in order. The tr strips the
# interior carriage returns Git Bash leaves in a multi-line command substitution; the
# assertions are about the commands, not about how the capture was framed.
hook_commands() { jq -r --arg e "$2" '[.hooks[$e][]?.hooks[]?.command] | .[]' "$1" 2>/dev/null | tr -d '\r'; }
hook_count()    { jq -r --arg e "$2" '[.hooks[$e][]?.hooks[]?.command] | length' "$1" 2>/dev/null; }

# What configure-settings.sh writes is platform-dependent by design. On Windows it
# writes the "mixed" spelling ("D:/a/repo/scripts/x.sh"): Claude Code may resolve the
# path with Windows APIs before spawning Git Bash, and its status line docs require
# forward slashes because Git Bash eats unquoted backslashes. cc_native_path is the
# identity function on macOS and Linux, so these expectations are unchanged there.
CMD_BASE="$(cc_native_path "$REPO_DIR")"
# On Windows the paths are also quoted, so that a PowerShell fallback prints them rather
# than opening the .sh in a Git Bash window (see configure-settings.sh).
hook_form() { if cc_is_windows; then printf '"%s"' "$1"; else printf '%s' "$1"; fi; }
STATUSLINE="$(hook_form "${CMD_BASE}/scripts/statusline.sh")"
# The file itself, for the tests that run it
SL_SCRIPT="${REPO_DIR}/scripts/statusline.sh"
STOP="$(hook_form "${CMD_BASE}/scripts/persist-session.sh")"
RESCAN="$(hook_form "${CMD_BASE}/scripts/safety-rescan.sh")"
SESSIONEND="$(hook_form "${CMD_BASE}/scripts/persist-on-exit.sh")"
AGENTSTOP="$(hook_form "${CMD_BASE}/scripts/agent-stop.sh")"

# ---------------------------------------------------------------- 1. cold start

CFG="${TMPROOT}/cold"
mkdir -p "$CFG"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "cold start: settings.json created"  "yes" "$([ -f "$S" ] && echo yes || echo no)"
check "cold start: statusLine"             "$STATUSLINE" "$(jq -r '.statusLine.command // ""' "$S" 2>/dev/null)"
check "cold start: Stop hook"              "$STOP"       "$(hook_commands "$S" Stop)"
check "cold start: SessionStart hook"      "$RESCAN"     "$(hook_commands "$S" SessionStart)"
check "cold start: SessionEnd hook"        "$SESSIONEND" "$(hook_commands "$S" SessionEnd)"
check "cold start: SubagentStop hook"      "$AGENTSTOP" "$(hook_commands "$S" SubagentStop)"
check "cold start: SubagentStop matcher leaves out an empty agent type" ".+" "$(jq -r '.hooks.SubagentStop[0].matcher // ""' "$S" 2>/dev/null | tr -d '\r')"

# Symlinked everywhere a symlink works. Git Bash cannot create one without Windows
# Developer Mode, so there the commands are copied on purpose and configure-settings.sh
# refreshes the copy on update; assert whichever form this platform is meant to produce.
MISSING=""
for c in carbon-report carbon-card carbon-update carbon-badge carbon-pr carbon-panel; do
  if cc_is_windows; then
    cmp -s "${REPO_DIR}/skills/${c}/SKILL.md" "${CFG}/commands/${c}.md" 2>/dev/null || MISSING="${MISSING}${c} "
  else
    [ -L "${CFG}/commands/${c}.md" ] || MISSING="${MISSING}${c} "
  fi
done
check "cold start: /carbon-* commands installed" "" "$MISSING"

# ---------------------------------------------------------------- 2. pre-1.1.3 install repaired

# The shape every curl install had before the SessionStart hook was wired: our statusLine and
# our Stop hook, no SessionStart at all.
CFG="${TMPROOT}/legacy"
mkdir -p "$CFG"
# Through jq, not a here-doc: on Windows the commands carry double quotes of their own.
jq -n --arg sl "$STATUSLINE" --arg stop "$STOP" '{
  model: "opus",
  statusLine: {type: "command", command: $sl},
  hooks: {Stop: [{matcher: "", hooks: [{type: "command", command: $stop}]}]}
}' > "${CFG}/settings.json"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "legacy install: SessionStart added"   "$RESCAN" "$(hook_commands "$S" SessionStart)"
check "legacy install: SessionEnd added"     "$SESSIONEND" "$(hook_commands "$S" SessionEnd)"
check "legacy install: SubagentStop added"   "$AGENTSTOP" "$(hook_commands "$S" SubagentStop)"
check "legacy install: Stop not duplicated"  "1"       "$(hook_count "$S" Stop)"
check "legacy install: unrelated keys kept"  "opus"    "$(jq -r '.model // ""' "$S" 2>/dev/null)"

# ---------------------------------------------------------------- 3. additive merge

CFG="${TMPROOT}/foreign"
mkdir -p "$CFG"
cat > "${CFG}/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "/opt/ccstatusline/run.sh"},
  "hooks": {
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "/opt/other/start.sh"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/other/pre.sh"}]}]
  }
}
EOF
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "foreign statusLine: not overwritten" "/opt/ccstatusline/run.sh" "$(jq -r '.statusLine.command // ""' "$S" 2>/dev/null)"
check "foreign SessionStart: preserved"     "/opt/other/start.sh
${RESCAN}"                                  "$(hook_commands "$S" SessionStart)"
check "unrelated event: untouched"          "/opt/other/pre.sh" "$(hook_commands "$S" PreToolUse)"
check "Stop added alongside"                "$STOP" "$(hook_commands "$S" Stop)"

# ---------------------------------------------------------------- 4. idempotence

CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1

check "idempotent: one SessionStart of ours" "1" "$(jq -r --arg c "$RESCAN" '[.hooks.SessionStart[]?.hooks[]?.command | select(. == $c)] | length' "$S" 2>/dev/null)"
check "idempotent: one Stop"                 "1" "$(hook_count "$S" Stop)"
check "idempotent: one SubagentStop"         "1" "$(hook_count "$S" SubagentStop)"
check "idempotent: foreign hook still there" "1" "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(. == "/opt/other/start.sh")] | length' "$S" 2>/dev/null)"

# ---------------------------------------------------------------- 5. equivalent path spellings

# The README's manual block writes `~/code/claude-carbon/...` while the installer writes the
# expanded absolute path, and Claude Code accepts escaped spaces. A hand-wired install followed
# by a curl install must not end up running the same hook twice.
CFG="${TMPROOT}/spelling"
mkdir -p "$CFG"
STOP_DOTTED="${REPO_DIR}/./scripts/persist-session.sh"
# Bare, so the here-doc below stays valid JSON where $RESCAN is quoted (Windows)
RESCAN_ALT="${CMD_BASE}/scripts/safety-rescan.sh"
# SC2088: the literal tilde is the point — this builds the unexpanded spelling a user would
# have hand-written, to prove configure-settings.sh recognizes it as the same hook.
# shellcheck disable=SC2088
case "$REPO_DIR" in
  "${HOME}"/*) RESCAN_ALT="~/${REPO_DIR#"${HOME}"/}/scripts/safety-rescan.sh" ;;
esac
# A here-doc, not jq --arg: Git Bash rewrites a POSIX path handed to the native jq.exe
# ("/d/a/x/./scripts" becomes "D:/a/x/scripts"), which would erase the spelling under test.
cat > "${CFG}/settings.json" <<EOF
{
  "hooks": {
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "${STOP_DOTTED}"}]}],
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "${RESCAN_ALT}"}]}]
  }
}
EOF
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "spelling: /./ form not duplicated"   "1" "$(hook_count "$S" Stop)"
check "spelling: tilde form not duplicated" "1" "$(hook_count "$S" SessionStart)"
check "spelling: original left as written"  "$STOP_DOTTED" "$(hook_commands "$S" Stop)"

# Quoted and bare are the same hook: a Windows install from before the quotes, or a
# settings.json copied between machines, must not end up with both.
CFG="${TMPROOT}/quoted"
mkdir -p "$CFG"
cat > "${CFG}/settings.json" <<EOF
{
  "hooks": {
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "\"${CMD_BASE}/scripts/persist-session.sh\""}]}],
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "${CMD_BASE}/scripts/safety-rescan.sh"}]}]
  }
}
EOF
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "spelling: quoted form not duplicated" "1" "$(hook_count "$S" Stop)"
check "spelling: bare form not duplicated"   "1" "$(hook_count "$S" SessionStart)"

# ---------------------------------------------------------------- 6. marketplace guard

# Claude Code declares the plugin's hooks from hooks/hooks.json for marketplace installs;
# writing settings.json there too would run every hook twice.
FAKE="${TMPROOT}/home/.claude/plugins/marketplace/claude-carbon"
CFG="${TMPROOT}/mkt"
mkdir -p "${FAKE}/scripts" "$CFG"
cp "$CONFIGURE" "${FAKE}/scripts/configure-settings.sh"
CLAUDE_CONFIG_DIR="$CFG" bash "${FAKE}/scripts/configure-settings.sh" >/dev/null 2>&1

check "marketplace cache: writes nothing" "no" "$([ -f "${CFG}/settings.json" ] && echo yes || echo no)"

# ---------------------------------------------------------------- 7. update repairs the wiring

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP update repair: sqlite3 not available"
else
  CLONE="${TMPROOT}/clone"
  CFG="${TMPROOT}/upd"
  mkdir -p "$CFG"
  # update.sh fast-forwards before repairing, so the fixture needs a branch with an upstream.
  # A CI checkout sitting on a detached HEAD would produce a clone without one: skip loudly
  # rather than report a failure that says nothing about the code.
  if git clone --quiet "$REPO_DIR" "$CLONE" 2>/dev/null &&
     git -C "$CLONE" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    # An install wired before the hook existed.
    cat > "${CFG}/settings.json" <<EOF
{
  "statusLine": {"type": "command", "command": "${CLONE}/scripts/statusline.sh"},
  "hooks": {
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "${CLONE}/scripts/persist-session.sh"}]}]
  }
}
EOF
    mkdir -p "${CFG}/claude-carbon"
    sqlite3 "${CFG}/claude-carbon/carbon.db" "CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY);" 2>/dev/null
    UPD_OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "${CLONE}/scripts/update.sh" 2>&1)"
    # configure-settings.sh writes the hook in native spelling (C:/... on Windows,
    # see CMD_BASE above), so the expectation has to be spelled the same way.
    check "update repairs SessionStart" "$(hook_form "$(cc_native_path "$CLONE")/scripts/safety-rescan.sh")" "$(hook_commands "${CFG}/settings.json" SessionStart)"
    check "update keeps Stop single"    "1" "$(hook_count "${CFG}/settings.json" Stop)"
    # update.sh hides the settings chatter but not the mod's lines, which may ask for a restart.
    check "update installs the mod" "yes" "$([ -f "${CFG}/skills/claude-carbon/.claude-carbon-managed" ] && echo yes || echo no)"
    case "$UPD_OUT" in
      *"mod: installed"*"Restart Claude Code"*) ok "update shows the mod's lines" ;;
      *) bad "update shows the mod's lines" "'mod: installed' then a restart line" "$UPD_OUT" ;;
    esac
    case "$UPD_OUT" in
      *" hook: "*) bad "update keeps the settings chatter hidden" "no 'hook:' line" "$UPD_OUT" ;;
      *) ok "update keeps the settings chatter hidden" ;;
    esac
  else
    echo "SKIP update repair: clone unavailable or without an upstream branch"
  fi
fi

# ---------------------------------------------------------------- 7b. the plugin turned on

# The plugin brings the four hooks itself: the installer adds the status line only, or each
# hook would run twice.
CFG="${TMPROOT}/plugin-on"
mkdir -p "$CFG"
echo '{"enabledPlugins": {"claude-carbon@claude-carbon": true}}' > "${CFG}/settings.json"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"
check "plugin on: status line added"   "$STATUSLINE" "$(jq -r '.statusLine.command // ""' "$S" 2>/dev/null)"
check "plugin on: no hook written"     "0" "$(jq -r '[.hooks // {} | .[][]?.hooks[]?] | length' "$S" 2>/dev/null)"
check "plugin on: the setting kept"    "true" "$(jq -r '.enabledPlugins["claude-carbon@claude-carbon"]' "$S" 2>/dev/null)"
# The community listing is the same plugin; the installer's own copy of the mod is not
CFG="${TMPROOT}/plugin-listing"
mkdir -p "$CFG"
echo '{"enabledPlugins": {"co2-tracker@claude-community": true}}' > "${CFG}/settings.json"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
check "community listing on: no hook written" "0" "$(jq -r '[.hooks // {} | .[][]?.hooks[]?] | length' "${CFG}/settings.json" 2>/dev/null)"
CFG="${TMPROOT}/skills-dir-copy"
mkdir -p "$CFG"
echo '{"enabledPlugins": {"claude-carbon@skills-dir": true}}' > "${CFG}/settings.json"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
check "installer's mod copy on: hooks written" "1" "$(hook_count "${CFG}/settings.json" Stop)"

# ---------------------------------------------------------------- 7c. /carbon-update for each install

# The skill's bash block, run the way a user's Claude runs it, with a stub claude on PATH
# and a stand-in clone whose updater only leaves a mark.
UPD_SKILL="${TMPROOT}/carbon-update.sh"
awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "${REPO_DIR}/skills/carbon-update/SKILL.md" > "$UPD_SKILL"
UPD_BIN="${TMPROOT}/upd-bin"
FAKE_CLONE="${TMPROOT}/fake-clone"
mkdir -p "$UPD_BIN" "${FAKE_CLONE}/scripts" "${FAKE_CLONE}/.git"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "${TMPROOT}/claude-calls" > "${UPD_BIN}/claude"
chmod +x "${UPD_BIN}/claude"
printf 'touch "%s"\n' "${TMPROOT}/update-ran" > "${FAKE_CLONE}/scripts/update.sh"
: > "${FAKE_CLONE}/scripts/statusline.sh"
FAKE_SL="$(hook_form "$(cc_native_path "$FAKE_CLONE")/scripts/statusline.sh")"
# A PATH with jq and the system's tools but no claude of the machine's own: only the stubs
# a case puts there answer
UPD_SYS_PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin"
# run_update_skill <settings.json> [stub dir on PATH, or "" for none]
run_update_skill() {
  rm -f "${TMPROOT}/claude-calls" "${TMPROOT}/update-ran"
  mkdir -p "${TMPROOT}/upd-home/cfg"
  printf '%s\n' "$1" > "${TMPROOT}/upd-home/cfg/settings.json"
  local stub_dir="${2-$UPD_BIN}"
  (
    unset CLAUDE_PLUGIN_ROOT CLAUDE_CARBON_DIR CLAUDE_CODE_EXECPATH
    HOME="${TMPROOT}/upd-home" CLAUDE_CONFIG_DIR="${TMPROOT}/upd-home/cfg" \
      PATH="${stub_dir:+${stub_dir}:}${UPD_SYS_PATH}" bash "$UPD_SKILL" 2>&1
  )
}

# Both installs, as on the plugin author's machine: the plugin is updated through Claude
# Code, the clone left alone (its updater would wire the hooks twice and re-price history)
OUT="$(run_update_skill "$(jq -n --arg sl "$FAKE_SL" '{statusLine: {type: "command", command: $sl}, enabledPlugins: {"claude-carbon@claude-carbon": true}}')")"
check "update, plugin on: marketplace refreshed" "1" "$(grep -c "^plugin marketplace update claude-carbon$" "${TMPROOT}/claude-calls" 2>/dev/null)"
check "update, plugin on: plugin updated" "1" "$(grep -c "^plugin update claude-carbon@claude-carbon$" "${TMPROOT}/claude-calls" 2>/dev/null)"
check "update, plugin on: the clone's updater not run" "no" "$([ -f "${TMPROOT}/update-ran" ] && echo yes || echo no)"
case "$OUT" in
  *"git -C"*) ok "update, plugin on: says how to update the clone" ;;
  *) bad "update, plugin on: says how to update the clone" "a git -C line" "$OUT" ;;
esac

# The co2-tracker listing of Anthropic's community directory: updated from that marketplace
OUT="$(run_update_skill '{"enabledPlugins": {"co2-tracker@claude-community": true}}')"
check "update, community listing: its marketplace" "1" "$(grep -c "^plugin marketplace update claude-community$" "${TMPROOT}/claude-calls" 2>/dev/null)"
check "update, community listing: its own name" "1" "$(grep -c "^plugin update co2-tracker@claude-community$" "${TMPROOT}/claude-calls" 2>/dev/null)"

# No claude on PATH: the one running the session (CLAUDE_CODE_EXECPATH), else the newest the
# desktop app keeps on a Mac, by version order (2.1.10 after 2.1.9)
PLUGIN_SETTINGS='{"enabledPlugins": {"claude-carbon@claude-carbon": true}}'
OUT="$(run_update_skill "$PLUGIN_SETTINGS" "")"
case "$OUT" in
  *"from a terminal"*) ok "update, no claude anywhere: says what to run" ;;
  *) bad "update, no claude anywhere: says what to run" "the manual commands" "$OUT" ;;
esac
DESKTOP="${TMPROOT}/upd-home/Library/Application Support/Claude/claude-code"
for v in 2.1.9 2.1.10; do
  mkdir -p "${DESKTOP}/${v}/h${v}/claude.app/Contents/MacOS"
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$v" "${TMPROOT}/claude-calls" \
    > "${DESKTOP}/${v}/h${v}/claude.app/Contents/MacOS/claude"
  chmod +x "${DESKTOP}/${v}/h${v}/claude.app/Contents/MacOS/claude"
done
run_update_skill "$PLUGIN_SETTINGS" "" >/dev/null
check "update, the desktop app's claude: the newest" "1" "$(grep -c "^2.1.10 plugin update claude-carbon@claude-carbon$" "${TMPROOT}/claude-calls" 2>/dev/null)"
OUT="$(
  rm -f "${TMPROOT}/claude-calls"
  unset CLAUDE_PLUGIN_ROOT CLAUDE_CARBON_DIR
  HOME="${TMPROOT}/upd-home" CLAUDE_CONFIG_DIR="${TMPROOT}/upd-home/cfg" PATH="$UPD_SYS_PATH" \
    CLAUDE_CODE_EXECPATH="${UPD_BIN}/claude" bash "$UPD_SKILL" 2>&1
)"
check "update, the session's own claude first" "1" "$(grep -c "^plugin update claude-carbon@claude-carbon$" "${TMPROOT}/claude-calls" 2>/dev/null)"
rm -r "${TMPROOT}/upd-home/Library"

# The installer's clone alone: its updater runs, Claude Code's plugin commands do not
OUT="$(run_update_skill "$(jq -n --arg sl "$FAKE_SL" '{statusLine: {type: "command", command: $sl}}')")"
check "update, clone only: its updater run" "yes" "$([ -f "${TMPROOT}/update-ran" ] && echo yes || echo no)"
check "update, clone only: no plugin command" "no" "$([ -s "${TMPROOT}/claude-calls" ] && echo yes || echo no)"

# ---------------------------------------------------------------- 8. settings survive a broken write

# configure-settings.sh writes through tmp + mv precisely so a failed write cannot truncate a
# user's settings. Feed it invalid JSON: it must refuse and leave the file byte-identical.
CFG="${TMPROOT}/broken"
mkdir -p "$CFG"
printf '{ this is not json' > "${CFG}/settings.json"
BEFORE="$(cat "${CFG}/settings.json")"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
check "invalid settings.json left untouched" "$BEFORE" "$(cat "${CFG}/settings.json")"

# ---------------------------------------------------------------- 9. install drift check

# The statusline compares this install's data/ files against the newest plugin cache copy.
# A docs-only edit to a "_"-prefixed comment key must stay quiet (false positive of
# 2026-08-22); a changed value must light the segment; an identical cache stays quiet.
CFG="${TMPROOT}/drift"
CACHE_DATA="${CFG}/plugins/cache/mkt/claude-carbon/9.9.9/data"
mkdir -p "$CACHE_DATA" "${CFG}/claude-carbon"
cp "${REPO_DIR}/data/prices.json" "${CACHE_DATA}/prices.json"

# drift_shown: "yes" when the statusline prints the drift segment for the current cache.
drift_shown() {
  if echo '{}' | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_NO_CARD_NUDGE=1 CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 \
       bash "$SL_SCRIPT" 2>/dev/null | grep -q "install drift"; then echo yes; else echo no; fi
}

cp "${REPO_DIR}/data/factors.json" "${CACHE_DATA}/factors.json"
check "drift: identical cache is quiet" "no" "$(drift_shown)"

jq '._cache_read_factor = "an older wording of the same comment"' "${REPO_DIR}/data/factors.json" > "${CACHE_DATA}/factors.json"
check "drift: comment-only difference is quiet" "no" "$(drift_shown)"

jq '.cache_read_factor = (.cache_read_factor + 0.01)' "${REPO_DIR}/data/factors.json" > "${CACHE_DATA}/factors.json"
check "drift: value difference is flagged" "yes" "$(drift_shown)"

cp "${REPO_DIR}/data/factors.json" "${CACHE_DATA}/factors.json"
jq '.models.sonnet.input = (.models.sonnet.input + 1)' "${REPO_DIR}/data/prices.json" > "${CACHE_DATA}/prices.json"
check "drift: nested price difference is flagged" "yes" "$(drift_shown)"

cp "${REPO_DIR}/data/prices.json" "${CACHE_DATA}/prices.json"
check "drift: CLAUDE_CARBON_NO_DRIFT_CHECK honoured" "no" "$(CLAUDE_CARBON_NO_DRIFT_CHECK=1 drift_shown)"

# ------------------------------------------------------- 9b. monthly card nudge

# Early in the month the status line gives the month just closed with its total and
# points at /carbon-card. The total is the card's monthly bar (excluded rows left
# out), formatted like the session figure, read once a day and cached in
# last-month-total.
# A month with fewer than 7 days of sessions shows nothing. A card generated this
# month (last-card-month stamp) clears it, the day threshold ends it, the opt-out
# silences it. The day is forced through the threshold: 31 means "today qualifies",
# 0 means "no day does". Every DB here is a throwaway under TMPROOT.
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP monthly card nudge: sqlite3 not available"
else
  THIS_MONTH="$(date +%Y-%m)"
  PREV_M="$((10#${THIS_MONTH#*-} - 1))"; PREV_Y="${THIS_MONTH%-*}"
  if [ "$PREV_M" -eq 0 ]; then PREV_M=12; PREV_Y="$((PREV_Y - 1))"; fi
  PREV_MONTH="$(printf '%04d-%02d' "$PREV_Y" "$PREV_M")"
  PREV_NAME="$(cc_prev_month_name "$THIS_MONTH")"
  TODAY_KEY="$(date +%Y-%m-%d)"

  # nudge_db <cfg> <days>: one 1500 g session on each of the first <days> days of the
  # closed month, plus an excluded 99999 g session on another day and a 50000 g
  # session this month, neither of which may count.
  nudge_db() {
    local db="${1}/claude-carbon/carbon.db" d
    mkdir -p "${1}/claude-carbon"
    sqlite3 "$db" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, methodology_version INTEGER DEFAULT 2, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"
    for d in $(seq 1 "$2"); do
      sqlite3 "$db" "INSERT INTO sessions (session_id, project, model, co2_grams, started_at) VALUES ('d${d}', 'p', 'claude-opus-5', 1500.0, '${PREV_MONTH}-$(printf '%02d' "$d")T10:00:00Z');"
    done
    sqlite3 "$db" "INSERT INTO sessions (session_id, project, model, co2_grams, started_at, excluded) VALUES ('ex', 'p', 'glm-4.7', 99999.0, '${PREV_MONTH}-20T10:00:00Z', 1);"
    sqlite3 "$db" "INSERT INTO sessions (session_id, project, model, co2_grams, started_at) VALUES ('now', 'p', 'claude-opus-5', 50000.0, '${THIS_MONTH}-01T10:00:00Z');"
  }
  nudge_line() {
    echo '{}' | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="${CFG}/claude-carbon/carbon.db" \
      CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 CLAUDE_CARBON_NO_DRIFT_CHECK=1 \
      bash "$SL_SCRIPT" 2>/dev/null | grep -o '📊 .*' || true
  }

  CFG="${TMPROOT}/nudge"
  nudge_db "$CFG" 7
  check "nudge: closed month and its total, in English" "📊 ${PREV_NAME}: 10.5kgCO₂ · /carbon-card" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  check "nudge: total cached under today's date"       "${TODAY_KEY} 10500" "$(cat "${CFG}/claude-carbon/last-month-total" 2>/dev/null)"
  # A row added after the first read is not seen: the query is not run again.
  sqlite3 "${CFG}/claude-carbon/carbon.db" "INSERT INTO sessions (session_id, project, model, co2_grams, started_at) VALUES ('late', 'p', 'claude-opus-5', 5000.0, '${PREV_MONTH}-09T10:00:00Z');"
  check "nudge: cache reused, query not rerun"          "📊 ${PREV_NAME}: 10.5kgCO₂ · /carbon-card" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  printf '%s 840\n' "$TODAY_KEY" > "${CFG}/claude-carbon/last-month-total"
  check "nudge: figure read from the cache, grams below 1 kg" "📊 ${PREV_NAME}: 840gCO₂ · /carbon-card" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  # A cache from an earlier day is read again: a session still running across the
  # 1st keeps adding to the closed month under its start date.
  printf '%s-01 840\n' "$PREV_MONTH" > "${CFG}/claude-carbon/last-month-total"
  check "nudge: a cache from another day is recomputed" "📊 ${PREV_NAME}: 15.5kgCO₂ · /carbon-card" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  check "nudge: past the day threshold it is gone"      "" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=0 nudge_line)"
  date +%Y-%m > "${CFG}/claude-carbon/last-card-month"
  check "nudge: a card this month clears it"            "" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  rm -f "${CFG}/claude-carbon/last-card-month"
  check "nudge: CLAUDE_CARBON_NO_CARD_NUDGE honoured"   "" "$(CLAUDE_CARBON_NO_CARD_NUDGE=1 CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"

  CFG="${TMPROOT}/nudge-thin"
  nudge_db "$CFG" 6
  check "nudge: fewer than 7 days, no nudge"            "" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)"
  check "nudge: fewer than 7 days is cached too"        "${TODAY_KEY} -" "$(cat "${CFG}/claude-carbon/last-month-total" 2>/dev/null)"

  CFG="${TMPROOT}/nudge-nodb"
  mkdir -p "${CFG}/claude-carbon"
  check "nudge: no DB, no nudge and no cache"           "|no cache" "$(CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY=31 nudge_line)|$([ -f "${CFG}/claude-carbon/last-month-total" ] && echo cache || echo no cache)"
fi

# ------------------------------------------------------- 10. statusline CO2 source

# The status line must report the SESSION total, not the size of the current context
# window. It reads this session's row from carbon.db (written by the Stop hook every
# turn) and only falls back to the context-window estimate when no row exists yet.
SL_DB="${TMPROOT}/statusline/carbon.db"
mkdir -p "${TMPROOT}/statusline"
sqlite3 "$SL_DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, methodology_version INTEGER DEFAULT 2, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"
sqlite3 "$SL_DB" "INSERT INTO sessions (session_id, project, model, co2_grams, cost_usd, excluded) VALUES ('sess-known', 'p', 'claude-opus-5', 26333.0, 1342.13, 0);"
sqlite3 "$SL_DB" "INSERT INTO sessions (session_id, project, model, co2_grams, cost_usd, excluded) VALUES ('sess-excluded', 'p', 'glm-4.7', 0.0, 0.0, 1);"

# A 200k context window on Opus factors is ~16 g; the stored session total is 26.3 kg.
sl_co2() {
  printf '{"session_id":"%s","model":{"id":"%s","display_name":"M"},"context_window":{"total_input_tokens":200000,"total_output_tokens":0,"used_percentage":20},"cost":{"total_cost_usd":1342.13},"workspace":{"current_dir":"/tmp/p"}}' "$1" "${2:-claude-opus-5}" \
    | TMPDIR="$TMPROOT" CLAUDE_CONFIG_DIR="${TMPROOT}/statusline/cfg" CLAUDE_CARBON_DB="$SL_DB" bash "$SL_SCRIPT" --segment 2>/dev/null | sed -E 's/.*· //'
}

check "statusline: cumulative total from the DB, not the context window" "26.3kgCO₂" "$(sl_co2 sess-known)"
check "statusline: unknown session falls back to the window estimate"    "16gCO₂"    "$(sl_co2 sess-unknown)"
check "statusline: excluded row does not leak, falls back"               "0gCO₂"     "$(sl_co2 sess-excluded glm-4.7)"
check "statusline: no session_id falls back"                             "16gCO₂"    "$(sl_co2 '')"

# First turn: no row yet, the Stop hook still writing it. The status line makes the hook's
# own computation on the transcript, cache reads at their factor: 4.3 g, shown 4 g, where
# the window estimate (all 80 202 input tokens at the full factor) said 6 g.
SL_TRANSCRIPT="${TMPROOT}/statusline/sess-first.jsonl"
printf '%s\n' '{"type":"assistant","requestId":"r1","timestamp":"2026-10-13T13:53:55Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":50784,"cache_creation":{"ephemeral_1h_input_tokens":50784},"cache_read_input_tokens":29416,"output_tokens":113}}}' > "$SL_TRANSCRIPT"
sl_first() {
  printf '{"session_id":"sess-first","transcript_path":"%s","model":{"id":"claude-opus-5-5","display_name":"M"},"context_window":{"total_input_tokens":80202,"total_output_tokens":113,"used_percentage":8},"cost":{"total_cost_usd":0.41},"workspace":{"current_dir":"/tmp/p"}}' "$1" \
    | TMPDIR="$TMPROOT" CLAUDE_CONFIG_DIR="${TMPROOT}/statusline/cfg" CLAUDE_CARBON_DB="$SL_DB" bash "$SL_SCRIPT" --segment 2>/dev/null | sed -E 's/.*· //'
}
check "statusline: first turn takes the transcript, as the Stop hook will" "4gCO₂" "$(sl_first "$SL_TRANSCRIPT")"
check "statusline: first turn, transcript gone, falls back to the window"  "6gCO₂" "$(sl_first "${TMPROOT}/statusline/none.jsonl")"

# The transcripts are read only without a row, and at most every 10 seconds: a jq on PATH
# counts the per-file passes (the only jq calls given --arg main)
SL_SHIM="${TMPROOT}/statusline/shim"
mkdir -p "$SL_SHIM"
printf '#!/usr/bin/env bash\ncase "$*" in *"--arg main"*) echo x >> "%s" ;; esac\nexec "%s" "$@"\n' "${TMPROOT}/statusline/passes" "$(command -v jq)" > "${SL_SHIM}/jq"
chmod +x "${SL_SHIM}/jq"
sl_tx() {
  printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-5-5","display_name":"M"},"context_window":{"total_input_tokens":80202,"total_output_tokens":113,"used_percentage":8},"cost":{"total_cost_usd":0.41},"workspace":{"current_dir":"/tmp/p"}}' "$1" "$2" \
    | PATH="${SL_SHIM}:$PATH" TMPDIR="$TMPROOT" CLAUDE_CONFIG_DIR="${TMPROOT}/statusline/cfg" CLAUDE_CARBON_DB="$SL_DB" bash "$SL_SCRIPT" --segment 2>/dev/null | sed -E 's/.*· //'
}
passes() { wc -l < "${TMPROOT}/statusline/passes" | tr -d ' '; }
SL_X="sess-excluded-claude-$$"
sqlite3 "$SL_DB" "INSERT INTO sessions (session_id, project, model, co2_grams, cost_usd, excluded) VALUES ('${SL_X}', 'p', 'claude-opus-5-5', 0.0, 0.0, 1);"
: > "${TMPROOT}/statusline/passes"
check "statusline: an excluded Claude session shows its row, transcripts unread" "0gCO₂|0" "$(sl_tx "$SL_X" "$SL_TRANSCRIPT")|$(passes)"
SL_T="sess-throttle-$$"
: > "${TMPROOT}/statusline/passes"
FIRST="$(sl_tx "$SL_T" "$SL_TRANSCRIPT")"
SECOND="$(sl_tx "$SL_T" "$SL_TRANSCRIPT")"
check "statusline: no row, the transcripts read once in 10 seconds" "4gCO₂|4gCO₂|1" "${FIRST}|${SECOND}|$(passes)"
# One more answer within those 10 seconds: the transcript grew, the figure follows
SL_GROW="${TMPROOT}/statusline/sess-grow.jsonl"
cp "$SL_TRANSCRIPT" "$SL_GROW"
SL_G="sess-grow-$$"
FIRST="$(sl_tx "$SL_G" "$SL_GROW")"
sed 's/"m1"/"m2"/; s/"r1"/"r2"/' "$SL_TRANSCRIPT" >> "$SL_GROW"
check "statusline: a transcript that grew is computed again" "4gCO₂|9gCO₂" "${FIRST}|$(sl_tx "$SL_G" "$SL_GROW")"
check "statusline: its cache beside the database, none in TMPDIR" "yes|0" \
  "$([ -f "${TMPROOT}/statusline/statusline-cache" ] && echo yes || echo no)|$(find "$TMPROOT" -maxdepth 1 -name 'claude-carbon-statusline-*' | wc -l | tr -d ' ')"

# ------------------------------------------------------- 11. decode-context sum

# Every session stores sum(output_tokens x context) over its assistant messages, main
# transcript and subagents alike, after the same (message.id, requestId) dedup as the
# token counts. Both writers (Stop hook, backfill) must agree, and backfill must fill
# the column on rows that predate it while the transcript is still on disk.
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP decode-context sum: sqlite3 not available"
else
  CFG="${TMPROOT}/octx"
  OCTX_DB="${CFG}/claude-carbon/carbon.db"
  OCTX_SESSION="12345678-1234-1234-1234-123456789abc"
  OCTX_PROJ="${TMPROOT}/octx-proj"
  OCTX_DIR="${CFG}/projects/-octx-proj"
  mkdir -p "${CFG}/claude-carbon" "$OCTX_PROJ" "${OCTX_DIR}/${OCTX_SESSION}/subagents"
  # A DB created before the column existed: the writers must add it themselves.
  sqlite3 "$OCTX_DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"
  # msg_1 is written twice (streaming snapshot then final): only the last counts,
  # 500 x (1000 + 20000 + 100000) = 60,500,000. msg_2: 2000 x 121500 = 243,000,000.
  # Subagent: 300 x (500 + 5000) = 1,650,000. Total 305,150,000.
  OCTX_MAIN="${OCTX_DIR}/${OCTX_SESSION}.jsonl"
  cat > "$OCTX_MAIN" <<EOF
{"type":"user","cwd":"${OCTX_PROJ}","gitBranch":"main","sessionId":"${OCTX_SESSION}","timestamp":"2026-09-04T10:00:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","requestId":"req_1","timestamp":"2026-09-04T10:00:01Z","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100000,"output_tokens":100}}}
{"type":"assistant","requestId":"req_1","timestamp":"2026-09-04T10:00:02Z","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100000,"output_tokens":500}}}
{"type":"assistant","requestId":"req_2","timestamp":"2026-09-04T10:00:03Z","message":{"id":"msg_2","model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":121500,"output_tokens":2000}}}
EOF
  cat > "${OCTX_DIR}/${OCTX_SESSION}/subagents/agent-1.jsonl" <<EOF
{"type":"assistant","requestId":"req_s1","timestamp":"2026-09-04T10:00:04Z","message":{"id":"msg_s1","model":"claude-haiku-4-5","usage":{"input_tokens":500,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":300}}}
EOF
  octx_col() { sqlite3 "$OCTX_DB" "SELECT COALESCE(output_context_sum, -1) FROM sessions WHERE session_id='${OCTX_SESSION}';" 2>/dev/null; }

  jq -n --arg s "$OCTX_SESSION" --arg t "$OCTX_MAIN" --arg c "$OCTX_PROJ" '{session_id: $s, transcript_path: $t, cwd: $c}' \
    | CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/persist-session.sh" >/dev/null 2>&1
  check "decode context: Stop hook stores sum(output x context), deduplicated, subagents included" "305150000" "$(octx_col)"
  check "decode context: Stop hook token counts unchanged by the new column" "2800|221500" "$(sqlite3 "$OCTX_DB" "SELECT output_tokens || '|' || cache_read_tokens FROM sessions WHERE session_id='${OCTX_SESSION}';")"
  LIVE_CO2="$(sqlite3 "$OCTX_DB" "SELECT co2_grams FROM sessions WHERE session_id='${OCTX_SESSION}';")"

  sqlite3 "$OCTX_DB" "DELETE FROM sessions;"
  CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/backfill.sh" >/dev/null 2>&1
  check "decode context: backfill stores the same sum"      "305150000" "$(octx_col)"
  check "decode context: backfill CO2 matches the Stop hook" "$LIVE_CO2" "$(sqlite3 "$OCTX_DB" "SELECT co2_grams FROM sessions WHERE session_id='${OCTX_SESSION}';")"

  # A row captured before the column existed: backfill fills it from the transcript. Its
  # ended_at is set to now, as the Stop hook would have left it: the fixture messages carry
  # fixed timestamps while the file was written just now, which backfill would otherwise
  # read as a transcript that grew after its row, and refresh instead of fill.
  # agents_collected = 0: such a row comes from a version that did not stamp it.
  sqlite3 "$OCTX_DB" "UPDATE sessions SET output_context_sum = 0, agents_collected = 0, ended_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE session_id='${OCTX_SESSION}';"
  BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/backfill.sh" 2>/dev/null)"
  check "decode context: backfill fills a pre-existing row" "305150000" "$(octx_col)"
  case "$BF_OUT" in
    *"Filled the decode-context sum (output_context_sum) on 1 existing row(s)"*) ok "decode context: fill is reported" ;;
    *) bad "decode context: fill is reported" "a 'Filled ... 1 existing row(s)' line" "$BF_OUT" ;;
  esac
  BF_OUT="$(CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/backfill.sh" 2>/dev/null)"
  case "$BF_OUT" in
    *"Filled the decode-context sum"*) bad "decode context: a filled row is not re-filled" "no 'Filled' line" "$BF_OUT" ;;
    *) ok "decode context: a filled row is not re-filled" ;;
  esac
fi

# ------------------------------------------------------- 12. the mod's copy under skills/

# install-mod.sh gives a git-clone install the mod as a plugin Claude Code loads from
# $CONFIG_DIR/skills/claude-carbon/ (claude-carbon@skills-dir). The copy must carry the
# module and nothing that runs a bash hook, never overwrite a folder the user made, step
# aside for an enabled claude-carbon plugin, and never be left half-written.
INSTALL_MOD="${REPO_DIR}/scripts/install-mod.sh"
MANAGED=".claude-carbon-managed"

# mod_run <config dir> [VAR=value...]: run install-mod.sh against that config dir, echo its output.
mod_run() {
  local cfg="$1"; shift
  env "$@" CLAUDE_CONFIG_DIR="$cfg" bash "$INSTALL_MOD" 2>&1
}
# Work directories left next to the copy, "" when there are none.
leftovers() {
  local d out=""
  for d in "$1"/skills/.claude-carbon.*; do
    [ -e "$d" ] && out="${out}${d##*/} "
  done
  printf '%s' "$out"
}
has() { [ -e "$1" ] && echo yes || echo no; }
same() { cmp -s "$1" "$2" && echo yes || echo no; }
said() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "output containing '$2'" "$3" ;;
  esac
}

# The cold start of section 1 went through configure-settings.sh: the copy is there.
CFG="${TMPROOT}/cold"
M="${CFG}/skills/claude-carbon"
check "mod: configure-settings.sh installs the copy" "yes" "$(has "${M}/${MANAGED}")"
check "mod: manifest keeps the plugin's name" "claude-carbon" "$(jq -r '.name' "${M}/.claude-plugin/plugin.json" 2>/dev/null)"
check "mod: manifest keeps the plugin's version" "$(jq -r '.version' "${REPO_DIR}/.claude-plugin/plugin.json")" "$(jq -r '.version' "${M}/.claude-plugin/plugin.json" 2>/dev/null)"
check "mod: manifest keeps the options" "$(jq -c '.userConfig' "${REPO_DIR}/.claude-plugin/plugin.json")" "$(jq -c '.userConfig' "${M}/.claude-plugin/plugin.json" 2>/dev/null)"
check "mod: manifest has no status line and no skills" "false false" "$(jq -r '"\(has("statusLine")) \(has("skills"))"' "${M}/.claude-plugin/plugin.json" 2>/dev/null)"
check "mod: hooks.json declares the module only" '{"modules":["./mod/register.tsx"]}' "$(jq -c '.' "${M}/hooks/hooks.json" 2>/dev/null | tr -d '\r')"
check "mod: no command in the copy's manifests" "0" "$(cat "${M}/.claude-plugin/plugin.json" "${M}/hooks/hooks.json" | grep -c '"command"')"
check "mod: no skill, script or command in the copy" "no no no" "$(has "${M}/skills") $(has "${M}/scripts") $(has "${M}/commands")"
check "mod: module identical to the clone's" "yes" "$(diff -r -x '*.test.tsx' "${REPO_DIR}/hooks/mod" "${M}/hooks/mod" >/dev/null 2>&1 && echo yes || echo no)"
check "mod: tests left out" "no" "$(has "${M}/hooks/mod/answer-co2.test.tsx")"
check "mod: factors travel with it" "yes" "$(same "${REPO_DIR}/data/factors.json" "${M}/data/factors.json")"
check "mod: prices travel with it" "yes" "$(same "${REPO_DIR}/data/prices.json" "${M}/data/prices.json")"
check "mod: types travel with it" "yes" "$(same "${REPO_DIR}/types/index.d.ts" "${M}/types/index.d.ts")"
check "mod: no work directory left" "" "$(leftovers "$CFG")"

OUT="$(mod_run "$CFG")"
said "mod: a second run is skipped" "mod: already installed (skipped)" "$OUT"
check "mod: a second run leaves nothing behind" "" "$(leftovers "$CFG")"

# A stale copy (an older version) is replaced whole.
printf 'stale' > "${M}/data/factors.json"
OUT="$(mod_run "$CFG")"
said "mod: a stale copy is updated" "mod: updated" "$OUT"
said "mod: an update asks for a restart" "Restart Claude Code to load it" "$OUT"
check "mod: the update brings the current factors" "yes" "$(same "${REPO_DIR}/data/factors.json" "${M}/data/factors.json")"
check "mod: the update brings the current prices" "yes" "$(same "${REPO_DIR}/data/prices.json" "${M}/data/prices.json")"
check "mod: the update keeps the marker" "yes" "$(has "${M}/${MANAGED}")"
check "mod: the update leaves nothing behind" "" "$(leftovers "$CFG")"

# The swap fails, as when Windows holds the copy in use during /carbon-update: the previous
# copy stays whole and in place, the new one is dropped, and the user is told to restart.
# A fake mv on PATH refuses the renames whose source matches SHIM_REFUSE and hands every
# other call to the real one.
SHIM="${TMPROOT}/shim"
mkdir -p "$SHIM"
REAL_MV="$(command -v mv)"
cat > "${SHIM}/mv" <<EOF
#!/usr/bin/env bash
case "\$1" in \${SHIM_REFUSE}) exit 1 ;; esac
exec "${REAL_MV}" "\$@"
EOF
chmod +x "${SHIM}/mv"

printf 'stale' > "${M}/data/factors.json"
OUT="$(mod_run "$CFG" PATH="${SHIM}:${PATH}" SHIM_REFUSE='*/skills/claude-carbon')"
said "mod: a locked copy asks for a restart" "Restart Claude Code, then run the installer again" "$OUT"
check "mod: a locked copy stays as it was" "stale" "$(cat "${M}/data/factors.json")"
check "mod: a locked copy keeps its marker" "yes" "$(has "${M}/${MANAGED}")"
check "mod: a locked copy leaves nothing behind" "" "$(leftovers "$CFG")"

# The new copy cannot be renamed in: the previous one is put back.
OUT="$(mod_run "$CFG" PATH="${SHIM}:${PATH}" SHIM_REFUSE='*/.claude-carbon.tmp.*')"
said "mod: a failed rename asks for a restart" "Restart Claude Code, then run the installer again" "$OUT"
check "mod: a failed rename puts the previous copy back" "stale" "$(cat "${M}/data/factors.json" 2>/dev/null)"
check "mod: a failed rename leaves nothing behind" "" "$(leftovers "$CFG")"

# skills/ is read-only: nothing can be built, the previous copy stays. Root and Windows
# ignore the permission bits, so the case only runs where they hold.
chmod 555 "${CFG}/skills"
if [ -w "${CFG}/skills" ]; then
  echo "SKIP mod read-only skills/: permission bits not enforced here"
else
  OUT="$(mod_run "$CFG")"
  said "mod: a read-only skills/ changes nothing" "nothing changed" "$OUT"
  check "mod: a read-only skills/ keeps the previous copy" "stale" "$(cat "${M}/data/factors.json")"
  check "mod: a read-only skills/ leaves nothing behind" "" "$(leftovers "$CFG")"
fi
chmod 755 "${CFG}/skills"

mod_run "$CFG" >/dev/null
check "mod: the next run brings the copy up to date" "yes" "$(same "${REPO_DIR}/data/factors.json" "${M}/data/factors.json")"

# A folder of the same name the user made is never touched.
CFG="${TMPROOT}/mod-user"
mkdir -p "${CFG}/skills/claude-carbon"
printf 'mine' > "${CFG}/skills/claude-carbon/notes.txt"
OUT="$(mod_run "$CFG")"
said "mod: a user's folder is reported" "was not made by this installer" "$OUT"
check "mod: a user's folder is left intact" "mine no" "$(cat "${CFG}/skills/claude-carbon/notes.txt") $(has "${CFG}/skills/claude-carbon/.claude-plugin")"
mod_run "$CFG" CLAUDE_CARBON_NO_MOD=1 >/dev/null
check "mod: CLAUDE_CARBON_NO_MOD=1 spares a user's folder" "mine" "$(cat "${CFG}/skills/claude-carbon/notes.txt" 2>/dev/null)"

# CLAUDE_CARBON_NO_MOD=1 skips the step and removes the copy this installer made.
CFG="${TMPROOT}/mod-optout"
mkdir -p "$CFG"
OUT="$(mod_run "$CFG" CLAUDE_CARBON_NO_MOD=1)"
said "mod: CLAUDE_CARBON_NO_MOD=1 skips" "mod: skipped (CLAUDE_CARBON_NO_MOD=1)" "$OUT"
check "mod: CLAUDE_CARBON_NO_MOD=1 installs nothing" "no" "$(has "${CFG}/skills/claude-carbon")"
mod_run "$CFG" >/dev/null
OUT="$(mod_run "$CFG" CLAUDE_CARBON_NO_MOD=1)"
said "mod: CLAUDE_CARBON_NO_MOD=1 removes the copy" "mod: removed (CLAUDE_CARBON_NO_MOD=1)" "$OUT"
check "mod: the removed copy is gone" "no" "$(has "${CFG}/skills/claude-carbon")"
check "mod: the removal leaves nothing behind" "" "$(leftovers "$CFG")"
# Through the real entry point too: configure-settings.sh passes the variable on.
mod_run "$CFG" >/dev/null
CLAUDE_CARBON_NO_MOD=1 CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
check "mod: CLAUDE_CARBON_NO_MOD=1 honoured through configure-settings.sh" "no" "$(has "${CFG}/skills/claude-carbon")"

# The claude-carbon plugin enabled from a marketplace already brings the mod.
for key in "claude-carbon@claude-carbon" "co2-tracker@claude-community"; do
  CFG="${TMPROOT}/mod-plugin-${key%%@*}"
  mkdir -p "$CFG"
  jq -n --arg k "$key" '{enabledPlugins: {($k): true}}' > "${CFG}/settings.json"
  OUT="$(mod_run "$CFG")"
  said "mod: ${key} enabled skips the step" "brings it" "$OUT"
  check "mod: ${key} enabled installs nothing" "no" "$(has "${CFG}/skills/claude-carbon")"
done

# Enabled after a copy was made: the copy goes, or every figure would be drawn twice.
CFG="${TMPROOT}/mod-plugin-later"
mkdir -p "$CFG"
mod_run "$CFG" >/dev/null
check "mod: fixture copy made" "yes" "$(has "${CFG}/skills/claude-carbon/${MANAGED}")"
echo '{"enabledPlugins": {"claude-carbon@claude-carbon": true}}' > "${CFG}/settings.json"
OUT="$(mod_run "$CFG")"
said "mod: a plugin enabled later removes the copy" "mod: removed the copy" "$OUT"
check "mod: the copy is gone once the plugin is enabled" "no" "$(has "${CFG}/skills/claude-carbon")"

# A disabled plugin does not count, and neither does the copy's own entry, whatever its value.
for entry in '"claude-carbon@claude-carbon": false' '"claude-carbon@skills-dir": true' '"claude-carbon@skills-dir": false'; do
  CFG="${TMPROOT}/mod-entry-$(printf '%s' "$entry" | tr -cd 'a-z')"
  mkdir -p "$CFG"
  echo "{\"enabledPlugins\": {${entry}}}" > "${CFG}/settings.json"
  mod_run "$CFG" >/dev/null
  check "mod: installed with ${entry}" "yes" "$(has "${CFG}/skills/claude-carbon/${MANAGED}")"
done

# Unreadable settings could hide an enabled plugin: no copy rather than a doubled mod.
CFG="${TMPROOT}/mod-badjson"
mkdir -p "$CFG"
printf '{ not json' > "${CFG}/settings.json"
OUT="$(mod_run "$CFG")"
said "mod: invalid settings.json skips the step" "is not valid JSON" "$OUT"
check "mod: invalid settings.json installs nothing" "no" "$(has "${CFG}/skills/claude-carbon")"

# A marketplace checkout loads the mod from its own hooks/hooks.json.
FAKE="${TMPROOT}/home/.claude/plugins/cache/mkt/claude-carbon/9.9.9"
CFG="${TMPROOT}/mod-mkt"
mkdir -p "${FAKE}/scripts" "$CFG"
cp "$INSTALL_MOD" "${REPO_DIR}/scripts/portable-lib.sh" "${FAKE}/scripts/"
cp -R "${REPO_DIR}/hooks" "${FAKE}/hooks"
CLAUDE_CONFIG_DIR="$CFG" bash "${FAKE}/scripts/install-mod.sh" >/dev/null 2>&1
check "mod: a marketplace checkout installs nothing" "no" "$(has "${CFG}/skills")"
# The same under a config dir CLAUDE_CONFIG_DIR names without ".claude" in its path.
CFG="${TMPROOT}/mod-mkt-custom"
FAKE="${CFG}/plugins/cache/mkt/claude-carbon/9.9.9"
mkdir -p "${FAKE}/scripts"
cp "$INSTALL_MOD" "${REPO_DIR}/scripts/portable-lib.sh" "${FAKE}/scripts/"
cp -R "${REPO_DIR}/hooks" "${FAKE}/hooks"
CLAUDE_CONFIG_DIR="$CFG" bash "${FAKE}/scripts/install-mod.sh" >/dev/null 2>&1
check "mod: a marketplace checkout under a custom config dir installs nothing" "no" "$(has "${CFG}/skills")"

# A checkout without hooks/mod has nothing to copy.
FAKE="${TMPROOT}/nomod"
CFG="${TMPROOT}/mod-none"
mkdir -p "${FAKE}/scripts" "${FAKE}/.claude-plugin" "$CFG"
cp "$INSTALL_MOD" "${REPO_DIR}/scripts/portable-lib.sh" "${FAKE}/scripts/"
cp "${REPO_DIR}/.claude-plugin/plugin.json" "${FAKE}/.claude-plugin/"
CLAUDE_CONFIG_DIR="$CFG" bash "${FAKE}/scripts/install-mod.sh" >/dev/null 2>&1
check "mod: a checkout without hooks/mod installs nothing" "no" "$(has "${CFG}/skills")"

# ---------------------------------------------------------------- jq 1.6 keywords
# jq 1.6 (Ubuntu 20.04 and 22.04) rejects a variable named after a keyword: `--arg end`
# then `$end` made a fresh install write no settings at all. CI runs a newer jq, so check
# the source instead of the behaviour.
KW_ARGS="$(grep -rn -E -- '--arg(json)? (end|if|then|else|elif|reduce|foreach|try|catch|label|import|include|def|and|or|not|as) ' \
  "${REPO_DIR}/scripts" "${REPO_DIR}/skills" "${REPO_DIR}/install.sh" 2>/dev/null || true)"
check "jq: no variable named after a jq 1.6 keyword" "" "$KW_ARGS"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} install/update assertions passed."
