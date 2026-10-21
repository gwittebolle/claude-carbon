#!/usr/bin/env bash
# run-release-tests.sh: scripts/release.sh refuses the releases that only bump a number.
#
#   - run again right after a release, HEAD is that release's commit: refused, even with
#     --force, and nothing is committed, tagged or pushed (the empty v1.18.0 of 2026-10-21);
#   - nothing under scripts/, hooks/, skills/, data/, install.sh or bin/ changed since the
#     last tag: refused unless --force;
#   - a runtime change releases: manifests bumped together, commit and tag pushed.
#
# Works on a throwaway repository with a local bare origin and a stub gh; the real repo and
# GitHub are never touched. bash 3.2 compatible.

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

for c in jq git; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c not found"; exit 0; }
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-carbon-release-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-release-tests.*) rm -r "$TMPROOT" ;;
  esac
}
trap cleanup EXIT

# A stub gh: release.sh requires one, and creates the GitHub release through it
STUB="${TMPROOT}/bin"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "${TMPROOT}/gh-calls" > "${STUB}/gh"
chmod +x "${STUB}/gh"
export PATH="${STUB}:${PATH}"

# The repository: the manifests release.sh bumps, one runtime script, release.sh itself
ORIGIN="${TMPROOT}/origin.git"
WORK="${TMPROOT}/work"
git init -q --bare "$ORIGIN"
git init -q "$WORK"
cd "$WORK" || exit 1
git checkout -q -b main
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config tag.gpgsign false
# No hook of the machine's own (a global core.hooksPath) runs in this repository
git config core.hooksPath "${TMPROOT}/no-hooks"
mkdir -p .claude-plugin scripts
echo '{"name": "claude-carbon", "version": "1.0.0"}' > package.json
echo '{"name": "claude-carbon", "version": "1.0.0"}' > .claude-plugin/plugin.json
echo '{"plugins": [{"name": "claude-carbon", "version": "1.0.0"}]}' > .claude-plugin/marketplace.json
printf 'version: 1.0.0\ndate-released: "2026-01-01"\n' > CITATION.cff
printf '# Changelog\n' > CHANGELOG.md
printf 'echo one\n' > scripts/thing.sh
cp "${REPO_DIR}/scripts/release.sh" scripts/release.sh
git add -A
git commit -q -m init
git tag -a v1.0.0 -m v1.0.0
git remote add origin "$ORIGIN"
git push -q origin main v1.0.0

release() { bash scripts/release.sh "$@" >"${TMPROOT}/out" 2>&1; echo $?; }
version() { jq -r .version .claude-plugin/plugin.json; }
head_sha() { git rev-parse HEAD; }

# ── 1. HEAD is the last release ─────────────────────────────────────────────────────────
BEFORE="$(head_sha)"
check "HEAD already released: refused" "$(release patch)" "1"
check "HEAD already released: says so" \
  "$(grep -c "already released as v1.0.0" "${TMPROOT}/out")" "1"
check "HEAD already released: refused with --force too" "$(release patch --force)" "1"
check "HEAD already released: nothing committed" "$(head_sha)" "$BEFORE"
check "HEAD already released: no tag" "$(git tag -l v1.0.1)" ""

# ── 2. Docs only since the last tag ─────────────────────────────────────────────────────
echo "More docs." > README.md
git add README.md
git commit -q -m "docs: readme"
git push -q origin main
BEFORE="$(head_sha)"
check "docs-only: refused" "$(release patch)" "1"
check "docs-only: says how to force" "$(grep -c -- "--force" "${TMPROOT}/out")" "1"
check "docs-only: nothing committed" "$(head_sha)" "$BEFORE"
check "docs-only: manifests untouched" "$(version)" "1.0.0"
check "docs-only, dry run: refused as well" "$(release patch --dry-run)" "1"
check "docs-only with --force, dry run: goes through" "$(release patch --force --dry-run)" "0"
check "docs-only with --force, dry run: writes nothing" "$(version)" "1.0.0"

# ── 3. A runtime change since the last tag ──────────────────────────────────────────────
printf 'echo two\n' > scripts/thing.sh
git add scripts/thing.sh
git commit -q -m "fix: thing"
git push -q origin main
check "runtime change: released" "$(release patch)" "0"
check "runtime change: version bumped" "$(version)" "1.0.1"
check "runtime change: tag pushed" "$(git ls-remote --tags origin v1.0.1 | grep -c v1.0.1)" "1"
check "runtime change: GitHub release asked for" "$(grep -c "release create v1.0.1" "${TMPROOT}/gh-calls")" "1"

# ── 4. The same command once more, as on 2026-10-21 ─────────────────────────────────────
BEFORE="$(head_sha)"
check "second run after a release: refused" "$(release patch)" "1"
check "second run after a release: nothing committed" "$(head_sha)" "$BEFORE"
check "second run after a release: no tag" "$(git tag -l v1.0.2)" ""
check "second run after a release: no second GitHub release" "$(grep -c "release create" "${TMPROOT}/gh-calls")" "1"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
