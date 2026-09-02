#!/usr/bin/env bash
# run-windows-e2e.sh — the assertions that only a real Windows machine can make.
#
# tests/run-portability-tests.sh pins the pure string logic, which any platform can
# check by forcing CC_OS. What it cannot reach is the part that made Windows fail in
# the first place: a real cygpath, a real native path pointing at a real file, and the
# way Claude Code actually spawns a hook. This suite covers exactly that, and skips
# with exit 0 everywhere else so it can sit in the normal CI matrix.
#
# Every case runs under its own throwaway CLAUDE_CONFIG_DIR; the real ~/.claude is
# never read or written. No network.
#
# bash 3.2 compatible. Dependencies: jq, sqlite3, git, cygpath (Git for Windows).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"

if ! cc_is_windows; then
  echo "SKIP run-windows-e2e.sh: not running under Git Bash / MSYS (CC_OS=${CC_OS})."
  echo "     These assertions need a real Windows filesystem; CI runs them on windows-latest."
  exit 0
fi

for c in jq sqlite3 git cygpath; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done

TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-win-e2e.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

cleanup() {
  case "$TMPROOT" in
    */claude-carbon-win-e2e.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "PASS $1"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
# contains <name> <needle> <haystack>
contains() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "to contain '$2'" "$3" ;; esac
}

echo "windows end-to-end (CC_OS=${CC_OS}, cygpath=$(command -v cygpath))"
echo "─────────────────────────────"

# ── 1. cc_path against the real filesystem ───────────────────────────────────
# Not a string comparison this time: convert a file's own native path back and
# assert bash can actually open the result.
echo ""
echo "cc_path round-trip on a real file"

PROBE_DIR="${TMPROOT}/probe dir"        # a space, because Program Files has one
mkdir -p "$PROBE_DIR"
PROBE="${PROBE_DIR}/transcript.jsonl"
echo '{"probe":true}' > "$PROBE"

NATIVE_PROBE="$(cygpath -w "$PROBE")"   # C:\...\probe dir\transcript.jsonl
contains "cygpath -w produced a native path" "\\" "$NATIVE_PROBE"

CONVERTED="$(cc_path "$NATIVE_PROBE")"
check "converted path is readable"      "yes" "$([ -f "$CONVERTED" ] && echo yes || echo no)"
check "converted path reads the file"   '{"probe":true}' "$(cat "$CONVERTED" 2>/dev/null)"
check "already-POSIX path unchanged"    "$PROBE" "$(cc_path "$PROBE")"

# The mixed spelling is what goes back into settings.json: bash must open it too.
MIXED="$(cc_native_path "$PROBE")"
contains "cc_native_path uses forward slashes" "/" "$MIXED"
case "$MIXED" in
  *\\*) bad "cc_native_path has no backslash" "no backslash" "$MIXED" ;;
  *)    ok  "cc_native_path has no backslash" ;;
esac
check "mixed path is readable by bash"  "yes" "$([ -f "$MIXED" ] && echo yes || echo no)"

# ── 2. The Stop hook fed a native transcript path ────────────────────────────
# This is the failure the whole port exists for: Claude Code hands the hook
# "C:\Users\...\x.jsonl" and bash cannot open it.
echo ""
echo "Stop hook with a native transcript_path"

export CLAUDE_CONFIG_DIR="${TMPROOT}/config"
DB_PATH="${CLAUDE_CONFIG_DIR}/claude-carbon/carbon.db"
mkdir -p "${CLAUDE_CONFIG_DIR}/claude-carbon"

sqlite3 "$DB_PATH" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"

PROJ="${TMPROOT}/myproj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main 2>/dev/null || { git -C "$PROJ" init -q; git -C "$PROJ" checkout -q -b main; }

SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="${TMPROOT}/session.jsonl"
cat > "$TRANSCRIPT" <<EOF
{"type":"user","cwd":"${PROJ}","gitBranch":"main","sessionId":"${SESSION}","message":{"role":"user","content":"go"}}
{"type":"assistant","cwd":"${PROJ}","gitBranch":"main","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100000,"output_tokens":5000}}}
EOF

# Exactly the spelling Claude Code uses: native, backslash-separated, both fields.
NATIVE_TRANSCRIPT="$(cygpath -w "$TRANSCRIPT")"
NATIVE_CWD="$(cygpath -w "$PROJ")"

jq -n --arg s "$SESSION" --arg t "$NATIVE_TRANSCRIPT" --arg c "$NATIVE_CWD" \
  '{session_id: $s, transcript_path: $t, cwd: $c}' \
  | bash "${REPO_DIR}/scripts/persist-session.sh"

ROW="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION}';")"
check "row persisted from a native path" "1" "$ROW"
check "output tokens captured"           "5000"   "$(sqlite3 "$DB_PATH" "SELECT output_tokens FROM sessions WHERE session_id='${SESSION}';")"
check "cache reads captured"             "100000" "$(sqlite3 "$DB_PATH" "SELECT cache_read_tokens FROM sessions WHERE session_id='${SESSION}';")"
check "project derived from native cwd"  "myproj" "$(sqlite3 "$DB_PATH" "SELECT project FROM sessions WHERE session_id='${SESSION}';")"
check "branch captured"                  "main"   "$(sqlite3 "$DB_PATH" "SELECT git_branch FROM sessions WHERE session_id='${SESSION}';")"

CO2="$(sqlite3 "$DB_PATH" "SELECT CAST(co2_grams AS INT) > 0 FROM sessions WHERE session_id='${SESSION}';")"
check "CO2 computed"                     "1" "$CO2"

# ── 3. The status line fed a native current_dir ──────────────────────────────
echo ""
echo "status line with a native workspace.current_dir"

SL_OUT="$(jq -n --arg s "$SESSION" --arg d "$NATIVE_CWD" \
  '{session_id: $s, model: {id: "claude-opus-5", display_name: "Opus 5"},
    context_window: {total_input_tokens: 10000, total_output_tokens: 5000, used_percentage: 20},
    cost: {total_cost_usd: 1.5}, workspace: {current_dir: $d}}' \
  | bash "${REPO_DIR}/scripts/statusline.sh")"

contains "project name resolved"  "myproj"  "$SL_OUT"
contains "cost rendered"          "\$1.50"  "$SL_OUT"
contains "CO2 rendered"           "CO₂"     "$SL_OUT"
# The DB row exists, so the status line must report the stored session total rather
# than the context-window fallback. Anything under a gram would mean it fell back.
case "$SL_OUT" in
  *" 0g CO₂"*) bad "status line read the stored row" "a non-zero total" "$SL_OUT" ;;
  *)           ok  "status line read the stored row" ;;
esac

# ── 4. Hook wiring the way Claude Code spawns it ─────────────────────────────
# Shell form: Claude Code substitutes the placeholder into the command string and
# hands the whole string to Git Bash. Reproduce that with a native plugin root,
# which is what broke before the manifests quoted the placeholder.
echo ""
echo "hook manifests spawn correctly from a native CLAUDE_PLUGIN_ROOT"

NATIVE_ROOT="$(cygpath -w "$REPO_DIR")"

spawn_like_claude_code() { # spawn_like_claude_code <command template>
  local template="$1" resolved
  resolved="${template//\$\{CLAUDE_PLUGIN_ROOT\}/$NATIVE_ROOT}"
  CLAUDE_PLUGIN_ROOT="$NATIVE_ROOT" bash -c "$resolved" 2>&1
}

STOP_TEMPLATE="$(jq -r '.hooks.Stop[0].hooks[0].command' "${REPO_DIR}/hooks/hooks.json")"
START_TEMPLATE="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "${REPO_DIR}/hooks/hooks.json")"
SL_TEMPLATE="$(jq -r '.statusLine.command' "${REPO_DIR}/.claude-plugin/plugin.json")"

# The Stop hook is silent by contract, so "found and ran" means no shell error.
STOP_ERR="$(printf '{}' | spawn_like_claude_code "$STOP_TEMPLATE")"
case "$STOP_ERR" in
  *"No such file"*|*"command not found"*|*"cannot execute"*)
    bad "Stop hook found from a native plugin root" "no shell error" "$STOP_ERR" ;;
  *) ok "Stop hook found from a native plugin root" ;;
esac

START_ERR="$(printf '{}' | spawn_like_claude_code "$START_TEMPLATE")"
case "$START_ERR" in
  *"No such file"*|*"command not found"*|*"cannot execute"*)
    bad "SessionStart hook found from a native plugin root" "no shell error" "$START_ERR" ;;
  *) ok "SessionStart hook found from a native plugin root" ;;
esac

SL_SPAWNED="$(jq -n --arg d "$NATIVE_CWD" \
  '{session_id: "none", model: {id: "claude-sonnet-5", display_name: "Sonnet 5"},
    context_window: {total_input_tokens: 1000, total_output_tokens: 100, used_percentage: 5},
    cost: {total_cost_usd: 0.25}, workspace: {current_dir: $d}}' \
  | spawn_like_claude_code "$SL_TEMPLATE")"
contains "status line runs from a native plugin root" "CO₂" "$SL_SPAWNED"

# ── 5. What configure-settings.sh writes back ────────────────────────────────
echo ""
echo "settings.json wiring"

export CLAUDE_CONFIG_DIR="${TMPROOT}/config2"
mkdir -p "$CLAUDE_CONFIG_DIR"
bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1

SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
check "settings.json created" "yes" "$([ -f "$SETTINGS" ] && echo yes || echo no)"

WRITTEN_SL="$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)"
# Claude Code's status line docs: a backslash in the command string is eaten by Git
# Bash and the command fails with no visible error. Forward slashes only.
case "$WRITTEN_SL" in
  *\\*) bad "statusLine path has no backslash" "no backslash" "$WRITTEN_SL" ;;
  *)    ok  "statusLine path has no backslash" ;;
esac
check "statusLine path is openable" "yes" "$([ -f "$WRITTEN_SL" ] && echo yes || echo no)"

WRITTEN_STOP="$(jq -r '.hooks.Stop[0].hooks[0].command // ""' "$SETTINGS" 2>/dev/null)"
check "Stop hook path is openable"  "yes" "$([ -f "$WRITTEN_STOP" ] && echo yes || echo no)"

# Rerunning must not register a second copy of anything, even though the path was
# written in the mixed spelling and normalize_cmd resolves it through `cd`+`pwd -P`.
bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1
check "idempotent: one Stop hook"        "1" "$(jq '[.hooks.Stop[]?.hooks[]?] | length' "$SETTINGS")"
check "idempotent: one SessionStart hook" "1" "$(jq '[.hooks.SessionStart[]?.hooks[]?] | length' "$SETTINGS")"

# The regression that hid behind a passing idempotence check: when another tool's
# hook sits AFTER ours in the same event, ours comes back from jq with a trailing
# carriage return and stops matching itself, so every run appends another copy. Our
# hook being last is the case that accidentally works, so put a foreign one after it.
echo ""
echo "dedupe survives a foreign hook sitting after ours"

CFG3="${TMPROOT}/config3"
mkdir -p "$CFG3"
NATIVE_SCRIPTS="$(cc_native_path "${REPO_DIR}/scripts")"
cat > "${CFG3}/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "${NATIVE_SCRIPTS}/safety-rescan.sh"}]},
      {"matcher": "", "hooks": [{"type": "command", "command": "/opt/other/start.sh"}]}
    ]
  }
}
EOF

CLAUDE_CONFIG_DIR="$CFG3" bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$CFG3" bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1

OURS_COUNT="$(jq -r --arg c "${NATIVE_SCRIPTS}/safety-rescan.sh" \
  '[.hooks.SessionStart[]?.hooks[]?.command | select(. == $c)] | length' "${CFG3}/settings.json")"
check "our hook not duplicated when it is not last" "1" "$OURS_COUNT"
check "the foreign hook survives" "1" \
  "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(. == "/opt/other/start.sh")] | length' "${CFG3}/settings.json")"

# ── 6. Slash commands: copies, and refreshed on update ───────────────────────
echo ""
echo "slash commands are copied and stay current"

CMD="${CLAUDE_CONFIG_DIR}/commands/carbon-report.md"
check "command installed"      "yes" "$([ -f "$CMD" ] && echo yes || echo no)"
check "installed as a copy"    "no"  "$([ -L "$CMD" ] && echo yes || echo no)"
check "content matches source" "yes" "$(cmp -s "${REPO_DIR}/skills/carbon-report/SKILL.md" "$CMD" && echo yes || echo no)"

# Simulate the copy going stale after an update, the way it would if the clone moved
# forward while the command file stayed behind.
printf '%s\n' "stale claude-carbon copy" > "$CMD"
bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1
check "stale copy refreshed"   "yes" "$(cmp -s "${REPO_DIR}/skills/carbon-report/SKILL.md" "$CMD" && echo yes || echo no)"

# A command the user wrote themselves carries no claude-carbon marker and must survive.
USER_CMD="${CLAUDE_CONFIG_DIR}/commands/carbon-badge.md"
printf '%s\n' "my own command, hands off" > "$USER_CMD"
bash "${REPO_DIR}/scripts/configure-settings.sh" >/dev/null 2>&1
check "user-written command untouched" "my own command, hands off" "$(cat "$USER_CMD")"

# ── 7. cc_tmpdir survives a native TMPDIR ────────────────────────────────────
echo ""
echo "cc_tmpdir with a native TMPDIR"

NATIVE_TMP="$(cygpath -w "$TMPROOT")"
RESOLVED="$(TMPDIR="$NATIVE_TMP" bash -c ". '${REPO_DIR}/scripts/portable-lib.sh'; cc_tmpdir")"
check "native TMPDIR resolves to a usable dir" "yes" "$([ -d "$RESOLVED" ] && echo yes || echo no)"
check "mktemp works under it" "yes" \
  "$(f="$(mktemp "${RESOLVED}/cc-probe.XXXXXX" 2>/dev/null)" && [ -f "$f" ] && rm -f "$f" && echo yes || echo no)"

echo ""
echo "─────────────────────────────"
echo "passed: ${PASSED}   failed: ${FAILED}"
[ "$FAILED" -eq 0 ] || exit 1
echo "All ${PASSED} Windows end-to-end assertions passed."
