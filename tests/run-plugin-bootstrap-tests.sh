#!/usr/bin/env bash
# run-plugin-bootstrap-tests.sh: assert what the SessionStart hook (scripts/safety-rescan.sh)
# does when there is no database yet, the case of the plugin installed alone: it creates
# the database once with the history found on disk, announces nothing on stdout, and stays
# out of the way when CLAUDE_CARBON_DB is set, when CLAUDE_CARBON_NO_AUTOSETUP is set,
# when the folder was already set up once, and when jq or sqlite3 is missing. An existing
# database is never touched by that path.
#
# Runs under a temp root; the real ~/.claude is never read.
# bash 3.2 compatible (macOS default). Dependencies: jq, sqlite3.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
for CMD in jq sqlite3; do
  command -v "$CMD" >/dev/null 2>&1 || { echo "FAIL: $CMD is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-bootstrap-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

cleanup() {
  case "$TMPROOT" in
    */claude-carbon-bootstrap-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"
  fi
}

HOOK="${REPO_DIR}/scripts/safety-rescan.sh"
SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# A config folder with one past session on disk and no claude-carbon folder
new_config() {
  mkdir -p "$1/projects/-tmp-bootproj"
  cat >"$1/projects/-tmp-bootproj/${SESSION}.jsonl" <<JSONL
{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","sessionId":"${SESSION}","cwd":"/tmp/bootproj","message":{"role":"user","content":"hi"}}
{"type":"assistant","timestamp":"2026-10-01T10:00:05.000Z","sessionId":"${SESSION}","cwd":"/tmp/bootproj","requestId":"req_1","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL
}
start() { # $1 = config dir, rest = extra env assignments
  local cfg="$1"
  shift
  # No release check: with a database the hook would ask GitHub for the tags
  printf '{}' | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_AUTOSETUP CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 \
    CLAUDE_CONFIG_DIR="$cfg" "$@" bash "$HOOK"
}
rows() { sqlite3 "$1" "SELECT COUNT(*) FROM sessions;" 2>/dev/null; }
wait_rows() { # $1 = db: until the detached backfill has written the session
  local i=0
  while [ "$(rows "$1")" != "1" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
}

# ------------------------------------------------ 1. no database, dependencies present
CFG="${TMPROOT}/cfg1"
new_config "$CFG"
OUT="$(start "$CFG" 2>&1)"
check "first start: exit 0" "$?" "0"
check "first start: nothing printed" "$OUT" ""
wait_rows "${CFG}/claude-carbon/carbon.db"
check "first start: the past session is recorded" "$(rows "${CFG}/claude-carbon/carbon.db")" "1"
check "first start: sentinel written" "$([ -f "${CFG}/claude-carbon/auto-setup" ] && echo yes)" "yes"
check "first start: no dependency marker" "$([ -f "${CFG}/claude-carbon/setup-needed" ] && echo yes)" ""

# The Stop hook then records live
PAYLOAD="$(jq -n --arg s "$SESSION" --arg t "${CFG}/projects/-tmp-bootproj/${SESSION}.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp/bootproj", hook_event_name: "Stop"}')"
echo "$PAYLOAD" | env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/persist-session.sh"
check "Stop hook after the creation: session row present" "$(sqlite3 "${CFG}/claude-carbon/carbon.db" "SELECT output_tokens FROM sessions WHERE session_id='${SESSION}';")" "100"

# ------------------------------------------------ 2. deleted on purpose: not brought back
rm -f "${CFG}/claude-carbon/carbon.db"
start "$CFG" >/dev/null 2>&1
sleep 1
check "deleted database: not recreated" "$([ -f "${CFG}/claude-carbon/carbon.db" ] && echo yes)" ""

# ------------------------------------------------ 3. CLAUDE_CARBON_DB set to a missing file
CFG="${TMPROOT}/cfg3"
new_config "$CFG"
start "$CFG" CLAUDE_CARBON_DB="${TMPROOT}/elsewhere/carbon.db" >/dev/null 2>&1
sleep 1
check "custom path missing: nothing at the custom path" "$([ -e "${TMPROOT}/elsewhere" ] && echo yes)" ""
check "custom path missing: nothing at the default path" "$([ -e "${CFG}/claude-carbon" ] && echo yes)" ""

# ------------------------------------------------ 4. opt-out
CFG="${TMPROOT}/cfg4"
new_config "$CFG"
start "$CFG" CLAUDE_CARBON_NO_AUTOSETUP=1 >/dev/null 2>&1
sleep 1
check "opt-out: nothing created" "$([ -e "${CFG}/claude-carbon" ] && echo yes)" ""

# ------------------------------------------------ 5. sqlite3 missing, then present
# A PATH holding every tool the hook calls but sqlite3. Not under Git Bash, where a
# symlink is a copy and a copied tool does not find its DLLs.
CFG="${TMPROOT}/cfg5"
new_config "$CFG"
if [ "$CC_OS" != "windows" ]; then
  TOOLS="${TMPROOT}/tools"
  mkdir -p "$TOOLS"
  for t in cat dirname mkdir rm uname tr jq touch date nohup; do
    src="$(command -v "$t" 2>/dev/null)"
    case "$src" in /*) ln -s "$src" "${TOOLS}/${t}" ;; esac
  done
  printf '{}' | env -i HOME="${TMPROOT}/home5" CLAUDE_CONFIG_DIR="$CFG" PATH="$TOOLS" "$(command -v bash)" "$HOOK" >/dev/null 2>&1
  check "sqlite3 missing: exit 0" "$?" "0"
  check "sqlite3 missing: marker names it" "$(cat "${CFG}/claude-carbon/setup-needed" 2>/dev/null)" "sqlite3"
  check "sqlite3 missing: no database" "$([ -f "${CFG}/claude-carbon/carbon.db" ] && echo yes)" ""
  check "sqlite3 missing: no sentinel, so the next start retries" "$([ -f "${CFG}/claude-carbon/auto-setup" ] && echo yes)" ""
else
  mkdir -p "${CFG}/claude-carbon"
  echo sqlite3 >"${CFG}/claude-carbon/setup-needed"
fi
start "$CFG" >/dev/null 2>&1
wait_rows "${CFG}/claude-carbon/carbon.db"
check "sqlite3 back: database created" "$(rows "${CFG}/claude-carbon/carbon.db")" "1"
check "sqlite3 back: marker removed" "$([ -f "${CFG}/claude-carbon/setup-needed" ] && echo yes)" ""

# ------------------------------------------------ 6. an existing database is left alone
CFG="${TMPROOT}/cfg6"
new_config "$CFG"
mkdir -p "${CFG}/claude-carbon"
DB="${CFG}/claude-carbon/carbon.db"
sqlite3 "$DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, co2_grams REAL, started_at TEXT, frozen INTEGER DEFAULT 0); INSERT INTO sessions VALUES ('old', 42.5, '2026-01-01T00:00:00Z', 1);"
touch "${CFG}/claude-carbon/.last-rescan" # the daily rescan already ran: only the new path could act
start "$CFG" >/dev/null 2>&1
sleep 1
check "existing database: frozen row unchanged" "$(sqlite3 "$DB" "SELECT session_id, co2_grams, frozen FROM sessions WHERE session_id='old';")" "old|42.5|1"
check "existing database: no sentinel" "$([ -f "${CFG}/claude-carbon/auto-setup" ] && echo yes)" ""

# ------------------------------------------------ 7. two sessions starting together
# A copy of the scripts whose backfill only counts its launches: one of the two starts
# gets the sentinel, the other leaves.
CFG="${TMPROOT}/cfg7"
new_config "$CFG"
FAKE="${TMPROOT}/scripts7"
mkdir -p "$FAKE"
cp "${REPO_DIR}/scripts/safety-rescan.sh" "${REPO_DIR}/scripts/portable-lib.sh" "$FAKE/"
printf '#!/usr/bin/env bash\necho launched >>"%s"\n' "${TMPROOT}/launches7" >"${FAKE}/backfill.sh"
for _ in 1 2 3 4; do
  printf '{}' | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_AUTOSETUP CLAUDE_CONFIG_DIR="$CFG" bash "${FAKE}/safety-rescan.sh" >/dev/null 2>&1 &
done
wait
i=0
while [ ! -s "${TMPROOT}/launches7" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 1
check "concurrent starts: one backfill launched" "$(wc -l <"${TMPROOT}/launches7" | tr -d ' ')" "1"
check "sentinel holds a mark" "$(cat "${CFG}/claude-carbon/auto-setup")" "1"

# ------------------------------------------------ 8. the plugin's status line
# Claude Code ignores a plugin's statusLine: the hook, run as the plugin (CLAUDE_PLUGIN_ROOT
# names its folder), keeps a fixed script that runs the current copy's status line, and
# points settings.json at it once, only when no status line is set.
plugin_copy() { # $1 = config dir, $2 = version: a copy of the plugin in Claude Code's cache
  local p="$1/plugins/cache/claude-carbon/claude-carbon/$2"
  mkdir -p "$p"
  cp -R "${REPO_DIR}/scripts" "${REPO_DIR}/data" "${REPO_DIR}/.claude-plugin" "$p/"
  printf '%s' "$p"
}
plugin_start() { # $1 = config dir, $2 = plugin root, rest = extra env assignments
  local cfg="$1" root="$2"
  shift 2
  printf '{}' | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_STATUSLINE CLAUDE_CARBON_NO_AUTOSETUP=1 \
    CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 CLAUDE_CONFIG_DIR="$cfg" CLAUDE_PLUGIN_ROOT="$root" "$@" \
    bash "${root}/scripts/safety-rescan.sh"
}
sl_command() { jq -r '.statusLine.command // ""' "$1/settings.json" 2>/dev/null | tr -d '\r'; }
# The command as the hook writes it: the native path, in double quotes on Windows
sl_expected() {
  local c
  c="$(cc_native_path "$1/claude-carbon/statusline.sh")"
  if cc_is_windows; then printf '"%s"' "$c"; else printf '%s' "${c// /\\ }"; fi
}

CFG="${TMPROOT}/sl1"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
printf '{"permissions": {"allow": ["Bash(ls:*)"]}}\n' >"${CFG}/settings.json"
OUT="$(plugin_start "$CFG" "$P1" 2>&1)"
check "plugin status line: nothing printed" "$OUT" ""
check "plugin status line: set in settings.json" "$(sl_command "$CFG")" "$(sl_expected "$CFG")"
check "plugin status line: other settings kept" "$(jq -c '.permissions.allow' "${CFG}/settings.json" | tr -d '\r')" '["Bash(ls:*)"]'
check "plugin status line: decision recorded" "$(cat "${CFG}/claude-carbon/statusline-set")" "set"
check "plugin status line: the script is executable" "$([ -x "${CFG}/claude-carbon/statusline.sh" ] && echo yes)" "yes"
check "plugin status line: plugin-root names this copy" "$(cat "${CFG}/claude-carbon/plugin-root")" "$(cc_native_path "$P1")"

# The script runs that copy's status line
SL_IN='{"session_id":"sl","model":{"id":"claude-opus-5","display_name":"Opus 5"},"cost":{"total_cost_usd":0.5},"workspace":{"current_dir":"/tmp/slproj"},"context_window":{"total_input_tokens":1000}}'
SL_OUT="$(printf '%s' "$SL_IN" | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 bash "${CFG}/claude-carbon/statusline.sh" 2>/dev/null)"
check "plugin status line: the script draws the status line" "$(printf '%s' "$SL_OUT" | grep -c 'gCO₂')" "1"

# Removed by the person afterwards: never put back
jq 'del(.statusLine)' "${CFG}/settings.json" >"${CFG}/s.tmp" && mv "${CFG}/s.tmp" "${CFG}/settings.json"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
check "plugin status line: a removed one is not put back" "$(sl_command "$CFG")" ""

# A new version: plugin-root follows it, settings.json is not rewritten
CFG="${TMPROOT}/sl2"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
printf '\n' >>"${CFG}/settings.json"
SIZE="$(wc -c <"${CFG}/settings.json" | tr -d ' ')"
P2="$(plugin_copy "$CFG" 1.21.0)"
plugin_start "$CFG" "$P2" >/dev/null 2>&1
check "new version: plugin-root follows it" "$(cat "${CFG}/claude-carbon/plugin-root")" "$(cc_native_path "$P2")"
check "new version: settings.json left as it is" "$(wc -c <"${CFG}/settings.json" | tr -d ' ')" "$SIZE"

# No settings.json yet: created with the status line alone
CFG="${TMPROOT}/sl3"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
check "no settings.json: created with the status line" "$(sl_command "$CFG")" "$(sl_expected "$CFG")"
check "no settings.json: nothing else in it" "$(jq -c 'keys' "${CFG}/settings.json" | tr -d '\r')" '["statusLine"]'

# Another tool's status line: left alone, and the decision kept
CFG="${TMPROOT}/sl4"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
printf '{"statusLine": {"type": "command", "command": "npx -y ccstatusline@latest"}}\n' >"${CFG}/settings.json"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
check "another status line: left alone" "$(sl_command "$CFG")" "npx -y ccstatusline@latest"
check "another status line: decision recorded" "$(cat "${CFG}/claude-carbon/statusline-set")" "skipped"
jq 'del(.statusLine)' "${CFG}/settings.json" >"${CFG}/s.tmp" && mv "${CFG}/s.tmp" "${CFG}/settings.json"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
check "another status line removed later: ours is not added" "$(sl_command "$CFG")" ""

# Not a JSON object: untouched, and looked at again next time
CFG="${TMPROOT}/sl5"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
printf '[1, 2]\n' >"${CFG}/settings.json"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
check "not an object: left as it was" "$(tr -d '\r' <"${CFG}/settings.json")" "[1, 2]"
check "not an object: no decision recorded" "$([ -f "${CFG}/claude-carbon/statusline-set" ] && echo yes)" ""

# CLAUDE_CARBON_NO_STATUSLINE: no status line, the script is still kept up to date
CFG="${TMPROOT}/sl6"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
plugin_start "$CFG" "$P1" CLAUDE_CARBON_NO_STATUSLINE=1 >/dev/null 2>&1
check "opt-out: no settings.json written" "$([ -f "${CFG}/settings.json" ] && echo yes)" ""
check "opt-out: no decision recorded" "$([ -f "${CFG}/claude-carbon/statusline-set" ] && echo yes)" ""
check "opt-out: the script is there" "$([ -f "${CFG}/claude-carbon/statusline.sh" ] && echo yes)" "yes"

# Not the plugin: a clone's hook (no CLAUDE_PLUGIN_ROOT, or one naming another folder)
CFG="${TMPROOT}/sl7"
new_config "$CFG"
start "$CFG" CLAUDE_CARBON_NO_AUTOSETUP=1 >/dev/null 2>&1
check "clone hook: no status line written" "$([ -f "${CFG}/settings.json" ] && echo yes)" ""
check "clone hook: no plugin-root" "$([ -f "${CFG}/claude-carbon/plugin-root" ] && echo yes)" ""
P1="$(plugin_copy "$CFG" 1.20.0)"
printf '{}' | env -u CLAUDE_CARBON_DB CLAUDE_CARBON_NO_AUTOSETUP=1 CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 \
  CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$P1" bash "$HOOK" >/dev/null 2>&1
check "another folder's CLAUDE_PLUGIN_ROOT: nothing written" "$([ -f "${CFG}/claude-carbon/plugin-root" ] && echo yes)" ""

# The script when the copy it names is gone: the newest copy beside it, else nothing
CFG="${TMPROOT}/sl8"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
plugin_start "$CFG" "$P1" CLAUDE_CARBON_NO_STATUSLINE=1 >/dev/null 2>&1
CACHE="${CFG}/plugins/cache/claude-carbon/claude-carbon"
for V in 1.9.0 1.21.0; do
  mkdir -p "${CACHE}/${V}/scripts"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "copy %s"\n' "$V" >"${CACHE}/${V}/scripts/statusline.sh"
done
rm -rf "$P1"
check "copy gone: the newest one beside it runs" "$(printf '{}' | bash "${CFG}/claude-carbon/statusline.sh")" "copy 1.21.0"
rm -rf "$CACHE"
check "plugin uninstalled: prints nothing" "$(printf '{}' | bash "${CFG}/claude-carbon/statusline.sh"; echo "rc=$?")" "rc=0"

# The plugin's own update flag: the status line run from the plugin names the new version
CFG="${TMPROOT}/sl9"
mkdir -p "$CFG"
P1="$(plugin_copy "$CFG" 1.20.0)"
plugin_start "$CFG" "$P1" >/dev/null 2>&1
printf '{"behind":true,"local":"1.20.0","remote":"1.21.0","checked_at":%s}\n' "$(date +%s)" \
  >"${CFG}/claude-carbon/plugin-update-check.json"
SL_OUT="$(printf '%s' "$SL_IN" | env -u CLAUDE_CARBON_NO_UPDATE_NOTIFIER CLAUDE_CONFIG_DIR="$CFG" \
  bash "${CFG}/claude-carbon/statusline.sh" 2>/dev/null)"
check "plugin update flag: the status line names the new version" \
  "$(printf '%s' "$SL_OUT" | grep -c '1.21.0 /carbon-update')" "1"
# The update applied since: the new copy runs, the flag still says 1.20.0 is behind
P2="$(plugin_copy "$CFG" 1.21.0)"
plugin_start "$CFG" "$P2" >/dev/null 2>&1
SL_OUT="$(printf '%s' "$SL_IN" | env -u CLAUDE_CARBON_NO_UPDATE_NOTIFIER CLAUDE_CONFIG_DIR="$CFG" \
  bash "${CFG}/claude-carbon/statusline.sh" 2>/dev/null)"
check "plugin update flag, update applied: no notice" \
  "$(printf '%s' "$SL_OUT" | grep -c '/carbon-update')" "0"

# settings.json behind a link (a dotfiles folder): the link is kept, nothing decided yet
if ! cc_is_windows; then
  CFG="${TMPROOT}/sl10"
  mkdir -p "$CFG" "${TMPROOT}/dotfiles"
  P1="$(plugin_copy "$CFG" 1.20.0)"
  printf '{"model": "opus"}\n' >"${TMPROOT}/dotfiles/settings.json"
  ln -s "${TMPROOT}/dotfiles/settings.json" "${CFG}/settings.json"
  plugin_start "$CFG" "$P1" >/dev/null 2>&1
  check "linked settings.json: the link is kept" "$([ -L "${CFG}/settings.json" ] && echo yes)" "yes"
  check "linked settings.json: its target untouched" "$(jq -c . "${TMPROOT}/dotfiles/settings.json")" '{"model":"opus"}'
  check "linked settings.json: no decision recorded" "$([ -f "${CFG}/claude-carbon/statusline-set" ] && echo yes)" ""

  # Its permissions are kept
  CFG="${TMPROOT}/sl11"
  mkdir -p "$CFG"
  P1="$(plugin_copy "$CFG" 1.20.0)"
  printf '{"model": "opus"}\n' >"${CFG}/settings.json"
  chmod 600 "${CFG}/settings.json"
  plugin_start "$CFG" "$P1" >/dev/null 2>&1
  check "permissions: status line set" "$(sl_command "$CFG")" "$(sl_expected "$CFG")"
  check "permissions: kept" "$(ls -l "${CFG}/settings.json" | cut -c1-10)" "-rw-------"

  # Read-only: left alone, nothing printed, nothing decided
  CFG="${TMPROOT}/sl12"
  mkdir -p "$CFG"
  P1="$(plugin_copy "$CFG" 1.20.0)"
  printf '{"model": "opus"}\n' >"${CFG}/settings.json"
  chmod 444 "${CFG}/settings.json"
  OUT="$(plugin_start "$CFG" "$P1" 2>&1)"
  check "read-only settings.json: nothing printed" "$OUT" ""
  check "read-only settings.json: untouched" "$(jq -c . "${CFG}/settings.json")" '{"model":"opus"}'
  check "read-only settings.json: no decision recorded" "$([ -f "${CFG}/claude-carbon/statusline-set" ] && echo yes)" ""
  chmod 644 "${CFG}/settings.json"

  # A config folder with a space: the command runs in a shell, the space is escaped
  CFG="${TMPROOT}/with space"
  mkdir -p "$CFG"
  P1="$(plugin_copy "$CFG" 1.20.0)"
  plugin_start "$CFG" "$P1" >/dev/null 2>&1
  check "space in the path: escaped" "$(sl_command "$CFG")" "$(sl_expected "$CFG")"
  check "space in the path: the command runs" \
    "$(printf '%s' "$SL_IN" | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 \
      bash -c "$(sl_command "$CFG")" 2>/dev/null | grep -c 'gCO₂')" "1"
fi

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
