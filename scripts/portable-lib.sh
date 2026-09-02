#!/usr/bin/env bash
# portable-lib.sh — cross-platform helpers shared by every claude-carbon script.
# Targets macOS, Linux, and native Windows through the Git Bash that Claude Code
# spawns for hooks and the status line (see README "Windows").
#
# Sourced, never executed. It deliberately sets no shell options: each caller owns
# its own error policy (the Stop hook, for one, must never abort).

# Idempotent: several libs source this one, and a script may pull in more than
# one of them. Spelled as a full `if` rather than `[ … ] && return 0`, whose
# non-zero status on the first source would abort a caller running under `set -e`.
# `return` (not `exit`) — this file is only ever sourced.
if [ -n "${CC_PORTABLE_LIB:-}" ]; then
  return 0
fi
CC_PORTABLE_LIB=1

# ── Platform ────────────────────────────────────────────────────────────────
# CC_OS is resolved once at source time, without a subshell: the status line runs
# this on every turn, so a `uname` spawn per call would be felt. $OSTYPE is a bash
# builtin variable and reads "msys" under Git Bash, "cygwin" under Cygwin.
case "${OSTYPE:-}" in
  darwin*)         CC_OS="darwin" ;;
  msys*|cygwin*)   CC_OS="windows" ;;
  linux*)          CC_OS="linux" ;;
  *)
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Darwin)                   CC_OS="darwin" ;;
      MINGW*|MSYS*|CYGWIN*)     CC_OS="windows" ;;
      *)                        CC_OS="linux" ;;
    esac
    ;;
esac

# cc_is_windows — true when running under Git Bash / MSYS / Cygwin on Windows.
cc_is_windows() { [ "$CC_OS" = "windows" ]; }

# ── Paths ───────────────────────────────────────────────────────────────────
# Claude Code is a native Windows binary: the JSON it pipes into hooks and the
# status line carries native paths ("C:\Users\me\.claude\projects\...\x.jsonl"),
# and ${CLAUDE_PLUGIN_ROOT} expands the same way. Bash cannot open those: the
# backslashes are escape characters, and the drive letter is not a mount point.
# Every path that crosses that boundary goes through cc_path first.
#
# cygpath ships with Git for Windows and is the authority (it knows the actual
# mount table, which a string rewrite does not). The manual fallback covers the
# rare install where it is missing.
CC_CYGPATH=""
if [ "$CC_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
  CC_CYGPATH="cygpath"
fi

# cc_path <path> — echoes a path bash can open. Identity on macOS and Linux, and
# on Windows for a path that is already POSIX (the common case once inside the
# scripts, so the cygpath spawn is paid only on the way in).
cc_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 0
  if [ "$CC_OS" != "windows" ]; then
    printf '%s' "$p"
    return 0
  fi
  case "$p" in
    [A-Za-z]:[\\/]*|*\\*)
      if [ -n "$CC_CYGPATH" ]; then
        local converted
        if converted="$($CC_CYGPATH -u "$p" 2>/dev/null)" && [ -n "$converted" ]; then
          printf '%s' "$converted"
          return 0
        fi
      fi
      # "C:\Users\me" → "/c/Users/me". Matches the default MSYS mount layout.
      p="${p//\\//}"
      case "$p" in
        [A-Za-z]:/*)
          local drive="${p%%:*}"
          printf '/%s%s' "$(printf '%s' "$drive" | tr 'A-Z' 'a-z')" "${p#*:}"
          ;;
        *) printf '%s' "$p" ;;
      esac
      ;;
    *) printf '%s' "$p" ;;
  esac
}

# cc_native_path <path> — the inverse of cc_path: echoes a path that the native
# Windows side understands, in the "mixed" spelling ("C:/Users/me/x"). Forward
# slashes, so bash can also open it verbatim without escaping. Used for the paths
# we hand back to Claude Code in settings.json, which it may resolve itself with
# Windows APIs before spawning Git Bash. Identity on macOS and Linux.
cc_native_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 0
  if [ "$CC_OS" != "windows" ] || [ -z "$CC_CYGPATH" ]; then
    printf '%s' "$p"
    return 0
  fi
  local converted
  if converted="$($CC_CYGPATH -m "$p" 2>/dev/null)" && [ -n "$converted" ]; then
    printf '%s' "$converted"
  else
    printf '%s' "$p"
  fi
}

# cc_tmpdir — writable scratch directory. Git Bash provides /tmp, but a Windows
# TMPDIR pointing at "C:\Users\ME~1\AppData\Local\Temp" must still be usable.
cc_tmpdir() {
  local d="${TMPDIR:-/tmp}"
  d="$(cc_path "$d")"
  d="${d%/}"
  [ -d "$d" ] || d="/tmp"
  printf '%s' "$d"
}

# ── Numbers ─────────────────────────────────────────────────────────────────
# bc is absent from Git for Windows and from a bare Debian image. awk is present
# everywhere the rest of this tool already needs it, so the float comparisons go
# through awk instead of adding a dependency users must install.

# cc_num_ge <a> <b> — exit 0 when a >= b, comparing as floats.
cc_num_ge() {
  LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# ── Filesystem ──────────────────────────────────────────────────────────────
# cc_mtime <file> — modification time in epoch seconds, 0 when unavailable.
# BSD stat first (macOS, the majority of installs): GNU stat then costs a second
# spawn only on Linux and Git Bash.
cc_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# cc_link_or_copy <src> <dst> — symlink where symlinks work, copy where they do
# not. Git Bash silently degrades `ln -s` to a copy unless Windows Developer Mode
# is on, so doing the copy ourselves keeps the outcome predictable; the caller is
# responsible for refreshing copies on update (see update.sh).
cc_link_or_copy() {
  if [ "$CC_OS" = "windows" ]; then
    cp -f "$1" "$2"
  else
    ln -s "$1" "$2"
  fi
}

# ── Dependencies ────────────────────────────────────────────────────────────
# cc_install_hint <command> — echoes the install line to show a user who is
# missing that command, in the package manager their platform actually has.
# Git for Windows ships bash, awk, sed, grep, date, curl and git, but neither
# jq nor sqlite3, so those two are the whole Windows prerequisite list.
cc_install_hint() {
  local cmd="$1"
  case "$CC_OS" in
    darwin) printf 'brew install %s' "$cmd" ;;
    windows)
      case "$cmd" in
        jq)      printf 'winget install jqlang.jq' ;;
        sqlite3) printf 'winget install SQLite.SQLite' ;;
        git)     printf 'winget install Git.Git' ;;
        node)    printf 'winget install OpenJS.NodeJS' ;;
        *)       printf 'winget install %s' "$cmd" ;;
      esac
      ;;
    *) printf 'apt install %s' "$cmd" ;;
  esac
}

# ── Locale ──────────────────────────────────────────────────────────────────
# cc_system_locale — the OS-level locale, for shells that carry no LANG at all
# (macOS GUI-launched hooks, and every Windows shell). Empty when unknown.
cc_system_locale() {
  case "$CC_OS" in
    darwin)
      defaults read -g AppleLocale 2>/dev/null || true
      ;;
    windows)
      # reg.exe is ~10x cheaper than spawning PowerShell for one property.
      # Output: "    LocaleName    REG_SZ    fr-FR"
      reg query "HKCU\\Control Panel\\International" //v LocaleName 2>/dev/null \
        | LC_ALL=C awk '/LocaleName/ { print $NF }' || true
      ;;
  esac
}
