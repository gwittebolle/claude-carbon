#!/usr/bin/env bash
# run-update-check-tests.sh: the daily release check (scripts/check-update.sh) on the two
# kinds of install, with a stub git on PATH (no network).
#
#   - a marketplace install asks for the release tags only (never a fetch into Claude
#     Code's cache) and writes plugin-update-check.json, the newest vX.Y.Z by version order;
#   - a git clone fetches its origin and writes update-check.json, as before;
#   - the opt-out, and a folder that is neither, write nothing;
#   - cc_is_plugin_cache tells the two apart.
#
# Runs under temp roots; the real ~/.claude is never read. bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "PASS $1"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $1"
    echo "  expected: $3"
    echo "  actual:   $2"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found"
  exit 0
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-update-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-update-tests.*) rm -r "$TMPROOT" ;;
  esac
}
trap cleanup EXIT

# A stub git: records each call, lists tags, and answers a clone's fetch and show
mkdir -p "$TMPROOT/bin"
cat >"$TMPROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GIT_LOG"
for a in "$@"; do
  case "$a" in
    ls-remote)
      printf 'aaa\trefs/tags/v1.9.0\nbbb\trefs/tags/v1.12.10\nccc\trefs/tags/v1.12.6\nddd\trefs/tags/latest\n'
      exit 0 ;;
    fetch) exit 0 ;;
    show) printf '{"version":"1.13.0"}\n'; exit 0 ;;
    symbolic-ref) exit 1 ;;
  esac
done
exit 0
EOF
chmod +x "$TMPROOT/bin/git"

# A copy of the plugin at <root>: its scripts and its manifest at <version>
plant() {
  mkdir -p "$1/scripts" "$1/.claude-plugin"
  cp "$REPO_DIR/scripts/check-update.sh" "$REPO_DIR/scripts/portable-lib.sh" "$1/scripts/"
  printf '{"version":"%s"}\n' "$2" >"$1/.claude-plugin/plugin.json"
}

# run <root> <config> [VAR=value…]
run() {
  local root="$1" config="$2"
  shift 2
  env -i HOME="$TMPROOT/home" PATH="$TMPROOT/bin:$PATH" GIT_LOG="$TMPROOT/git.log" \
    CLAUDE_CONFIG_DIR="$config" "$@" bash "$root/scripts/check-update.sh"
}

# 1. A marketplace install
CONFIG="$TMPROOT/mkt/config"
PLUGIN="$CONFIG/plugins/cache/claude-carbon/claude-carbon/1.12.5"
plant "$PLUGIN" 1.12.5
: >"$TMPROOT/git.log"
run "$PLUGIN" "$CONFIG"
FLAG="$CONFIG/claude-carbon/plugin-update-check.json"
check "marketplace: flag written" "$([ -f "$FLAG" ] && echo yes)" "yes"
check "marketplace: newest tag by version order" "$(jq -r .remote "$FLAG" 2>/dev/null)" "1.12.10"
check "marketplace: behind" "$(jq -r .behind "$FLAG" 2>/dev/null)" "true"
check "marketplace: own version" "$(jq -r .local "$FLAG" 2>/dev/null)" "1.12.5"
check "marketplace: no clone flag" "$([ -f "$CONFIG/claude-carbon/update-check.json" ] && echo yes)" ""
check "marketplace: tags asked, nothing fetched" \
  "$(grep -c ' fetch' "$TMPROOT/git.log")/$(grep -c 'ls-remote' "$TMPROOT/git.log")" "0/1"

# Up to date: written, not behind
plant "$PLUGIN" 1.12.10
run "$PLUGIN" "$CONFIG"
check "marketplace: up to date" "$(jq -r .behind "$FLAG" 2>/dev/null)" "false"

# 2. A git clone
CONFIG="$TMPROOT/clone/config"
CLONE="$TMPROOT/clone/claude-carbon"
plant "$CLONE" 1.12.5
mkdir -p "$CLONE/.git"
: >"$TMPROOT/git.log"
run "$CLONE" "$CONFIG"
check "clone: flag for the status line" "$(jq -r .remote "$CONFIG/claude-carbon/update-check.json" 2>/dev/null)" "1.13.0"
check "clone: no pane flag" "$([ -f "$CONFIG/claude-carbon/plugin-update-check.json" ] && echo yes)" ""
check "clone: fetched, no tag listing" \
  "$(grep -c ' fetch' "$TMPROOT/git.log")/$(grep -c 'ls-remote' "$TMPROOT/git.log")" "1/0"

# 3. The opt-out, and a folder that is neither
CONFIG="$TMPROOT/off/config"
PLUGIN="$CONFIG/plugins/cache/claude-carbon/claude-carbon/1.12.5"
plant "$PLUGIN" 1.12.5
run "$PLUGIN" "$CONFIG" CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1
check "opt-out: nothing written" "$(ls "$CONFIG/claude-carbon" 2>/dev/null)" ""
CONFIG="$TMPROOT/plain/config"
plant "$TMPROOT/plain/copy" 1.12.5
run "$TMPROOT/plain/copy" "$CONFIG"
check "neither: nothing written" "$(ls "$CONFIG/claude-carbon" 2>/dev/null)" ""

# 4. cc_is_plugin_cache
. "$REPO_DIR/scripts/portable-lib.sh"
is_cache() { cc_is_plugin_cache "$1" && echo yes || echo no; }
check "cache: home config" "$(is_cache /Users/a/.claude/plugins/cache/claude-carbon/claude-carbon/1.12.5/scripts)" "yes"
check "cache: CLAUDE_CONFIG_DIR" "$(is_cache /srv/cfg/plugins/cache/claude-carbon/claude-carbon/1.12.5)" "yes"
check "cache: a clone" "$(is_cache /Users/a/code/claude-carbon/scripts)" "no"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
