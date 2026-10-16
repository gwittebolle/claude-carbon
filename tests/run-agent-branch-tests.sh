#!/usr/bin/env bash
# run-agent-branch-tests.sh: the SubagentStop hook (agent-stop.sh) records an agent that
# worked on a branch of its own, and /carbon-pr counts it there. Sessions in a real
# repository with worktrees, their agents ending one by one, each hook fed the fields
# Claude Code sends (agent_id, agent_type, agent_transcript_path, cwd, session_id,
# transcript_path). Assert that:
#   1. an agent in a linked worktree of its own counts on that worktree's branch (an
#      isolated agent on the branch it made, a workflow agent on a real branch), not when
#      Claude Code named the branch (worktree-agent-*, worktree-wf_*) or it is detached;
#      a branch the user named worktree-foo is a branch;
#   2. an agent in the session's folder (or a subfolder of the main folder) counts on the
#      worktree it names in at least half of its calls that give a place: absolute, ../
#      relative, ~/ with a shell-escaped space, ./ inside; x-1013 is not named by
#      x-1013-facultatif; naming the main folder, a worktree Claude Code named, a detached
#      one, two worktrees as often, one in less than half of the calls, or a worktree's
#      bare one-word name in a message or a description moves nothing;
#   3. a session that itself runs in a worktree: its agents there are not "in a worktree
#      of their own", and its own folder is not a worktree they name;
#   4. left alone: a cwd outside any repository, Claude Code's own agents (no type, or a
#      transcript its session does not read), forks (meta.json or agent type); a resumed
#      agent's rows are replaced, or kept when no branch is found any more; twenty agents
#      ending at once are all recorded;
#   5. the C:/, c:/, /c/ and ~/ spellings of a Windows worktree are recognised;
#   6. the report: a branch sums its sessions, minus their agents gone elsewhere, plus the
#      agents of other sessions come to it, and says so, per model too (a model left with
#      nothing is not shown); the branches add up to the sessions (tokens exactly, CO2 and
#      cost at %.4f); a row an older writer left (agents_collected 0), a frozen (v1) row
#      and a row written before its agent ended take no agent part, and nothing goes below
#      zero; a PR from a fork is refused;
#   7. recompute.sh re-derives agent_usage, also for a session not recorded yet, never a
#      v1 session's;
#   8. no jq is started with more than 30,000 bytes of arguments (150 worktrees);
#   9. without any agent row the comment is byte for byte the 1.15.6 one, also on a
#      read-only database that has no agent_usage table.
#
# Throwaway dirs only (HOME, CLAUDE_CONFIG_DIR, CLAUDE_CARBON_DB, a scratch repository);
# the real ~/.claude is never read or written. bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="${REPO_DIR}/scripts/agent-stop.sh"
PERSIST="${REPO_DIR}/scripts/persist-session.sh"
RECOMPUTE="${REPO_DIR}/scripts/recompute.sh"
PR_SCRIPT="${CC_TEST_PR_SCRIPT:-${REPO_DIR}/scripts/generate-pr-report.sh}"
FACTORS="${REPO_DIR}/data/factors.json"
PRICES="${REPO_DIR}/data/prices.json"

for c in sqlite3 jq awk git; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-agent-branch-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-agent-branch-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT
# A home of its own: ~/ in the agents' commands, and no user git configuration
export HOME="${TMPROOT}/home"
mkdir -p "$HOME"

PASSED=0
FAILED=0
check() {
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1)); echo "PASS $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"
  fi
}
# has <text> <output>: yes when the output contains the text
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# ---------------------------------------------------------------- the repository
git_q() { git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1; }
CODE="${HOME}/code"
MAIN="${CODE}/proj"
mkdir -p "$MAIN/src"
git -C "$MAIN" init -q -b main 2>/dev/null || { git -C "$MAIN" init -q; git -C "$MAIN" checkout -q -b main; }
git_q -C "$MAIN" commit -q --allow-empty -m init
WTS="${CODE}/.worktrees"
git_q -C "$MAIN" worktree add -q -b feat/t-1013 "${WTS}/proj-1013"
git_q -C "$MAIN" worktree add -q -b feat/t-1013-fac "${WTS}/proj-1013-facultatif"
git_q -C "$MAIN" worktree add -q -b feat/space "${WTS}/proj sp"
git_q -C "$MAIN" worktree add -q -b feat/other "${WTS}/proj-other"
git_q -C "$MAIN" worktree add -q --detach "${WTS}/proj-det"
git_q -C "$MAIN" worktree add -q -b feat/side "${CODE}/proj-wt-side"
# Isolated agents: Claude Code names the branch; one agent made its own
git_q -C "$MAIN" worktree add -q -b worktree-agent-iso1 "${MAIN}/.claude/worktrees/agent-iso1"
git_q -C "${MAIN}/.claude/worktrees/agent-iso1" checkout -q -b feat/iso
git_q -C "$MAIN" worktree add -q -b worktree-agent-iso2 "${MAIN}/.claude/worktrees/agent-iso2"
# Workflow agents: one left on the branch Claude Code named, one that made a real one
git_q -C "$MAIN" worktree add -q -b worktree-wf_run-1 "${MAIN}/.claude/worktrees/wf_run-1"
git_q -C "$MAIN" worktree add -q -b worktree-wf_run-2 "${MAIN}/.claude/worktrees/wf_run-2"
git_q -C "${MAIN}/.claude/worktrees/wf_run-2" checkout -q -b feat/wf-real
# claude --worktree foo: a branch the user asked for
git_q -C "$MAIN" worktree add -q -b worktree-foo "${MAIN}/.claude/worktrees/foo"
# A worktree at the repository's root under a one-word name
git_q -C "$MAIN" worktree add -q -b feat/docs "${MAIN}/docs"
# The paths as git spells them: what the agents' commands name, and their cwd
wt() { git -C "$MAIN" worktree list --porcelain | tr -d '\r' | sed -n 's/^worktree //p' | grep "/$1\$"; }
P_MAIN="$(wt proj)"; P_1013="$(wt proj-1013)"; P_FAC="$(wt proj-1013-facultatif)"; P_SP="$(wt 'proj sp')"
P_OTHER="$(wt proj-other)"; P_DET="$(wt proj-det)"; P_SIDE="$(wt proj-wt-side)"
P_ISO1="$(wt agent-iso1)"; P_ISO2="$(wt agent-iso2)"; P_WF1="$(wt wf_run-1)"; P_WF2="$(wt wf_run-2)"; P_FOO="$(wt foo)"; P_DOCS="$(wt docs)"
check "setup: the worktrees" "yes" \
  "$([ -n "$P_DOCS" ] && [ -n "$P_MAIN" ] && [ -n "$P_1013" ] && [ -n "$P_FAC" ] && [ -n "$P_SP" ] && [ -n "$P_SIDE" ] && [ -n "$P_ISO1" ] && [ -n "$P_WF2" ] && [ -n "$P_FOO" ] && echo yes || echo no)"

CFG="${TMPROOT}/cfg"
DB="${CFG}/claude-carbon/carbon.db"
PROJ="${CFG}/projects/-code-proj"
mkdir -p "${CFG}/claude-carbon" "$PROJ"
SCHEMA="CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0);"
sqlite3 "$DB" "$SCHEMA"
q() { sqlite3 "$DB" "$1" 2>/dev/null; }

# msg <id> <input> <output> <cwd> [tool inputs, a JSON array]: one assistant message
msg() {
  jq -n -c --arg id "$1" --argjson in "$2" --argjson out "$3" --arg cwd "$4" --argjson tools "${5:-[]}" \
    --arg b "${MSG_BRANCH:-main}" --arg m "${MSG_MODEL:-claude-opus-5-5}" \
    '{type: "assistant", requestId: ("r" + $id), timestamp: "2026-01-01T10:00:00.250Z", gitBranch: $b, cwd: $cwd,
      message: {id: ("m" + $id), model: $m,
                content: ([{type: "text", text: "working"}] + [$tools | to_entries[] | {type: "tool_use", id: ("t" + $id + "-" + (.key | tostring)), name: "Bash", input: .value}]),
                usage: {input_tokens: $in, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: $out}}}'
}
cmd() { jq -n -c --arg c "$1" '{command: $c, description: "step"}'; }
# session <sid> <cwd> <branch> <input> <output>: a main transcript whose first line gives its folder
session() {
  { jq -n -c --arg c "$2" --arg b "$3" '{type: "user", cwd: $c, gitBranch: $b, message: {role: "user", content: "go"}}'
    MSG_BRANCH="$3" msg "0$1" "$4" "$5" "$2"; } > "${PROJ}/$1.jsonl"
}
# agent <sid> <agent id> <input> <output> <cwd> [calls...]: the agent's transcript, one
# message without any call, then one message per call (1 token in, 1 out)
agent() {
  local s="$1" id="$2" in="$3" out="$4" cwd="$5" k=0 a f
  shift 5
  f="${AGENT_FILE:-${PROJ}/${s}/subagents/agent-${id}.jsonl}"
  mkdir -p "${f%/*}"
  msg "${id}x" "$in" "$out" "$cwd" > "$f"
  for a in "$@"; do
    msg "${id}${k}" 1 1 "$cwd" "[$a]" >> "$f"
    k=$((k + 1))
  done
}
# stop <sid> <agent id> <cwd> [agent type] [transcript]: SubagentStop as Claude Code sends it
stop_input() {
  local s="$1" id="$2" cwd="${3:-}" type="${4-general-purpose}" t="${5:-${PROJ}/$1/subagents/agent-$2.jsonl}"
  jq -n -c --arg s "$s" --arg t "${PROJ}/$s.jsonl" --arg id "$id" --arg at "$t" --arg type "$type" --arg cwd "$cwd" \
    '{session_id: $s, transcript_path: $t, cwd: $cwd, permission_mode: "default", hook_event_name: "SubagentStop",
      stop_hook_active: false, agent_id: $id, agent_type: $type, agent_transcript_path: $at,
      last_assistant_message: "done", background_tasks: [], session_crons: []}'
}
stop() { stop_input "$@" | CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK"; }
branch_of() { q "SELECT group_concat(DISTINCT git_branch || ':' || how) FROM agent_usage WHERE session_id='$1' AND agent_id='$2';"; }

# ---------------------------------------------------------------- 1 to 4. the agents of four sessions
S="33333333-aaaa-bbbb-cccc-000000000001"
session "$S" "$P_MAIN" main 100 10
# The session's folder, naming a worktree in 3 of its 4 calls
agent "$S" aaa 200 20 "$P_MAIN" "$(cmd "cd '$P_1013' && make")" "$(cmd "git -C \"$P_1013\" status")" \
  "$(jq -n -c --arg p "$P_1013/src/x.ts" '{file_path: $p}')" "$(cmd ls)"
# ../ relative, its path starting like proj-1013's
agent "$S" bbb 300 30 "$P_MAIN" "$(cmd "cd ../.worktrees/proj-1013-facultatif && ls")"
# ~/ with a shell-escaped space
agent "$S" sss 310 31 "$P_MAIN" "$(cmd 'cd ~/code/.worktrees/proj\ sp && npm test')" "$(cmd 'git -C ~/code/.worktrees/proj\ sp log -1')"
agent "$S" ccc 400 40 "$P_MAIN" "$(cmd "cat '$P_MAIN/src/a.ts'")"
agent "$S" mmm 410 41 "$P_MAIN" "$(cmd "cat '$P_ISO2/x'")" "$(cmd "ls '$P_WF1'")"
agent "$S" jjj 420 42 "$P_MAIN" "$(cmd "ls '$P_DET'")"
agent "$S" ooo 430 43 "$P_MAIN" "$(cmd "cd '$P_1013'")" "$(cmd "cd '$P_OTHER'")"
agent "$S" ppp 440 44 "$P_MAIN" "$(cmd "cd '$P_OTHER'")" "$(cmd ls)" "$(cmd pwd)"
agent "$S" qqq 450 45 "$P_MAIN"
agent "$S" ddd 500 50 "$P_ISO1"
agent "$S" dd2 510 51 "$P_ISO2" "$(cmd "cd '$P_1013'")"
AGENT_FILE="${PROJ}/${S}/subagents/workflows/wf_run/agent-eee.jsonl" agent "$S" eee 600 60 "$P_WF1"
AGENT_FILE="${PROJ}/${S}/subagents/workflows/wf_run/agent-fff.jsonl" agent "$S" fff 700 70 "$P_WF2"
agent "$S" hhh 800 80 "$P_FOO"
agent "$S" iii 900 90 "$P_MAIN/src"
agent "$S" ii2 910 91 "$P_MAIN/src" "$(cmd "cd $P_1013/src")"
agent "$S" kkk 110 11 "$P_ISO1"
printf '{"agentType":"fork","isFork":true}\n' > "${PROJ}/${S}/subagents/agent-kkk.meta.json"
agent "$S" kk2 120 12 "$P_ISO1"
# A one-word worktree name in a commit message and a description: not a place
agent "$S" wrd 140 14 "$P_MAIN" "$(jq -n -c '{command: "git commit -m \"update docs\"", description: "Update docs"}')" "$(cmd "npm test")"
agent "$S" dot 150 15 "$P_MAIN" "$(cmd "cd ./docs && make")" "$(jq -n -c '{todos: []}')"
# An agent on another model than its session
MSG_MODEL=claude-haiku-4-5 agent "$S" hku 160 16 "$P_MAIN" "$(cmd "cd '$P_1013' && make")"
mkdir -p "${TMPROOT}/elsewhere"
agent "$S" out 130 13 "${TMPROOT}/elsewhere" "$(cmd "cd '$P_1013'")"
stop "$S" aaa "$P_MAIN"
stop "$S" bbb "$P_MAIN"
stop "$S" sss "$P_MAIN"
stop "$S" ccc "$P_MAIN"
stop "$S" mmm "$P_MAIN"
stop "$S" jjj "$P_MAIN"
stop "$S" ooo "$P_MAIN"
stop "$S" ppp "$P_MAIN"
stop "$S" qqq "$P_MAIN"
stop "$S" ddd "$P_ISO1"
stop "$S" dd2 "$P_ISO2"
stop "$S" eee "$P_WF1" workflow-subagent "${PROJ}/${S}/subagents/workflows/wf_run/agent-eee.jsonl"
stop "$S" fff "$P_WF2" workflow-subagent "${PROJ}/${S}/subagents/workflows/wf_run/agent-fff.jsonl"
stop "$S" hhh "$P_FOO"
stop "$S" iii "$P_MAIN/src"
stop "$S" ii2 "$P_MAIN/src"
stop "$S" kkk "$P_ISO1"
stop "$S" kk2 "$P_ISO1" fork
stop "$S" out "${TMPROOT}/elsewhere"
stop "$S" wrd "$P_MAIN"
stop "$S" dot "$P_MAIN"
stop "$S" hku "$P_MAIN"
check "isolated agent, on the branch it made: that branch" "feat/iso:cwd" "$(branch_of "$S" ddd)"
check "isolated agent, on the branch Claude Code named: nothing, whatever it names" "" "$(branch_of "$S" dd2)"
check "workflow agent, on worktree-wf_*: nothing" "" "$(branch_of "$S" eee)"
check "workflow agent, on a branch it made (transcript under workflows/)" "feat/wf-real:cwd" "$(branch_of "$S" fff)"
check "a branch the user named worktree-foo: a branch" "worktree-foo:cwd" "$(branch_of "$S" hhh)"
check "the session's folder, a worktree named in 3 of 4 calls" "feat/t-1013:cited" "$(branch_of "$S" aaa)"
check "../ relative, x-1013-facultatif not taken for x-1013" "feat/t-1013-fac:cited" "$(branch_of "$S" bbb)"
check "a path under ~/, with a shell-escaped space" "feat/space:cited" "$(branch_of "$S" sss)"
check "the main folder named: nothing" "" "$(branch_of "$S" ccc)"
check "worktrees Claude Code named, named: nothing" "" "$(branch_of "$S" mmm)"
check "a detached worktree named: nothing" "" "$(branch_of "$S" jjj)"
check "two worktrees named as often: nothing" "" "$(branch_of "$S" ooo)"
check "a worktree named in 1 of 3 calls: nothing" "" "$(branch_of "$S" ppp)"
check "no tool call: nothing" "" "$(branch_of "$S" qqq)"
check "a subfolder of the main folder is not a worktree of its own" "" "$(branch_of "$S" iii)"
check "a subfolder of the main folder, naming a worktree" "feat/t-1013:cited" "$(branch_of "$S" ii2)"
check "a fork (meta.json): nothing" "" "$(branch_of "$S" kkk)"
check "a fork (agent type): nothing" "" "$(branch_of "$S" kk2)"
check "a cwd outside any repository: nothing" "" "$(branch_of "$S" out)"
check "a one-word worktree name in a message or a description: nothing" "" "$(branch_of "$S" wrd)"
check "./ inside the main folder, a call without a place not counted" "feat/docs:cited" "$(branch_of "$S" dot)"
check "an agent on another model" "feat/t-1013:cited|claude-haiku-4-5" "$(branch_of "$S" hku)|$(q "SELECT model FROM agent_usage WHERE agent_id='hku';")"
# aaa: 200 + 4 x 1 tokens in, 20 + 4 x 1 out, on Opus, priced by hand from the data files
OPUS="$(jq -r '"\(.models.opus.input) \(.models.opus.output)"' "$FACTORS") $(jq -r '"\(.models.opus.input) \(.models.opus.output)"' "$PRICES")"
check "the agent's own usage, priced at its model" \
  "$(echo "$OPUS" | awk '{ printf "204|24|%.4f|%.6f|2026-01-01T10:00:00.250Z", (204 * $1 + 24 * $2) / 1e6, (204 * $3 + 24 * $4) / 1e6 }')" \
  "$(q "SELECT input_tokens || '|' || output_tokens || '|' || printf('%.4f', co2_grams) || '|' || printf('%.6f', cost_usd) || '|' || last_ts FROM agent_usage WHERE agent_id='aaa';")"
REPO_KEY="$(cd "${P_MAIN}/.git" && pwd -P)"
cc_is_windows && REPO_KEY="$(printf '%s' "$REPO_KEY" | tr 'A-Z' 'a-z')"
check "the repository: its common git folder" "$REPO_KEY" "$(q "SELECT DISTINCT repo FROM agent_usage WHERE agent_id='ddd';")"

# Claude Code's own agents: no type, or a transcript its session's row does not read
msg "x" 10 1 "$P_MAIN" > "${TMPROOT}/elsewhere/agent-int.jsonl"
stop "$S" int "$P_ISO1" general-purpose "${TMPROOT}/elsewhere/agent-int.jsonl"
agent "$S" int2 10 1 "$P_ISO1"
stop "$S" int2 "$P_ISO1" ""
AGENT_FILE="${PROJ}/${S}/subagents/deeper/agent-int3.jsonl" agent "$S" int3 10 1 "$P_ISO1"
stop "$S" int3 "$P_ISO1" general-purpose "${PROJ}/${S}/subagents/deeper/agent-int3.jsonl"
stop "$S" ghost "$P_ISO1"
check "Claude Code's own agents (no type, a transcript elsewhere or none): nothing" "0" \
  "$(q "SELECT COUNT(*) FROM agent_usage WHERE agent_id IN ('int', 'int2', 'int3', 'ghost');")"

# Resumed: aaa wrote more and ends again; bbb then names the main folder far more often
msg "aaa-r" 1000 100 "$P_MAIN" "[$(cmd "cd '$P_1013'")]" >> "${PROJ}/${S}/subagents/agent-aaa.jsonl"
stop "$S" aaa "$P_MAIN"
check "a resumed agent: its rows replaced with the new totals" "1|1204|124" \
  "$(q "SELECT COUNT(*) || '|' || SUM(input_tokens) || '|' || SUM(output_tokens) FROM agent_usage WHERE agent_id='aaa';")"
BBB_BEFORE="$(q "SELECT input_tokens || '|' || output_tokens || '|' || git_branch FROM agent_usage WHERE agent_id='bbb';")"
for k in 1 2 3; do msg "bbb-r$k" 5 5 "$P_MAIN" "[$(cmd "cat '$P_MAIN/README'")]" >> "${PROJ}/${S}/subagents/agent-bbb.jsonl"; done
stop "$S" bbb "$P_MAIN"
check "a resumed agent with no branch found any more: its earlier rows kept" "$BBB_BEFORE" \
  "$(q "SELECT input_tokens || '|' || output_tokens || '|' || git_branch FROM agent_usage WHERE agent_id='bbb';")"

# A session that itself runs in a linked worktree (claude --worktree, or a session opened there)
S2="33333333-aaaa-bbbb-cccc-000000000002"
session "$S2" "$P_SIDE" feat/side 100 10
agent "$S2" lll 300 30 "$P_SIDE" "$(cmd "cat '$P_SIDE/src/a.ts'")"
agent "$S2" ll2 310 31 "$P_SIDE" "$(cmd "cd '$P_1013' && npm test")"
agent "$S2" ll3 320 32 "$P_ISO1"
stop "$S2" lll "$P_SIDE"
stop "$S2" ll2 "$P_SIDE"
stop "$S2" ll3 "$P_ISO1"
check "a session in a worktree, its agent there naming that worktree: nothing" "" "$(branch_of "$S2" lll)"
check "a session in a worktree, its agent there naming another one" "feat/t-1013:cited" "$(branch_of "$S2" ll2)"
check "a session in a worktree, its agent in a worktree of its own" "feat/iso:cwd" "$(branch_of "$S2" ll3)"

# Twenty agents of a workflow ending at once
S3="33333333-aaaa-bbbb-cccc-000000000003"
session "$S3" "$P_MAIN" main 100 10
k=0
while [ "$k" -lt 20 ]; do AGENT_FILE="${PROJ}/${S3}/subagents/workflows/wf_b/agent-w$k.jsonl" agent "$S3" "w$k" 100 10 "$P_ISO1"; k=$((k + 1)); done
k=0
while [ "$k" -lt 20 ]; do
  stop "$S3" "w$k" "$P_ISO1" workflow-subagent "${PROJ}/${S3}/subagents/workflows/wf_b/agent-w$k.jsonl" &
  k=$((k + 1))
done
wait
check "twenty agents ending at once: all recorded" "20" "$(q "SELECT COUNT(DISTINCT agent_id) FROM agent_usage WHERE session_id='${S3}';")"

# A session run in the worktree of feat/t-1013 itself, without agents
S4="33333333-aaaa-bbbb-cccc-000000000004"
session "$S4" "$P_1013" feat/t-1013 150 15

# ---------------------------------------------------------------- 5. Windows spellings
WIN_WTS="worktree C:/Users/me/code/proj
HEAD 0
branch refs/heads/main

worktree C:/Users/me/code/.worktrees/proj-x
HEAD 0
branch refs/heads/feat/x

worktree C:/Users/me/code/.worktrees/proj-x-extra
HEAD 0
branch refs/heads/feat/x-extra
"
WIN_C="$(printf '%s' "$WIN_WTS" | awk -v top="C:/Users/me/code/proj" -v stop="C:/Users/me/code/proj" -v home="/c/Users/me" "$CC_AWK_AGENT_CANDIDATES")"
check "Windows: each spelling of a worktree" \
  "../.worktrees/proj-x /c/Users/me/code/.worktrees/proj-x C:/Users/me/code/.worktrees/proj-x c:/Users/me/code/.worktrees/proj-x ~/code/.worktrees/proj-x" \
  "$(printf '%s' "$WIN_C" | jq -r '[.[] | select(.b == "feat/x") | .p] | sort | join(" ")' | tr -d '\r')"
win_names() { { printf '%s\n' "$WIN_C"; msg w 1 1 C:/ "[$(cmd "$1")]"; } | jq -R -n -r "$CC_JQ_AGENT_BRANCH" | tr -d '\r'; }
check "Windows: C:\\ with backslashes" "feat/x" "$(win_names 'cd C:\Users\me\code\.worktrees\proj-x && dir')"
check "Windows: /c/" "feat/x" "$(win_names 'cd /c/Users/me/code/.worktrees/proj-x')"
check "Windows: c:/" "feat/x" "$(win_names 'git -C c:/Users/me/code/.worktrees/proj-x status')"
check "Windows: a longer name is another worktree" "feat/x-extra" "$(win_names 'cd C:\Users\me\code\.worktrees\proj-x-extra')"

# ---------------------------------------------------------------- 6. the report
payload() { jq -n --arg s "$1" --arg t "${PROJ}/$1.jsonl" --arg c "$2" '{session_id: $s, transcript_path: $t, cwd: $c}'; }
payload "$S" "$P_MAIN" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
payload "$S2" "$P_SIDE" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
payload "$S3" "$P_MAIN" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
payload "$S4" "$P_1013" | CLAUDE_CONFIG_DIR="$CFG" bash "$PERSIST"
check "setup: four sessions recorded, every agent read" "4" "$(q "SELECT COUNT(*) FROM sessions WHERE agents_collected = 2;")"

STUBS="${TMPROOT}/stubs"
mkdir -p "$STUBS"
cat > "${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view 1 --json headRefName,isCrossRepository --jq "*) echo "feat/iso false" ;;
  "pr view 2 --json headRefName,isCrossRepository --jq "*) echo "main false" ;;
  "pr view 3 --json headRefName,isCrossRepository --jq "*) echo "feat/t-1013-fac false" ;;
  "pr view 4 --json headRefName,isCrossRepository --jq "*) echo "feat/wf-real false" ;;
  "pr view 5 --json headRefName,isCrossRepository --jq "*) echo "worktree-foo false" ;;
  "pr view 6 --json headRefName,isCrossRepository --jq "*) echo "feat/space false" ;;
  "pr view 7 --json headRefName,isCrossRepository --jq "*) echo "feat/docs false" ;;
  "pr view 9 --json headRefName,isCrossRepository --jq "*) echo "feat/t-1013 true" ;;
  *) exit 1 ;;
esac
STUB
# sqlite3 as the report runs it, with its totals query's answer kept aside: the figures
# before any rounding for display
REAL_SQLITE="$(command -v sqlite3)"
cat > "${STUBS}/sqlite3" <<STUB
#!/usr/bin/env bash
out="\$("${REAL_SQLITE}" "\$@")"; rc=\$?
case "\$*" in *"WHEN sign > 0 THEN sid END"*) printf '%s\n' "\$out" > "${TMPROOT}/raw" ;; esac
[ -z "\$out" ] || printf '%s\n' "\$out"
exit \$rc
STUB
chmod +x "${STUBS}/gh" "${STUBS}/sqlite3"
report() { (cd "$1" && PATH="${STUBS}:$PATH" CLAUDE_CARBON_DB="$DB" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" --dry-run "${@:2}"); }
# raw <dir> [--pr N]: "sessions|co2|cost|tokens|cache reads|sessions elsewhere", unrounded
raw() { : > "${TMPROOT}/raw"; report "$@" >/dev/null 2>&1; tr -d '\r' < "${TMPROOT}/raw"; }
tok() { q "SELECT input_tokens + output_tokens FROM sessions WHERE session_id='$1';"; }
atok() { q "SELECT COALESCE(SUM(input_tokens + output_tokens), 0) FROM agent_usage WHERE $1;"; }

OUT="$(report "$P_1013")"
# feat/t-1013, from its worktree: S4, plus aaa, ii2 and hku (of S) and ll2 (of S2)
check "feat/t-1013: its session, and the agents of two sessions run elsewhere" \
  "3|$(( $(tok "$S4") + $(atok "agent_id IN ('aaa', 'ii2', 'll2', 'hku')") ))|2" \
  "$(raw "$P_1013" | awk -F '|' '{ print $1 "|" $4 "|" $6 }')"
check "feat/t-1013: the comment says so" "yes" \
  "$(has 'Includes the agents of 2 session(s) recorded under another branch or folder that worked on this branch.' "$OUT")"
# main: S and S3, without their agents gone to other branches
check "main: its sessions without the agents that left" \
  "2|$(( $(tok "$S") + $(tok "$S3") - $(atok "session_id IN ('$S', '$S3')") ))|0" \
  "$(raw "$P_MAIN" --pr 2 | awk -F '|' '{ print $1 "|" $4 "|" $6 }')"
check "main: no agents line" "no" "$(has 'Includes the agents' "$(report "$P_MAIN" --pr 2)")"
check "feat/iso: the agents of three sessions, no session of its own" \
  "3|$(atok "git_branch = 'feat/iso'")|3" "$(raw "$P_MAIN" --pr 1 | awk -F '|' '{ print $1 "|" $4 "|" $6 }')"
ERR="$(report "$P_MAIN" --pr 9 2>&1)"
check "a PR from a fork: refused, nothing summed" "yes|no" \
  "$(has 'comes from a fork' "$ERR")|$(has 'developing this PR' "$ERR")"

# The branches add up to the sessions: tokens exactly, CO2 and cost at %.4f
SUMS="$( { raw "$P_MAIN" --pr 2; raw "$P_SIDE"; raw "$P_1013"; raw "$P_MAIN" --pr 1; raw "$P_MAIN" --pr 3
           raw "$P_MAIN" --pr 4; raw "$P_MAIN" --pr 5; raw "$P_MAIN" --pr 6; raw "$P_MAIN" --pr 7; } \
  | awk -F '|' '{ c += $2; k += $3; t += $4; r += $5 } END { printf "%.0f|%.0f|%.4f|%.4f\n", t, r, c, k }')"
check "the branches add up to the sessions" \
  "$(q "SELECT printf('%d|%d|%.4f|%.4f', SUM(input_tokens + output_tokens), SUM(cache_read_tokens), SUM(co2_grams), SUM(cost_usd)) FROM sessions;")" \
  "$SUMS"

# A row an older writer left takes no agent part: main counts S whole, feat/iso loses ddd
q "UPDATE sessions SET agents_collected = 0 WHERE session_id='${S}';"
check "an older writer's row: main counts it whole" "$(( $(tok "$S") + $(tok "$S3") - $(atok "session_id = '$S3'") ))" \
  "$(raw "$P_MAIN" --pr 2 | awk -F '|' '{ print $4 }')"
check "an older writer's row: its agents counted nowhere else" "$(atok "git_branch = 'feat/iso' AND session_id <> '$S'")" \
  "$(raw "$P_MAIN" --pr 1 | awk -F '|' '{ print $4 }')"
q "UPDATE sessions SET agents_collected = 2 WHERE session_id='${S}';"
q "UPDATE sessions SET methodology_version = 1 WHERE session_id='${S3}';"
check "a frozen (v1) row: its agents not counted" "$(atok "git_branch = 'feat/iso' AND session_id <> '$S3'")" \
  "$(raw "$P_MAIN" --pr 1 | awk -F '|' '{ print $4 }')"
q "UPDATE sessions SET methodology_version = 2 WHERE session_id='${S3}';"

# Per model: hku's Haiku tokens leave main entirely (no Haiku row there), and come to feat/t-1013
check "per model: a model that left entirely is not shown" "no" "$(has '`claude-haiku-4-5`' "$(report "$P_MAIN" --pr 2)")"
check "per model: it is shown where its agent went" "yes" \
  "$(has "| \`claude-haiku-4-5\` | 1 | $(q "SELECT input_tokens - cache_creation_tokens FROM agent_usage WHERE agent_id='hku';") |" "$(report "$P_1013")")"
# The Opus row of main: its sessions' Opus tokens without its agents' (as the report
# formats them: uncached input, then output)
fmt_tok() { awk '{ if ($1 >= 1000000) printf "%.1fM\n", $1 / 1000000; else if ($1 >= 1000) printf "%.0fk\n", $1 / 1000; else printf "%d\n", $1 }'; }
OPUS_SQL="FROM session_models WHERE model = 'claude-opus-5-5' AND session_id IN ('$S', '$S3')"
AGENT_SQL="FROM agent_usage WHERE model = 'claude-opus-5-5' AND session_id IN ('$S', '$S3')"
check "per model: main's Opus row, without the agents that left" \
  "$(q "SELECT (SELECT SUM(input_tokens - cache_creation_tokens) $OPUS_SQL) - (SELECT SUM(input_tokens - cache_creation_tokens) $AGENT_SQL);" | fmt_tok)|$(q "SELECT (SELECT SUM(output_tokens) $OPUS_SQL) - (SELECT SUM(output_tokens) $AGENT_SQL);" | fmt_tok)" \
  "$(report "$P_MAIN" --pr 2 | awk -F '|' '/^\| `claude-opus-5-5`/ { gsub(/ /, ""); print $4 "|" $7 }')"

# A row written before its agents ended (they ended after the session's last Stop): its
# agents stay with it until the next one, and no total goes below zero
q "UPDATE sessions SET ended_at = '2025-12-31T23:59:59Z' WHERE session_id='${S}';"
check "a row older than its agents: main counts it whole" "$(( $(tok "$S") + $(tok "$S3") - $(atok "session_id = '$S3'") ))" \
  "$(raw "$P_MAIN" --pr 2 | awk -F '|' '{ print $4 }')"
check "a row older than its agents: they are not counted elsewhere yet" "$(atok "git_branch = 'feat/iso' AND session_id <> '$S'")" \
  "$(raw "$P_MAIN" --pr 1 | awk -F '|' '{ print $4 }')"
check "a row older than its agents: no figure below zero" "no" "$(has '| -' "$(report "$P_MAIN" --pr 2)$(report "$P_MAIN" --pr 1)")"
q "UPDATE sessions SET ended_at = '2026-10-16T12:00:00Z' WHERE session_id='${S}';"

# ---------------------------------------------------------------- 7. recompute
# An agent of a session not recorded yet, and one of a frozen session
q "INSERT INTO agent_usage (session_id, agent_id, repo, git_branch, how, model, input_tokens, output_tokens, co2_grams, cost_usd) VALUES
  ('not-yet', 'z1', 'r', 'feat/z', 'cwd', 'claude-opus-5-5', 1000000, 0, 0, 0),
  ('frozen', 'z2', 'r', 'feat/z', 'cwd', 'claude-opus-5-5', 1000000, 0, 7, 0);"
q "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, methodology_version, git_branch) VALUES ('frozen', 'proj', 'claude-opus-5-5', 1000000, 0, 0, 7, 1, 'main');"
EXPECT="$(q "SELECT SUM(co2_grams) FROM agent_usage WHERE session_id NOT IN ('not-yet', 'frozen');")"
Z1="$(q "SELECT printf('%.0f', input_tokens * fin / 1000000.0) FROM agent_usage, (SELECT $(jq -r '.models.opus.input' "$FACTORS") AS fin) WHERE agent_id = 'z1';")"
q "UPDATE agent_usage SET co2_grams = 0 WHERE session_id <> 'frozen';"
CLAUDE_CARBON_DB="$DB" bash "$RECOMPUTE" >/dev/null 2>&1
# The hook stored each row at %.4f; recompute keeps the full value
check "recompute re-derives agent_usage (to the hook's rounding)" "ok" \
  "$(q "SELECT CASE WHEN ABS(SUM(co2_grams) - ${EXPECT}) <= 0.00005 * COUNT(*) + 1e-9 THEN 'ok' ELSE SUM(co2_grams) || ' vs ${EXPECT}' END FROM agent_usage WHERE session_id NOT IN ('not-yet', 'frozen');")"
check "recompute: an agent of a session not recorded yet, re-derived; a frozen one, not" "${Z1}|7" \
  "$(q "SELECT printf('%.0f', (SELECT co2_grams FROM agent_usage WHERE agent_id='z1')) || '|' || printf('%.0f', (SELECT co2_grams FROM agent_usage WHERE agent_id='z2'));")"

# ---------------------------------------------------------------- 8. no jq argv over 30,000 bytes
# 150 more worktrees with long names: their spellings reach jq on stdin, never as arguments
k=0
while [ "$k" -lt 150 ]; do
  git_q -C "$MAIN" worktree add -q --no-checkout -b "feat/long-$k" "${WTS}/proj-a-rather-long-worktree-name-to-fill-a-command-line-$k"
  k=$((k + 1))
done
REAL_JQ="$(command -v jq)"
ARGV="${TMPROOT}/argv"
mkdir -p "$ARGV"
cat > "${ARGV}/jq" <<EOF
#!/usr/bin/env bash
# the bytes of a jq command line: each argument and its terminating NUL
LC_ALL=C
n=0
for a in "\$@"; do n=\$((n + \${#a} + 1)); done
echo "\$n" >> "${TMPROOT}/argv-sizes"
exec "${REAL_JQ}" "\$@"
EOF
chmod +x "${ARGV}/jq"
: > "${TMPROOT}/argv-sizes"
agent "$S" big 100 10 "$P_MAIN" "$(cmd "cd '${WTS}/proj-a-rather-long-worktree-name-to-fill-a-command-line-149' && make")"
PATH="${ARGV}:$PATH" stop "$S" big "$P_MAIN"
check "150 worktrees: the agent's branch found" "feat/long-149:cited" "$(branch_of "$S" big)"
check "150 worktrees: no jq argv over 30,000 bytes" "yes" \
  "$(awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { print (m > 0 && m < 30000) ? "yes" : "max " m }' "${TMPROOT}/argv-sizes")"

# ---------------------------------------------------------------- 9. no agent row: the 1.15.6 comment
# Fixed rows, and the comment generate-pr-report.sh 1.15.6 printed for them, byte for byte
G_DIR="${TMPROOT}/golden/proj"
mkdir -p "$G_DIR"
git -C "$G_DIR" init -q -b feat/g 2>/dev/null || { git -C "$G_DIR" init -q; git -C "$G_DIR" checkout -q -b feat/g; }
G_DB="${TMPROOT}/golden.db"
sqlite3 "$G_DB" "$SCHEMA"
sqlite3 "$G_DB" "CREATE TABLE session_models (session_id TEXT NOT NULL, model TEXT NOT NULL, input_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0, co2_grams REAL DEFAULT 0, PRIMARY KEY (session_id, model));
INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams, methodology_version, git_branch) VALUES
  ('g1', 'proj', 'claude-opus-5-5', 120000, 30000, 2000000, 50000, 4.25, 210.5, 2, 'feat/g'),
  ('g2', 'proj', 'claude-sonnet-4-5', 40000, 5000, 300000, 0, 0.35, 12.25, 2, 'feat/g'),
  ('g3', 'proj', 'claude-opus-5-5', 999, 99, 9999, 0, 9.99, 999, 2, 'main');
INSERT INTO session_models VALUES
  ('g1', 'claude-opus-5-5', 100000, 50000, 0, 1800000, 25000, 4.0, 200.0),
  ('g1', 'claude-haiku-4-5', 20000, 0, 0, 200000, 5000, 0.25, 10.5);"
GOLDEN='<!-- claude-carbon-dev-report -->
**Claude Code carbon report** · developing this PR

| CO2e | Cost* | Tokens (in + cache write + out) | Cache reads | Sessions |
|---|---|---|---|---|
| **223 g** | $4.60 | 195k | 2.3M | 2 |

≈ 1.1 km driven by car (200 g/km, world avg)

<details>
<summary>Token detail per model</summary>

| Model | Sessions | Uncached input | Cache write | Cache read | Output | CO2e | Cost |
|---|---|---|---|---|---|---|---|
| `claude-opus-5-5` | 1 | 50k | 50k | 1.8M | 25k | 200 g | $4.00 |
| `claude-sonnet-4-5` | 1 | 40k | 0 | 300k | 5k | 12 g | $0.35 |
| `claude-haiku-4-5` | 1 | 20k | 0 | 200k | 5k | 10 g | $0.25 |

</details>

<sub>*API list price of the equivalent usage; a subscription bills its flat fee instead.</sub>

<sub>Local Claude Code sessions on `feat/g` · Estimated by [claude-carbon](https://github.com/gwittebolle/claude-carbon) · [methodology](https://github.com/gwittebolle/claude-carbon/blob/main/METHODOLOGY.md) · [turn off](https://github.com/gwittebolle/claude-carbon#pr-dev-footprint-carbon-pr) · team view · [tokenclimate.com](https://tokenclimate.com/en?ref=carbon-pr)</sub>'
g_report() { (cd "$G_DIR" && CLAUDE_CARBON_DB="${1:-$G_DB}" CLAUDE_CARBON_LOCALE=world bash "$PR_SCRIPT" --dry-run 2>/dev/null); }
# A database the report cannot migrate (read-only): no agent_usage table, the same comment
cp "$G_DB" "${TMPROOT}/golden-ro.db"
chmod 444 "${TMPROOT}/golden-ro.db"
check "a read-only database without agent_usage: the 1.15.6 comment" "$GOLDEN" "$(g_report "${TMPROOT}/golden-ro.db")"
chmod 644 "${TMPROOT}/golden-ro.db"
check "no agent row: the 1.15.6 comment" "$GOLDEN" "$(g_report)"
# Agents of other repositories and branches change nothing either
sqlite3 "$G_DB" "INSERT INTO agent_usage (session_id, agent_id, repo, git_branch, how, model, input_tokens, output_tokens, co2_grams, cost_usd) VALUES
  ('g3', 'x', '/elsewhere/.git', 'feat/g', 'cwd', 'claude-opus-5-5', 50, 5, 1, 1);"
check "agent rows elsewhere: still the 1.15.6 comment" "$GOLDEN" "$(g_report)"

# ---------------------------------------------------------------- 10. the plugin wires it
check "hooks.json: SubagentStop runs agent-stop.sh, for agents with a type" \
  "\"\${CLAUDE_PLUGIN_ROOT}/scripts/agent-stop.sh\"|.+" \
  "$(jq -r '.hooks.SubagentStop[0] | (.hooks[0].command // "") + "|" + (.matcher // "")' "${REPO_DIR}/hooks/hooks.json" | tr -d '\r')"
check "agent-stop.sh is executable" "yes" "$([ -x "$HOOK" ] && echo yes || echo no)"
# Exits 0 at once on what it cannot use: no input, no database, a bad event
check "no input: exits 0" "0" "$(: | CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK"; echo $?)"
check "no database: exits 0" "0" "$(stop_input "$S" aaa | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CARBON_DB="${TMPROOT}/absent.db" bash "$HOOK"; echo $?)"
check "not JSON: exits 0" "0" "$(printf 'not json' | CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK"; echo $?)"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
