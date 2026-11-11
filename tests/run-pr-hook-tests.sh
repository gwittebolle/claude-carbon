#!/usr/bin/env bash
# run-pr-hook-tests.sh: assert the PR report a repository asks for
# ("env": {"CLAUDE_CARBON_PR": "1"} in its .claude/settings.json):
#  - scripts/pr-hook.sh (PostToolUse on `gh pr create` and `git push`): silent in a
#    repository that does not ask; asks the developer once, on `gh pr create` only; leaves
#    a marker once they said yes; nothing after never; CLAUDE_CARBON_NO_PR_AUTO;
#  - scripts/generate-pr-report.sh --consent: the answer kept per repository;
#  - scripts/pr-flush.sh: the marker consumed, the report run once, only with a yes;
#  - cc_repo_key and pr-consent.tsv: no scheme, no credentials, and no way for a
#    repository's origin to write another repository's answer.
# Nothing is posted: the report script is replaced by one that counts its runs.
#
# Runs under a temp root; the real ~/.claude is never read.
# bash 3.2 compatible (macOS default). Dependencies: jq, git.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
for CMD in jq git; do
  command -v "$CMD" >/dev/null 2>&1 || { echo "FAIL: $CMD is required" >&2; exit 1; }
done

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-pr-hook-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

cleanup() {
  case "$TMPROOT" in
    */claude-carbon-pr-hook-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"
  fi
}

CFG="${TMPROOT}/cfg"
DATA="${CFG}/claude-carbon"
mkdir -p "$DATA"
: >"${DATA}/carbon.db" # the hook only checks that a database is there

new_repo() { # $1 = folder, $2 = origin url, $3 = "ask" to ask for the report
  mkdir -p "$1/.claude"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/feat/x
  [ -n "$2" ] && git -C "$1" remote add origin "$2"
  if [ "$3" = "ask" ]; then
    printf '{"env": {"CLAUDE_CARBON_PR": "1"}}\n' >"$1/.claude/settings.json"
  else
    printf '{"env": {"OTHER": "1"}}\n' >"$1/.claude/settings.json"
  fi
}
payload() { jq -cn --arg c "$1" --arg d "$2" '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'; }
hook() { # $1 = command, $2 = cwd, rest = env
  local c="$1" d="$2"
  shift 2
  payload "$c" "$d" | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_PR_AUTO CLAUDE_CONFIG_DIR="$CFG" "$@" bash "${REPO_DIR}/scripts/pr-hook.sh"
}
consent() { cc_pr_consent_get "$DATA" "$1"; }
pending() { ls "${DATA}/pr-pending" 2>/dev/null | wc -l | tr -d ' '; }

# ------------------------------------------------ cc_repo_key
K="${TMPROOT}/key"
new_repo "$K" "https://someone:s3cret@github.com/acme/app.git" ""
check "key: https, credentials and .git dropped" "$(cc_repo_key "$K")" "github.com/acme/app"
git -C "$K" remote set-url origin "git@github.com:acme/app.git"
check "key: ssh form" "$(cc_repo_key "$K")" "github.com/acme/app"
git -C "$K" remote remove origin
check "key: no origin, the folder" "$(cc_repo_key "$K")" "$K"
git -C "$K" config remote.origin.url "evil.example:x@github.com/acme/app"
check "key: an scp form towards another host is not taken for github.com" "$(cc_repo_key "$K")" "evil.example/x@github.com/acme/app"
git -C "$K" config --unset remote.origin.url

# An origin that tries to write another repository's line
TAB="$(printf '\t')"
EVIL="${TMPROOT}/evil"
new_repo "$EVIL" "" "ask"
git -C "$EVIL" config remote.origin.url "https://github.com/victim/repo${TAB}yes"
check "key: a tab in the origin gives no key" "$(cc_repo_key "$EVIL")" ""
check "tab in the origin: the hook says nothing" "$(hook 'gh pr create --fill' "$EVIL")" ""
check "tab in the origin: nothing recorded" "$([ -f "${DATA}/pr-consent.tsv" ] && echo yes)" ""
# A line with a field too many is not an answer, and a backslash in a key is kept as it is
printf 'github.com/victim/repo\tyes\tasked\t2026-01-01\n' >"${DATA}/pr-consent.tsv"
check "consent: a four-field line is ignored" "$(cc_pr_consent_get "$DATA" "github.com/victim/repo")" ""
cc_pr_consent_set "$DATA" 'C:\tmp\repo' asked
check "consent: a key with backslashes is found again" "$(cc_pr_consent_get "$DATA" 'C:\tmp\repo')" "asked"
cc_pr_consent_set "$DATA" "some/repo" maybe
check "consent: only the three answers are written" "$(cc_pr_consent_get "$DATA" "some/repo")" ""
rm -f "${DATA}/pr-consent.tsv"

# ------------------------------------------------ a repository that does not ask
PLAIN="${TMPROOT}/plain"
new_repo "$PLAIN" "git@github.com:acme/plain.git" ""
check "not asked for: gh pr create prints nothing" "$(hook 'gh pr create --fill' "$PLAIN")" ""
check "not asked for: no answer recorded" "$([ -f "${DATA}/pr-consent.tsv" ] && echo yes)" ""

# ------------------------------------------------ a repository that asks
ASK="${TMPROOT}/ask"
new_repo "$ASK" "git@github.com:acme/ask.git" "ask"
mkdir -p "$ASK/src"
KEY="github.com/acme/ask"

check "another command: nothing" "$(hook 'npm test' "$ASK")" ""
check "the words in a commit message: nothing" "$(hook 'git commit -m "prepare gh pr create"' "$ASK")" ""
check "the words in an echo: nothing" "$(hook 'echo "git push"' "$ASK")" ""
check "a subagent's gh pr create: nothing" "$(jq -cn --arg d "$ASK" '{tool_input: {command: "gh pr create --fill"}, cwd: $d, agent_id: "a1"}' | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_PR_AUTO CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/pr-hook.sh")" ""
check "none of those counted as the question" "$(consent "$KEY")" ""

# The forms a real command takes
for FORM in 'GH_TOKEN=x gh pr create --fill' 'command gh pr create' 'env A=1 B=2 gh pr create' "git add .${NL:-
}gh pr create --fill" 'cd src && gh pr create' '(gh pr create)'; do
  rm -f "${DATA}/pr-consent.tsv"
  check "asked on: $(printf '%s' "$FORM" | tr '\n' ' ')" "$(hook "$FORM" "$ASK" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse"
done
rm -f "${DATA}/pr-consent.tsv"

# A repository that ships its own config folder, with a yes in it, through its settings'
# env: the answers are not read there
HOSTILE="${TMPROOT}/hostile"
new_repo "$HOSTILE" "git@github.com:acme/hostile.git" "ask"
mkdir -p "$HOSTILE/.cc/claude-carbon"
: >"$HOSTILE/.cc/claude-carbon/carbon.db"
printf 'github.com/acme/hostile\tyes\t2026-01-01\n' >"$HOSTILE/.cc/claude-carbon/pr-consent.tsv"
check "config folder inside the repository: a push leaves nothing" \
  "$(payload 'git push' "$HOSTILE" | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_PR_AUTO CLAUDE_CONFIG_DIR="$HOSTILE/.cc" bash "${REPO_DIR}/scripts/pr-hook.sh"; ls "$HOSTILE/.cc/claude-carbon/pr-pending" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "relative config folder: a push leaves nothing" \
  "$(cd "$HOSTILE" && payload 'git push' "$HOSTILE" | env -u CLAUDE_CARBON_DB -u CLAUDE_CARBON_NO_PR_AUTO CLAUDE_CONFIG_DIR=".cc" bash "${REPO_DIR}/scripts/pr-hook.sh"; ls "$HOSTILE/.cc/claude-carbon/pr-pending" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "database inside the repository: a push leaves nothing" "$(cc_pr_consent_set "$DATA" "github.com/acme/hostile" yes; hook 'git push' "$HOSTILE" CLAUDE_CARBON_DB="$HOSTILE/.cc/claude-carbon/carbon.db"; pending)" "0"
(cd "$HOSTILE" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$HOSTILE/.cc" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent never >/dev/null 2>&1)
check "config folder inside the repository: no answer is taken" "$?" "1"
rm -f "${DATA}/pr-consent.tsv"

# A yes before any question, or in a repository that does not ask, is not taken
(cd "$ASK" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent yes >/dev/null 2>&1)
check "--consent yes before the question: refused" "$?|$(consent "$KEY")" "1|"
(cd "$PLAIN" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent yes >/dev/null 2>&1)
check "--consent yes where nothing is asked: refused" "$?|$(consent "github.com/acme/plain")" "1|"
check "push before any answer: nothing" "$(hook 'git push -u origin feat/x' "$ASK")" ""
check "push before any answer: not marked as asked" "$(consent "$KEY")" ""

OUT="$(hook 'gh pr create --title x --body y' "$ASK/src")"
check "first gh pr create, after a cd: still asked" "$(hook 'cd src && gh pr create --fill' "$PLAIN")" ""
check "first gh pr create: one JSON object for Claude" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse"
check "first gh pr create: each answer's command ends its own line" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -c -- '--consent \(yes\|never\)$')" "2"
check "first gh pr create: the script's path is quoted for a shell" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -cF "bash '${REPO_DIR}/scripts/generate-pr-report.sh' --consent yes")" "1"
check "first gh pr create: marked as asked" "$(consent "$KEY")" "asked"
check "first gh pr create: nothing pending" "$(pending)" "0"
check "second gh pr create: not asked again" "$(hook 'gh pr create --fill' "$ASK")" ""
check "push after the question went unanswered: nothing pending" "$(hook 'git push' "$ASK"; pending)" "0"

# The answer, through the report script (it stops before any figure for `never`)
never_out="$(cd "$ASK" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent never 2>&1)"
check "--consent never: exit 0" "$?" "0"
check "--consent never: recorded" "$(consent "$KEY")" "never"
check "--consent never: says /carbon-pr still works" "$(printf '%s' "$never_out" | grep -c '/carbon-pr still posts')" "1"
check "after never: push leaves nothing pending" "$(hook 'git push' "$ASK"; pending)" "0"
(cd "$ASK" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent maybe >/dev/null 2>&1)
check "--consent maybe: refused" "$?" "2"
check "--consent maybe: the answer stays" "$(consent "$KEY")" "never"

# The yes, through the report script: recorded, then the run goes on to the figures (and
# stops there, this database being an empty file)
(cd "$ASK" && env -u CLAUDE_CARBON_DB CLAUDE_CONFIG_DIR="$CFG" bash "${REPO_DIR}/scripts/generate-pr-report.sh" --consent yes >/dev/null 2>&1)
check "--consent yes after the question: recorded" "$(consent "$KEY")" "yes"
check "one line per repository" "$(grep -c "^${KEY}	" "${DATA}/pr-consent.tsv")" "1"
check "after yes: gh pr create prints nothing" "$(hook 'gh pr create --fill' "$ASK")" ""
check "after yes: a report is pending" "$(pending)" "1"
check "after yes: a push keeps one marker" "$(hook 'git push' "$ASK/src"; pending)" "1"
rm -rf "${DATA}/pr-pending"
check "opt-out variable: nothing pending" "$(hook 'git push' "$ASK" CLAUDE_CARBON_NO_PR_AUTO=1; pending)" "0"
check "no database: nothing pending" "$(hook 'git push' "$ASK" CLAUDE_CARBON_DB="${TMPROOT}/none.db"; pending)" "0"

# ------------------------------------------------ pr-flush.sh, with a report that counts
FAKE="${TMPROOT}/scripts"
mkdir -p "$FAKE"
cp "${REPO_DIR}/scripts/pr-flush.sh" "${REPO_DIR}/scripts/portable-lib.sh" "$FAKE/"
RUNS="${TMPROOT}/runs"
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$(pwd -P)" "$*" >>"%s"\n' "$RUNS" >"${FAKE}/generate-pr-report.sh"
flush() { env -u CLAUDE_CARBON_NO_PR_AUTO CLAUDE_CONFIG_DIR="$CFG" "$@" bash "${FAKE}/pr-flush.sh"; }
runs() { [ -f "$RUNS" ] && wc -l <"$RUNS" | tr -d ' ' || echo 0; }

flush
check "flush with nothing pending: no report" "$(runs)" "0"
hook 'git push' "$ASK/src" >/dev/null
flush
check "flush: the report runs once, from the repository's root, as an automatic run" "$(cat "$RUNS" 2>/dev/null)" "$(cd "$ASK" && pwd -P) --auto"
check "flush: marker consumed" "$(pending)" "0"
flush
check "flush again: no second report" "$(runs)" "1"

hook 'git push' "$ASK" >/dev/null
flush & flush & flush &
wait
check "three flushes at once: one report" "$(runs)" "2"

hook 'git push' "$ASK" >/dev/null
git -C "$ASK" symbolic-ref HEAD refs/heads/other
flush
check "branch changed since the push: no report, marker gone" "$(runs) $(pending)" "2 0"
git -C "$ASK" symbolic-ref HEAD refs/heads/feat/x

hook 'git push' "$ASK" >/dev/null
cc_pr_consent_set "$DATA" "$KEY" never
flush
check "answer changed to never before the flush: no report, marker gone" "$(runs) $(pending)" "2 0"

cc_pr_consent_set "$DATA" "$KEY" yes
hook 'git push' "$ASK" >/dev/null
touch -t 202001010000 "${DATA}/pr-pending/"*
flush
check "a marker older than an hour: no report, marker gone" "$(runs) $(pending)" "2 0"

hook 'git push' "$ASK" >/dev/null
flush CLAUDE_CARBON_NO_PR_AUTO=1
check "opt-out at the flush: no report" "$(runs)" "2"
rm -rf "${DATA}/pr-pending"
hook 'git push' "$ASK" >/dev/null
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "${GH_REPO:-unset}" "${GH_HOST:-unset}" >"%s"\n' "${TMPROOT}/gh-env" >"${FAKE}/generate-pr-report.sh"
flush GH_REPO=victim/other GH_HOST=evil.example
check "flush: GH_REPO and GH_HOST do not reach the report" "$(cat "${TMPROOT}/gh-env" 2>/dev/null)" "unset|unset"
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$(pwd -P)" "$*" >>"%s"\n' "$RUNS" >"${FAKE}/generate-pr-report.sh"
rm -rf "${DATA}/pr-pending"

hook 'git push' "$ASK" >/dev/null
printf '{}\n' >"$ASK/.claude/settings.json"
flush
check "repository stopped asking before the flush: no report" "$(runs)" "2"

# The Stop hook starts the flush only when a marker is there
check "Stop hook: looks for a marker, not for the folder" "$(grep -c 'ls -A "${CONFIG_DIR}/claude-carbon/pr-pending"' "${REPO_DIR}/scripts/persist-session.sh")" "1"

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
