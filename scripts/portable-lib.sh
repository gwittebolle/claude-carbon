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

# cc_path_vars <name>…: cc_path applied to each named variable, in place, with one cygpath
# for all of them on Windows (each process costs tens of milliseconds there), and nothing
# started elsewhere. Falls back to cc_path one by one when cygpath does not answer one
# line per path.
cc_path_vars() {
  local v line i=0
  local names=() args=() conv=()
  [ "$CC_OS" = "windows" ] || return 0
  for v in "$@"; do
    case "${!v}" in
      [A-Za-z]:[\\/]*|*\\*) names+=("$v"); args+=("${!v}") ;;
    esac
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  if [ -n "$CC_CYGPATH" ] && line="$($CC_CYGPATH -u "${args[@]}" 2>/dev/null)"; then
    line="${line//$'\r'/}"
    while IFS= read -r v; do conv+=("$v"); done <<EOF
$line
EOF
  fi
  while [ "$i" -lt "${#names[@]}" ]; do
    if [ "${#conv[@]}" -eq "${#names[@]}" ] && [ -n "${conv[$i]}" ]; then
      printf -v "${names[$i]}" '%s' "${conv[$i]}"
    else
      printf -v "${names[$i]}" '%s' "$(cc_path "${args[$i]}")"
    fi
    i=$((i + 1))
  done
}

# ── A private jq ────────────────────────────────────────────────────────────
# macOS ships jq from 15 (Sequoia) on. On an older Mac with none, install.sh fetches
# the official binary into the data folder; every script finds it there, while a jq of
# the system, when there is one, keeps precedence.
if ! command -v jq >/dev/null 2>&1; then
  CC_JQ_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/claude-carbon/bin"
  if [ -x "${CC_JQ_DIR}/jq" ]; then
    PATH="${CC_JQ_DIR}:${PATH}"
    export PATH
  fi
fi

# ── winget's links ──────────────────────────────────────────────────────────
# winget reaches the jq and sqlite3 it installs through links in
# %LOCALAPPDATA%\Microsoft\WinGet\Links, a folder it adds to the user PATH. A Claude
# Code started before that install keeps its old PATH until it restarts, and so do
# the hooks and slash commands it spawns. Appended, so any other jq or sqlite3 wins.
if [ "$CC_OS" = "windows" ] && [ -n "${LOCALAPPDATA:-}" ] &&
   { ! command -v jq >/dev/null 2>&1 || ! command -v sqlite3 >/dev/null 2>&1; }; then
  CC_WINGET_LINKS="$(cc_path "$LOCALAPPDATA")/Microsoft/WinGet/Links"
  if [ -d "$CC_WINGET_LINKS" ]; then
    PATH="${PATH}:${CC_WINGET_LINKS}"
    export PATH
  fi
fi

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
# BSD stat first on macOS, GNU stat elsewhere; the other one only when the first gives
# no plain number (a GNU stat ahead of /usr/bin on a Mac, coreutils' gnubin; the other
# BSDs off macOS). Never a `stat -f … || stat -c …` chain: GNU stat reads `-f %m` as
# "file-system status of the files %m and <file>", prints a multi-line block for the
# real file and only then fails, so the chain returned that block with the epoch
# appended, and every caller doing arithmetic on it died.
cc_mtime() {
  local m
  if [ "$CC_OS" = "darwin" ]; then
    m="$(stat -f %m "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  else
    m="$(stat -c %Y "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
  fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# cc_carbon_plugin_on <settings JSON on stdin>: prints true when the claude-carbon plugin
# is installed from a marketplace and turned on, under its own name or the co2-tracker
# listing of Anthropic's community directory, and false otherwise. The installer's copy of
# the mod (claude-carbon@skills-dir) is not the plugin. The plugin brings the hooks and the
# mod itself, so the installer then writes neither.
cc_carbon_plugin_on() {
  local on
  on="$(jq -r '[(.enabledPlugins // {}) | to_entries[]
      | select(.value == true)
      | select(.key | test("^(claude-carbon|co2-tracker)@"))
      | select(.key != "claude-carbon@skills-dir")] | length > 0' 2>/dev/null)" || on=""
  if [ "${on%$'\r'}" = "true" ]; then echo true; else echo false; fi
}

# cc_is_plugin_cache <dir>: 0 when <dir> is a copy Claude Code's plugin marketplace
# manages (under the config folder's plugins/), which only `claude plugin update` may change.
cc_is_plugin_cache() {
  case "$1" in */.claude/plugins/*|*/plugins/cache/*) return 0 ;; esac
  return 1
}

# ── Processes ───────────────────────────────────────────────────────────────
# cc_detach <command> [args…]: run a command fully in the background, so it outlives
# the hook that started it: session start moving on, the SessionEnd budget expiring, or
# the terminal window closing (nohup ignores the hangup). setsid is absent on macOS, so
# it is probed. (The old `( setsid … & ) || ( … & )` idiom never reached its fallback,
# because backgrounding always makes the subshell exit 0 — so on macOS nothing ran.)
cc_detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 </dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" >/dev/null 2>&1 </dev/null &
  else
    "$@" >/dev/null 2>&1 </dev/null &
  fi
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
        # `--source winget`: otherwise winget also queries the Microsoft Store
        # source and, when that one is unreachable (TLS-inspecting proxy,
        # locked-down Store), aborts the whole install instead of falling back.
        jq)      printf 'winget install jqlang.jq --source winget' ;;
        sqlite3) printf 'winget install SQLite.SQLite --source winget' ;;
        git)     printf 'winget install Git.Git --source winget' ;;
        node)    printf 'winget install OpenJS.NodeJS --source winget' ;;
        *)       printf 'winget install %s --source winget' "$cmd" ;;
      esac
      ;;
    *) printf 'apt install %s' "$cmd" ;;
  esac
}

# ── User folders and the file manager ───────────────────────────────────────
# cc_downloads_dir — the user's Downloads folder, as a path bash can open. The
# cards used to land in <repo>/exports, which on a marketplace install is a
# hidden, per-version cache directory: nobody could find them, and every update
# orphaned the previous ones. Downloads exists on all three platforms and is
# where people look for a file they were handed. The folder is not checked for
# existence: the source consulted is authoritative, and the caller mkdir -p's.
cc_downloads_dir() {
  local d=""
  case "$CC_OS" in
    windows)
      # The Downloads known folder can be redirected (OneDrive does it, and so does
      # moving it under Documents), so ask the registry rather than assume
      # %USERPROFILE%\Downloads. The value is a REG_EXPAND_SZ, its %VARS% unexpanded.
      # First through the runtime's /proc/registry, which hands it over in the shell's
      # own encoding. reg.exe prints it in the console's code page: on a French Windows
      # "Téléchargements" came back as "T?l?chargements", and the cards went to a new
      # folder of that name (2026-10-21). Either way only a folder that exists is taken.
      local value="${CC_REGISTRY_ROOT:-/proc/registry}/HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/User Shell Folders/{374DE290-123F-4565-9164-39C4925E467B}"
      [ -r "$value" ] && d="$(cc_existing_win_dir "$(tr -d '\000\r' < "$value")")"
      if [ -z "$d" ]; then
        # Output: "    {374DE290-...}    REG_EXPAND_SZ    %USERPROFILE%\Downloads"
        d="$(cc_existing_win_dir "$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' \
               //v '{374DE290-123F-4565-9164-39C4925E467B}' 2>/dev/null \
             | LC_ALL=C awk '/374DE290/ { sub(/^[ \t]*\{[^}]*\}[ \t]+REG_[A-Z_]+[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print }' \
             || true)")"
      fi
      ;;
    linux)
      if command -v xdg-user-dir >/dev/null 2>&1; then
        d="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
        # xdg-user-dir answers $HOME when the folder is not configured, which is
        # an absence, not a Downloads directory.
        [ "$d" = "$HOME" ] && d=""
      fi
      ;;
  esac
  [ -n "$d" ] || d="$HOME/Downloads"
  printf '%s' "$d"
}

# cc_existing_win_dir <registry path>: the path with its %VARS% expanded, as bash opens
# it, when that folder exists; nothing otherwise. A path read in the wrong encoding names
# a folder that is not there, and is never created.
cc_existing_win_dir() {
  local d="${1:-}" name
  [ -n "$d" ] || return 0
  while [[ "$d" =~ %([A-Za-z_][A-Za-z0-9_]*)% ]]; do
    name="${BASH_REMATCH[1]}"
    d="${d//%${name}%/${!name:-}}"
  done
  d="$(cc_path "$d")"
  if [ -d "$d" ]; then printf '%s' "$d"; fi
}

# cc_reveal <file> — show the file in the desktop file manager: Finder with the
# file selected on macOS, Explorer on the folder on Windows (explorer's /select,
# switch does not survive a path with spaces reliably), the default file manager
# on the folder on Linux. Best effort and silent: a headless box, a CI runner or
# a user who set CLAUDE_CARBON_NO_OPEN gets nothing, and never an error.
cc_reveal() {
  local f="${1:-}"
  { [ -n "$f" ] && [ -e "$f" ]; } || return 0
  { [ -z "${CLAUDE_CARBON_NO_OPEN:-}" ] && [ -z "${CI:-}" ]; } || return 0
  local dir
  dir="$(dirname "$f")"
  case "$CC_OS" in
    darwin)
      if command -v open >/dev/null 2>&1; then open -R "$f" >/dev/null 2>&1 || true; fi
      ;;
    windows)
      # explorer.exe exits 1 even when it succeeds, and wants a native path.
      if command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$(cc_native_path "$dir")" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$dir" >/dev/null 2>&1 &
      fi
      ;;
  esac
  return 0
}

# ── Calendar ────────────────────────────────────────────────────────────────
# cc_prev_month_name <YYYY-MM> — English name of the month before the given one.
# Pure arithmetic on the string: no `date -d` (GNU only) or `date -v` (BSD only),
# and the name is deliberately English whatever the locale, since the status
# line's other labels are.
cc_prev_month_name() {
  local m="${1#*-}" names
  m="$((10#${m:-1} - 1))"
  [ "$m" -eq 0 ] && m=12
  names=(January February March April May June July August September October November December)
  printf '%s' "${names[$((m - 1))]}"
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

# ── Database schema ─────────────────────────────────────────────────────────
# cc_ensure_schema <db>: bring an existing carbon.db up to the current schema:
# the columns added to `sessions` over time, and the `session_models` and `agent_usage` tables. The
# `sessions` table itself is created by setup.sh and backfill.sh, not here, so a hook
# never creates a DB the user has not set up. Idempotent. One probe decides whether
# anything needs doing, so the Stop hook pays a single sqlite3 call once migrated.
#
# session_models holds one row per (session, model): the session's tokens split by the
# model that produced each assistant message, main transcript and subagents merged.
# Its token columns have the same semantics as the matching `sessions` columns
# (input_tokens = regular input + cache write), and for every session that has child
# rows, each token column, co2_grams and cost_usd of `sessions` equal the sum over
# them. Sessions recorded before the table existed have no child rows.
#
# sessions.agents_collected says which transcripts the version that last wrote the row
# read: CC_AGENTS_COLLECTED (2) for the main transcript, its subagents and the agents its
# workflows started; 0 (the default) for a version that did not say, up to 1.15.3, which
# may have missed the workflow agents. Every writer lists its columns, so an older Stop
# hook still running in a session opened before an update resets it to 0 when it
# rewrites the row, and backfill.sh then knows to look at that row again.
# shellcheck disable=SC2034 # read by the scripts that source this file
CC_AGENTS_COLLECTED=2
# agent_usage: the usage of an agent that worked on a branch of its own, per model,
# recorded by the SubagentStop hook (agent-stop.sh) for /carbon-pr. Same token columns as
# session_models; the agent's tokens are also in its session's row. repo is the
# repository's common git folder (absolute; lower case on Windows), worktree the folder
# of the worktree the branch was checked out in (as git spells it: the report also looks
# for the branch's sessions under its name), how says how the branch was found: "cwd"
# (the agent ran in a worktree of its own) or "cited" (its commands named one). last_ts
# is the agent's last message: the report moves the agent only once its session's row
# was written after it (ended_at), so that the row holds it.
CC_AGENT_USAGE_DDL="CREATE TABLE IF NOT EXISTS agent_usage (session_id TEXT NOT NULL, agent_id TEXT NOT NULL, repo TEXT NOT NULL, git_branch TEXT NOT NULL, worktree TEXT NOT NULL DEFAULT '', how TEXT NOT NULL, model TEXT NOT NULL, input_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0, co2_grams REAL DEFAULT 0, last_ts TEXT DEFAULT '', seen_at TEXT, PRIMARY KEY (session_id, agent_id, model));"
CC_SESSION_MODELS_DDL="CREATE TABLE IF NOT EXISTS session_models (session_id TEXT NOT NULL, model TEXT NOT NULL, input_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0, co2_grams REAL DEFAULT 0, PRIMARY KEY (session_id, model));"
cc_ensure_schema() {
  local db="$1" probe col
  probe="$(cc_sql -cmd ".timeout 5000" "$db" "SELECT (SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('cache_read_tokens','cache_creation_tokens','methodology_version','excluded','git_branch','cache_creation_1h_tokens','output_context_sum','agents_collected')) || '|' || (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('session_models', 'agent_usage'));" 2>/dev/null)" || probe=""
  [ "$probe" = "8|2" ] && return 0
  for col in "cache_read_tokens INTEGER DEFAULT 0" "cache_creation_tokens INTEGER DEFAULT 0" \
             "methodology_version INTEGER DEFAULT 1" "excluded INTEGER DEFAULT 0" \
             "git_branch TEXT DEFAULT ''" "cache_creation_1h_tokens INTEGER DEFAULT 0" \
             "output_context_sum INTEGER DEFAULT 0" "agents_collected INTEGER DEFAULT 0"; do
    sqlite3 -cmd ".timeout 5000" "$db" "ALTER TABLE sessions ADD COLUMN ${col};" >/dev/null 2>&1 || true
  done
  sqlite3 -cmd ".timeout 5000" "$db" "$CC_SESSION_MODELS_DDL $CC_AGENT_USAGE_DDL" >/dev/null 2>&1 || true
}

# cc_collect_subagents <session-dir>: the session's subagent transcripts into the
# array CC_SUB_FILES. Claude Code writes a subagent at <session>/subagents/agent-*.jsonl
# and an agent a workflow started at <session>/subagents/workflows/wf_*/agent-*.jsonl
# (the workflow's journal.jsonl beside it carries no usage). Reading the first only
# missed every workflow agent, up to five times a session's own CO2. A file that cannot
# be read is left out: one unreadable agent must not cost the whole session.
cc_collect_subagents() {
  CC_SUB_FILES=()
  local dir="$1" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl "$dir"/workflows/*/agent-*.jsonl; do
    [ -f "$f" ] && [ -r "$f" ] && CC_SUB_FILES+=("$f")
  done
  return 0
}

# cc_max_mtime <file>…: the latest modification time of the files, in epoch seconds, in
# one stat call (0 when none can be read). BSD stat first on macOS, GNU stat elsewhere,
# and the other one when the first gives nothing: a GNU stat ahead of /usr/bin on a Mac
# (coreutils' gnubin) reads -f as --file-system.
cc_max_mtime() {
  local m
  [ $# -gt 0 ] || { printf '0\n'; return 0; }
  if [ "$CC_OS" = "darwin" ]; then
    m="$(cc_max_of "$(stat -f %m "$@" 2>/dev/null || true)")"
    [ "$m" != "0" ] || m="$(cc_max_of "$(stat -c %Y "$@" 2>/dev/null || true)")"
  else
    m="$(cc_max_of "$(stat -c %Y "$@" 2>/dev/null || true)")"
    [ "$m" != "0" ] || m="$(cc_max_of "$(stat -f %m "$@" 2>/dev/null || true)")"
  fi
  printf '%s\n' "$m"
}

# cc_max_of <lines>: the largest of the lines that are a plain number, 0 when none is.
cc_max_of() {
  printf '%s\n' "$1" | awk 'BEGIN { m = 0 } { sub(/\r$/, "") } /^[0-9]+$/ { if ($1 + 0 > m) m = $1 + 0 } END { printf "%.0f\n", m }'
}

# cc_sql <sqlite3 arguments>: sqlite3 with the CR removed from its output (an older
# sqlite3.exe on Windows ends its lines in CRLF, and "0\r" is no number), exit status kept.
cc_sql() {
  local out
  out="$(sqlite3 "$@")" || return $?
  printf '%s\n' "${out//$'\r'/}"
}

# cc_export_sessions <db>: write sessions-history.tsv next to the DB, one line per
# session with CO2, oldest first: session id, start time in epoch seconds, grams of CO2,
# methodology version, project (its folder's name, tabs and line breaks made spaces),
# API-price cost in dollars (empty when unknown), dominant model, then the tokens by kind
# (uncached input, cache write, cache read, output; 0 when unknown). Legacy (v1) rows are
# in it, as stored.
# The mod's /carbon-panel pane reads it; the mod itself never opens the DB. Read-only
# (-readonly), so a frozen series cannot be written from here. A unique temp name and a
# rename: two sessions ending a turn at once never leave a half-written file, and a
# failed query leaves the previous file in place. No rows gives an empty file, which the
# pane reads as an empty history.
cc_export_sessions() {
  local db="$1" out tmp
  out="$(dirname "$db")/sessions-history.tsv"
  tmp="${out}.tmp.$$"
  if sqlite3 -readonly -cmd ".timeout 5000" -separator "$(printf '\t')" "$db" \
    "SELECT session_id, CAST(strftime('%s', started_at) AS INTEGER), ROUND(co2_grams, 3), COALESCE(methodology_version, 1), REPLACE(REPLACE(REPLACE(COALESCE(project, ''), char(9), ' '), char(10), ' '), char(13), ' '), COALESCE(ROUND(cost_usd, 4), ''), REPLACE(REPLACE(COALESCE(model, ''), char(9), ' '), char(10), ' '), MAX(COALESCE(input_tokens, 0) - COALESCE(cache_creation_tokens, 0), 0), COALESCE(cache_creation_tokens, 0), COALESCE(cache_read_tokens, 0), COALESCE(output_tokens, 0) FROM sessions WHERE COALESCE(excluded, 0) = 0 AND co2_grams > 0 AND strftime('%s', started_at) IS NOT NULL ORDER BY started_at;" \
    >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# ── Models: family, factors, prices ─────────────────────────────────────────
# The single resolution of a model id into its emission factors and its prices, shared
# by the Stop hook, backfill, recompute, the status line and the vector replays. It
# replaces five copies of the family detection that had drifted in their precedence.
#
# Family (energy factors, and the default price): a case-insensitive substring match,
# in this precedence: haiku, then opus, then fable|mythos, else sonnet. That is the
# order persist-session.sh and recompute.sh applied (last match wins there); backfill.sh
# and statusline.sh tested fable first, which only differs for an id naming two
# families, and no Claude id does.
#
# Price overrides (prices.json model_overrides): a key matches the id exactly, or as a
# prefix followed by nothing but a dated snapshot suffix "-YYYYMMDD", so that
# "claude-opus-5-5" matches "claude-opus-5-5-20260922" but never "claude-opus-5-50".
# A trailing context marker such as "[1m]" is ignored. The longest matching key wins.
# An override may set input, output and any of the three cache multipliers; whatever
# it leaves out falls back to the family price and the global multipliers. Factors
# (factors.json) stay per family.
#
# jq definitions, prepended to a jq program. $f is factors.json, $p prices.json.
CC_JQ_MODEL_DEFS='
def cc_family:
  (if type == "string" then ascii_downcase else "" end) as $m
  | if ($m | test("haiku")) then "haiku"
    elif ($m | test("opus")) then "opus"
    elif ($m | test("fable|mythos")) then "fable"
    else "sonnet" end;
def cc_override($ov):
  ((if type == "string" then ascii_downcase else "" end) | sub("\\[[^\\]]*\\]$"; "")) as $m
  | [ ($ov // {}) | to_entries[]
      | select((.key | startswith("_") | not) and ((.value | type) == "object"))
      | (.key | ascii_downcase) as $k
      | select($m == $k
               or (($m | startswith($k + "-")) and ($m[(($k | length) + 1):] | test("^[0-9]{8}$")))) ]
  | sort_by(-(.key | length))
  | (first // {}) | (.value // {});
def cc_params($f; $p):
  cc_family as $fam
  | cc_override($p.model_overrides) as $o
  | ({fable: [156, 3304], opus: [78, 1652], sonnet: [39, 826], haiku: [10, 207]}[$fam]) as $fd
  | ({fable: [10, 50], opus: [4, 20], sonnet: [2, 10], haiku: [0.1, 0.5]}[$fam]) as $pd
  | { family: $fam,
      fin:   ($f.models[$fam].input  // $fd[0]),
      fout:  ($f.models[$fam].output // $fd[1]),
      crf:   ($f.cache_read_factor // 0.08),
      pin:   ($o.input  // $p.models[$fam].input  // $pd[0]),
      pout:  ($o.output // $p.models[$fam].output // $pd[1]),
      cwm:   ($o.cache_write_multiplier    // $p.cache_write_multiplier    // 1.25),
      cwm1h: ($o.cache_write_multiplier_1h // $p.cache_write_multiplier_1h // 2.0),
      crm:   ($o.cache_read_multiplier     // $p.cache_read_multiplier     // 0.1) };
def cc_param_cols: [.fin, .fout, .crf, .pin, .pout, .cwm, .cwm1h, .crm];
'

# cc_model_params <factors.json> <prices.json>: reads model ids on stdin, one per
# line, and prints one tab-separated line per id:
#   model family fin fout crf pin pout cwm cwm1h crm
# (factors in gCO2e/Mtok, prices in USD/Mtok, the three cache price multipliers).
# CR is stripped on both sides: on Windows, sqlite3 and jq emit CRLF, so a model id
# would carry a trailing \r and the last column would fail the numeric check.
cc_model_params() {
  tr -d '\r' | jq -R -r --slurpfile f "$1" --slurpfile p "$2" \
    "${CC_JQ_MODEL_DEFS}"' . as $m | cc_params($f[0]; $p[0]) as $x | [$m, $x.family] + ($x | cc_param_cols) | @tsv' \
    | tr -d '\r'
}

# cc_exclude_regex <factors.json>: the user's exclude_models patterns joined with "|".
cc_exclude_regex() {
  jq -r '(.exclude_models // []) | join("|")' "$1" 2>/dev/null || true
}

# cc_is_excluded_model <model> [exclude_regex]: exit 0 when the model is left out of
# cost/CO2 accounting: not an Anthropic Claude model (a local model behind
# ANTHROPIC_BASE_URL, the "<synthetic>" marker), or matching a user pattern
# (grep -E, case-insensitive). The "claude" test is a glob: no process spawned.
cc_is_excluded_model() {
  case "$1" in
    *[Cc][Ll][Aa][Uu][Dd][Ee]*) ;;
    *) return 0 ;;
  esac
  if [ -n "${2:-}" ] && printf '%s\n' "$1" | grep -qiE "$2"; then return 0; fi
  return 1
}

# ── Session usage: tokens per model, CO2 and cost ───────────────────────────
# The per-message aggregation behind the Stop hook and backfill, in two jq steps.
#
# Per file (CC_JQ_FILE_USAGE): each transcript, the main one and every subagent's, is
# reduced on its own, since the aggregation never crosses files: the last occurrence of
# each assistant message is kept per file (key message.id|requestId: streaming snapshots
# grow output_tokens, the last one carries the final value; the same message in two
# files is counted in both, as it always was), a message without a model string goes to
# its file's dominant model, and the tokens are summed per model. The main transcript
# also gives its dominant model, its last git branch and its first timestamp. One JSON
# line per file:
#   {f, bad, main, dom, b, t0, t1, m: [[model, input, cache write, cache write 1h,
#                                        cache read, output, output x context], ...]}
# (bad: lines that did not parse, raw reading only; t0, t1: first and last timestamps).
#
# Merge (CC_JQ_MERGE_USAGE): the file lines, on stdin, summed per model, priced, and
# printed as the lines below, all tab-separated:
#   X  <exclude regex>
#   S  <main dominant model> <git branch> <first ts (main)> <last ts (all files)>
#   M  <model> <input> <cache write> <cache write 1h> <cache read> <output> <output x context>
#      <fin> <fout> <crf> <pin> <pout> <cwm> <cwm1h> <crm>
# Both programs stay inline (a .jq file checked out with CRLF by Git for Windows is refused
# by jq 1.7.1) and use nothing newer than jq 1.6 (Ubuntu 22.04, Debian 11).
CC_JQ_FILE_USAGE='
def n: if type == "number" then . else 0 end;
def dom: map(.model) | map(select(length > 0))
         | if length == 0 then "claude-sonnet" else group_by(.) | sort_by(-length) | first | first end;
def lines: if $raw then (inputs | if test("^[ \t\r]*$") then empty else (try fromjson catch {cc_bad: true}) end)
            else inputs end;
[ lines | input_filename as $fn
  | if type != "object" then empty
    elif .cc_bad == true then { fn: $fn, bad: true }
    elif .type == "assistant" and (.message | type) == "object" and .message.usage != null then
      { fn: $fn, u: true, id: .message.id, rid: .requestId,
        model: (.message.model | if type == "string" then . else "" end),
        ts: (.timestamp | if type == "string" then . else "" end),
        b: (.gitBranch | if type == "string" then . else "" end),
        it: (.message.usage.input_tokens | n),
        cw: (.message.usage.cache_creation_input_tokens | n),
        cw1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens? | n),
        cr: (.message.usage.cache_read_input_tokens | n),
        out: (.message.usage.output_tokens | n) }
    elif $fn == $main and (.gitBranch | type) == "string" and (.gitBranch | length) > 0 then
      { fn: $fn, b: .gitBranch }
    else empty end ]
| group_by(.fn)[]
| .[0].fn as $file
| [.[] | select(.u == true)] as $all
| ( ($all | map(select(.id != null and .rid != null))
          | reduce .[] as $m ({}; .[($m.id | tostring) + "|" + ($m.rid | tostring)] = $m)
          | [.[]])
    + ($all | map(select(.id == null or .rid == null))) ) as $d
| ($d | dom) as $dm
| ($d | map(.ts) | map(select(length > 0)) | sort) as $ts
| { f: $file,
    bad: (map(select(.bad == true)) | length),
    main: ($file == $main),
    dom: $dm,
    b: ([.[] | (.b // "") | select(length > 0)] | last // ""),
    t0: ($ts | first // ""),
    t1: ($ts | last // ""),
    m: [ $d | map(if .model == "" then .model = $dm else . end) | group_by(.model)[]
         | [ .[0].model, (map(.it) | add), (map(.cw) | add), (map(.cw1h) | add),
             (map(.cr) | add), (map(.out) | add), (map(.out * (.it + .cw + .cr)) | add) ] ] }
'
CC_JQ_MERGE_USAGE='
[inputs] as $files
| ([$files[] | select(.main == true)] | first // {}) as $mf
| (["X", ($f[0].exclude_models // [] | join("|"))] | @tsv),
  (["S", ($mf.dom // "claude-sonnet"), ($mf.b // ""), ($mf.t0 // ""),
    ([$files[].t1 | select(length > 0)] | sort | last // "")] | @tsv),
  ( [$files[].m[]] | group_by(.[0])[]
    | { model: .[0][0], it: (map(.[1]) | add), cw: (map(.[2]) | add), cw1h: (map(.[3]) | add),
        cr: (map(.[4]) | add), out: (map(.[5]) | add), octx: (map(.[6]) | add) }
    | select(.it + .cw + .cr + .out > 0)
    | . as $r
    | (.model | cc_params($f[0]; $p[0]) | cc_param_cols) as $pc
    | (["M", $r.model, $r.it, $r.cw, $r.cw1h, $r.cr, $r.out, $r.octx] + $pc) | @tsv )
'

# The CO2 and cost of one row, the formulas of METHODOLOGY.md (same expressions and
# printf precision the plugin has always used, so stored values do not move):
#   co2  = ((input + cache_write) * fin + cache_read * (fin * crf) + output * fout) / 1e6
#   cost = (input * pin + cw_1h * (pin * cwm1h) + cw_5m * (pin * cwm)
#           + cache_read * (pin * crm) + output * pout) / 1e6
# cw_1h is clamped to the total write; an excluded model keeps its tokens at 0 CO2, 0 cost.
# Input: the M lines with a trailing excluded flag. Output, tab-separated:
#   R  <model> <input + cache write> <cache write> <cache write 1h> <cache read> <output> <co2> <cost>
#   T  <input + cache write> <cache write> <cache write 1h> <cache read> <output> <output x context> <co2> <cost>
# Token counts go through %.0f, not %d: a long session's cache reads pass 2^31.
CC_AWK_PRICE='
BEGIN { FS = "\t"; OFS = "\t" }
$1 == "M" {
  it = $3 + 0; cw = $4 + 0; cw1h = $5 + 0; cr = $6 + 0; out = $7 + 0; octx = $8 + 0
  fin = $9; fout = $10; crf = $11; pin = $12; pout = $13; cwm = $14; cwm1h = $15; crm = $16; ex = $17
  if (cw1h > cw) cw1h = cw
  cw5m = cw - cw1h
  if (ex == "1") { co2 = "0.0000"; cost = "0.000000" }
  else {
    co2  = sprintf("%.4f", ((it + cw) * fin + cr * (fin * crf) + out * fout) / 1000000)
    cost = sprintf("%.6f", (it * pin + cw1h * (pin * cwm1h) + cw5m * (pin * cwm) + cr * (pin * crm) + out * pout) / 1000000)
  }
  print "R", $2, sprintf("%.0f", it + cw), sprintf("%.0f", cw), sprintf("%.0f", cw1h), sprintf("%.0f", cr), sprintf("%.0f", out), co2, cost
  t_in += it + cw; t_cw += cw; t_cw1h += cw1h; t_cr += cr; t_out += out; t_octx += octx
  t_co2 += co2; t_cost += cost
}
END {
  printf "T\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.4f\t%.6f\n", t_in, t_cw, t_cw1h, t_cr, t_out, t_octx, t_co2, t_cost
}
'

# cc_session_usage <factors.json> <prices.json> <main.jsonl> [subagent.jsonl…]
# Prints the S line, one R line per model and the T line (see above). Fails when the
# transcripts cannot be read at all. A subagent transcript already gone or unreadable when
# this function starts is left out; one that disappears after that, before or while jq
# reads it, fails the pass (exit 1), and the session keeps its previous row.
#
# jq runs in the session's folder and is given relative paths, in batches of at most
# CC_JQ_ARGV_MAX bytes of arguments, program included (see cc_usage_read).
#
# Cache (opt-in: CC_USAGE_CACHE_DIR, set by the Stop hook, the rescan and the status
# line; CLAUDE_CARBON_NO_USAGE_CACHE=1 leaves it empty and unwritten). An agent's
# transcript stops changing once the agent is done, so its file line (CC_JQ_FILE_USAGE)
# is kept, keyed by its path relative to the session's folder, its size, its mtime, its
# ctime and its inode (of the file a symlink points to), all read by one stat before the
# files are read, and reused while they are the same: the session's files are then read
# again only for the main transcript (never kept: it grows) and the agents that changed.
# A stat that does not answer as expected (a missing file, an unknown flavour) means no
# cache for that pass. A file jq could not read, a file with a line that did not parse,
# and a path outside the session's folder are never kept. The cache file is rewritten
# only when an agent's entry changed, and a cache that does not parse is ignored and
# rewritten from a full read. One file per session, named after the session id (unique;
# a path and an inode in the key keep two folders' sessions of one id from ever sharing
# an entry) with CC_USAGE_CACHE_VERSION in the name; the rescan removes the files not
# written for 45 days. One JSON line per agent, keys in this order:
#   {"p": path, "s": size, "m": mtime, "c": ctime, "i": inode, "a": <its file line>}
# The reader (CC_AWK_USAGE_CACHE) goes by position: any change to an entry's shape, to
# what CC_JQ_FILE_USAGE puts in a file line, or to how cc_usage_read reads a file, needs
# a new CC_USAGE_CACHE_VERSION (tests/run-usage-cache-tests.sh keeps the history).
CC_JQ_ARGV_MAX=16000
CC_USAGE_CACHE_VERSION=1
cc_session_usage() {
  local factors="$1" prices="$2" main="$3" raw_out line tag model rest exre="" rows="" s_line="" f
  local LC_ALL=C dir sid base mainrel cachefile="" joined="" kept="" hits="" misses=""
  local fresh="" newlines="" changed=0 attempt
  local agents=() toread=()
  shift 3
  [ -r "$main" ] || return 1
  case "$main" in */*) dir="${main%/*}" ;; *) dir="." ;; esac
  [ -n "$dir" ] || dir="/"
  sid="${main##*/}"
  sid="${sid%.jsonl}"
  if [ -d "$dir/$sid" ]; then base="$dir/$sid"; mainrel="../$sid.jsonl"; else base="$dir"; mainrel="$sid.jsonl"; fi
  for f in "$@"; do
    [ -r "$f" ] || continue
    case "$f" in
      "$base"/*) agents+=("${f#"$base"/}") ;;
      *) agents+=("$f") ;;
    esac
  done
  if [ -n "${CC_USAGE_CACHE_DIR:-}" ] && [ "${CLAUDE_CARBON_NO_USAGE_CACHE:-0}" != "1" ] && [ "${#agents[@]}" -gt 0 ]; then
    cachefile="${CC_USAGE_CACHE_DIR}/${sid//[^A-Za-z0-9._-]/_}.v${CC_USAGE_CACHE_VERSION}.jsonl"
  fi
  # Two attempts: with the cache, then, if what it gave does not merge, from a full read
  for attempt in 1 2; do
    toread=("$mainrel")
    kept=""; hits=""; misses=""; changed=""
    if [ -n "$cachefile" ]; then
      joined="$(cc_usage_join "$base" "$cachefile" "$attempt" "${agents[@]}")" || joined=""
      while IFS= read -r line; do
        case "$line" in
          "K	"*) kept="${kept}${line#K	}
" ;;
          "A	"*) hits="${hits}${line#A	}
" ;;
          "M	"*) rest="${line#M	}"; toread+=("${rest%%	*}"); misses="${misses}${rest}
" ;;
          "C	"*) changed="${line#C	}" ;;
        esac
      done <<EOF
$joined
EOF
      # No answer from the join: no cache for this pass
      if [ -z "$changed" ]; then
        cachefile=""; kept=""; hits=""; misses=""
        toread=("$mainrel")
      fi
    fi
    if [ -z "$cachefile" ]; then
      toread+=(${agents[@]+"${agents[@]}"})
    fi
    fresh="$(cc_usage_read "$base" "$mainrel" "${toread[@]}")" || return 1
    raw_out="$(printf '%s\n%s\n' "$hits" "$fresh" | jq -n -r --slurpfile f "$factors" --slurpfile p "$prices" \
                 "${CC_JQ_MODEL_DEFS}${CC_JQ_MERGE_USAGE}" 2>/dev/null)" || raw_out=""
    # jq.exe ends its lines in CRLF, and MSYS bash only drops the CR of the last one: the
    # others reached the exclusion patterns (X) and the session's last timestamp (S), which
    # backfill stored with a CR as the end of a session it added
    raw_out="${raw_out//$'\r'/}"
    [ -n "$raw_out" ] && break
    # Nothing merges without the cache: the transcripts themselves are the trouble
    [ -n "$hits" ] || return 1
  done
  [ -n "$raw_out" ] || return 1
  # The agents read this time, with their stat, join the entries kept
  # (not when they only re-read files that are never kept: same entries, same file)
  if [ -n "$cachefile" ] && { [ "$changed" != "0" ] || [ "$attempt" = "2" ]; }; then
    newlines="$({ printf '%s' "$misses"; printf '\t--fresh--\n'; printf '%s\n' "$fresh"; } | awk "$CC_AWK_USAGE_ENTRIES")" || newlines=""
    if [ "${kept}${newlines}" != "$(cat "$cachefile" 2>/dev/null || true)
" ]; then
      mkdir -p "$CC_USAGE_CACHE_DIR" 2>/dev/null || true
      { printf '%s%s' "$kept" "$newlines" > "${cachefile}.tmp.$$" && mv -f "${cachefile}.tmp.$$" "$cachefile"; } 2>/dev/null \
        || rm -f "${cachefile}.tmp.$$" 2>/dev/null || true
    fi
  fi
  # Exclusion is decided in bash, with grep -E as it always was: user patterns are ERE.
  while IFS= read -r line; do
    tag="${line%%	*}"
    case "$tag" in
      X) exre="${line#X	}" ;;
      S) s_line="$line" ;;
      M)
        rest="${line#M	}"
        model="${rest%%	*}"
        if cc_is_excluded_model "$model" "$exre"; then
          rows="${rows}${line}	1
"
        else
          rows="${rows}${line}	0
"
        fi
        ;;
    esac
  done <<EOF
$raw_out
EOF
  printf '%s\n' "$s_line"
  printf '%s' "$rows" | LC_ALL=C awk "$CC_AWK_PRICE"
}

# cc_usage_read <base> <main, relative> <file…>: the file lines (CC_JQ_FILE_USAGE) of the
# files, read from <base> in batches of at most CC_JQ_ARGV_MAX bytes of arguments: a
# session with hundreds of agents passed every absolute path to one jq, and on Windows,
# where a program's command line stops at 32,767 characters, jq did not start and the
# session stayed as it was. Relative paths are also left as they are by MSYS, which
# converts /c/... arguments for jq.exe. A batch that does not parse (a line cut by a
# concurrent write) is read again as raw text, skipping the lines that are not JSON. Raw
# reading runs a file's last line, if it has no newline, into the next file's first: the
# files around one with a line that did not parse are read again alone, so only the cut
# line is lost. Fails when a batch cannot be read at all.
cc_usage_read() {
  local base="$1" mainrel="$2" LC_ALL=C budget size len i part bad redo f all=""
  local rels=() batch=()
  shift 2
  rels=("$@")
  # Bytes left for the paths, each with its terminating NUL, once the program and the other
  # arguments are counted (LC_ALL=C: ${#} counts bytes)
  budget=$((CC_JQ_ARGV_MAX - ${#CC_JQ_FILE_USAGE} - ${#mainrel} - 64))
  i=0
  size=0
  while [ "$i" -le "${#rels[@]}" ]; do
    if [ "$i" -lt "${#rels[@]}" ]; then
      len=$(( ${#rels[$i]} + 1 ))
      if [ "${#batch[@]}" -eq 0 ] || [ $((size + len)) -le "$budget" ]; then
        batch+=("${rels[$i]}")
        size=$((size + len))
        i=$((i + 1))
        continue
      fi
    else
      i=$((i + 1))
    fi
    [ "${#batch[@]}" -gt 0 ] || continue
    # Read the batch: strict, then raw, then the files around a line that did not parse
    part="$(cd "$base" && jq -n -c --arg main "$mainrel" --argjson raw false "$CC_JQ_FILE_USAGE" "${batch[@]}" 2>/dev/null)" \
      || {
        part="$(cd "$base" && jq -n -c -R --arg main "$mainrel" --argjson raw true "$CC_JQ_FILE_USAGE" "${batch[@]}" 2>/dev/null)" \
          || return 1
        part="${part//$'\r'/}"
        bad="$(printf '%s\n' "$part" | jq -r 'select(.bad > 0) | .f' 2>/dev/null)" || return 1
        bad="${bad//$'\r'/}"
        if [ -n "$bad" ]; then
          redo="$(cc_redo_neighbours "$base" "$bad" "${batch[@]}")"
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            part="$(printf '%s\n' "$part" | grep -vF "{\"f\":\"${f}\"," || true)"
            part="${part}
$(cd "$base" && jq -n -c -R --arg main "$mainrel" --argjson raw true "$CC_JQ_FILE_USAGE" "$f" 2>/dev/null)" \
              || return 1
          done <<EOF
$redo
EOF
        fi
      }
    all="${all}${part//$'\r'/}
"
    batch=()
    size=0
  done
  printf '%s' "$all"
}

# cc_usage_join <base> <cache file> <attempt> <file…>: one stat of the files (from
# <base>, following symlinks: the file a link points to is what jq reads), joined with
# the cache file (not read on attempt 2), through CC_AWK_USAGE_CACHE. The stat flavour
# that matches the system first (BSD on macOS, GNU elsewhere), the other one when the
# first does not answer as expected. Fails, printing nothing, when neither does: no cache
# for that pass.
cc_usage_join() {
  local base="$1" cache="$2" attempt="$3" out flavour
  shift 3
  [ "$attempt" = "1" ] || cache=""
  if [ "$CC_OS" = "darwin" ]; then set -- bsd gnu "$@"; else set -- gnu bsd "$@"; fi
  for flavour in "$1" "$2"; do
    if [ "$flavour" = "gnu" ]; then
      out="$(cd "$base" && stat -L -c '%s %Y %Z %i %n' "${@:3}" 2>/dev/null)" || out=""
    else
      out="$(cd "$base" && stat -L -f '%z %m %c %i %N' "${@:3}" 2>/dev/null)" || out=""
    fi
    [ -n "$out" ] || continue
    out="$({ printf '%s\n' "${@:3}"; printf '\t--stat--\n'; printf '%s\n' "$out"; } \
      | awk -v cache="$cache" "$CC_AWK_USAGE_CACHE")" || continue
    printf '%s\n' "$out"
    return 0
  done
  return 1
}

# CC_AWK_USAGE_CACHE: on stdin, the files asked for, a "\t--stat--" line, then the stat
# lines ("size mtime ctime inode path"); the cache file given as -v cache. Exits 1 unless
# every file gets plain numbers, an mtime above 0 and its own path back. Prints
#   K <entry>   an entry whose file did not change, kept
#   A <file line>   its file line, for the merge
#   M <path> <size> <mtime> <ctime> <inode>   a file to read (new, changed, entry unusable)
#   C <n>   entries changed: files to read, and entries of files gone
# An entry that does not have the expected shape is ignored, its file read again.
CC_AWK_USAGE_CACHE='
{ sub(/\r$/, "") }
$0 == "\t--stat--" { s = 1; next }
!s { want[++w] = $0; next }
{
  n++
  name = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", name)
  if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $2 + 0 <= 0 || name != want[n]) bad = 1
  path[n] = name; sz[n] = $1; mt[n] = $2; ct[n] = $3; ino[n] = $4; at[name] = n
}
END {
  if (bad || n != w || w == 0) exit 1
  pre = "{\"p\":\""
  while (cache != "" && (getline line < cache) > 0) {
    sub(/\r$/, "", line)
    if (index(line, pre) != 1) continue
    r = substr(line, length(pre) + 1)
    i = index(r, "\",\"s\":"); if (!i) continue
    p = substr(r, 1, i - 1); r = substr(r, i + 6)
    i = index(r, ",\"m\":"); if (!i) continue
    sv = substr(r, 1, i - 1); r = substr(r, i + 5)
    i = index(r, ",\"c\":"); if (!i) continue
    mv = substr(r, 1, i - 1); r = substr(r, i + 5)
    i = index(r, ",\"i\":"); if (!i) continue
    cv = substr(r, 1, i - 1); r = substr(r, i + 5)
    i = index(r, ",\"a\":{"); if (!i) continue
    iv = substr(r, 1, i - 1); a = substr(r, i + 5)
    if (sv !~ /^[0-9]+$/ || mv !~ /^[0-9]+$/ || cv !~ /^[0-9]+$/ || iv !~ /^[0-9]+$/ || substr(a, length(a) - 1) != "}}") continue
    a = substr(a, 1, length(a) - 1)
    if (!(p in at)) { gone++; continue }
    k = at[p]
    if (seen[k] || sv != sz[k] || mv != mt[k] || cv != ct[k] || iv != ino[k]) continue
    seen[k] = 1; keep[k] = line; agg[k] = a
  }
  if (cache != "") close(cache)
  for (k = 1; k <= n; k++) {
    if (seen[k]) { print "K\t" keep[k]; print "A\t" agg[k] }
    else { print "M\t" path[k] "\t" sz[k] "\t" mt[k] "\t" ct[k] "\t" ino[k]; changed++ }
  }
  print "C\t" (changed + gone)
}'

# CC_AWK_USAGE_ENTRIES: the files read ("path<TAB>size<TAB>mtime<TAB>ctime<TAB>inode"
# lines), a "\t--fresh--" line, then the file lines jq gave: one cache entry per file
# read. A file with no line (no message in it) is kept with no model. Never kept: a file
# with a line that did not parse (read raw, "bad" above 0: it may be cut by a write in
# progress), a path outside the session's folder, a path JSON would have to escape.
CC_AWK_USAGE_ENTRIES='
BEGIN { FS = "\t" }
{ sub(/\r$/, "") }
$0 == "\t--fresh--" { f = 1; next }
!f { if ($1 != "") { n++; path[n] = $1; sz[$1] = $2; mt[$1] = $3; ct[$1] = $4; ino[$1] = $5 } next }
{
  pre = "{\"f\":\""
  if (index($0, pre) != 1) next
  r = substr($0, length(pre) + 1); i = index(r, "\""); if (!i) next
  p = substr(r, 1, i - 1)
  if (!(p in sz)) next
  agg[p] = $0
  if (index(r, "\",\"bad\":0,") != i) badline[p] = 1
}
END {
  for (k = 1; k <= n; k++) {
    p = path[k]
    if (p ~ /["\\]/ || p ~ /^\// || p ~ /^[A-Za-z]:/ || (p in badline)) continue
    a = (p in agg) ? agg[p] : "{\"f\":\"" p "\",\"m\":[]}"
    print "{\"p\":\"" p "\",\"s\":" sz[p] ",\"m\":" mt[p] ",\"c\":" ct[p] ",\"i\":" ino[p] ",\"a\":" a "}"
  }
}'

# cc_redo_neighbours <base> <files, one per line> <batch…>: those files and the ones just
# before and after each in the batch, once each, one per line (see cc_session_usage). An
# empty file adds no line, so the neighbours are the nearest files that are not empty.
cc_redo_neighbours() {
  local base="$1" wanted="$2" f k n
  local files=()
  shift 2
  for f in "$@"; do
    case "$f" in /*) [ -s "$f" ] ;; *) [ -s "$base/$f" ] ;; esac && files+=("$f")
  done
  n=${#files[@]}
  k=0
  while [ "$k" -lt "$n" ]; do
    case "
$wanted
" in
      *"
${files[$k]}
"*)
        [ "$k" -gt 0 ] && printf '%s\n' "${files[$((k - 1))]}"
        printf '%s\n' "${files[$k]}"
        [ $((k + 1)) -lt "$n" ] && printf '%s\n' "${files[$((k + 1))]}"
        ;;
    esac
    k=$((k + 1))
  done | awk 'length($0) > 0 && !seen[$0]++'
}

# CC_SQ: a single quote, for doubling quotes in SQL literals: X="${X//$CC_SQ/$CC_SQ$CC_SQ}".
# The spelling "${X//\'/\'\'}" inside double quotes keeps the backslashes on bash 3.2
# (the macOS /bin/bash), which turned every apostrophe into \'\' and broke the statement.
CC_SQ="'"

# cc_sql_quote <string>: the string as a single-quoted SQL literal.
cc_sql_quote() {
  local s="${1//$CC_SQ/$CC_SQ$CC_SQ}"
  printf "'%s'" "$s"
}

# cc_session_models_sql <session_id> <usage output> [condition]: the statements that
# replace a session's child rows: DELETE, then one INSERT per R line. The caller wraps
# them, and its own `sessions` write, in one transaction. With a condition (an SQL
# expression), each statement only applies when it holds, so the caller can make the
# whole write depend on the row it finds once it holds the lock.
cc_session_models_sql() {
  local sid line tag model it cw cw1h cr out co2 cost cond="${3:-1}"
  sid="$(cc_sql_quote "$1")"
  printf 'DELETE FROM session_models WHERE session_id=%s AND (%s);\n' "$sid" "$cond"
  while IFS="	" read -r tag model it cw cw1h cr out co2 cost; do
    [ "$tag" = "R" ] || continue
    case "${it}${cw}${cw1h}${cr}${out}" in ''|*[!0-9]*) continue ;; esac
    case "$co2$cost" in ''|*[!0-9.]*) continue ;; esac
    printf 'INSERT INTO session_models (session_id, model, input_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, output_tokens, co2_grams, cost_usd) SELECT %s, %s, %s, %s, %s, %s, %s, %s, %s WHERE (%s);\n' \
      "$sid" "$(cc_sql_quote "$model")" "$it" "$cw" "$cw1h" "$cr" "$out" "$co2" "$cost" "$cond"
  done <<EOF
$2
EOF
}

# cc_parse_usage <usage output>: sets, in the caller's shell:
#   CC_U_MODEL CC_U_BRANCH CC_U_FIRST_TS CC_U_LAST_TS   (from the S line)
#   CC_U_IN CC_U_CW CC_U_CW1H CC_U_CR CC_U_OUT CC_U_OCTX CC_U_CO2 CC_U_COST   (the T line)
# The S line is split by hand: `read` collapses consecutive tabs, and an empty branch
# or timestamp must stay in its column.
# shellcheck disable=SC2034 # the CC_U_* globals are this function's output, read by the caller
cc_parse_usage() {
  local line rest
  CC_U_MODEL="claude-sonnet"; CC_U_BRANCH=""; CC_U_FIRST_TS=""; CC_U_LAST_TS=""
  CC_U_IN=0; CC_U_CW=0; CC_U_CW1H=0; CC_U_CR=0; CC_U_OUT=0; CC_U_OCTX=0; CC_U_CO2=0; CC_U_COST=0
  while IFS= read -r line; do
    case "$line" in
      "S	"*)
        rest="${line#S	}"
        CC_U_MODEL="${rest%%	*}";    rest="${rest#*	}"
        CC_U_BRANCH="${rest%%	*}";   rest="${rest#*	}"
        CC_U_FIRST_TS="${rest%%	*}"; CC_U_LAST_TS="${rest#*	}"
        ;;
      "T	"*)
        IFS="	" read -r _ CC_U_IN CC_U_CW CC_U_CW1H CC_U_CR CC_U_OUT CC_U_OCTX CC_U_CO2 CC_U_COST <<EOF
$line
EOF
        ;;
    esac
  done <<EOF
$1
EOF
  [ -n "$CC_U_MODEL" ] || CC_U_MODEL="claude-sonnet"
}

# ── An agent's branch (agent-stop.sh) ──────────────────────────────────────
# CC_AWK_AGENT_CANDIDATES: `git worktree list --porcelain` on stdin; -v top (the agent's
# worktree root), stop (the session's), home and homen (the home folder as bash spells it,
# and as git does on Windows: C:/...). Prints one JSON array of {p, b, t}: each worktree
# an agent working from top could name, with its branch (b), its folder as git spells it
# (t) and each spelling of its path (p): as git gives it; with its drive letter in both
# cases and as /c/... on Windows; ~/... under the home folder; ../... beside top; ./...
# inside top, and also bare when that path has a slash (a bare word such as "docs" would
# be read in any command). Lines may end in CR (git on Windows). Left out: the main
# folder (the first entry), top, stop, a detached HEAD, a branch Claude Code named
# (worktree-agent-*, worktree-wf_*), and a path or branch that would need escaping in JSON
# (a quote, a backslash, a tab).
# shellcheck disable=SC2034 # read by agent-stop.sh
CC_AWK_AGENT_CANDIDATES='
function add(p) {
  if (p == "" || (p in seen)) return
  seen[p] = 1
  out = out (out == "" ? "" : ",") "{\"p\":\"" p "\",\"b\":\"" branch "\",\"t\":\"" path "\"}"
}
function flush(   pb, d, base, r) {
  if (path != "" && n > 1 && path != top && path != stop && branch != "" &&
      branch !~ /^worktree-(agent-|wf_)/ && path !~ /["\\\t]/ && branch !~ /["\\\t]/) {
    add(path)
    pb = path
    if (path ~ /^[A-Za-z]:\//) {
      d = substr(path, 1, 1)
      add(tolower(d) substr(path, 2)); add(toupper(d) substr(path, 2))
      pb = "/" tolower(d) substr(path, 3)
      add(pb)
    }
    if (homen != "" && homen != "/" && index(path, homen "/") == 1) add("~" substr(path, length(homen) + 1))
    else if (home != "" && home != "/" && index(pb, home "/") == 1) add("~" substr(pb, length(home) + 1))
    base = top; sub(/\/[^\/]*$/, "", base)
    if (base != "" && index(path, base "/") == 1) add(".." substr(path, length(base) + 1))
    if (index(path, top "/") == 1) {
      r = substr(path, length(top) + 2)
      add("./" r)
      if (index(r, "/")) add(r)
    }
  }
  path = ""; branch = ""
}
{ sub(/\r$/, "") }
/^worktree / { flush(); path = substr($0, 10); n++; next }
/^branch / { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
END { flush(); print "[" out "]" }'

# CC_JQ_AGENT_BRANCH (jq -R -n): on stdin, the candidates array above on its first line,
# then an agent's transcript lines (those with a tool call are enough). Prints, on two
# lines, the branch and the folder of the worktree that the agent's tool calls name in at
# least half of them, and no other worktree as often; nothing otherwise. Only calls that give a place count, and only that
# place is read: the input's command, file_path, path or notebook_path (not a description,
# a prompt or the text an edit writes). A call names a worktree when one of its spellings
# appears there (shell-escaped spaces read as spaces, backslashes as slashes), not
# preceded by a path character or a slash, and followed by nothing, a slash, a quote, a
# space or a shell separator: x-1013 is not named by x-1013-facultatif, nor by
# /other/x-1013. jq 1.6.
# shellcheck disable=SC2034 # read by agent-stop.sh
CC_JQ_AGENT_BRANCH='
def pc: (explode[0] // 0) as $c
  | ($c >= 48 and $c <= 57) or ($c >= 65 and $c <= 90) or ($c >= 97 and $c <= 122)
    or $c == 45 or $c == 46 or $c == 95;
def names($p):
  contains($p)
  and (split($p) as $parts
       | any(range(1; $parts | length);
             ($parts[. - 1][-1:]) as $x | ($parts[.][0:1]) as $y
             | ((($x | pc) or $x == "/") | not) and ($y | . == "" or ("/\"'"'"' \t\n;&|)>,:`}" | contains($y)))));
(input | fromjson) as $c
| [ inputs | fromjson? | objects | select(.type == "assistant")
    | .message.content | if type == "array" then .[] else empty end
    | objects | select(.type == "tool_use" and (.id | type) == "string")
    | [ .input | objects | (.command, .file_path, .path, .notebook_path) | strings | select(length > 0) ] as $places
    | select($places | length > 0)
    | ($places | join("\n") | split("\\ ") | join(" ") | split("\\") | join("/")) as $h
    | { id: .id, w: ([ $c[] | select(.p as $p | $h | names($p)) | .b ] | unique) } ]
| unique_by(.id) | length as $calls
| ([ .[].w[] ] | group_by(.) | map({ b: .[0], n: length }) | sort_by(-.n)) as $cnt
| if ($cnt | length) > 0 and $cnt[0].n * 2 >= $calls
     and (($cnt | length) == 1 or $cnt[1].n < $cnt[0].n)
  then "\($cnt[0].b)\n\([ $c[] | select(.b == $cnt[0].b) | .t ][0])" else empty end'
