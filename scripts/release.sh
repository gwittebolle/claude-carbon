#!/usr/bin/env bash
set -euo pipefail

# release.sh — cut a release: bump the three manifests that must stay in sync, tag, push, and
# open a GitHub release draft pre-filled with the CHANGELOG lines added since the last tag.
#
#   bash scripts/release.sh patch|minor|major|X.Y.Z [--dry-run] [--npm] [--publish]
#
#   --dry-run   print every step, change nothing
#   --npm       also run `npm publish` (needs npm auth; skipped by default)
#   --publish   publish the GitHub release instead of leaving it a draft
#
# Why this exists: the update notice users see is keyed on the version in
# .claude-plugin/plugin.json, not on commits. A change to anything that runs on their machine
# (scripts/, hooks/, skills/, data/, install.sh, bin/) only reaches them once a release bumps
# it. Docs-only changes deliberately do not nag. Three manifests hold that version and a
# mismatch makes the notice lie, so they are bumped together, here, or not at all.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

PKG=package.json
PLUGIN=.claude-plugin/plugin.json
MARKET=.claude-plugin/marketplace.json
MARKET_PATH='.plugins[] | select(.name == "claude-carbon") | .version'

BUMP=""
DRY_RUN=0
DO_NPM=0
DRAFT=1

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --npm)     DO_NPM=1 ;;
    --publish) DRAFT=0 ;;
    patch|minor|major) BUMP="$arg" ;;
    [0-9]*.[0-9]*.[0-9]*) BUMP="$arg" ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: bash scripts/release.sh patch|minor|major|X.Y.Z [--dry-run] [--npm] [--publish]" >&2
       exit 2 ;;
  esac
done

[ -n "$BUMP" ] || { echo "Missing bump level. Usage: bash scripts/release.sh patch|minor|major|X.Y.Z [--dry-run] [--npm] [--publish]" >&2; exit 2; }

for cmd in jq git gh; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

run() {  # echo in dry-run, execute otherwise
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- preconditions

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "ERROR: on branch '$BRANCH'; releases are cut from main." >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || { echo "ERROR: working tree is dirty. Commit or stash first." >&2; git status --short >&2; exit 1; }

git fetch --quiet origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "ERROR: local main and origin/main differ. Pull or push first." >&2
  exit 1
fi

# npm publishes at the very end, after the bump is committed and the tag pushed. An expired
# npm session there leaves a half-done release, and re-running the script double-bumps
# (the orphan v1.2.0 tag, 2026-08-19). Fail here instead, before anything is written.
if [ "$DO_NPM" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  command -v npm >/dev/null 2>&1 || { echo "ERROR: --npm passed but npm is not installed." >&2; exit 1; }
  npm whoami >/dev/null 2>&1 || { echo "ERROR: --npm passed but npm is not authenticated. Run 'npm login' first." >&2; exit 1; }
fi

# The three manifests must already agree; a pre-existing mismatch is a bug to fix by hand,
# not something to paper over with a bump.
V_PKG="$(jq -r '.version // empty' "$PKG")"
V_PLUGIN="$(jq -r '.version // empty' "$PLUGIN")"
V_MARKET="$(jq -r "$MARKET_PATH // empty" "$MARKET")"

if [ "$V_PKG" != "$V_PLUGIN" ] || [ "$V_PKG" != "$V_MARKET" ]; then
  echo "ERROR: manifests disagree before bumping." >&2
  echo "  $PKG    : ${V_PKG:-<none>}" >&2
  echo "  $PLUGIN : ${V_PLUGIN:-<none>}" >&2
  echo "  $MARKET : ${V_MARKET:-<none>}" >&2
  exit 1
fi

CURRENT="$V_PKG"
case "$CURRENT" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "ERROR: current version '$CURRENT' is not X.Y.Z." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- new version

if [ "$BUMP" = "patch" ] || [ "$BUMP" = "minor" ] || [ "$BUMP" = "major" ]; then
  IFS='.' read -r MA MI PA <<< "$CURRENT"
  case "$BUMP" in
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
  esac
  NEW="${MA}.${MI}.${PA}"
else
  NEW="$BUMP"
fi

TAG="v${NEW}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && { echo "ERROR: tag ${TAG} already exists." >&2; exit 1; }

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"

echo ""
echo "  claude-carbon release"
echo "  ${CURRENT} → ${NEW}   (tag ${TAG}${LAST_TAG:+, previous ${LAST_TAG}})"
[ "$DRY_RUN" = "1" ] && echo "  DRY RUN: nothing will be written or pushed"
echo ""

# What is actually shipping: runtime changes are what the notice is meant to announce.
if [ -n "$LAST_TAG" ]; then
  RUNTIME_CHANGED="$(git diff --name-only "${LAST_TAG}..HEAD" -- scripts hooks skills data install.sh bin action.yml 2>/dev/null || true)"
  if [ -n "$RUNTIME_CHANGED" ]; then
    echo "Runtime files changed since ${LAST_TAG}:"
    echo "$RUNTIME_CHANGED" | sed 's/^/  /'
  else
    echo "No runtime file changed since ${LAST_TAG}; this release is docs-only."
    echo "Users gain nothing by updating, and the notice will nag them anyway."
  fi
  echo ""
fi

# ---------------------------------------------------------------- bump

echo "Bumping manifests..."
bump_json() {  # $1 = file, $2 = jq assignment
  local file="$1" filter="$2" tmp
  tmp="${file}.tmp.$$"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $file → $NEW"
    return
  fi
  jq --arg v "$NEW" "$filter" "$file" > "$tmp" && mv -f "$tmp" "$file"
  echo "  $file → $NEW"
}

bump_json "$PKG"    '.version = $v'
bump_json "$PLUGIN" '.version = $v'
bump_json "$MARKET" '(.plugins[] | select(.name == "claude-carbon") | .version) = $v'

if [ "$DRY_RUN" != "1" ]; then
  # Re-read rather than trust the writes.
  A="$(jq -r '.version' "$PKG")"; B="$(jq -r '.version' "$PLUGIN")"; C="$(jq -r "$MARKET_PATH" "$MARKET")"
  if [ "$A" != "$NEW" ] || [ "$B" != "$NEW" ] || [ "$C" != "$NEW" ]; then
    echo "ERROR: bump did not land ($A / $B / $C). Manifests left as-is; fix by hand." >&2
    exit 1
  fi
fi

# npm's lockfile carries the version too when one is committed.
if [ -f package-lock.json ] && [ "$DRY_RUN" != "1" ]; then
  tmp="package-lock.json.tmp.$$"
  jq --arg v "$NEW" '.version = $v | (if .packages? and .packages[""]? then .packages[""].version = $v else . end)' \
    package-lock.json > "$tmp" && mv -f "$tmp" package-lock.json
  echo "  package-lock.json → $NEW"
fi

# ---------------------------------------------------------------- release notes

NOTES_FILE="$(mktemp -t claude-carbon-release)"
{
  echo "## What's new"
  echo ""
  if [ -n "$LAST_TAG" ]; then
    # Lines added to the CHANGELOG since the last tag: raw material to rewrite, not the
    # final copy. GitHub release notes read as a summary, the CHANGELOG as a log.
    git diff "${LAST_TAG}..HEAD" -- CHANGELOG.md | sed -n 's/^+//p' | grep -v '^++' || true
  fi
} > "$NOTES_FILE"

echo ""
echo "Draft release notes from the CHANGELOG (edit before publishing):"
sed 's/^/  | /' "$NOTES_FILE" | head -20
echo ""

# ---------------------------------------------------------------- commit, tag, push

if [ -f package-lock.json ]; then
  run git add "$PKG" "$PLUGIN" "$MARKET" package-lock.json
else
  run git add "$PKG" "$PLUGIN" "$MARKET"
fi
run git commit -q -m "chore: release ${NEW}"
run git tag -a "$TAG" -m "${TAG}"
run git push origin main
run git push origin "$TAG"

create_release() {
  if [ "$DRAFT" = "1" ]; then
    run gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE" --draft
  else
    run gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE"
  fi
}

# `if !` rather than a bare call: under `set -e` a gh failure would abort here, after the
# commit and tag are already pushed, without saying what state things are in.
if create_release; then
  if [ "$DRAFT" = "1" ]; then
    echo ""
    echo "GitHub release created as a DRAFT. Edit the notes, then publish:"
    echo "  gh release edit ${TAG} --draft=false"
  fi
else
  echo "" >&2
  echo "The bump, the commit and the tag ${TAG} are pushed; only the GitHub release failed." >&2
  echo "Nothing is inconsistent. Create it when ready with:" >&2
  echo "  gh release create ${TAG} --title ${TAG} --notes-file ${NOTES_FILE}" >&2
  echo "(draft notes kept at ${NOTES_FILE})" >&2
  exit 1
fi

if [ "$DO_NPM" = "1" ]; then
  # The commit, tag and GitHub release already exist at this point: on a publish failure,
  # fix the cause and rerun ONLY `npm publish`, never the whole script (it would re-bump).
  run npm publish || {
    echo "ERROR: npm publish failed. The release itself is done (commit, tag, GitHub release)." >&2
    echo "Fix the cause (npm login?) and run ONLY:  npm publish" >&2
    exit 1
  }
else
  echo ""
  echo "npm not published (the tarball only carries bin/). If bin/ changed, run:"
  echo "  npm publish"
fi

[ "$DRY_RUN" = "1" ] || rm -f "$NOTES_FILE"
echo ""
echo "Done: ${NEW}."
