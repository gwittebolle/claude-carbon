#!/usr/bin/env bash
# run-jq-fetch-tests.sh: the jq a Mac without one gets from install.sh (cc_fetch_jq) and
# the PATH scripts/portable-lib.sh builds around it.
#
#   - a download whose checksum does not match installs nothing and leaves no temp file;
#   - portable-lib puts <config>/claude-carbon/bin first on PATH when no jq is found,
#     and leaves a jq of the system first when there is one;
#   - with CLAUDE_CARBON_NETWORK_TESTS=1 on macOS, the real jq 1.8.1 is fetched, checked
#     and runs (the macOS CI job sets it).
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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-jq-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-jq-tests.*) rm -r "$TMPROOT" ;;
  esac
}
trap cleanup EXIT

# The function as install.sh defines it, between its markers
FETCH="$(awk '/^# >>> fetch jq/{f=1;next} /^# <<< fetch jq/{f=0} f' "${REPO_DIR}/install.sh")"
check "fetch block found in install.sh" "$([ -n "$FETCH" ] && echo yes)" "yes"
eval "$FETCH"

# 1. A download that is not the published binary installs nothing
FAKE_BASE="${TMPROOT}/release"
mkdir -p "$FAKE_BASE"
printf 'not jq\n' >"${FAKE_BASE}/jq-macos-arm64"
printf 'not jq\n' >"${FAKE_BASE}/jq-macos-amd64"
DEST="${TMPROOT}/config/claude-carbon/bin"
if CLAUDE_CARBON_JQ_BASE="file://${FAKE_BASE}" cc_fetch_jq "$DEST"; then RESULT=installed; else RESULT=refused; fi
check "a wrong checksum is refused" "$RESULT" "refused"
check "nothing installed" "$([ -e "${DEST}/jq" ] && echo present || echo absent)" "absent"
LEFT=0
for f in "$DEST"/jq.download.*; do [ -e "$f" ] && LEFT=$((LEFT + 1)); done
check "no temp file left" "$LEFT" "0"

# 2. portable-lib's PATH: the tools it needs, and no jq of the system
TOOLS="${TMPROOT}/tools"
mkdir -p "$TOOLS"
for t in bash uname tr cat dirname; do
  src="$(command -v "$t" 2>/dev/null)"
  [ -n "$src" ] && ln -s "$src" "${TOOLS}/${t}"
done
CONFIG="${TMPROOT}/home/.claude"
mkdir -p "${CONFIG}/claude-carbon/bin"
printf '#!/bin/sh\necho private-jq\n' >"${CONFIG}/claude-carbon/bin/jq"
chmod +x "${CONFIG}/claude-carbon/bin/jq"
found() {
  env -i HOME="${TMPROOT}/home" CLAUDE_CONFIG_DIR="$CONFIG" PATH="$1" \
    "${TOOLS}/bash" -c ". '${REPO_DIR}/scripts/portable-lib.sh'; jq"
}
check "no jq on the system: the private one runs" "$(found "$TOOLS")" "private-jq"
SYSTEM="${TMPROOT}/system"
mkdir -p "$SYSTEM"
printf '#!/bin/sh\necho system-jq\n' >"${SYSTEM}/jq"
chmod +x "${SYSTEM}/jq"
check "a jq of the system keeps precedence" "$(found "${SYSTEM}:${TOOLS}")" "system-jq"
rm "${CONFIG}/claude-carbon/bin/jq"
check "no private jq: PATH unchanged" \
  "$(env -i HOME="${TMPROOT}/home" CLAUDE_CONFIG_DIR="$CONFIG" PATH="$TOOLS" "${TOOLS}/bash" -c ". '${REPO_DIR}/scripts/portable-lib.sh'; printf '%s' \"\$PATH\"")" \
  "$TOOLS"

# 3. The real download, on macOS when asked
case "${OSTYPE:-}" in
  darwin*)
    if [ "${CLAUDE_CARBON_NETWORK_TESTS:-0}" = "1" ]; then
      REAL="${TMPROOT}/real/claude-carbon/bin"
      if cc_fetch_jq "$REAL"; then RESULT=installed; else RESULT=failed; fi
      check "the official jq is fetched and checked" "$RESULT" "installed"
      check "it runs" "$("${REAL}/jq" --version 2>/dev/null)" "jq-1.8.1"
    else
      echo "SKIP real download (set CLAUDE_CARBON_NETWORK_TESTS=1)"
    fi
    ;;
  *) echo "SKIP real download (macOS only)" ;;
esac

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
