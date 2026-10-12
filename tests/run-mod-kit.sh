#!/usr/bin/env bash
# run-mod-kit.sh: run the mod's own tests (hooks/mod/*.test.tsx) under `claude plugin test`,
# the test kit Claude Code ships for mods. Each test file runs in a child of the claude
# binary against a mocked engine: no model, no login, no network.
#
# The binary is $CLAUDE_BIN, else the first `claude` on PATH. CI pins it
# (@anthropic-ai/claude-code@2.1.296); locally it is whatever version you run, printed
# first so a failure can be told apart from a kit change.
#
# HOME and CLAUDE_CONFIG_DIR point at a throwaway dir: the binary writes a .claude.json
# there at startup, and the real ~/.claude is never read or written.
#
# bash 3.2 compatible (macOS default). Dependencies: claude.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

CLAUDE="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -z "$CLAUDE" ] || [ ! -x "$CLAUDE" ]; then
  echo "FAIL: claude is required (npm install -g @anthropic-ai/claude-code, or set CLAUDE_BIN)" >&2
  exit 1
fi

# cc_tmpdir rather than $TMPDIR directly: under Git Bash on Windows TMPDIR can
# hold a native "C:\Users\..." path, which mktemp cannot use as a template.
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-mod-kit.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

# Only ever delete a path we just created under a temp root, never an arbitrary variable.
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-mod-kit.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "${TMPROOT}/.claude"

kit() {
  HOME="$TMPROOT" CLAUDE_CONFIG_DIR="${TMPROOT}/.claude" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    "$CLAUDE" "$@"
}

echo "claude $(kit --version)"

# The kit finds the mod through hooks/hooks.json, so it runs on the plugin root. It exits 1
# on a failing test, and also when it finds no test file at all.
kit plugin test "$REPO_DIR"
