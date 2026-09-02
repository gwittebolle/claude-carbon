#!/usr/bin/env bash
# run-portability-tests.sh — guards the cross-platform contract.
#
# claude-carbon runs on macOS, Linux, and native Windows through the Git Bash that
# Claude Code spawns for hooks and the status line. Almost none of that is testable
# by running it on one machine, so this suite pins the parts that are: the pure
# string logic of the path conversion (exercised with the platform forced), the
# absence of dependencies Git for Windows does not ship, and the two places where
# the same logic is written twice and could silently drift apart.
#
# Runs on every platform. Dependencies: bash, awk.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is()   { # is <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

echo "portability tests"
echo "─────────────────────────────"

# ── 1. cc_path: the Windows string rewrite ───────────────────────────────────
# Sourced in a subshell with the platform forced to Windows and cygpath disabled,
# which is the branch a macOS or Linux runner can actually execute. The cygpath
# branch is covered by the Windows CI job, where cygpath is real.
echo ""
echo "cc_path (platform forced to windows, no cygpath)"

winpath() (
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  CC_OS="windows"
  CC_CYGPATH=""
  cc_path "$1"
)

is "backslash drive path"      "/c/Users/me/x.jsonl" "$(winpath 'C:\Users\me\x.jsonl')"
is "lowercase drive letter"    "/d/tmp/a"            "$(winpath 'd:\tmp\a')"
is "forward-slash drive path"  "/e/proj"             "$(winpath 'E:/proj')"
is "mixed separators"          "/c/Users/me/a/b"     "$(winpath 'C:\Users\me/a\b')"
is "already POSIX"             "/c/Users/me"         "$(winpath '/c/Users/me')"
is "relative path untouched"   "scripts/x.sh"        "$(winpath 'scripts/x.sh')"
is "empty stays empty"         ""                    "$(winpath '')"
is "path with a space"         "/c/Program Files/Git" "$(winpath 'C:\Program Files\Git')"

# On macOS and Linux cc_path must be the identity function, including for a string
# that merely looks like a Windows path — a file really named "C:\x" on a Mac.
posixpath() (
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  CC_OS="linux"
  cc_path "$1"
)
echo ""
echo "cc_path (platform forced to linux)"
is "identity on POSIX path"    "/home/me/.claude"    "$(posixpath '/home/me/.claude')"
is "identity on odd filename"  'C:\weird'            "$(posixpath 'C:\weird')"

# ── 2. cc_num_ge: the bc replacement ─────────────────────────────────────────
# bc is absent from Git for Windows, so every float comparison moved to awk. These
# are the exact thresholds format_co2 and the projection tier depend on.
echo ""
echo "cc_num_ge (awk float comparison)"
# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"

ge() { if cc_num_ge "$1" "$2"; then echo yes; else echo no; fi; }
is "equal values"              "yes" "$(ge 1000 1000)"
is "just below the tier"       "no"  "$(ge 999.9 1000)"
is "just above the tier"       "yes" "$(ge 1000.1 1000)"
is "tonne tier boundary"       "yes" "$(ge 10000000 10000000)"
is "below the tonne tier"      "no"  "$(ge 9999999.5 10000000)"
is "zero against zero"         "yes" "$(ge 0 0)"
is "fraction below one"        "no"  "$(ge 0.5 1)"
is "large float"               "yes" "$(ge 123456.789 1000)"
# sqlite3 renders a large REAL in scientific notation, so a total can reach the
# formatter spelled "1e3". awk parses that; bc rejects it with a syntax error, which
# is one more reason the comparison moved off bc rather than a regression from it.
is "scientific notation"       "yes" "$(ge 1e3 1000)"
is "scientific notation below" "no"  "$(ge 1e2 1000)"

# Cross-check against bc itself wherever bc still exists, so the replacement is
# provably equivalent on the machines that can prove it.
if command -v bc >/dev/null 2>&1; then
  echo ""
  echo "cc_num_ge vs bc (cross-check)"
  BC_MISMATCH=0
  # Decimal literals only: bc has no scientific-notation literal and errors on "1e3",
  # which is asserted separately above.
  for pair in "1000 1000" "999.9 1000" "1000.1 1000" "0 0" "0.5 1" "10000000 10000000" \
              "9999999.5 10000000" "123456.789 1000" "431.7045 1000"; do
    set -- $pair
    if cc_num_ge "$1" "$2"; then AWK_R=1; else AWK_R=0; fi
    BC_R="$(echo "$1 >= $2" | LC_ALL=C bc -l)"
    [ "$AWK_R" = "$BC_R" ] || { BC_MISMATCH=1; bad "bc parity for '$1 >= $2'" "awk=$AWK_R bc=$BC_R"; }
  done
  [ "$BC_MISMATCH" = "0" ] && ok "agrees with bc on all sampled comparisons"
fi

# ── 3. install.sh's inline fallback must not drift ───────────────────────────
# The installer is curl-piped with no clone on disk, so it carries its own copy of
# cc_path and cc_install_hint. Extract that copy and diff its behaviour against the
# real library on every input both are expected to handle.
echo ""
echo "install.sh fallback agrees with scripts/portable-lib.sh"

FALLBACK="$(awk '/# >>> portable-lib fallback/{f=1;next} /# <<< portable-lib fallback/{f=0} f' "${REPO_DIR}/install.sh")"
if [ -z "$FALLBACK" ]; then
  bad "fallback block found in install.sh" "markers missing or empty"
else
  ok "fallback block found in install.sh"

  DRIFT=0
  for OS in darwin linux windows; do
    for CMD in jq sqlite3 git node curl; do
      LIB_OUT="$(
        # shellcheck source=scripts/portable-lib.sh
        . "${REPO_DIR}/scripts/portable-lib.sh"
        CC_OS="$OS"
        cc_install_hint "$CMD"
      )"
      FB_OUT="$(eval "$FALLBACK"; CC_OS="$OS"; cc_install_hint "$CMD")"
      if [ "$LIB_OUT" != "$FB_OUT" ]; then
        DRIFT=1
        bad "install hint for $CMD on $OS" "lib='$LIB_OUT' fallback='$FB_OUT'"
      fi
    done
  done
  [ "$DRIFT" = "0" ] && ok "install hints identical for 5 commands x 3 platforms"

  DRIFT=0
  for P in 'C:\Users\me\x.jsonl' 'd:\tmp\a' 'E:/proj' '/c/Users/me' 'scripts/x.sh' 'C:\Program Files\Git'; do
    # Neither side has cygpath forced: on macOS and Linux both take the string
    # rewrite, on the Windows runner both take cygpath. Either way they must agree.
    LIB_OUT="$(
      # shellcheck source=scripts/portable-lib.sh
      . "${REPO_DIR}/scripts/portable-lib.sh"
      CC_OS="windows"
      cc_path "$P"
    )"
    FB_OUT="$(eval "$FALLBACK"; CC_OS="windows"; cc_path "$P")"
    if [ "$LIB_OUT" != "$FB_OUT" ]; then
      DRIFT=1
      bad "cc_path for '$P'" "lib='$LIB_OUT' fallback='$FB_OUT'"
    fi
  done
  [ "$DRIFT" = "0" ] && ok "cc_path identical on 6 sample paths"
fi

# ── 4. Dependencies Git for Windows does not ship ────────────────────────────
# Anything reachable from a Windows user's machine must stay within bash, awk, sed,
# grep, date, curl, git (shipped with Git for Windows) plus jq and sqlite3 (the two
# documented prerequisites) and node (only for the PNG cards, which need Playwright
# anyway). bc and python3 were dependencies before Windows support and must not come back.
echo ""
echo "no reintroduced non-Windows dependencies"

RUNTIME_FILES=""
for f in "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}/install.sh" "${REPO_DIR}"/skills/*/SKILL.md; do
  case "$f" in
    */release.sh|*/check-versions.sh|*/traffic-snapshot.sh) continue ;;  # maintainer tooling, never runs on a user machine
  esac
  RUNTIME_FILES="$RUNTIME_FILES $f"
done

# shellcheck disable=SC2086
BAD_BC="$(grep -nE '(^|[^[:alnum:]_./-])bc[[:space:]]+-l|\|[[:space:]]*bc([[:space:]]|$)' $RUNTIME_FILES 2>/dev/null || true)"
if [ -z "$BAD_BC" ]; then ok "no bc invocation"; else bad "no bc invocation" "$BAD_BC"; fi

# shellcheck disable=SC2086
BAD_PY="$(grep -nE '(^|[^[:alnum:]_./-])python3?[[:space:]]' $RUNTIME_FILES 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [ -z "$BAD_PY" ]; then ok "no python invocation"; else bad "no python invocation" "$BAD_PY"; fi

# shellcheck disable=SC2086
BAD_TMP="$(grep -nE '(^|[^[:alnum:]_$"{/-])/tmp/' $RUNTIME_FILES 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [ -z "$BAD_TMP" ]; then ok "no hardcoded /tmp path"; else bad "no hardcoded /tmp path" "$BAD_TMP"; fi

# ── 5. Line endings ──────────────────────────────────────────────────────────
# Git for Windows clones with core.autocrlf=true, which would rewrite every script
# to CRLF and make bash choke on the carriage returns. .gitattributes pins them.
echo ""
echo "line endings"

if [ -f "${REPO_DIR}/.gitattributes" ] && grep -qE '^\*\.sh[[:space:]]+text[[:space:]]+eol=lf' "${REPO_DIR}/.gitattributes"; then
  ok ".gitattributes pins *.sh to LF"
else
  bad ".gitattributes pins *.sh to LF" "missing '*.sh text eol=lf'"
fi

CRLF_FILES=""
for f in "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}"/tests/*.sh "${REPO_DIR}/install.sh"; do
  if LC_ALL=C grep -qU $'\r' "$f" 2>/dev/null; then CRLF_FILES="${CRLF_FILES} $(basename "$f")"; fi
done
if [ -z "$CRLF_FILES" ]; then ok "no CRLF in tracked shell scripts"; else bad "no CRLF in tracked shell scripts" "$CRLF_FILES"; fi

# ── 6. Hook and status-line wiring ───────────────────────────────────────────
# Claude Code runs these through a shell (sh -c, or Git Bash on Windows). The docs
# require each path placeholder to be double-quoted there: unquoted, a Windows
# CLAUDE_PLUGIN_ROOT loses its backslashes and the hook fails with no visible error.
echo ""
echo "plugin wiring quotes its path placeholders"

for spec in ".claude-plugin/plugin.json" "hooks/hooks.json"; do
  UNQUOTED="$(grep -n '"command": "\${CLAUDE_PLUGIN_ROOT}' "${REPO_DIR}/${spec}" 2>/dev/null || true)"
  if [ -z "$UNQUOTED" ]; then ok "${spec}: placeholders quoted"; else bad "${spec}: placeholders quoted" "$UNQUOTED"; fi
done

# ── 7. Everything still parses ───────────────────────────────────────────────
echo ""
echo "syntax"

SYNTAX_BAD=""
for f in "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}"/tests/*.sh "${REPO_DIR}/install.sh"; do
  bash -n "$f" 2>/dev/null || SYNTAX_BAD="${SYNTAX_BAD} $(basename "$f")"
done
if [ -z "$SYNTAX_BAD" ]; then ok "all shell scripts parse"; else bad "all shell scripts parse" "$SYNTAX_BAD"; fi

# The skills carry their own inline bash, which no shell ever syntax-checks in
# normal use: a typo there only surfaces when a user runs the slash command.
SKILL_BAD=""
SKILL_TMP="$(mktemp)"
for f in "${REPO_DIR}"/skills/*/SKILL.md; do
  awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$f" > "$SKILL_TMP"
  bash -n "$SKILL_TMP" 2>/dev/null || SKILL_BAD="${SKILL_BAD} $(basename "$(dirname "$f")")"
done
rm -f "$SKILL_TMP"
if [ -z "$SKILL_BAD" ]; then ok "all SKILL.md bash blocks parse"; else bad "all SKILL.md bash blocks parse" "$SKILL_BAD"; fi

# Every skill must carry the path helper: they resolve CLAUDE_* variables before
# any library is reachable, so each one needs its own copy.
HELPER_BAD=""
for f in "${REPO_DIR}"/skills/*/SKILL.md; do
  grep -q 'ccp() {' "$f" || HELPER_BAD="${HELPER_BAD} $(basename "$(dirname "$f")")"
done
if [ -z "$HELPER_BAD" ]; then ok "all skills define the ccp path helper"; else bad "all skills define the ccp path helper" "$HELPER_BAD"; fi

echo ""
echo "─────────────────────────────"
echo "passed: ${PASS}   failed: ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
