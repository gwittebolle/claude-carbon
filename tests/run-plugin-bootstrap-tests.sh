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

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
