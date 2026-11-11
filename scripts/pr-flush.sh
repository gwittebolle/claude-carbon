#!/usr/bin/env bash
# pr-flush.sh: run by the Stop hook, detached, once the answer is recorded. For each
# marker pr-hook.sh left (a push or a `gh pr create` in a repository that asks for the PR
# report, by a developer who said yes), post or update the comment through
# generate-pr-report.sh --auto, with the developer's own gh auth. A marker is claimed by
# renaming it, so two sessions ending together run one report; one older than an hour is
# dropped (its session never reached a Stop); one whose branch is no longer the one
# checked out is dropped too, the report being for the branch in place. Silent, whatever
# happens.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
[ -z "${CLAUDE_CARBON_NO_PR_AUTO:-}" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

DATA_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")/claude-carbon"
PENDING_DIR="${DATA_DIR}/pr-pending"
[ -d "$PENDING_DIR" ] || exit 0
NOW="$(date +%s)"

for MARKER in "$PENDING_DIR"/*; do
  [ -f "$MARKER" ] || continue
  case "$MARKER" in *.claimed.*) # left by a run that died: dropped once old
    [ "$(( NOW - $(cc_mtime "$MARKER") ))" -gt 3600 ] 2>/dev/null && rm -f "$MARKER" 2>/dev/null
    continue ;;
  esac
  CLAIM="${MARKER}.claimed.$$"
  mv "$MARKER" "$CLAIM" 2>/dev/null || continue
  AGE="$(( NOW - $(cc_mtime "$CLAIM") ))"
  TOPLEVEL=""; BRANCH=""
  { IFS= read -r TOPLEVEL; IFS= read -r BRANCH; } <"$CLAIM" 2>/dev/null
  rm -f "$CLAIM" 2>/dev/null
  [ "$AGE" -le 3600 ] 2>/dev/null || continue
  [ -n "$TOPLEVEL" ] && [ -n "$BRANCH" ] && [ -d "$TOPLEVEL" ] || continue
  # Asked for and agreed to, still, and the same branch: each can have changed since the push
  cc_pr_asked_for "$TOPLEVEL" || continue
  [ "$(cc_pr_consent_get "$DATA_DIR" "$(cc_repo_key "$TOPLEVEL")")" = "yes" ] || continue
  [ "$(cc_git_branch "$TOPLEVEL")" = "$BRANCH" ] || continue
  ( cd "$TOPLEVEL" 2>/dev/null && bash "${SCRIPT_DIR}/generate-pr-report.sh" --auto ) >/dev/null 2>&1
done
exit 0
