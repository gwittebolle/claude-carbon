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
# Runs on every platform. Dependencies: bash, awk (the /carbon-card run in 7b also
# needs sqlite3, node and jq, and skips without them).
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

# cc_path_vars: the variables named, converted in place by one cygpath for all of them
# (a fake one here, that answers each argument on its own line and logs its calls), or
# one by one by the string rewrite when it does not answer a line per path. Nothing is
# started for a path already POSIX, nor off Windows.
FAKE_CYG="$(mktemp -d "$(. "${REPO_DIR}/scripts/portable-lib.sh"; cc_tmpdir)/claude-carbon-cygpath.XXXXXX")"
cat > "${FAKE_CYG}/cygpath" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${FAKE_CYG}/calls"
shift
for a in "\$@"; do
  case "\$a" in *short*) continue ;; esac
  a="\${a//\\\\//}"; d="\${a%%:*}"
  printf '/%s%s\n' "\$(printf '%s' "\$d" | tr 'A-Z' 'a-z')" "\${a#*:}"
done
STUB
chmod +x "${FAKE_CYG}/cygpath"
pathvars() (
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  CC_OS="$1"
  CC_CYGPATH="${FAKE_CYG}/cygpath"
  A='C:\Users\me\x.jsonl'; B='/c/already/posix'; C='D:/tmp/a b'; E=''
  [ "${2:-}" = "short" ] && C='D:\short'
  cc_path_vars A B C E
  printf '%s|%s|%s|%s' "$A" "$B" "$C" "$E"
)
echo ""
echo "cc_path_vars (cygpath faked)"
: > "${FAKE_CYG}/calls"
is "converted in place"        "/c/Users/me/x.jsonl|/c/already/posix|/d/tmp/a b|" "$(pathvars windows)"
is "one cygpath for all"       "1" "$(wc -l < "${FAKE_CYG}/calls" | tr -d ' ')"
is "a line short: one by one"  "/c/Users/me/x.jsonl|/c/already/posix|/d/short|" "$(pathvars windows short)"
: > "${FAKE_CYG}/calls"
is "identity off Windows"      'C:\Users\me\x.jsonl|/c/already/posix|D:/tmp/a b|' "$(pathvars linux)"
is "no cygpath off Windows"    "0" "$(wc -l < "${FAKE_CYG}/calls" | tr -d ' ')"
case "$FAKE_CYG" in */claude-carbon-cygpath.*) rm -rf "$FAKE_CYG" ;; esac

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

# ── 2b. cc_mtime: one integer on every stat flavour ──────────────────────────
# GNU stat (Linux, Git Bash) and BSD stat (macOS) spell "mtime in epoch seconds"
# differently, and trying the BSD form on GNU printed a multi-line block before
# failing. Every caller does arithmetic on the result, so anything but a bare
# integer kills it. Runs with the native stat of each CI runner.
echo ""
echo "cc_mtime (native stat)"
MT_FILE="$(mktemp "$(cc_tmpdir)/cc-mtime.XXXXXX")"
MT="$(cc_mtime "$MT_FILE")"
case "$MT" in
  ''|*[!0-9]*) bad "a bare integer" "got '$MT'" ;;
  *) ok "a bare integer" ;;
esac
MT_NOW="$(date +%s)"
if [ "${MT:-0}" -ge $((MT_NOW - 60)) ] 2>/dev/null && [ "${MT:-0}" -le $((MT_NOW + 60)) ] 2>/dev/null; then
  ok "within a minute of now"
else
  bad "within a minute of now" "got '$MT', now $MT_NOW"
fi
# Off macOS the BSD syntax is only a fallback after the GNU one; forcing the
# platform exercises that order on whichever stat this runner has.
is "same epoch with the non-macOS order" "$MT" "$(CC_OS=linux; cc_mtime "$MT_FILE")"
is "missing file gives 0"                "0"   "$(cc_mtime "${MT_FILE}.absent")"
rm -f "$MT_FILE"

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

# An array, expanded quoted. This list used to be a space-joined string expanded
# unquoted, which split a checkout under a directory with a space in its name (say
# "~/Claude OS/code/claude-carbon") into filenames that do not exist. grep then read
# nothing, and every guard below reported "ok" while checking exactly zero files.
RUNTIME_FILES=()
for f in "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}/install.sh" "${REPO_DIR}"/skills/*/SKILL.md; do
  case "$f" in
    */release.sh|*/check-versions.sh|*/traffic-snapshot.sh) continue ;;  # maintainer tooling, never runs on a user machine
  esac
  [ -f "$f" ] || continue
  RUNTIME_FILES+=("$f")
done

# Positive control. A guard that cannot fail is worse than no guard, so prove the file
# list is real and readable before trusting anything the guards below do not find.
if [ "${#RUNTIME_FILES[@]}" -ge 15 ]; then
  ok "runtime file list built (${#RUNTIME_FILES[@]} files)"
else
  bad "runtime file list built" "expected at least 15 readable files, got ${#RUNTIME_FILES[@]}"
fi
CONTROL="$(grep -lE '(^|[^[:alnum:]_./-])jq[[:space:]]' "${RUNTIME_FILES[@]}" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${CONTROL:-0}" -ge 5 ]; then
  ok "grep reads the runtime files (jq found in ${CONTROL})"
else
  bad "grep reads the runtime files" "expected jq in at least 5 files, found it in ${CONTROL:-0}"
fi

BAD_BC="$(grep -nE '(^|[^[:alnum:]_./-])bc[[:space:]]+-l|\|[[:space:]]*bc([[:space:]]|$)' "${RUNTIME_FILES[@]}" 2>/dev/null || true)"
if [ -z "$BAD_BC" ]; then ok "no bc invocation"; else bad "no bc invocation" "$BAD_BC"; fi

BAD_PY="$(grep -nE '(^|[^[:alnum:]_./-])python3?[[:space:]]' "${RUNTIME_FILES[@]}" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [ -z "$BAD_PY" ]; then ok "no python invocation"; else bad "no python invocation" "$BAD_PY"; fi

BAD_TMP="$(grep -nE '(^|[^[:alnum:]_$"{/-])/tmp/' "${RUNTIME_FILES[@]}" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [ -z "$BAD_TMP" ]; then ok "no hardcoded /tmp path"; else bad "no hardcoded /tmp path" "$BAD_TMP"; fi

# Only cc_tmpdir may read TMPDIR. Under Git Bash it can hold a native Windows path
# (C:\Users\...\Temp) that mktemp cannot use, and the guard above does not see
# "${TMPDIR:-/tmp}" or "$TMPDIR/". The control proves the pattern still matches the one
# line of cc_tmpdir that reads it, which is the only line exempted.
CC_TMPDIR_READ='/scripts/portable-lib\.sh:[0-9]*:[[:space:]]*local d="\$\{TMPDIR:-/tmp\}"$'
TMPDIR_READS="$(grep -nE '\$\{?TMPDIR([^[:alnum:]_]|$)' "${RUNTIME_FILES[@]}" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
BAD_TMPDIR="$(printf '%s\n' "$TMPDIR_READS" | grep -vE "$CC_TMPDIR_READ" | grep -v '^$' || true)"
if ! printf '%s\n' "$TMPDIR_READS" | grep -qE "$CC_TMPDIR_READ"; then
  bad "TMPDIR read by cc_tmpdir only" "the pattern no longer matches cc_tmpdir in scripts/portable-lib.sh"
elif [ -z "$BAD_TMPDIR" ]; then
  ok "TMPDIR read by cc_tmpdir only"
else
  bad "TMPDIR read by cc_tmpdir only" "$BAD_TMPDIR"
fi

# Every path built from a CLAUDE_* variable has to go through the conversion. The user
# sets those, so on Windows they arrive in whatever spelling the user typed. Miss one
# and the failure is silent: a read that finds nothing, or a write that lands somewhere
# the reader never looks. Two were missed on the first pass (install.sh skipped the
# re-pricing on update, and the card stamped its month where the status line could not
# see it), which is what this guard exists to prevent from recurring. An assignment
# converted in place on the same line (`X="${CLAUDE_...}"; cc_path_vars X`) goes through it.
RAW_ENV="$(grep -nE '^[[:space:]]*[A-Z_]+="\$\{?CLAUDE_(CONFIG_DIR|CARBON_DB|CARBON_DIR|CARBON_EXPORT_DIR|PLUGIN_ROOT)' "${RUNTIME_FILES[@]}" 2>/dev/null \
  | awk '{ c = $0; sub(/^[^:]*:[0-9]+:[ \t]*/, "", c); n = c; sub(/=.*/, "", n); if (c ~ ("; cc_path_vars " n "$")) next; print }' || true)"
if [ -z "$RAW_ENV" ]; then
  ok "every CLAUDE_* path assignment is converted"
else
  bad "every CLAUDE_* path assignment is converted" "$RAW_ENV"
fi

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

# Started with a terminal for stdin, a hook has no JSON coming: the Git Bash window Windows
# opens when Claude Code fell back to PowerShell. Each script must leave rather than wait.
for s in statusline.sh persist-session.sh persist-on-exit.sh safety-rescan.sh agent-stop.sh; do
  if grep -q '^\[ -t 0 \] && exit 0$' "${REPO_DIR}/scripts/${s}"; then
    ok "${s}: leaves when stdin is a terminal"
  else
    bad "${s}: leaves when stdin is a terminal" "no '[ -t 0 ] && exit 0' line"
  fi
done

# ── 7. Where the cards go, and how they are shown ────────────────────────────
# cc_downloads_dir consults a different authority per platform; each branch is
# exercised with the platform forced and the authority faked on PATH. cc_reveal
# must spawn the file manager only when it should, and never fail.
echo ""
echo "cc_downloads_dir (per-platform authority, faked)"

FAKE_HOME="$(mktemp -d)"
FAKE_BIN="${FAKE_HOME}/bin"
mkdir -p "$FAKE_BIN"

downloads() ( # downloads <os> [extra PATH dir]
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  CC_OS="$1"
  CC_CYGPATH=""
  HOME="$FAKE_HOME"
  PATH="${2:-/nonexistent}:/usr/bin:/bin"
  # A registry tree of the test's own, empty unless a case fills it
  CC_REGISTRY_ROOT="${FAKE_REGISTRY:-/nonexistent}"
  cc_downloads_dir
)

is "darwin: HOME/Downloads"                 "${FAKE_HOME}/Downloads" "$(downloads darwin)"
is "linux without xdg-user-dir: HOME/Downloads" "${FAKE_HOME}/Downloads" "$(downloads linux)"

printf '#!/usr/bin/env bash\necho "%s"\n' "${FAKE_HOME}/Téléchargements" > "${FAKE_BIN}/xdg-user-dir"
chmod +x "${FAKE_BIN}/xdg-user-dir"
is "linux: xdg-user-dir DOWNLOAD wins"      "${FAKE_HOME}/Téléchargements" "$(downloads linux "$FAKE_BIN")"

printf '#!/usr/bin/env bash\necho "%s"\n' "${FAKE_HOME}" > "${FAKE_BIN}/xdg-user-dir"
is "linux: xdg-user-dir answering HOME is treated as unset" "${FAKE_HOME}/Downloads" "$(downloads linux "$FAKE_BIN")"

# reg.exe output as Git Bash sees it: the known-folder GUID, the type, an
# unexpanded %USERPROFILE%, a trailing CR. OneDrive redirection is the reason to
# read the registry at all, so the fake answers with a redirected path.
# The profile is a folder of the test's own, so that the folders the registry names exist
# (only an existing one is taken).
PROFILE="${FAKE_HOME}/profile"
mkdir -p "${PROFILE}/OneDrive/Downloads" "${PROFILE}/Documents/Téléchargements"
cat > "${FAKE_BIN}/reg" <<'EOF'
#!/usr/bin/env bash
printf '%s\r\n' '' 'HKEY_CURRENT_USER\Software\...' '    {374DE290-123F-4565-9164-39C4925E467B}    REG_EXPAND_SZ    %USERPROFILE%\OneDrive\Downloads' ''
EOF
chmod +x "${FAKE_BIN}/reg"
is "windows: reg.exe known folder, %USERPROFILE% expanded, converted" \
   "${PROFILE}/OneDrive/Downloads" \
   "$(USERPROFILE="$PROFILE" downloads windows "$FAKE_BIN")"

# The runtime's /proc/registry first: a value file, NUL-terminated, in the shell's encoding.
# A French Windows with Downloads moved under Documents (2026-10-21).
REGISTRY_DIR="${FAKE_HOME}/registry"
KNOWN="${REGISTRY_DIR}/HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/User Shell Folders"
mkdir -p "$KNOWN"
printf '%s\0' '%USERPROFILE%\Documents\Téléchargements' > "${KNOWN}/{374DE290-123F-4565-9164-39C4925E467B}"
is "windows: /proc/registry wins, accents kept" \
   "${PROFILE}/Documents/Téléchargements" \
   "$(FAKE_REGISTRY="$REGISTRY_DIR" USERPROFILE="$PROFILE" downloads windows "$FAKE_BIN")"

# reg.exe's console code page turns é into a byte that is not UTF-8: that folder does not
# exist, so it is neither taken nor created
printf '#!/usr/bin/env bash\nprintf "    {374DE290-123F-4565-9164-39C4925E467B}    REG_EXPAND_SZ    %%%%USERPROFILE%%%%\\\\Documents\\\\T\\202l\\202chargements\\r\\n"\n' > "${FAKE_BIN}/reg"
is "windows: a path read in the wrong encoding falls back to HOME/Downloads" \
   "${FAKE_HOME}/Downloads" \
   "$(USERPROFILE="$PROFILE" downloads windows "$FAKE_BIN")"
is "windows: and no folder of that name is made" "1" "$(find "${PROFILE}/Documents" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

printf '#!/usr/bin/env bash\nexit 1\n' > "${FAKE_BIN}/reg"
is "windows: registry unavailable falls back to HOME/Downloads" "${FAKE_HOME}/Downloads" "$(downloads windows "$FAKE_BIN")"

echo ""
echo "cc_reveal (file manager faked on PATH)"

MARK="${FAKE_HOME}/reveal.log"
CARD="${FAKE_HOME}/card.png"
: > "$CARD"
for tool in open explorer.exe xdg-open; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$tool" "$MARK" > "${FAKE_BIN}/${tool}"
  chmod +x "${FAKE_BIN}/${tool}"
done

reveal() ( # reveal <os> <file>; REVEAL_NO_OPEN / REVEAL_CI set by the caller stand in for the real variables
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  # Both read by cc_reveal, which shellcheck does not follow into the library.
  # shellcheck disable=SC2034
  CC_OS="$1" CC_CYGPATH=""
  PATH="${FAKE_BIN}:/usr/bin:/bin"
  # Empty is unset to cc_reveal, and it shields the run from a real CI variable.
  export DISPLAY=:0 CLAUDE_CARBON_NO_OPEN="${REVEAL_NO_OPEN:-}" CI="${REVEAL_CI:-}"
  cc_reveal "$2"; echo "rc=$?"
)

: > "$MARK"
is "darwin: exits 0"                       "rc=0" "$(reveal darwin "$CARD")"
is "darwin: Finder selects the file"       "open -R ${CARD}" "$(cat "$MARK")"

: > "$MARK"
is "windows: exits 0"                      "rc=0" "$(reveal windows "$CARD")"
is "windows: Explorer opens the folder"    "explorer.exe ${FAKE_HOME}" "$(cat "$MARK")"

: > "$MARK"
is "linux: exits 0"                        "rc=0" "$(reveal linux "$CARD")"
# xdg-open is backgrounded so the script never waits on a file manager: give the
# fake up to 2s to land, then judge.
for _ in $(seq 1 20); do [ -s "$MARK" ] && break; sleep 0.1; done
is "linux: file manager opens the folder"  "xdg-open ${FAKE_HOME}" "$(cat "$MARK")"

: > "$MARK"
REVEAL_NO_OPEN=1 reveal darwin "$CARD" >/dev/null
is "CLAUDE_CARBON_NO_OPEN: nothing spawned" "" "$(cat "$MARK")"
REVEAL_CI=true reveal darwin "$CARD" >/dev/null
is "CI: nothing spawned"                    "" "$(cat "$MARK")"
is "missing file: exits 0, nothing spawned" "rc=0" "$(reveal darwin "${FAKE_HOME}/absent.png")"
is "missing file: log still empty"          "" "$(cat "$MARK")"

# ── 7b. /carbon-card without Chromium ────────────────────────────────────────
# No playwright-core, or one whose Chromium cannot start: the script must not end
# in an error. The summary page opens in the browser (the same fakes as above
# stand in for open, explorer.exe and xdg-open), the month is stamped for the
# status line, and the Totals line is printed first. The script finds its
# playwright-core the way it does for a user: node's resolution, which NODE_PATH
# points at a stub, then the global npm root (a fake npm answers an empty one) and
# HOME (a throwaway one). Only the fixed Homebrew paths cannot be faked: with a
# Playwright there, the no-playwright-core case is skipped.
echo ""
echo "/carbon-card without Chromium (opener faked on PATH)"

if command -v sqlite3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  CARD_DB="${FAKE_HOME}/carbon.db"
  sqlite3 "$CARD_DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, methodology_version INTEGER DEFAULT 2, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"
  sqlite3 "$CARD_DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at) VALUES ('c1', 'p', 'claude-opus-5', 1000, 100, 1.5, 2500.0, '$(date +%Y-%m)-01T10:00:00Z');"
  # Each NODE_PATH dir below holds a playwright-core, or none: one that fails to
  # load, one that loads but whose Chromium will not start.
  NO_PW="${FAKE_HOME}/np-absent"
  BROKEN_PW="${FAKE_HOME}/np-broken"
  NO_CHROMIUM="${FAKE_HOME}/np-no-chromium"
  mkdir -p "$NO_PW" "${BROKEN_PW}/playwright-core" "${NO_CHROMIUM}/playwright-core" "${FAKE_HOME}/tmp" "${FAKE_HOME}/cfg" "${FAKE_HOME}/card-bin"
  echo 'throw new Error("Cannot find module playwright-core/lib");' > "${BROKEN_PW}/playwright-core/index.js"
  echo 'exports.chromium = { launch: () => Promise.reject(new Error("Executable does not exist")) };' > "${NO_CHROMIUM}/playwright-core/index.js"
  printf '#!/usr/bin/env bash\necho "%s"\n' "${FAKE_HOME}/npm-global" > "${FAKE_HOME}/card-bin/npm"
  chmod +x "${FAKE_HOME}/card-bin/npm"

  card() ( # card <NODE_PATH dir>; CARD_NO_OPEN set by the caller stands in for CLAUDE_CARBON_NO_OPEN
    PATH="${FAKE_HOME}/card-bin:${FAKE_BIN}:${PATH}"
    # Out of the repo, so node resolves nothing from a node_modules above it.
    cd "$FAKE_HOME" || exit 1
    export HOME="$FAKE_HOME" TMPDIR="${FAKE_HOME}/tmp" DISPLAY=:0 CI="" \
      CLAUDE_CONFIG_DIR="${FAKE_HOME}/cfg" CLAUDE_CARBON_DB="$CARD_DB" \
      CLAUDE_CARBON_EXPORT_DIR="${FAKE_HOME}/out" CLAUDE_CARBON_LOCALE=fr_FR \
      NODE_PATH="$1" CLAUDE_CARBON_NO_OPEN="${CARD_NO_OPEN:-}" \
      CLAUDE_CARBON_BROWSER="${CARD_BROWSER:-none}"
    bash "${REPO_DIR}/scripts/generate-report.sh" 2>&1
    echo "rc=$?"
  )
  # The lookup's two paths no test can fake.
  HOMEBREW_PW=""
  for d in /opt/homebrew/lib/node_modules/playwright-core /opt/homebrew/lib/node_modules/playwright/node_modules/playwright-core; do
    [ -d "$d" ] && HOMEBREW_PW="$d"
  done
  CARD_CASES="$BROKEN_PW $NO_CHROMIUM"
  if [ -z "$HOMEBREW_PW" ]; then
    CARD_CASES="$NO_PW $CARD_CASES"
  else
    echo "  skip no playwright-core: one is installed at $HOMEBREW_PW"
  fi
  opened() { # what the opener was handed, once a backgrounded xdg-open has had up to 2s to land
    for _ in $(seq 1 20); do [ -s "$MARK" ] && break; sleep 0.1; done
    case "$(cat "$MARK")" in *claude-carbon-summary-fr-*.html) echo "summary fr" ;; "") echo "nothing" ;; *) cat "$MARK" ;; esac
  }

  for pw in $CARD_CASES; do
    case "$pw" in
      *absent) what="no playwright-core" ;;
      *broken) what="playwright-core does not load" ;;
      *) what="Chromium does not start" ;;
    esac
    : > "$MARK"
    rm -f "${FAKE_HOME}/cfg/claude-carbon/last-card-month"
    OUT="$(card "$pw")"
    is "${what}: exits 0"                         "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
    is "${what}: the browser gets the FR summary" "summary fr" "$(opened)"
    is "${what}: month stamped"                   "$(date +%Y-%m)" "$(cat "${FAKE_HOME}/cfg/claude-carbon/last-card-month" 2>/dev/null)"
    is "${what}: Totals line, then the browser line" "Totals|No" \
      "$(printf '%s\n' "$OUT" | grep -E '^(Totals since|No PNG)' | cut -d' ' -f1 | paste -sd'|' -)"
    is "${what}: no PNG written"                  "0" "$(find "${FAKE_HOME}/out" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
    # The browser copy sits in the export folder (a snap browser cannot read /tmp,
    # and the system cleans it), carries its logo and fits itself to the window.
    PAGE="$(find "${FAKE_HOME}/out" -name 'claude-carbon-summary-fr-*.html' 2>/dev/null | head -1)"
    is "${what}: page in the export folder"       "yes" "$([ -n "$PAGE" ] && echo yes || echo no)"
    is "${what}: logo inline, fit script in"      "0|1|1" \
      "$(grep -c 'src="logo.png"' "$PAGE" 2>/dev/null)|$(grep -c 'data:image/png;base64,' "$PAGE" 2>/dev/null)|$(grep -c 'function ccFit' "$PAGE" 2>/dev/null)"
    is "${what}: no temp page left"               "0" "$(find "${FAKE_HOME}/tmp" -name 'claude-carbon-*.html' 2>/dev/null | wc -l | tr -d ' ')"
    rm -f "${FAKE_HOME}/out/"*.html
  done

  # Chromium starts but every export fails: no card, so the month is not stamped
  # and the status line nudge stays up.
  NO_SHOT="${FAKE_HOME}/np-no-shot"
  mkdir -p "${NO_SHOT}/playwright-core"
  echo 'const page = { goto: async () => {}, waitForTimeout: async () => {}, screenshot: async () => {} }; exports.chromium = { launch: async () => ({ newPage: async () => page, close: async () => {} }) };' > "${NO_SHOT}/playwright-core/index.js"
  rm -f "${FAKE_HOME}/cfg/claude-carbon/last-card-month"
  OUT="$(CARD_NO_OPEN=1 card "$NO_SHOT")"
  is "exports all fail: month not stamped"      "none" "$(cat "${FAKE_HOME}/cfg/claude-carbon/last-card-month" 2>/dev/null || echo none)"

  : > "$MARK"
  OUT="$(CARD_NO_OPEN=1 card "$NO_CHROMIUM")"
  is "CLAUDE_CARBON_NO_OPEN: nothing spawned" "nothing" "$(opened)"
  case "$OUT" in
    *"No PNG: open "*claude-carbon-summary-fr-*.html" in a browser"*) ok "CLAUDE_CARBON_NO_OPEN: the line names the page instead" ;;
    *) bad "CLAUDE_CARBON_NO_OPEN: the line names the page instead" "$OUT" ;;
  esac

  # The machine's own browser, without Playwright: a stub that writes what Chrome's
  # --screenshot would, a PNG whose header says 2160x2160 (or a wrong size, which is no
  # card and leaves the page in the browser). A bash stub cannot be spawned by node on
  # Windows, where the real browser below stands in.
  if [ "$CC_OS" != "windows" ]; then
    for size in 2160 800; do
      cat > "${FAKE_HOME}/card-bin/fake-chrome" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in --screenshot=*) out="\${a#--screenshot=}" ;; --user-data-dir=*) [ -d "\${a#--user-data-dir=}" ] || exit 9 ;; esac
done
printf '\\211PNG\\r\\n\\032\\n\\000\\000\\000\\rIHDR' > "\$out"
node -e 'const b=Buffer.alloc(8);b.writeUInt32BE(+process.argv[1],0);b.writeUInt32BE(+process.argv[1],4);process.stdout.write(b)' $size >> "\$out"
STUB
      chmod +x "${FAKE_HOME}/card-bin/fake-chrome"
      rm -f "${FAKE_HOME}/out/"*.png "${FAKE_HOME}/out/"*.html "${FAKE_HOME}/cfg/claude-carbon/last-card-month"
      : > "$MARK"
      OUT="$(CARD_NO_OPEN=1 CARD_BROWSER="${FAKE_HOME}/card-bin/fake-chrome" card "$NO_CHROMIUM")"
      PNGS="$(find "${FAKE_HOME}/out" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$size" = 2160 ]; then
        case "$OUT" in *"Exporting PNGs via fake-chrome"*) ok "system browser: named as the engine" ;; *) bad "system browser: named as the engine" "$OUT" ;; esac
        is "system browser: the PNGs"            "4" "$PNGS"
        is "system browser: month stamped"       "$(date +%Y-%m)" "$(cat "${FAKE_HOME}/cfg/claude-carbon/last-card-month" 2>/dev/null)"
        is "system browser: profile removed"     "0" "$(find "${FAKE_HOME}/tmp" -name 'claude-carbon-browser-*' 2>/dev/null | wc -l | tr -d ' ')"
      else
        is "system browser, wrong size: no PNG kept" "0" "$PNGS"
        case "$OUT" in *"No PNG: open "*claude-carbon-summary-fr-*.html*) ok "system browser, wrong size: the page instead" ;; *) bad "system browser, wrong size: the page instead" "$OUT" ;; esac
        is "system browser, wrong size: rc"      "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
      fi
    done
  fi

  # A browser that hangs and ignores SIGTERM (seen on a macOS runner): killed after 60 s,
  # not tried for the other three cards, and the page opens instead.
  if [ "$CC_OS" != "windows" ]; then
    printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 120\n' > "${FAKE_HOME}/card-bin/hung-chrome"
    chmod +x "${FAKE_HOME}/card-bin/hung-chrome"
    T0=$(date +%s)
    OUT="$(CARD_NO_OPEN=1 CARD_BROWSER="${FAKE_HOME}/card-bin/hung-chrome" card "$NO_CHROMIUM")"
    T1=$(date +%s)
    is "hung browser: one try, then the page" "1|yes|rc=0" \
      "$(printf '%s\n' "$OUT" | grep -c FAILED)|$([ $((T1 - T0)) -lt 110 ] && echo yes || echo "no ($((T1 - T0))s)")|$(printf '%s\n' "$OUT" | tail -1)"
  fi

  # The token tile counts every token, cache reads included, in billions past 1e9 (Md in
  # French), with the share of cache reads under it; a note says so once to someone who
  # made a card before, never to a new install.
  TOK_DB="${FAKE_HOME}/tokens.db"
  sqlite3 "$TOK_DB" "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, methodology_version INTEGER DEFAULT 2, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '');"
  sqlite3 "$TOK_DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens, cost_usd, co2_grams, started_at, cache_read_tokens) VALUES ('t1', 'p', 'claude-opus-5', 1000000, 100000, 1.5, 2500.0, '$(date +%Y-%m)-01T10:00:00Z', 2000000000);"
  SAVED_DB="$CARD_DB"; CARD_DB="$TOK_DB"
  rm -f "${FAKE_HOME}/out/"*.html "${FAKE_HOME}/cfg/claude-carbon/last-card-month" "${FAKE_HOME}/cfg/claude-carbon/card-tokens-with-cache"
  OUT="$(CARD_NO_OPEN=1 card "$NO_CHROMIUM")"
  PAGE="$(find "${FAKE_HOME}/out" -name 'claude-carbon-summary-fr-*.html' 2>/dev/null | head -1)"
  is "tokens: cache reads counted, in Md" "1" "$(grep -c '>2,0 Md<' "$PAGE" 2>/dev/null)"
  NBSP_CHAR="$(printf '\302\240')"
  is "tokens: label and cache share" "1" "$(grep -c "tokens traités<br>dont 99${NBSP_CHAR}% relus en cache" "$PAGE" 2>/dev/null)"
  is "tokens: no note on a first card" "0" "$(printf '%s\n' "$OUT" | grep -c '^Note:')"
  is "tokens: stamp written on a first card" "yes" "$([ -f "${FAKE_HOME}/cfg/claude-carbon/card-tokens-with-cache" ] && echo yes || echo no)"
  rm -f "${FAKE_HOME}/cfg/claude-carbon/card-tokens-with-cache" "${FAKE_HOME}/out/"*.html
  OUT="$(CARD_NO_OPEN=1 card "$NO_CHROMIUM")"
  is "tokens: note once after an earlier card, before Totals" "Note:|Totals" \
    "$(printf '%s\n' "$OUT" | grep -E '^(Note:|Totals since)' | cut -d' ' -f1 | paste -sd'|' -)"
  rm -f "${FAKE_HOME}/out/"*.html
  OUT="$(CARD_NO_OPEN=1 card "$NO_CHROMIUM")"
  is "tokens: the note never comes back" "0" "$(printf '%s\n' "$OUT" | grep -c '^Note:')"
  rm -f "${FAKE_HOME}/out/"*.html
  CARD_DB="$SAVED_DB"

  # Variables of the same names inherited from the user's shell are never acted on:
  # a folder named BROWSER_PROFILE survives, a SERVER_PID is not killed.
  KEEP="${FAKE_HOME}/keep-profile"; mkdir -p "$KEEP"; : > "${KEEP}/Bookmarks"
  OUT="$(BROWSER_PROFILE="$KEEP" SERVER_PID=999999 CARD_NO_OPEN=1 card "$NO_CHROMIUM")"
  is "inherited BROWSER_PROFILE and SERVER_PID: left alone, rc" "yes|rc=0" \
    "$([ -f "${KEEP}/Bookmarks" ] && echo yes || echo no)|$(printf '%s\n' "$OUT" | tail -1)"

  # A real Chrome, Edge or Chromium when the runner has one: a card of 2160x2160
  # The script's own lookup, lifted out of it, run as a user's machine would
  awk '$0 == "find_system_browser() {" { f = 1 } f { print } f && $0 == "}" { exit }' \
    "${REPO_DIR}/scripts/generate-report.sh" > "${FAKE_HOME}/find-browser.sh"
  REAL_BROWSER="$(CLAUDE_CARBON_BROWSER="" bash -c '. "$1/scripts/portable-lib.sh" && . "$2" && find_system_browser' _ "$REPO_DIR" "${FAKE_HOME}/find-browser.sh" 2>/dev/null || true)"
  if [ -n "$REAL_BROWSER" ]; then
    rm -f "${FAKE_HOME}/out/"*.png "${FAKE_HOME}/out/"*.html
    OUT="$(CARD_NO_OPEN=1 CARD_BROWSER="$REAL_BROWSER" card "$NO_CHROMIUM")"
    SUMMARY="$(find "${FAKE_HOME}/out" -name 'claude-carbon-summary-fr-*.png' 2>/dev/null | head -1)"
    is "real browser ($(basename "$REAL_BROWSER")): a 2160x2160 card" "2160x2160" \
      "$([ -n "$SUMMARY" ] && node -e 'const b=require("fs").readFileSync(process.argv[1]);console.log(b.readUInt32BE(16)+"x"+b.readUInt32BE(20))' "$(cc_native_path "$SUMMARY")" 2>/dev/null)"
    # On a failure, what the browser itself says: the card script's lines, then one
    # headless shot of a static page with the same flags, its time and its log
    if [ -z "$SUMMARY" ]; then
      printf '%s\n' "$OUT" | sed 's/^/    card: /' | tail -12
      printf '<!doctype html><title>x</title><p>x</p>' > "${FAKE_HOME}/probe.html"
      node -e '
const { spawnSync } = require("child_process");
const { pathToFileURL } = require("url");
const [browser, page, out, profile] = process.argv.slice(1);
for (const extra of [["--virtual-time-budget=5000"], []]) {
  const t0 = Date.now();
  const r = spawnSync(browser, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--user-data-dir=" + profile + extra.length, "--window-size=200,200", "--enable-logging=stderr", "--v=0", ...extra, "--screenshot=" + out, pathToFileURL(page).href], { encoding: "utf8", timeout: 60000, killSignal: "SIGKILL" });
  console.log(`    probe ${extra.join(" ") || "(no virtual time)"}: ${Date.now() - t0} ms, status ${r.status}, signal ${r.signal}, png ${require("fs").existsSync(out)}`);
  console.log(String(r.stderr || "").split("\n").filter(Boolean).slice(-8).map((l) => "      " + l).join("\n"));
  try { require("fs").unlinkSync(out); } catch (e) {}
}' "$(cc_native_path "$REAL_BROWSER")" "$(cc_native_path "${FAKE_HOME}/probe.html")" "$(cc_native_path "${FAKE_HOME}/probe.png")" "$(cc_native_path "${FAKE_HOME}/probe-profile")" || true
    fi
  else
    echo "  skip real browser: no Chrome, Edge or Chromium here"
  fi
else
  echo "  skip (sqlite3, node and jq are needed)"
fi

# ── 7c. The card's footer: a command to type, the repo under it ──────────────
echo ""
echo "card footer"

NBSP="$(printf '\302\240')"
# footer_text <template> <class>: the text of that footer element, tags stripped,
# &nbsp; turned into the real character.
footer_text() {
  grep -m1 "class=\"$2\"" "$1" | sed -e 's/<[^>]*>//g' -e "s/&nbsp;/${NBSP}/g" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
for t in report-summary report-detailed; do
  is "${t} FR: footer"          "Mesurez la vôtre${NBSP}: claude-carbon sur GitHub" "$(footer_text "${REPO_DIR}/templates/${t}.html" cta-label)"
  is "${t} EN: footer"          "Measure yours: claude-carbon on GitHub"     "$(footer_text "${REPO_DIR}/templates/${t}-en.html" cta-label)"
  is "${t} FR: repo kept"       "github.com/gwittebolle/claude-carbon"      "$(footer_text "${REPO_DIR}/templates/${t}.html" cta-link)"
  is "${t} EN: repo kept"       "github.com/gwittebolle/claude-carbon"      "$(footer_text "${REPO_DIR}/templates/${t}-en.html" cta-link)"
  is "${t} FR: team view kept"  "vue équipe · tokenclimate.com"             "$(footer_text "${REPO_DIR}/templates/${t}.html" team-link)"
  is "${t} EN: team view kept"  "team view · tokenclimate.com"              "$(footer_text "${REPO_DIR}/templates/${t}-en.html" team-link)"
done

rm -rf "$FAKE_HOME"

# ── 8. cc_prev_month_name: the nudge's label ─────────────────────────────────
# Pure string arithmetic, so it can be pinned on fixed inputs, January wrap-around
# included. English whatever the locale.
echo ""
echo "cc_prev_month_name"

prev_month() (
  # shellcheck source=scripts/portable-lib.sh
  . "${REPO_DIR}/scripts/portable-lib.sh"
  LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 cc_prev_month_name "$1"
)
is "September -> August"          "August"    "$(prev_month 2026-09)"
is "October -> September"         "September" "$(prev_month 2026-10)"
is "January wraps to December"    "December"  "$(prev_month 2026-01)"
is "February -> January"          "January"   "$(prev_month 2026-02)"
is "leading zero is not octal"    "July"      "$(prev_month 2026-08)"

# ── 9. Everything still parses ───────────────────────────────────────────────
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

# Every skill that runs bash must carry the path helper: they resolve CLAUDE_* variables
# before any library is reachable, so each one needs its own copy. A skill with no bash
# block (carbon-panel, which the mod answers) resolves nothing.
HELPER_BAD=""
for f in "${REPO_DIR}"/skills/*/SKILL.md; do
  grep -q '^```bash$' "$f" || continue
  grep -q 'ccp() {' "$f" || HELPER_BAD="${HELPER_BAD} $(basename "$(dirname "$f")")"
done
if [ -z "$HELPER_BAD" ]; then ok "skills that run bash define the ccp path helper"; else bad "skills that run bash define the ccp path helper" "$HELPER_BAD"; fi

echo ""
echo "─────────────────────────────"
echo "passed: ${PASS}   failed: ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
