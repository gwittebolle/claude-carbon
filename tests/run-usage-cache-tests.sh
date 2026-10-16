#!/usr/bin/env bash
# run-usage-cache-tests.sh: the per-agent usage cache (cc_session_usage) changes no figure
# and keeps no stale one. Assert that:
#   1. what a cache entry holds and CC_USAGE_CACHE_VERSION move together;
#   2. without the cache, with it cold and with it warm, the lines are the same, on
#      sessions with subagents, workflow agents, a model switch, an empty agent and an
#      agent cut mid-line;
#   3. a warm pass reads the main transcript and the changed agents only, and leaves the
#      cache file alone when no agent changed;
#   4. an agent changed in the same second (another size), replaced by a file of the same
#      size and mtime (another inode), rewritten in place to the same size, mtime and
#      inode (another ctime), or reached through a symlink whose target grew, is read
#      again; one with a cut line, or outside the session's folder, is never kept;
#   5. a cache that does not parse, has entries of the wrong shape, or gives file lines
#      that do not merge, is ignored and rewritten from a full read;
#   6. a stat that does not answer as expected, CLAUDE_CARBON_NO_USAGE_CACHE=1, and a
#      caller that did not ask for the cache, write nothing;
#   7. a file that disappears after its stat fails the pass and is not kept;
#   8. two Stop hooks at once leave a cache that parses and the right row;
#   9. the rescan removes cache files unused for 45 days and orphaned temporary files.
#
# Throwaway dirs only (CLAUDE_CONFIG_DIR, CC_USAGE_CACHE_DIR under a temp root); the real
# ~/.claude is never read or written. bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"
BACKFILL="${REPO_DIR}/scripts/backfill.sh"
FACTORS="${REPO_DIR}/data/factors.json"
PRICES="${REPO_DIR}/data/prices.json"

for c in sqlite3 jq awk cksum; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-usage-cache-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-usage-cache-tests.*) chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
# has <text> <output>: yes when the output contains the text (a function: bash 3.2 reads
# the ) of a case pattern inside $( ) as the end of the substitution)
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
check() {
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1)); echo "PASS $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"
  fi
}

# ---------------------------------------------------------------- 1. what an entry holds
# A cache entry is what CC_JQ_FILE_USAGE makes of a file, as cc_usage_read (and the
# re-reads of cc_redo_neighbours) feed it, in the shape CC_AWK_USAGE_ENTRIES writes and
# CC_AWK_USAGE_CACHE reads. Change any of them and old entries would merge with new ones:
# add a line below with a new version, set CC_USAGE_CACHE_VERSION to it, never edit a line.
HISTORY="1:2091254546"
FINGERPRINT="$( { printf '%s' "$CC_JQ_FILE_USAGE" "$CC_AWK_USAGE_ENTRIES" "$CC_AWK_USAGE_CACHE"
                  awk '/^cc_usage_read\(\) \{/,/^}/ { print } /^cc_redo_neighbours\(\) \{/,/^}/ { print }' "${REPO_DIR}/scripts/portable-lib.sh"
                } | tr -d '\r' | cksum | awk '{ print $1 }')"
LAST="$(printf '%s\n' $HISTORY | tail -n 1)"
check "the cache's code matches the last version of the history (a new line if not)" "${CC_USAGE_CACHE_VERSION}:${FINGERPRINT}" "$LAST"
check "versions increase, fingerprints never repeat" "ok" \
  "$(printf '%s\n' $HISTORY | awk -F: '{ if ($1 + 0 <= last || seen[$2]++) bad = 1; last = $1 + 0 } END { print bad ? "no" : "ok" }')"

# ---------------------------------------------------------------- fixtures
CFG="${TMPROOT}/cfg"
PROJ="${CFG}/projects/-tmp-cacheproj"
CACHE="${CFG}/claude-carbon/usage-cache"
DB="${CFG}/claude-carbon/carbon.db"
mkdir -p "$PROJ" "${CFG}/claude-carbon"
sqlite3 "$DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0);"
q() { sqlite3 "$DB" "$1" 2>/dev/null; }
# msg <id> <model> <input> <cache write> <cache read> <output>
msg() {
  printf '{"type":"assistant","requestId":"r%s","timestamp":"2026-10-15T10:00:%02dZ","gitBranch":"main","cwd":"/tmp/cacheproj","message":{"id":"m%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s},"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$1" "$(( ${#1} % 60 ))" "$1" "$2" "$3" "$4" "$4" "$5" "$6"
}
# make_session <sid>: a main transcript with a model switch, two subagents, two workflow
# agents, an empty agent and one cut mid-line
make_session() {
  local s="$1" d="${PROJ}/$1/subagents"
  mkdir -p "$d/workflows/wf_one"
  { echo '{"type":"user","cwd":"/tmp/cacheproj","gitBranch":"main","message":{"role":"user","content":"go"}}'
    msg "0$s" claude-opus-5-5 100 2000 30000 400
    msg "1$s" claude-sonnet-4-6 50 0 10000 100; } > "${PROJ}/$s.jsonl"
  msg "2$s" claude-haiku-4-5 500 0 5000 50 > "$d/agent-a.jsonl"
  { msg "3$s" claude-sonnet-5-5 700 100 20000 70; msg "3$s" claude-sonnet-5-5 700 100 20000 90; } > "$d/agent-b.jsonl"
  msg "4$s" claude-opus-5-5 0 10000 100000 1000 > "$d/workflows/wf_one/agent-c.jsonl"
  msg "5$s" claude-opus-5-5 0 3000 40000 300 > "$d/workflows/wf_one/agent-d.jsonl"
  : > "$d/agent-empty.jsonl"
  { msg "6$s" claude-sonnet-5-5 10 0 0 5; printf '%s' '{"type":"assistant","message":{"id":"x'; } > "$d/agent-cut.jsonl"
}
# usage <sid> [cache dir]: cc_session_usage on the session, the cache on when a dir is given
usage() {
  local s="$1"
  cc_collect_subagents "${PROJ}/$s/subagents"
  if [ -n "${2:-}" ]; then
    CC_USAGE_CACHE_DIR="$2" cc_session_usage "$FACTORS" "$PRICES" "${PROJ}/$s.jsonl" ${CC_SUB_FILES[@]+"${CC_SUB_FILES[@]}"}
  else
    cc_session_usage "$FACTORS" "$PRICES" "${PROJ}/$s.jsonl" ${CC_SUB_FILES[@]+"${CC_SUB_FILES[@]}"}
  fi
}
cachefile() { ls "$CACHE"/*"$1"* 2>/dev/null | head -n 1; }
# A jq on PATH that records the transcripts each per-file pass is given
SHIM="${TMPROOT}/shim"
mkdir -p "$SHIM"
REAL_JQ="$(command -v jq)"
cat > "${SHIM}/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in *"--arg main"*)
  prev=""
  for a in "\$@"; do
    [ "\$prev" = "main" ] || case "\$a" in *.jsonl) echo "\${a##*/}" >> "${TMPROOT}/read" ;; esac
    prev="\$a"
  done ;;
esac
exec "${REAL_JQ}" "\$@"
EOF
chmod +x "${SHIM}/jq"
reads() { sort -u "${TMPROOT}/read" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# ---------------------------------------------------------------- 2. same lines
S1="22222222-cccc-0000-0000-000000000001"
make_session "$S1"
NOCACHE="$(usage "$S1")"
COLD="$(usage "$S1" "$CACHE")"
WARM="$(usage "$S1" "$CACHE")"
check "without, cold and warm: the same lines" "yes|yes" \
  "$([ "$NOCACHE" = "$COLD" ] && echo yes || echo no)|$([ "$NOCACHE" = "$WARM" ] && echo yes || echo no)"
check "the lines are not empty" "yes" "$(has "$(printf 'T\t')" "$NOCACHE")"
CF="$(cachefile "$S1")"
check "one cache file, named after the session and the version, every line JSON" "${S1}.v${CC_USAGE_CACHE_VERSION}.jsonl|5" \
  "${CF##*/}|$(jq -c '.p' "$CF" 2>/dev/null | wc -l | tr -d ' ')"
check "the agent with a cut line is not kept" "0" "$(grep -c 'agent-cut' "$CF")"
check "the main transcript is not in it" "0" "$(grep -c "\"p\":\"\\.\\./${S1}.jsonl\"" "$CF")"

# ---------------------------------------------------------------- 3. a warm pass
: > "${TMPROOT}/read"
touch -t 202001010000 "$CF"
BEFORE="$(cc_mtime "$CF")"
WARM="$(PATH="${SHIM}:$PATH" usage "$S1" "$CACHE")"
check "warm: the main transcript and the agent with a cut line only" "${S1}.jsonl agent-cut.jsonl" "$(reads)"
check "warm: same lines, cache file not rewritten" "yes|$BEFORE" "$([ "$NOCACHE" = "$WARM" ] && echo yes || echo no)|$(cc_mtime "$CF")"

# ---------------------------------------------------------------- 4. changed agents
A="${PROJ}/${S1}/subagents/agent-a.jsonl"
cp -p "$A" "${TMPROOT}/a.orig"
msg "7$S1" claude-haiku-4-5 1 0 0 1 >> "$A"
touch -r "${TMPROOT}/a.orig" "$A"
: > "${TMPROOT}/read"
GROWN="$(PATH="${SHIM}:$PATH" usage "$S1" "$CACHE")"
check "same mtime, another size: read again" "${S1}.jsonl agent-a.jsonl agent-cut.jsonl" "$(reads)"
check "and the lines follow" "yes" "$([ "$GROWN" = "$(usage "$S1")" ] && [ "$GROWN" != "$NOCACHE" ] && echo yes || echo no)"
# Same size and mtime, other content, another file: another inode
B="${PROJ}/${S1}/subagents/agent-b.jsonl"
sed 's/"output_tokens":90/"output_tokens":91/' "$B" > "${TMPROOT}/b.new"
touch -r "$B" "${TMPROOT}/b.new"
mv -f "${TMPROOT}/b.new" "$B"
: > "${TMPROOT}/read"
SWAPPED="$(PATH="${SHIM}:$PATH" usage "$S1" "$CACHE")"
check "same size and mtime, another inode: read again" "${S1}.jsonl agent-b.jsonl agent-cut.jsonl" "$(reads)"
check "and the lines follow" "yes" "$([ "$SWAPPED" = "$(usage "$S1")" ] && echo yes || echo no)"
# Rewritten in place: same size, mtime and inode, another content and ctime
C="${PROJ}/${S1}/subagents/workflows/wf_one/agent-c.jsonl"
cp -p "$C" "${TMPROOT}/c.orig"
sleep 1
sed 's/"output_tokens":1000/"output_tokens":1001/' "${TMPROOT}/c.orig" > "${TMPROOT}/c.new"
cat "${TMPROOT}/c.new" > "$C"
touch -r "${TMPROOT}/c.orig" "$C"
: > "${TMPROOT}/read"
INPLACE="$(PATH="${SHIM}:$PATH" usage "$S1" "$CACHE")"
check "same size, mtime and inode, another ctime: read again" "${S1}.jsonl agent-c.jsonl agent-cut.jsonl" "$(reads)"
check "and the lines follow" "yes" "$([ "$INPLACE" = "$(usage "$S1")" ] && echo yes || echo no)"
# An agent reached through a symlink: its target grows, the link does not change
TARGET="${TMPROOT}/elsewhere/agent-l.jsonl"
mkdir -p "${TMPROOT}/elsewhere"
msg "8$S1" claude-sonnet-5-5 100 0 0 10 > "$TARGET"
ln -s "$TARGET" "${PROJ}/${S1}/subagents/agent-l.jsonl" 2>/dev/null
if [ -L "${PROJ}/${S1}/subagents/agent-l.jsonl" ]; then
  usage "$S1" "$CACHE" >/dev/null
  msg "9$S1" claude-sonnet-5-5 100 0 0 10 >> "$TARGET"
  check "a symlinked agent whose target grew: the lines follow" "yes" \
    "$([ "$(usage "$S1" "$CACHE")" = "$(usage "$S1")" ] && echo yes || echo no)"
  rm -f "${PROJ}/${S1}/subagents/agent-l.jsonl"
else
  echo "SKIP symlinked agent: this system makes no symlink"
fi
# An agent outside the session's folder, given by its absolute path: read, never kept
OUTSIDE="${TMPROOT}/elsewhere/agent-o.jsonl"
msg "10$S1" claude-sonnet-5-5 100 0 0 10 > "$OUTSIDE"
cc_collect_subagents "${PROJ}/${S1}/subagents"
CC_USAGE_CACHE_DIR="$CACHE" cc_session_usage "$FACTORS" "$PRICES" "${PROJ}/${S1}.jsonl" "${CC_SUB_FILES[@]}" "$OUTSIDE" >/dev/null
check "an agent outside the session's folder is not kept" "0" "$(grep -c 'agent-o' "$CF")"

# ---------------------------------------------------------------- 5. a cache to ignore
REF="$(usage "$S1")"
printf 'not json at all\n{"p":"subagents/agent-a.jsonl","s":"x","m":1,"i":1,"a":{"f":"subagents/agent-a.jsonl","m":[]}}\n{"p":"subagents/agent-b.jso' > "$CF"
check "garbage, wrong types, a cut line: same lines" "yes" "$([ "$(usage "$S1" "$CACHE")" = "$REF" ] && echo yes || echo no)"
check "rewritten whole" "5" "$(jq -c '.p' "$CF" 2>/dev/null | wc -l | tr -d ' ')"
# Entries with the right keys and stat, but file lines that do not merge
jq -c '.a = {"f": .p, "m": "oops"}' "$CF" > "${TMPROOT}/bad" && cp "${TMPROOT}/bad" "$CF"
check "file lines that do not merge: same lines, from a full read" "yes" "$([ "$(usage "$S1" "$CACHE")" = "$REF" ] && echo yes || echo no)"
check "rewritten whole again" "0" "$(grep -c '"oops"' "$CF")"

# ---------------------------------------------------------------- 6. nothing written
S2="22222222-cccc-0000-0000-000000000002"
make_session "$S2"
# A stat that answers garbage
mkdir -p "${TMPROOT}/badstat"
printf '#!/usr/bin/env bash\necho "not a stat"\n' > "${TMPROOT}/badstat/stat"
chmod +x "${TMPROOT}/badstat/stat"
check "an unexpected stat: same lines, no cache file" "yes|" \
  "$([ "$(PATH="${TMPROOT}/badstat:$PATH" usage "$S2" "$CACHE")" = "$(usage "$S2")" ] && echo yes || echo no)|$(cachefile "$S2")"
check "CLAUDE_CARBON_NO_USAGE_CACHE=1: no cache file" "" "$(CLAUDE_CARBON_NO_USAGE_CACHE=1 usage "$S2" "$CACHE" >/dev/null; cachefile "$S2")"
usage "$S2" >/dev/null
check "no CC_USAGE_CACHE_DIR: no cache file" "" "$(cachefile "$S2")"

# ---------------------------------------------------------------- 7. a file gone after its stat
# A stat that removes agent-d once it has answered: jq then cannot open it
S3="22222222-cccc-0000-0000-000000000003"
make_session "$S3"
D3="${PROJ}/${S3}/subagents/workflows/wf_one/agent-d.jsonl"
mkdir -p "${TMPROOT}/gonestat"
REAL_STAT="$(command -v stat)"
printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?; rm -f "%s"; exit $rc\n' "$REAL_STAT" "$D3" > "${TMPROOT}/gonestat/stat"
chmod +x "${TMPROOT}/gonestat/stat"
OUT3="$(PATH="${TMPROOT}/gonestat:$PATH" usage "$S3" "$CACHE")"
RC3=$?
check "a file gone after its stat: the pass fails, nothing kept" "1||" "${RC3}|${OUT3}|$(cachefile "$S3")"

# ---------------------------------------------------------------- 8. two Stop hooks at once
S4="22222222-cccc-0000-0000-000000000004"
make_session "$S4"
payload() { jq -n --arg s "$1" --arg t "${PROJ}/$1.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp/cacheproj"}'; }
payload "$S4" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST" &
payload "$S4" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST" &
wait
EXPECT4="$(usage "$S4" | awk -F '\t' '$1 == "T" { print $2 "|" $5 "|" $6 }')"
check "two at once: the row" "$EXPECT4" "$(q "SELECT input_tokens || '|' || cache_read_tokens || '|' || output_tokens FROM sessions WHERE session_id='${S4}';")"
CF4="$(cachefile "$S4")"
check "two at once: the cache parses, one entry per agent (the cut one aside)" "5|0" \
  "$(jq -c '.p' "$CF4" 2>/dev/null | wc -l | tr -d ' ')|$(find "$CACHE" -name '*.tmp.*' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- 9. purge
touch -t 202001010000 "$CF4"
: > "${CACHE}/old.v1.jsonl.tmp.123"
touch -t 202001010000 "${CACHE}/old.v1.jsonl.tmp.123"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="$DB" bash "$BACKFILL" >/dev/null 2>&1
check "the rescan removes the unused file and the orphan, keeps the rest" "no|no|yes" \
  "$([ -e "$CF4" ] && echo yes || echo no)|$([ -e "${CACHE}/old.v1.jsonl.tmp.123" ] && echo yes || echo no)|$([ -e "$CF" ] && echo yes || echo no)"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
