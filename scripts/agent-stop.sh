#!/usr/bin/env bash
# agent-stop.sh: SubagentStop hook. When an agent ends having worked on a git branch of
# its own, record that branch and the agent's usage, per model, in agent_usage. /carbon-pr
# then counts the agent for that branch rather than for the one its session ended on (a
# session on main that sends agents to build a PR in a worktree). The session's own row
# is not touched: the agent's tokens stay in it, and the report moves them.
#
# The branch is read here, as the agent ends, while its worktree still exists:
#   - "cwd": the agent ran in a linked worktree (not the repository's main folder) other
#     than the session's own folder, as Claude Code's isolated and workflow agents do:
#     the branch that worktree has now;
#   - "cited": the agent ran in the session's folder or in the main folder, and its tool
#     calls named another worktree of the repository in at least half of those that give
#     a place (a command, a file path), and no other worktree as often: that worktree's
#     branch. A deduction. A worktree is named by its absolute path (also C:/, c:/ and
#     /c/ on Windows, ~/ under the home folder), by ../ from the agent's worktree when it
#     sits beside it, by ./ when it sits within; a longer path that only starts the same
#     (x-1013-facultatif for x-1013) does not name it (CC_JQ_AGENT_BRANCH).
# Never a branch: one Claude Code named for a worktree of its own (worktree-agent-*,
# worktree-wf_*; a worktree-foo the user asked for with --worktree is a branch), a
# detached HEAD. Never recorded: a fork (it replays its parent's messages), an agent whose
# transcript is not one its session's row reads (Claude Code's own agents), an event
# without an agent type. When no branch is found, an earlier record of the agent (it was
# resumed) is left as it is. The agent's last message is kept with its usage: the report
# moves the agent only once its session's row postdates it.
#
# Synchronous and short: a jq for the event, a jq for the session's folder, one or two git
# calls; then, for an agent in the session's folder, git worktree list and one jq over its
# tool calls (grep keeps only those lines); then, only when a branch is found, the agent's
# usage (cc_session_usage, as its session reads that file) and one sqlite3 transaction.
# Intentionally no set -e: this hook must exit 0 in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}")"

INPUT="$(cat 2>/dev/null)" || exit 0
[ -f "$DB_PATH" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

# The event's fields, joined by the unit separator: not white space, so an empty field
# (agent_type, for Claude Code's own agents) keeps its place
FIELDS="$(printf '%s' "$INPUT" | jq -r '[.session_id, .transcript_path, .agent_id, .agent_transcript_path, .agent_type, .cwd]
  | map(if type == "string" then . else "" end) | join("\u001f")' 2>/dev/null | tr -d '\r')" || exit 0
IFS="$(printf '\037')" read -r SESSION_ID TRANSCRIPT AGENT_ID AGENT_T AGENT_TYPE AGENT_CWD <<EOF
$FIELDS
EOF
case "$SESSION_ID" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
case "$AGENT_ID" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
# No type: one of Claude Code's own agents in a session run without --agent (before
# 2.1.275 the matcher lets them through; with --agent they carry its name, and the check
# of their transcript below leaves them out). A fork replays its parent's messages: it
# stays with its session.
case "$AGENT_TYPE" in ''|fork) exit 0 ;; esac
TRANSCRIPT="$(cc_path "$TRANSCRIPT")"
AGENT_T="$(cc_path "$AGENT_T")"
AGENT_CWD="$(cc_path "$AGENT_CWD")"

# Only an agent its session's row reads (cc_collect_subagents): <session>/subagents/
# agent-<id>.jsonl, or workflows/<run>/agent-<id>.jsonl under it
SUB_DIR="${TRANSCRIPT%/*}/${SESSION_ID}/subagents"
REL="${AGENT_T#"${SUB_DIR}/"}"
case "$REL" in
  "agent-${AGENT_ID}.jsonl") ;;
  "workflows/"*"/agent-${AGENT_ID}.jsonl")
    RUN="${REL#workflows/}"
    RUN="${RUN%/agent-"${AGENT_ID}".jsonl}"
    case "$RUN" in ''|*/*) exit 0 ;; esac
    ;;
  *) exit 0 ;;
esac
[ -f "$AGENT_T" ] && [ -r "$AGENT_T" ] && [ -d "$AGENT_CWD" ] || exit 0
META="$(cat "${AGENT_T%.jsonl}.meta.json" 2>/dev/null)" || META=""
case "$META" in *'"isFork":true'*|*'"isFork": true'*) exit 0 ;; esac

# The session's folder: the first one its transcript records (a reduce, not first(): in
# jq 1.6 the ? upstream of first() swallows its break, and every folder came out)
SESSION_CWD="$(head -n 50 "$TRANSCRIPT" 2>/dev/null | jq -R -r -n \
  'reduce (inputs | fromjson? | objects | .cwd | strings | select(length > 0)) as $c (null; . // $c) // empty' \
  2>/dev/null | tr -d '\r')" || SESSION_CWD=""
SESSION_CWD="$(cc_path "$SESSION_CWD")"

# wt_info <dir>: sets W_COMMON (the repository's common git folder, absolute, links
# resolved: the key /carbon-pr matches), W_LINKED (1 in a linked worktree, 0 in the main
# folder or a subfolder of it), W_TOP (the worktree's root, as git spells it) and W_BRANCH
# ("HEAD" when detached). git 2.31+ prints the folders absolute; an older one prints its
# unknown flag back and the folders relative to where it runs, so it is asked again from
# the root. Fails outside a repository.
wt_info() {
  local out common gdir top branch
  W_COMMON=""; W_LINKED=0; W_TOP=""; W_BRANCH=""
  out="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir --git-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null | tr -d '\r')" || return 1
  { IFS= read -r common; IFS= read -r gdir; IFS= read -r top; IFS= read -r branch; } <<EOF
$out
EOF
  case "$common" in
    /*|[A-Za-z]:/*) ;;
    *)
      top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" || return 1
      [ -n "$top" ] || return 1
      out="$(cd "$top" 2>/dev/null && git rev-parse --git-common-dir --git-dir --abbrev-ref HEAD 2>/dev/null | tr -d '\r')" || return 1
      { IFS= read -r common; IFS= read -r gdir; IFS= read -r branch; } <<EOF
$out
EOF
      case "$common" in /*|[A-Za-z]:/*) ;; *) common="${top}/${common}" ;; esac
      case "$gdir" in /*|[A-Za-z]:/*) ;; *) gdir="${top}/${gdir}" ;; esac
      ;;
  esac
  [ -n "$common" ] && [ -n "$gdir" ] && [ -n "$top" ] && [ -n "$branch" ] || return 1
  common="$(cd "$common" 2>/dev/null && pwd -P)" || return 1
  gdir="$(cd "$gdir" 2>/dev/null && pwd -P)" || return 1
  [ "$gdir" = "$common" ] || W_LINKED=1
  W_COMMON="$common"; W_TOP="$top"; W_BRANCH="$branch"
}
# automatic <branch>: a branch Claude Code named for a worktree of its own, or none
automatic() {
  case "$1" in ''|HEAD|worktree-agent-*|worktree-wf_*) return 0 ;; esac
  return 1
}

wt_info "$AGENT_CWD" || exit 0
A_COMMON="$W_COMMON"; A_LINKED="$W_LINKED"; A_TOP="$W_TOP"; A_BRANCH="$W_BRANCH"
# The repository's key, as generate-pr-report.sh spells it: Windows paths in any case
cc_is_windows && A_COMMON="$(printf '%s' "$A_COMMON" | tr 'A-Z' 'a-z')"
S_TOP=""
if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  if [ "$SESSION_CWD" = "$AGENT_CWD" ]; then
    S_TOP="$A_TOP"
  elif wt_info "$SESSION_CWD"; then
    S_TOP="$W_TOP"
  fi
fi

BRANCH=""
HOW=""
if [ "$A_LINKED" = "1" ] && [ "$A_TOP" != "$S_TOP" ]; then
  # A worktree of its own: its branch, whatever the agent's commands say
  automatic "$A_BRANCH" || { BRANCH="$A_BRANCH"; HOW="cwd"; }
else
  # The session's folder or the main folder: the worktree its tool calls name, among the
  # repository's other worktrees, each with its spellings (one JSON array)
  CANDIDATES="$(git -C "$A_TOP" worktree list --porcelain 2>/dev/null | tr -d '\r' \
    | awk -v top="$A_TOP" -v stop="$S_TOP" -v home="$(cc_path "${HOME:-}")" -v homen="$(cc_native_path "$(cc_path "${HOME:-}")")" \
      "$CC_AWK_AGENT_CANDIDATES")"
  if [ -n "$CANDIDATES" ] && [ "$CANDIDATES" != "[]" ]; then
    BRANCH="$({ printf '%s\n' "$CANDIDATES"; grep -F '"tool_use"' "$AGENT_T" 2>/dev/null; } \
      | jq -R -n -r "$CC_JQ_AGENT_BRANCH" 2>/dev/null | tr -d '\r')" || BRANCH=""
    [ -n "$BRANCH" ] && HOW="cited"
  fi
fi
[ -n "$BRANCH" ] || exit 0

# The agent's usage, as its session's pass reads this file (per-file reduction, its own
# dominant model for the messages without one), priced per model: the same R lines
USAGE="$(cc_session_usage "$FACTORS_FILE" "$PRICES_FILE" "$AGENT_T")" || exit 0
# Its last message (the S line's last timestamp), which its session's row must postdate
cc_parse_usage "$USAGE"
Q_LAST="$(cc_sql_quote "$CC_U_LAST_TS")"
Q_SID="$(cc_sql_quote "$SESSION_ID")"
Q_AGENT="$(cc_sql_quote "$AGENT_ID")"
Q_REPO="$(cc_sql_quote "$A_COMMON")"
Q_BRANCH="$(cc_sql_quote "$BRANCH")"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""
ROWS=""
while IFS="	" read -r tag model it cw cw1h cr out co2 cost; do
  [ "$tag" = "R" ] || continue
  case "${it}${cw}${cw1h}${cr}${out}" in ''|*[!0-9]*) continue ;; esac
  case "$co2$cost" in ''|*[!0-9.]*) continue ;; esac
  ROWS="${ROWS}INSERT INTO agent_usage (session_id, agent_id, repo, git_branch, how, model, input_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, output_tokens, co2_grams, cost_usd, last_ts, seen_at) VALUES (${Q_SID}, ${Q_AGENT}, ${Q_REPO}, ${Q_BRANCH}, '${HOW}', '${model//$CC_SQ/$CC_SQ$CC_SQ}', ${it}, ${cw}, ${cw1h}, ${cr}, ${out}, ${co2}, ${cost}, ${Q_LAST}, '${NOW}');
"
done <<EOF
$USAGE
EOF

# The agent's rows replaced in one transaction (a resumed agent ends again with larger
# totals). Many agents of a workflow can end at once: one more try after the busy timeout.
# The hook runs before the agent's result is handed back, so it never waits more than
# about 10 s: the same 5 s timeout as the plugin's other writers, twice.
SQL="${CC_AGENT_USAGE_DDL}
BEGIN IMMEDIATE;
DELETE FROM agent_usage WHERE session_id = ${Q_SID} AND agent_id = ${Q_AGENT};
${ROWS}COMMIT;"
sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$SQL" >/dev/null 2>&1 \
  || sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$SQL" >/dev/null 2>&1 || true
exit 0
