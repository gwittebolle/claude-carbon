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
# The worktree's folder is recorded with the branch: /carbon-pr looks for the branch's
# sessions there too. A branch is read as refs/heads/<name>, never in its short form,
# which a tag of the same name turns into heads/<name>.
# Never a branch: one Claude Code named for a worktree of its own (worktree-agent-*,
# worktree-wf_*; a worktree-foo the user asked for with --worktree is a branch), a
# detached HEAD. Never recorded: a fork (it replays its parent's messages), an agent whose
# transcript is not one its session's row reads (Claude Code's own agents), an event
# without an agent type. When no branch is found, an earlier record of the agent (it was
# resumed) is left as it is. The agent's last message is kept with its usage: the report
# moves the agent only once its session's row postdates it.
#
# The transcript may lag the agent at this point (Claude Code writes it asynchronously):
# when the event's last_assistant_message is not in its last lines yet, the hook reads
# them again every 0.2 s, for at most 1 s, then counts what is there.
#
# Synchronous and short: a jq for the event, a jq for the session's folder, one or two git
# calls; then, for an agent in the session's folder, git worktree list and one jq over its
# tool calls (grep keeps only those lines); then, only when a branch is found, the agent's
# usage (cc_session_usage, as its session reads that file) and one sqlite3 transaction.
# Few processes beyond those: on Windows each one costs tens of milliseconds, so paths are
# converted in one cygpath call and nothing else is forked for a string.
# Intentionally no set -e: this hook must exit 0 in all cases.

# This script's folder, without a subshell: Claude Code may pass a native path
CC_SELF="${BASH_SOURCE[0]//\\//}"
case "$CC_SELF" in */*) SCRIPT_DIR="${CC_SELF%/*}" ;; *) SCRIPT_DIR="." ;; esac
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR="/"
case "$SCRIPT_DIR" in /*|[A-Za-z]:/*) ;; *) SCRIPT_DIR="${PWD}/${SCRIPT_DIR}" ;; esac
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
DB_PATH="${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/claude-carbon/carbon.db}"; cc_path_vars DB_PATH
[ -f "$DB_PATH" ] || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
command -v git >/dev/null 2>&1 || exit 0

# The event's fields, joined by the unit separator: not white space, so an empty field
# (agent_type, for Claude Code's own agents) keeps its place. The last one is the end of
# the agent's final message as a transcript spells it: the last 64 characters of its JSON
# string, without the quotes and the white space around it (one line, never the separator).
FIELDS="$(jq -r '. as $e
  | [.session_id, .transcript_path, .agent_id, .agent_transcript_path, .agent_type, .cwd]
  | map(if type == "string" then . else "" end)
  + [$e.last_assistant_message | if type == "string" then (try (sub("^\\s+"; "") | sub("\\s+$"; "")) catch .) | tojson | .[1:-1] | .[-64:] else "" end]
  | join("\u001f")' 2>/dev/null <<<"$INPUT")" || exit 0
FIELDS="${FIELDS%$'\r'}"
IFS=$'\037' read -r SESSION_ID TRANSCRIPT AGENT_ID AGENT_T AGENT_TYPE AGENT_CWD LAST_KEY <<EOF
$FIELDS
EOF
case "$SESSION_ID" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
case "$AGENT_ID" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
# No type: one of Claude Code's own agents in a session run without --agent (before
# 2.1.275 the matcher lets them through; with --agent they carry its name, and the check
# of their transcript below leaves them out). A fork replays its parent's messages: it
# stays with its session.
case "$AGENT_TYPE" in ''|fork) exit 0 ;; esac
cc_path_vars TRANSCRIPT AGENT_T AGENT_CWD

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
META=""
[ -r "${AGENT_T%.jsonl}.meta.json" ] && IFS= read -r -d '' META < "${AGENT_T%.jsonl}.meta.json"
case "$META" in *'"isFork":true'*|*'"isFork": true'*) exit 0 ;; esac

# The session's folder: the first one its transcript records (a reduce, not first(): in
# jq 1.6 the ? upstream of first() swallows its break, and every folder came out)
SESSION_CWD="$(head -n 50 "$TRANSCRIPT" 2>/dev/null | jq -R -r -n \
  'reduce (inputs | fromjson? | objects | .cwd | strings | select(length > 0)) as $c (null; . // $c) // empty' \
  2>/dev/null)" || SESSION_CWD=""
SESSION_CWD="${SESSION_CWD%$'\r'}"
cc_path_vars SESSION_CWD

# wt_info <dir>: sets W_COMMON (the repository's common git folder, absolute, links
# resolved: the key /carbon-pr matches), W_LINKED (1 in a linked worktree, 0 in the main
# folder or a subfolder of it), W_TOP (the worktree's root, as git spells it) and W_BRANCH
# ("HEAD" when detached). git 2.31+ prints the folders absolute; an older one prints its
# unknown flag back and the folders relative to where it runs, so it is asked again from
# the root. Fails outside a repository.
wt_info() {
  local out common gdir top branch real
  W_COMMON=""; W_LINKED=0; W_TOP=""; W_BRANCH=""
  out="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir --git-dir --show-toplevel --symbolic-full-name HEAD 2>/dev/null)" || return 1
  out="${out//$'\r'/}"
  { IFS= read -r common; IFS= read -r gdir; IFS= read -r top; IFS= read -r branch; } <<EOF
$out
EOF
  case "$common" in
    /*|[A-Za-z]:/*) ;;
    *)
      top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
      top="${top//$'\r'/}"
      [ -n "$top" ] || return 1
      out="$(cd "$top" 2>/dev/null && git rev-parse --git-common-dir --git-dir --symbolic-full-name HEAD 2>/dev/null)" || return 1
      out="${out//$'\r'/}"
      { IFS= read -r common; IFS= read -r gdir; IFS= read -r branch; } <<EOF
$out
EOF
      case "$common" in /*|[A-Za-z]:/*) ;; *) common="${top}/${common}" ;; esac
      case "$gdir" in /*|[A-Za-z]:/*) ;; *) gdir="${top}/${gdir}" ;; esac
      ;;
  esac
  [ -n "$common" ] && [ -n "$gdir" ] && [ -n "$top" ] && [ -n "$branch" ] || return 1
  # Both folders with their links resolved, in one subshell
  real="$(cd "$common" 2>/dev/null && pwd -P && cd "$gdir" 2>/dev/null && pwd -P)" || return 1
  case "$real" in *$'\n'*) ;; *) return 1 ;; esac
  common="${real%%$'\n'*}"; gdir="${real#*$'\n'}"
  [ -n "$common" ] && [ -n "$gdir" ] || return 1
  [ "$gdir" = "$common" ] || W_LINKED=1
  W_COMMON="$common"; W_TOP="$top"; W_BRANCH="${branch#refs/heads/}"
}
# automatic <branch>: a branch Claude Code named for a worktree of its own, or none
automatic() {
  case "$1" in ''|HEAD|worktree-agent-*|worktree-wf_*) return 0 ;; esac
  return 1
}

wt_info "$AGENT_CWD" || exit 0
A_COMMON="$W_COMMON"; A_LINKED="$W_LINKED"; A_TOP="$W_TOP"; A_BRANCH="$W_BRANCH"
S_TOP=""
if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  if [ "$SESSION_CWD" = "$AGENT_CWD" ]; then
    S_TOP="$A_TOP"
  elif wt_info "$SESSION_CWD"; then
    S_TOP="$W_TOP"
    # An agent that worked in another repository than its session's stays with its
    # session: the report of its session's branch keeps it (an agent leaves a branch only
    # for one of the same repository), so the other repository's must not count it too
    [ "$W_COMMON" = "$A_COMMON" ] || exit 0
  fi
fi
# The repository's key, as generate-pr-report.sh spells it: Windows paths in any case
cc_is_windows && A_COMMON="$(printf '%s' "$A_COMMON" | tr 'A-Z' 'a-z')"

BRANCH=""
WT=""
HOW=""
if [ "$A_LINKED" = "1" ] && [ "$A_TOP" != "$S_TOP" ]; then
  # A worktree of its own: its branch, whatever the agent's commands say
  automatic "$A_BRANCH" || { BRANCH="$A_BRANCH"; WT="$A_TOP"; HOW="cwd"; }
else
  # The session's folder or the main folder: the worktree its tool calls name, among the
  # repository's other worktrees, each with its spellings (one JSON array)
  HOME_U="${HOME:-}"
  cc_path_vars HOME_U
  HOME_N="$HOME_U"
  cc_is_windows && HOME_N="$(cc_native_path "$HOME_U")"
  CANDIDATES="$(git -C "$A_TOP" worktree list --porcelain 2>/dev/null \
    | awk -v top="$A_TOP" -v stop="$S_TOP" -v home="$HOME_U" -v homen="$HOME_N" "$CC_AWK_AGENT_CANDIDATES")"
  if [ -n "$CANDIDATES" ] && [ "$CANDIDATES" != "[]" ]; then
    # Two lines: the branch, then its worktree as git spells it
    FOUND="$({ printf '%s\n' "$CANDIDATES"; grep -F '"tool_use"' "$AGENT_T" 2>/dev/null; } \
      | jq -R -n -r "$CC_JQ_AGENT_BRANCH" 2>/dev/null)" || FOUND=""
    FOUND="${FOUND//$'\r'/}"
    case "$FOUND" in
      *$'\n'*)
        BRANCH="${FOUND%%$'\n'*}"; WT="${FOUND#*$'\n'}"
        [ -n "$BRANCH" ] && [ -n "$WT" ] && HOW="cited"
        ;;
    esac
  fi
fi
[ -n "$HOW" ] || exit 0

# The agent's final message, when its transcript does not hold it yet: read again every
# 0.2 s, for at most 1 s (the hook holds back the agent's result meanwhile). It is there
# when the last line of assistant text in the transcript's tail holds the message's end
# (the key goes through the environment: awk -v would read its backslashes as escapes).
if [ -n "$LAST_KEY" ]; then
  k=0
  while ! tail -n 40 "$AGENT_T" 2>/dev/null | LC_ALL=C CC_LAST_KEY="$LAST_KEY" awk '
      index($0, "\"type\":\"assistant\"") && index($0, "\"type\":\"text\"") { last = index($0, ENVIRON["CC_LAST_KEY"]) > 0 }
      END { exit !last }' 2>/dev/null; do
    [ "$k" -lt 5 ] || break
    sleep 0.2 2>/dev/null || break
    k=$((k + 1))
  done
fi

# The agent's usage, as its session's pass reads this file (per-file reduction, its own
# dominant model for the messages without one), priced per model: the same R lines
USAGE="$(cc_session_usage "$FACTORS_FILE" "$PRICES_FILE" "$AGENT_T")" || exit 0
# Its last message (the S line's last timestamp), which its session's row must postdate
cc_parse_usage "$USAGE"
# SQL literals, quotes doubled in place (the ids are checked above)
V_KEY="'${SESSION_ID}', '${AGENT_ID}', '${A_COMMON//$CC_SQ/$CC_SQ$CC_SQ}', '${BRANCH//$CC_SQ/$CC_SQ$CC_SQ}', '${WT//$CC_SQ/$CC_SQ$CC_SQ}', '${HOW}'"
V_LAST="'${CC_U_LAST_TS//$CC_SQ/$CC_SQ$CC_SQ}'"
ROWS=""
while IFS=$'\t' read -r tag model it cw cw1h cr out co2 cost; do
  [ "$tag" = "R" ] || continue
  case "${it}${cw}${cw1h}${cr}${out}" in ''|*[!0-9]*) continue ;; esac
  case "$co2$cost" in ''|*[!0-9.]*) continue ;; esac
  ROWS="${ROWS}INSERT INTO agent_usage (session_id, agent_id, repo, git_branch, worktree, how, model, input_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, output_tokens, co2_grams, cost_usd, last_ts, seen_at) VALUES (${V_KEY}, '${model//$CC_SQ/$CC_SQ$CC_SQ}', ${it}, ${cw}, ${cw1h}, ${cr}, ${out}, ${co2}, ${cost}, ${V_LAST}, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
"
done <<EOF
$USAGE
EOF

# The agent's rows replaced in one transaction (a resumed agent ends again with larger
# totals). Many agents of a workflow can end at once: one more try after the busy timeout.
# The hook runs before the agent's result is handed back, so it never waits more than
# about 10 s: the same 5 s timeout as the plugin's other writers, twice. A database busy
# longer than that (a long read elsewhere) loses the record: the agent then counts with
# its session.
SQL="${CC_AGENT_USAGE_DDL}
BEGIN IMMEDIATE;
DELETE FROM agent_usage WHERE session_id = '${SESSION_ID}' AND agent_id = '${AGENT_ID}';
${ROWS}COMMIT;"
sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$SQL" >/dev/null 2>&1 \
  || sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$SQL" >/dev/null 2>&1 || true
exit 0
