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
# Picked by platform, not by trial: GNU stat (Linux, Git Bash) reads `-f %m` as
# "file-system status of the files %m and <file>", prints a multi-line block for
# the real file and only then fails, so a `stat -f … || stat -c …` chain returned
# that block with the epoch appended, and every caller doing arithmetic on it died.
# Off macOS, `-f %m` stays as a fallback for the other BSDs, after `-c` has failed
# without printing anything.
cc_mtime() {
  local m
  if [ "$CC_OS" = "darwin" ]; then
    m="$(stat -f %m "$1" 2>/dev/null)"
  else
    m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)"
  fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
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
      # The Downloads known folder can be redirected (OneDrive does it), so ask
      # the registry rather than assume %USERPROFILE%\Downloads. The value is a
      # REG_EXPAND_SZ and comes back with its %VARS% unexpanded.
      # Output: "    {374DE290-...}    REG_EXPAND_SZ    %USERPROFILE%\Downloads"
      d="$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' \
             //v '{374DE290-123F-4565-9164-39C4925E467B}' 2>/dev/null \
           | LC_ALL=C awk '/374DE290/ { sub(/^[ \t]*\{[^}]*\}[ \t]+REG_[A-Z_]+[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print }' \
           || true)"
      local name
      while [[ "$d" =~ %([A-Za-z_][A-Za-z0-9_]*)% ]]; do
        name="${BASH_REMATCH[1]}"
        d="${d//%${name}%/${!name:-}}"
      done
      d="$(cc_path "$d")"
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
# the columns added to `sessions` over time, and the `session_models` table. The
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
CC_SESSION_MODELS_DDL="CREATE TABLE IF NOT EXISTS session_models (session_id TEXT NOT NULL, model TEXT NOT NULL, input_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cache_creation_1h_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0, co2_grams REAL DEFAULT 0, PRIMARY KEY (session_id, model));"
cc_ensure_schema() {
  local db="$1" probe col
  probe="$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT (SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('cache_read_tokens','cache_creation_tokens','methodology_version','excluded','git_branch','cache_creation_1h_tokens','output_context_sum')) || '|' || (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_models');" 2>/dev/null)" || probe=""
  [ "$probe" = "7|1" ] && return 0
  for col in "cache_read_tokens INTEGER DEFAULT 0" "cache_creation_tokens INTEGER DEFAULT 0" \
             "methodology_version INTEGER DEFAULT 1" "excluded INTEGER DEFAULT 0" \
             "git_branch TEXT DEFAULT ''" "cache_creation_1h_tokens INTEGER DEFAULT 0" \
             "output_context_sum INTEGER DEFAULT 0"; do
    sqlite3 -cmd ".timeout 5000" "$db" "ALTER TABLE sessions ADD COLUMN ${col};" >/dev/null 2>&1 || true
  done
  sqlite3 -cmd ".timeout 5000" "$db" "$CC_SESSION_MODELS_DDL" >/dev/null 2>&1 || true
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
  | ({fable: [156, 3304], opus: [78, 1652], sonnet: [39, 826], haiku: [20, 413]}[$fam]) as $fd
  | ({fable: [10, 50], opus: [5, 25], sonnet: [2, 10], haiku: [1, 5]}[$fam]) as $pd
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
cc_model_params() {
  jq -R -r --slurpfile f "$1" --slurpfile p "$2" \
    "${CC_JQ_MODEL_DEFS}"' . as $m | cc_params($f[0]; $p[0]) as $x | [$m, $x.family] + ($x | cc_param_cols) | @tsv'
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
# The per-message aggregation behind the Stop hook and backfill. One jq pass reads the
# main transcript and every subagent transcript, keeps the last occurrence of each
# assistant message per file (key message.id|requestId: streaming snapshots grow
# output_tokens, the last one carries the final value), and attributes each message to
# the model that produced it. A message without a model string is attributed to its
# file's dominant model, as the per-file pricing did before. If a file does not parse
# (a line cut by a concurrent write), the pass is re-run reading lines as raw text and
# skipping the ones that are not JSON.
#
# The jq program emits, all tab-separated:
#   X  <exclude regex>
#   S  <main dominant model> <git branch> <first ts (main)> <last ts (all files)>
#   M  <model> <input> <cache write> <cache write 1h> <cache read> <output> <output x context>
#      <fin> <fout> <crf> <pin> <pout> <cwm> <cwm1h> <crm>
CC_JQ_USAGE='
def lines: if $raw then (inputs | fromjson? // empty) else inputs end;
def n: if type == "number" then . else 0 end;
def dom: map(.model) | map(select(length > 0))
         | if length == 0 then "claude-sonnet" else group_by(.) | sort_by(-length) | first | first end;
[ lines | objects | input_filename as $fn
  | if .type == "assistant" and (.message | type) == "object" and .message.usage != null then
      { fn: $fn, id: .message.id, rid: .requestId,
        model: (.message.model | if type == "string" then . else "" end),
        ts: (.timestamp | if type == "string" then . else "" end),
        b: (.gitBranch | if type == "string" then . else "" end),
        it: (.message.usage.input_tokens | n),
        cw: (.message.usage.cache_creation_input_tokens | n),
        cw1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens? | n),
        cr: (.message.usage.cache_read_input_tokens | n),
        out: (.message.usage.output_tokens | n) }
    elif $fn == $main and (.gitBranch | type) == "string" and (.gitBranch | length) > 0 then
      { fn: $fn, branch_only: true, b: .gitBranch }
    else empty end ] as $recs
| ([$recs[] | select(.fn == $main and (.b | length) > 0) | .b] | last // "") as $branch
| [$recs[] | select(.branch_only != true)] as $all
| ( ($all | map(select(.id != null and .rid != null))
          | reduce .[] as $m ({}; .[$m.fn + "\u0001" + ($m.id | tostring) + "|" + ($m.rid | tostring)] = $m)
          | [.[]])
    + ($all | map(select(.id == null or .rid == null))) ) as $d
| ($d | map(select(.fn == $main)) | dom) as $main_model
| ($d | group_by(.fn) | map(dom as $dm | map(if .model == "" then .model = $dm else . end)) | add // []) as $d2
| (["X", ($f[0].exclude_models // [] | join("|"))] | @tsv),
  (["S", $main_model, $branch,
    ($d | map(select(.fn == $main) | .ts) | map(select(length > 0)) | sort | first // ""),
    ($d | map(.ts) | map(select(length > 0)) | sort | last // "")] | @tsv),
  ( $d2 | group_by(.model)[]
    | { model: .[0].model,
        it: (map(.it) | add), cw: (map(.cw) | add), cw1h: (map(.cw1h) | add),
        cr: (map(.cr) | add), out: (map(.out) | add),
        octx: (map(.out * (.it + .cw + .cr)) | add) }
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
# transcripts cannot be read at all.
cc_session_usage() {
  local factors="$1" prices="$2" main="$3" raw_out line tag model rest exre="" rows="" s_line=""
  shift 2
  raw_out="$(jq -n -r --slurpfile f "$factors" --slurpfile p "$prices" --arg main "$main" \
               --argjson raw false "${CC_JQ_MODEL_DEFS}${CC_JQ_USAGE}" "$@" 2>/dev/null)" \
    || raw_out="$(jq -n -R -r --slurpfile f "$factors" --slurpfile p "$prices" --arg main "$main" \
               --argjson raw true "${CC_JQ_MODEL_DEFS}${CC_JQ_USAGE}" "$@" 2>/dev/null)" \
    || return 1
  [ -n "$raw_out" ] || return 1
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

# CC_SQ: a single quote, for doubling quotes in SQL literals: X="${X//$CC_SQ/$CC_SQ$CC_SQ}".
# The spelling "${X//\'/\'\'}" inside double quotes keeps the backslashes on bash 3.2
# (the macOS /bin/bash), which turned every apostrophe into \'\' and broke the statement.
CC_SQ="'"

# cc_sql_quote <string>: the string as a single-quoted SQL literal.
cc_sql_quote() {
  local s="${1//$CC_SQ/$CC_SQ$CC_SQ}"
  printf "'%s'" "$s"
}

# cc_session_models_sql <session_id> <usage output>: the statements that replace a
# session's child rows: DELETE, then one INSERT per R line. The caller wraps them, and
# its own `sessions` write, in one transaction.
cc_session_models_sql() {
  local sid line tag model it cw cw1h cr out co2 cost
  sid="$(cc_sql_quote "$1")"
  printf 'DELETE FROM session_models WHERE session_id=%s;\n' "$sid"
  while IFS="	" read -r tag model it cw cw1h cr out co2 cost; do
    [ "$tag" = "R" ] || continue
    case "${it}${cw}${cw1h}${cr}${out}" in ''|*[!0-9]*) continue ;; esac
    case "$co2$cost" in ''|*[!0-9.]*) continue ;; esac
    printf 'INSERT INTO session_models (session_id, model, input_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, output_tokens, co2_grams, cost_usd) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s);\n' \
      "$sid" "$(cc_sql_quote "$model")" "$it" "$cw" "$cw1h" "$cr" "$out" "$co2" "$cost"
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
