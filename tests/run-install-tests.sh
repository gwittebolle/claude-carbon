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
STATUSLINE="${CMD_BASE}/scripts/statusline.sh"
STOP="${CMD_BASE}/scripts/persist-session.sh"
RESCAN="${CMD_BASE}/scripts/safety-rescan.sh"

# ---------------------------------------------------------------- 1. cold start

CFG="${TMPROOT}/cold"
mkdir -p "$CFG"
CLAUDE_CONFIG_DIR="$CFG" bash "$CONFIGURE" >/dev/null 2>&1
S="${CFG}/settings.json"

check "cold start: settings.json created"  "yes" "$([ -f "$S" ] && echo yes || echo no)"
check "cold start: statusLine"             "$STATUSLINE" "$(jq -r '.statusLine.command // ""' "$S" 2>/dev/null)"
check "cold start: Stop hook"              "$STOP"       "$(hook_commands "$S" Stop)"
check "cold start: SessionStart hook"      "$RESCAN"     "$(hook_commands "$S" SessionStart)"

# Symlinked everywhere a symlink works. Git Bash cannot create one without Windows
# Developer Mode, so there the commands are copied on purpose and configure-settings.sh
# refreshes the copy on update; assert whichever form this platform is meant to produce.
MISSING=""
for c in carbon-report carbon-card carbon-update carbon-badge carbon-pr; do
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
    # configure-settings.sh writes the hook in native spelling (C:/... on Windows,
    # see CMD_BASE above), so the expectation has to be spelled the same way.
    check "update repairs SessionStart" "$(cc_native_path "$CLONE")/scripts/safety-rescan.sh" "$(hook_commands "${CFG}/settings.json" SessionStart)"
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
    | CLAUDE_CARBON_DB="$SL_DB" bash "$STATUSLINE" --segment 2>/dev/null | sed -E 's/.*· //'
}

check "statusline: cumulative total from the DB, not the context window" "26.3kg CO₂" "$(sl_co2 sess-known)"
check "statusline: unknown session falls back to the window estimate"    "16g CO₂"    "$(sl_co2 sess-unknown)"
check "statusline: excluded row does not leak, falls back"               "0g CO₂"     "$(sl_co2 sess-excluded glm-4.7)"
check "statusline: no session_id falls back"                             "16g CO₂"    "$(sl_co2 '')"

# ----------------------------------------------------------------

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} failed, ${PASSED} passed."
  exit 1
fi
echo "All ${PASSED} install/update assertions passed."
