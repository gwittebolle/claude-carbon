#!/usr/bin/env bash
# run-install-tests.sh — exercise the wiring that puts claude-carbon into Claude Code:
# scripts/configure-settings.sh (settings.json merge + /carbon-* commands) and the repair
# path scripts/update.sh takes on an install that predates a hook.
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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-tests.XXXXXX")"
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
bad() {  FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; }

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# Commands registered for a hook event, newline-separated, in order.
hook_commands() { jq -r --arg e "$2" '[.hooks[$e][]?.hooks[]?.command] | .[]' "$1" 2>/dev/null; }
hook_count()    { jq -r --arg e "$2" '[.hooks[$e][]?.hooks[]?.command] | length' "$1" 2>/dev/null; }

STATUSLINE="${REPO_DIR}/scripts/statusline.sh"
STOP="${REPO_DIR}/scripts/persist-session.sh"
RESCAN="${REPO_DIR}/scripts/safety-rescan.sh"

# ---------------------------------------------------------------- 1. cold start

CFG="${TMPROOT}/cold"
mkdir -p "$CFG"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "cold start: settings.json created"  "yes" "$([ -f "$S" ] && echo yes || echo no)"
check "cold start: statusLine"             "$STATUSLINE" "$(jq -r '.statusLine.command // ""' "$S" 2>/dev/null)"
check "cold start: Stop hook"              "$STOP"       "$(hook_commands "$S" Stop)"
check "cold start: SessionStart hook"      "$RESCAN"     "$(hook_commands "$S" SessionStart)"

MISSING=""
for c in carbon-report carbon-card carbon-update carbon-badge carbon-pr; do
  [ -L "${CFG}/commands/${c}.md" ] || MISSING="${MISSING}${c} "
done
check "cold start: /carbon-* commands linked" "" "$MISSING"

# ---------------------------------------------------------------- 2. pre-1.1.3 install repaired

# The shape every curl install had before the SessionStart hook was wired: our statusLine and
# our Stop hook, no SessionStart at all.
CFG="${TMPROOT}/legacy"
mkdir -p "$CFG"
cat > "${CFG}/settings.json" <<EOF
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "${STATUSLINE}"},
  "hooks": {
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "${STOP}"}]}]
  }
}
EOF
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "legacy install: SessionStart added"   "$RESCAN" "$(hook_commands "$S" SessionStart)"
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
check "idempotent: foreign hook still there" "1" "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(. == "/opt/other/start.sh")] | length' "$S" 2>/dev/null)"

# ---------------------------------------------------------------- 5. equivalent path spellings

# The README's manual block writes `~/code/claude-carbon/...` while the installer writes the
# expanded absolute path, and Claude Code accepts escaped spaces. A hand-wired install followed
# by a curl install must not end up running the same hook twice.
CFG="${TMPROOT}/spelling"
mkdir -p "$CFG"
STOP_DOTTED="${REPO_DIR}/./scripts/persist-session.sh"
RESCAN_ALT="$RESCAN"
# SC2088: the literal tilde is the point — this builds the unexpanded spelling a user would
# have hand-written, to prove configure-settings.sh recognizes it as the same hook.
# shellcheck disable=SC2088
case "$REPO_DIR" in
  "${HOME}"/*) RESCAN_ALT="~/${REPO_DIR#"${HOME}"/}/scripts/safety-rescan.sh" ;;
esac
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
    CLAUDE_CONFIG_DIR="$CFG" bash "${CLONE}/scripts/update.sh" >/dev/null 2>&1
    check "update repairs SessionStart" "${CLONE}/scripts/safety-rescan.sh" "$(hook_commands "${CFG}/settings.json" SessionStart)"
    check "update keeps Stop single"    "1" "$(hook_count "${CFG}/settings.json" Stop)"
  else
    echo "SKIP update repair: clone unavailable or without an upstream branch"
  fi
fi

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
       bash "$STATUSLINE" 2>/dev/null | grep -q "install drift"; then echo yes; else echo no; fi
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

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} install/update assertions passed."
