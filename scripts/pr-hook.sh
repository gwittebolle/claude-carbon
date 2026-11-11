#!/usr/bin/env bash
# pr-hook.sh: PostToolUse hook on the Bash calls that open a pull request or push a
# branch (`gh pr create`, `git push`). It acts only in a repository whose shared
# .claude/settings.json asks for the PR report ("env": {"CLAUDE_CARBON_PR": "1"}):
#  - this developer said yes for the repository: a marker is left, and the Stop hook posts
#    or updates the comment once the answer's tokens are recorded (pr-flush.sh);
#  - they said never, or were asked before: nothing;
#  - they were never asked: on `gh pr create` only, Claude is told to ask them, once. No
#    answer counts as no.
# CLAUDE_CARBON_NO_PR_AUTO turns all of it off for a developer. Calls no network itself.
# Must exit 0 and print nothing but the one JSON object for Claude.

[ -t 0 ] && exit 0
[ -z "${CLAUDE_CARBON_NO_PR_AUTO:-}" ] || { cat >/dev/null 2>&1; exit 0; }
INPUT="$(cat 2>/dev/null)" || exit 0
# A Claude Code without the hook's `if` filter runs this on every Bash call: leave at once
case "$INPUT" in
  *"gh pr create"*|*"git push"*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# A subagent has no one to ask, and its pushes are its session's
[ "$(printf '%s' "$INPUT" | jq -r '.agent_id // .agent_type // ""' 2>/dev/null)" = "" ] || exit 0
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
# The command itself, at the start of the line or after ; & | (: not the words in a
# commit message or an echo
CREATE_RE='(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
PUSH_RE='(^|[;&|(])[[:space:]]*git[[:space:]]+push([[:space:]]|$)'
if [[ "$COMMAND" =~ $CREATE_RE ]]; then
  KIND="create"
elif [[ "$COMMAND" =~ $PUSH_RE ]]; then
  KIND="push"
else
  exit 0
fi
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
CWD="$(cc_path "$CWD")"
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0
TOPLEVEL="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$TOPLEVEL" ] || exit 0
cc_pr_asked_for "$TOPLEVEL" || exit 0

DATA_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")/claude-carbon"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${DATA_DIR}/carbon.db}")"
# No database, no figure to post
[ -f "$DB_PATH" ] || exit 0

KEY="$(cc_repo_key "$TOPLEVEL")"
[ -n "$KEY" ] || exit 0
case "$(cc_pr_consent_get "$DATA_DIR" "$KEY")" in
  yes)
    BRANCH="$(cc_git_branch "$TOPLEVEL")"
    [ -n "$BRANCH" ] || exit 0
    PENDING="$(cc_pr_pending "$DATA_DIR" "$TOPLEVEL" "$BRANCH")"
    mkdir -p "$(dirname "$PENDING")" 2>/dev/null && printf '%s\n%s\n' "$TOPLEVEL" "$BRANCH" >"$PENDING" 2>/dev/null
    ;;
  never|asked) ;;
  *)
    [ "$KIND" = "create" ] || exit 0
    cc_pr_consent_set "$DATA_DIR" "$KEY" asked || exit 0
    REPORT="${SCRIPT_DIR}/generate-pr-report.sh"
    jq -cn --arg report "$REPORT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext:
      ("claude-carbon: this repository asks for a carbon report on its pull requests (CLAUDE_CARBON_PR in its .claude/settings.json). The user has not chosen yet for this repository, and nothing has been posted. Ask them once, in one short question: do they want the report of their own local Claude Code sessions on a branch (CO2 estimate, API-price cost, tokens) posted as one comment on their pull requests of this repository, under their own GitHub account, and kept up to date when they push? If they say yes, run from this repository: bash " + ($report | @sh) + " --consent yes . If they say no, run: bash " + ($report | @sh) + " --consent never . Never run either unless the user typed that answer themselves in this conversation. If they do not answer, do nothing: they will not be asked again.")}}' 2>/dev/null
    ;;
esac
exit 0
