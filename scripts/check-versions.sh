#!/usr/bin/env bash
set -uo pipefail

# check-versions.sh — guard the version that drives the update notice.
#
#   bash scripts/check-versions.sh
#
# Two checks, deliberately different in severity:
#
#   1. FAIL if the three manifests disagree. Users are told a new version exists by comparing
#      .claude-plugin/plugin.json against origin/main; npm and the marketplace read the other
#      two. A mismatch makes at least one of them lie, and that is always a bug.
#
#   2. WARN if files that run on a user's machine changed since the last tag while the version
#      did not. Not a failure: batching several commits into one release is normal, and a
#      docs-only commit must never nag anyone. It is a reminder that whatever has accumulated
#      is still invisible to every installed user until `scripts/release.sh` bumps it.
#
# Exit 0 on warnings, 1 on a real mismatch.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || { echo "ERROR: cannot enter $REPO_DIR" >&2; exit 1; }

PKG=package.json
PLUGIN=.claude-plugin/plugin.json
MARKET=.claude-plugin/marketplace.json
MARKET_PATH='.plugins[] | select(.name == "claude-carbon") | .version'

# Paths whose contents execute on an installed machine. Everything else (README, CHANGELOG,
# stats, .github, tests) can change freely without anyone needing to update.
RUNTIME_PATHS=(scripts hooks skills data install.sh bin)

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::$1"
  else
    echo "WARNING: $1" >&2
  fi
}

# ---------------------------------------------------------------- 1. manifests agree

V_PKG="$(jq -r '.version // empty' "$PKG" 2>/dev/null)"
V_PLUGIN="$(jq -r '.version // empty' "$PLUGIN" 2>/dev/null)"
V_MARKET="$(jq -r "$MARKET_PATH // empty" "$MARKET" 2>/dev/null)"

for pair in "$PKG:$V_PKG" "$PLUGIN:$V_PLUGIN" "$MARKET:$V_MARKET"; do
  if [ -z "${pair#*:}" ]; then
    echo "FAIL: no version found in ${pair%%:*}" >&2
    exit 1
  fi
done

if [ "$V_PKG" != "$V_PLUGIN" ] || [ "$V_PKG" != "$V_MARKET" ]; then
  echo "FAIL: the three manifests must carry the same version." >&2
  echo "  ${PKG}    : ${V_PKG}" >&2
  echo "  ${PLUGIN} : ${V_PLUGIN}" >&2
  echo "  ${MARKET} : ${V_MARKET}" >&2
  echo "" >&2
  echo "  Bump them together with: bash scripts/release.sh patch" >&2
  exit 1
fi

echo "OK: all three manifests at ${V_PKG}."

# ---------------------------------------------------------------- 2. unreleased runtime work

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
if [ -z "$LAST_TAG" ]; then
  echo "No tag found; skipping the unreleased-changes check."
  exit 0
fi

CHANGED="$(git diff --name-only "${LAST_TAG}..HEAD" -- "${RUNTIME_PATHS[@]}" 2>/dev/null)"
TAG_VERSION="$(git show "${LAST_TAG}:${PLUGIN}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"

if [ -n "$CHANGED" ] && [ "$V_PLUGIN" = "$TAG_VERSION" ]; then
  COUNT="$(echo "$CHANGED" | wc -l | tr -d ' ')"
  warn "${COUNT} runtime file(s) changed since ${LAST_TAG} but the version is still ${V_PLUGIN}, so no installed user is being told. Cut a release when ready: bash scripts/release.sh patch"
  echo "$CHANGED" | sed 's/^/  /' >&2
elif [ -n "$CHANGED" ]; then
  echo "OK: runtime changed since ${LAST_TAG} and the version moved (${TAG_VERSION} → ${V_PLUGIN})."
else
  echo "OK: no runtime change since ${LAST_TAG}."
fi

exit 0
