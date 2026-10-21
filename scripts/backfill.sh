#!/usr/bin/env bash
set -euo pipefail

# backfill.sh — Parse all historical Claude Code JSONL transcripts and insert into carbon.db.
# Includes subagent JSONL files in the calculation (each message priced at its own model).
# Deduplicates assistant messages by (message.id, requestId) so resumed/compacted sessions
# that replay prior messages within a file are not double-counted (matches ccusage).
# Stores raw token counts (input, cache_write, cache_read, output) per session so cost and
# CO2 can be re-derived later via recompute.sh without the (30-day-purged) JSONL. Cache
# writes are split by TTL tier (cache_creation_1h_tokens is the 1-hour subset), which is
# what the two billing rates apply to; see data/prices.json. output_context_sum is the sum
# over assistant messages of output_tokens x (input + cache_write + cache_read), the KV
# cache size each generated token re-reads; stored for a future context-dependent decode
# term, not used by any formula yet (METHODOLOGY.md, "Cache read energy").
#
# Tokens are also stored per model in session_models (see cc_session_usage in
# portable-lib.sh), written in the same transaction as the sessions row. An existing
# methodology-v2 row that has no child rows yet (recorded before the table existed) gets
# them from its transcript while that is still on disk, provided the transcript still
# yields the row's stored token totals: its token columns stay as they are, and its
# co2_grams and cost_usd become the sum over its models, which is what the Stop hook
# would store today. A row whose totals disagree with its transcript is left alone.
#
# A row is rewritten from its transcripts (refresh, workflow pass) only if it holds no
# more tokens than the new parse once the write lock is held: usage only grows, so a row
# with more was written meanwhile by a Stop hook that saw more of the session. The one
# exception is a legacy (v1) row, which over-counted: it is rebuilt with fewer tokens, as
# long as its transcripts are all still there (see legacy_complete). A frozen row is never
# rewritten, checked again under the write lock.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}")"
# The per-agent usage cache (see cc_session_usage), beside Claude Code's own data, never
# beside a database CLAUDE_CARBON_DB may have put in a synced folder
CC_USAGE_CACHE_DIR="${CONFIG_DIR}/claude-carbon/usage-cache"

# Rows written by this version of the methodology (raw-token columns populated).
METHODOLOGY_VERSION=2

# Ensure schema exists and is migrated (idempotent; safe on fresh or pre-existing DBs).
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0, agents_collected INTEGER DEFAULT 0, frozen INTEGER DEFAULT 0); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
cc_ensure_schema "$DB_PATH"

# User-defined exclusion patterns (grep -E, case-insensitive), joined with |
EXCLUDE_MODELS="$(cc_exclude_regex "$FACTORS_FILE")"

ADDED=0
SKIPPED=0
REPAIRED=0
FILLED=0
REFRESHED=0
WORKFLOWS=0
REBUILT=0
# The CO2 of the rebuilt legacy rows, as stored and as rebuilt: the gap is said once
REBUILT_FROM=0
REBUILT_TO=0

# legacy_complete <main transcript> <session id>: 0 when the session's transcripts still give
# at least what its legacy row stored. That row summed, over the main transcript and
# subagents/*.jsonl, every assistant line's input plus cache write, and its output, replayed
# lines included (no dedup). Less than that now means a file is gone, and a rebuild from
# what is left would lower the figure for good: the row then stays as it is.
legacy_complete() {
  local stored raw dir f
  local files=("$1")
  dir="$(dirname "$1")/$2/subagents"
  for f in "$dir"/*.jsonl; do [ -f "$f" ] && files+=("$f"); done
  stored="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COALESCE(input_tokens, 0) || ' ' || COALESCE(output_tokens, 0) FROM sessions WHERE session_id='$2';" 2>/dev/null)" || return 1
  raw="$(jq -Rrn '[inputs | fromjson? | select(.type == "assistant" and .message.usage != null) | .message.usage]
    | "\(map((.input_tokens // 0) + (.cache_creation_input_tokens // 0)) | add // 0) \(map(.output_tokens // 0) | add // 0)"' \
    "${files[@]}" 2>/dev/null)" || return 1
  stored="${stored%$'\r'}"; raw="${raw%$'\r'}"
  case "${stored}${raw}" in *[!0-9\ ]*|'') return 1 ;; esac
  [ "${raw% *}" -ge "${stored% *}" ] && [ "${raw#* }" -ge "${stored#* }" ]
}
SPLIT=0
ERRORS=0

# A row is refreshed when its transcript was written more than this many seconds after
# the row's ended_at. The slack absorbs the transcript's asynchronous writes landing just
# after the Stop hook recorded the turn.
REFRESH_SLACK=60
# 1.15.3 kept a single marker, .workflow-agents-counted, for its one-time workflow pass. A
# session opened before the update kept running the older Stop hook, which rewrote rows
# without their workflow agents after the marker was set. The pass now goes by each row's
# agents_collected (see cc_ensure_schema); the marker is no longer read.

# UUID regex pattern
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# session_usage <main.jsonl> <session_id>: cc_session_usage over the main transcript and
# its subagents (each message priced at its own model; see portable-lib.sh).
session_usage() {
  local main="$1" sid="$2"
  cc_collect_subagents "$(dirname "$main")/${sid}/subagents"
  cc_session_usage "$FACTORS_FILE" "$PRICES_FILE" "$main" ${CC_SUB_FILES[@]+"${CC_SUB_FILES[@]}"}
}

# TOKENS_SQL: what a row holds, for the comparisons with a parse (input + cache read + output)
TOKENS_SQL="COALESCE(input_tokens, 0) + COALESCE(cache_read_tokens, 0) + COALESCE(output_tokens, 0)"

# take_end: END_EPOCH, the last time the current session's transcripts (main and agents)
# were written, read once per session and always before they are parsed: content written
# after it is newer than the end a rewritten row takes, so the next rescan sees it.
take_end() {
  if [ -z "$END_EPOCH" ]; then
    cc_collect_subagents "$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
    END_EPOCH="$(cc_max_mtime "$JSONL_FILE" ${CC_SUB_FILES[@]+"${CC_SUB_FILES[@]}"})"
  fi
}

# parse_once: parse the current session (JSONL_FILE, SESSION_ID) the first time a repair
# pass needs it, then reuse the result. Exit 0 when the transcript yielded something.
parse_once() {
  if [ "$PARSED" = "0" ]; then
    PARSED=1
    take_end
    USAGE="$(session_usage "$JSONL_FILE" "$SESSION_ID" 2>/dev/null)" || USAGE=""
    cc_parse_usage "$USAGE"
  fi
  [ -n "$USAGE" ]
}

# Scan all JSONL files under $CONFIG_DIR/projects/, max 2 levels deep
# Exclude subagents/ and vercel-plugin/ directories (subagents are handled per session)
while IFS= read -r JSONL_FILE; do
  # Skip files in excluded directories
  if echo "$JSONL_FILE" | grep -qE '/(subagents|vercel-plugin)/'; then
    continue
  fi

  # Extract session_id from filename (basename without extension)
  FILENAME="$(basename "$JSONL_FILE" .jsonl)"

  # Must match UUID pattern
  if ! echo "$FILENAME" | grep -qiE "$UUID_PATTERN"; then
    continue
  fi

  SESSION_ID="$FILENAME"

  # Skip if already in DB (SESSION_ID is a validated UUID, safe for SQL)
  # A database busy past the timeout skips the session this time; nothing is stamped, so
  # the next rescan looks at it again. The row's end and token total are read here, before
  # any parse: a pass writes only if the row still has both when it writes (every Stop
  # hook sets the end to its own time), so a turn an older Stop hook records meanwhile is
  # never overwritten by a parse that did not see it.
  ROW_SNAP="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) || '|' || MAX(CASE WHEN ${CC_NOT_FROZEN} THEN 0 ELSE 1 END, 0) || '|' || COALESCE(MAX(methodology_version), 1) || '|' || COALESCE(MAX(RTRIM(ended_at, char(13))), '') || '|' || COALESCE(MAX(${TOKENS_SQL}), 0) FROM sessions WHERE session_id='${SESSION_ID}';" 2>/dev/null)" || { ERRORS=$((ERRORS + 1)); continue; }
  EXISTS="${ROW_SNAP%%|*}"
  ROW_REST="${ROW_SNAP#*|}"
  ROW_FROZEN="${ROW_REST%%|*}"; ROW_REST="${ROW_REST#*|}"
  ROW_VERSION="${ROW_REST%%|*}"; ROW_REST="${ROW_REST#*|}"
  ROW_END="${ROW_REST%|*}"
  ROW_TOKENS="${ROW_SNAP##*|}"
  case "$EXISTS$ROW_TOKENS$ROW_FROZEN$ROW_VERSION" in ''|*[!0-9]*) ERRORS=$((ERRORS + 1)); continue ;; esac
  # A frozen row is left exactly as it is
  if [ "$ROW_FROZEN" != "0" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  ROW_END="${ROW_END//$CC_SQ/$CC_SQ$CC_SQ}"
  # The end is read and compared without a trailing CR: earlier versions on Windows stored
  # the end of a session they added with one (jq's CRLF), which sqlite3 may print as ^M
  UNCHANGED="RTRIM(COALESCE(ended_at, ''), char(13)) = '${ROW_END}' AND (${TOKENS_SQL}) = ${ROW_TOKENS} AND ${CC_NOT_FROZEN}"
  END_EPOCH=""
  # Refresh check: a row whose transcript was written well after its ended_at is missing
  # the session's tail (a turn interrupted before the Stop hook, then a crash, a kill, or a
  # window closed without SessionEnd running). Such a row is re-aggregated below instead of
  # skipped. Keyed on the file's mtime, so an unchanged session costs a stat, not a parse.
  STALE=0
  # A legacy row (methodology_version 1, before 2026-06-05) counted replayed messages more
  # than once, about 3 times too many tokens, and no cache reads. While its transcript is
  # here it is rebuilt from it, as a fresh v2 row, even though that holds fewer tokens.
  # Only when the transcripts are all still there: one purged before the others would
  # lower the figure for good.
  LEGACY=0
  if [ "$EXISTS" -gt 0 ] && [ "$ROW_VERSION" -lt 2 ] && legacy_complete "$JSONL_FILE" "$SESSION_ID"; then
    LEGACY=1
    STALE=1
    LEGACY_G="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COALESCE(co2_grams, 0) FROM sessions WHERE session_id='${SESSION_ID}';" 2>/dev/null)" || LEGACY_G=0
  fi
  if [ "$EXISTS" -gt 0 ] && [ "$LEGACY" = "0" ]; then
    MTIME="$(cc_mtime "$JSONL_FILE")"
    STALE="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(methodology_version, 1) >= 2 AND ${MTIME} > COALESCE(CAST(strftime('%s', ended_at) AS INTEGER), 0) + ${REFRESH_SLACK};" 2>/dev/null || echo 0)"
  fi
  # Workflow pass: a v2 row that may lack its workflow agents (their transcripts sit in
  # <session>/subagents/workflows/) gets re-aggregated with them, while they are still on
  # disk, when they hold tokens the row lacks. A row whose writer did not read them all
  # (agents_collected below CC_AGENTS_COLLECTED: recorded up to 1.15.3, or rewritten since
  # by the older Stop hook of a session opened before an update) is parsed, then
  # re-aggregated or, when nothing is missing, stamped. A stamped row is looked at again
  # only when an agent transcript was written after it ended (an agent that finished after
  # the last Stop). A legacy (v1) row is rebuilt whole instead (above), a frozen row skipped.
  USAGE=""
  PARSED=0
  WF_TRIGGER=0
  if [ "$EXISTS" -gt 0 ] && [ "$STALE" != "1" ]; then
    WF_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents/workflows"
    if [ -d "$WF_DIR" ]; then
      WF_ROWINFO="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COALESCE(agents_collected, 0) || '|' || COALESCE(CAST(strftime('%s', ended_at) AS INTEGER), 0) || '|' || (${TOKENS_SQL}) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(methodology_version, 1) >= 2;" 2>/dev/null || echo "")"
      if [ -n "$WF_ROWINFO" ]; then
        WF_SEEN="${WF_ROWINFO%%|*}"
        WF_REST="${WF_ROWINFO#*|}"
        WF_END="${WF_REST%%|*}"
        WF_ROW="${WF_REST#*|}"
        # One stat for all the agent transcripts, read only when the session has any
        WF_LOOK=0
        WF_ANY=0
        for WF_FILE in "$WF_DIR"/*/agent-*.jsonl; do
          [ -f "$WF_FILE" ] && { WF_ANY=1; break; }
        done
        if [ "$WF_ANY" = "1" ]; then
          if [ "$WF_SEEN" -lt "$CC_AGENTS_COLLECTED" ] 2>/dev/null \
            || [ "$(cc_max_mtime "$WF_DIR"/*/agent-*.jsonl)" -gt "$((WF_END + REFRESH_SLACK))" ]; then
            WF_LOOK=1
          fi
        fi
        if [ "$WF_LOOK" = "1" ] && parse_once; then
          if [ "$((CC_U_IN + CC_U_CR + CC_U_OUT))" -gt "$WF_ROW" ] 2>/dev/null; then
            STALE=1
            WF_TRIGGER=1
          else
            # Nothing missing. The row takes the end of what was parsed, so an agent's last
            # write without usage does not bring it back at every rescan, and is stamped
            # unless it still lacks a column the repair passes below fill (they skip stamped
            # rows); both only if the row did not change since it was read.
            sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET ended_at = MAX(COALESCE(ended_at, ''), strftime('%Y-%m-%dT%H:%M:%SZ', ${END_EPOCH:-0}, 'unixepoch')), agents_collected = CASE WHEN NOT (COALESCE(cache_creation_1h_tokens, 0) = 0 AND COALESCE(cache_creation_tokens, 0) > 0) AND NOT (COALESCE(output_context_sum, 0) = 0 AND COALESCE(output_tokens, 0) > 0) AND EXISTS (SELECT 1 FROM session_models m WHERE m.session_id = sessions.session_id) THEN ${CC_AGENTS_COLLECTED} ELSE agents_collected END WHERE session_id='${SESSION_ID}' AND ${UNCHANGED};" >/dev/null 2>&1 || true
          fi
        fi
      fi
    fi
  fi
  if [ "$EXISTS" -gt 0 ] && [ "$STALE" != "1" ]; then
    # Repair pass: rows captured before the git_branch column existed get their
    # branch backfilled while the transcript is still on disk (30-day window).
    BRANCH_MISSING="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(git_branch, '') = '';" 2>/dev/null || echo 0)"
    if [ "$BRANCH_MISSING" = "1" ]; then
      GIT_BRANCH="$(jq -rn '[inputs | .gitBranch? // empty | select(type == "string" and length > 0)] | last // ""' "$JSONL_FILE" 2>/dev/null)" || GIT_BRANCH=""
      if [ -n "$GIT_BRANCH" ]; then
        GIT_BRANCH="${GIT_BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"
        sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET git_branch='${GIT_BRANCH}' WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
      fi
    fi

    # The transcript is parsed at most once per session below, and only when a pass needs
    # it (the workflow pass above may already have parsed it).

    # Split pass: a v2 row recorded before session_models existed gets its per-model
    # rows, if its transcript still yields the row's stored token totals. Token columns
    # are left as stored; co2_grams and cost_usd become the per-model sum; the 1-hour
    # cache-write subset and output_context_sum are refilled from the same parse, which
    # covers the two repair passes below.
    # A stamped row was written from all its transcripts: its child rows are complete,
    # none for a session without usage. Child rows and the row change only if the row
    # still holds what was compared with the parse, and has not been rewritten since it
    # was read (a Stop hook in between would leave its tokens over these child rows).
    SPLIT_MISSING="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) FROM sessions s WHERE s.session_id='${SESSION_ID}' AND COALESCE(s.methodology_version, 1) >= 2 AND COALESCE(s.agents_collected, 0) < ${CC_AGENTS_COLLECTED} AND NOT EXISTS (SELECT 1 FROM session_models m WHERE m.session_id = s.session_id);" 2>/dev/null || echo 0)"
    if [ "$SPLIT_MISSING" = "1" ] && parse_once; then
      STORED="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COALESCE(input_tokens, 0) || '|' || COALESCE(cache_creation_tokens, 0) || '|' || COALESCE(cache_read_tokens, 0) || '|' || COALESCE(output_tokens, 0) FROM sessions WHERE session_id='${SESSION_ID}';" 2>/dev/null || echo "")"
      if [ "$STORED" = "${CC_U_IN}|${CC_U_CW}|${CC_U_CR}|${CC_U_OUT}" ]; then
        SAME="COALESCE(input_tokens, 0) = ${CC_U_IN} AND COALESCE(cache_creation_tokens, 0) = ${CC_U_CW} AND COALESCE(cache_read_tokens, 0) = ${CC_U_CR} AND COALESCE(output_tokens, 0) = ${CC_U_OUT} AND RTRIM(COALESCE(ended_at, ''), char(13)) = '${ROW_END}' AND ${CC_NOT_FROZEN}"
        case "$USAGE" in
          *"
R	"*)
            SPLIT_DONE="$(cc_sql -bail -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
$(cc_session_models_sql "$SESSION_ID" "$USAGE" "(SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND ${SAME}) = 1")
UPDATE sessions SET cache_creation_1h_tokens = ${CC_U_CW1H}, output_context_sum = ${CC_U_OCTX}, co2_grams = ${CC_U_CO2}, cost_usd = ${CC_U_COST}, agents_collected = ${CC_AGENTS_COLLECTED} WHERE session_id='${SESSION_ID}' AND ${SAME};
SELECT changes();
COMMIT;" 2>/dev/null || echo "")"
            if [ "$SPLIT_DONE" = "1" ]; then
              SPLIT=$((SPLIT + 1))
              SKIPPED=$((SKIPPED + 1))
              continue
            fi
            ;;
          *)
            # No usage in the transcripts, none in the row (0 tokens): nothing to split,
            # stamped so the session is not parsed again at every rescan
            [ "$STORED" = "0|0|0|0" ] && sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET agents_collected = ${CC_AGENTS_COLLECTED} WHERE session_id='${SESSION_ID}' AND ${SAME};" >/dev/null 2>&1
            ;;
        esac
      fi
    fi

    # Repair pass: rows captured before the cache-write TTL split existed carry
    # cache_creation_1h_tokens = 0, which prices their whole cache write at the
    # 5-minute tier. Refill the raw column from the transcript while it is still
    # on disk; run `recompute.sh --with-cost` afterwards to re-derive cost_usd.
    # A genuinely 5-minute-tier session repairs to 0 and simply stays correct. A stamped
    # row (agents_collected) was written from a full parse, or checked against one: its
    # 0 is that genuine 0, and it is not parsed again for it at every rescan.
    TTL_MISSING="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(cache_creation_1h_tokens, 0) = 0 AND COALESCE(cache_creation_tokens, 0) > 0 AND COALESCE(methodology_version, 1) >= 2 AND COALESCE(agents_collected, 0) < ${CC_AGENTS_COLLECTED};" 2>/dev/null || echo 0)"
    if [ "$TTL_MISSING" = "1" ] && parse_once; then
      case "$CC_U_CW1H" in
        ''|*[!0-9]*) ;;
        0) ;;
        *) sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET cache_creation_1h_tokens = MIN(${CC_U_CW1H}, COALESCE(cache_creation_tokens, 0)) WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
           REPAIRED=$((REPAIRED + 1)) ;;
      esac
    fi
    # Fill pass: rows captured before output_context_sum existed carry 0. Refill it
    # from the transcript (main + subagents) while it is still on disk. No formula
    # reads the column yet, so nothing needs re-deriving afterwards.
    OCTX_MISSING="$(cc_sql -cmd ".timeout 5000" "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(output_context_sum, 0) = 0 AND COALESCE(output_tokens, 0) > 0 AND COALESCE(methodology_version, 1) >= 2 AND COALESCE(agents_collected, 0) < ${CC_AGENTS_COLLECTED};" 2>/dev/null || echo 0)"
    if [ "$OCTX_MISSING" = "1" ] && parse_once; then
      case "$CC_U_OCTX" in
        ''|*[!0-9]*) ;;
        0) ;;
        *) sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET output_context_sum = ${CC_U_OCTX} WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
           FILLED=$((FILLED + 1)) ;;
      esac
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Project name = basename of the session's last cwd, matching persist-session.sh,
  # whose Stop hook sees the cwd of the latest turn: a session opened in a parent folder
  # that moves into a sub-project is named after the sub-project on both paths.
  # Read line by line (-R, fromjson?) so a line cut by a crash or a concurrent write
  # does not lose the cwd of the lines before it. The transcript directory name encodes
  # the full path with hyphens, so real hyphens in project names cannot be recovered from it.
  PROJECT_CWD="$(jq -Rrn 'reduce (inputs | fromjson? | .cwd? | select(type == "string" and length > 0)) as $c (""; $c)' "$JSONL_FILE" 2>/dev/null || true)"
  PROJECT_CWD="$(cc_path "$PROJECT_CWD")"
  if [ -n "$PROJECT_CWD" ]; then
    PROJECT="$(basename "$PROJECT_CWD")"
  else
    PROJECT="unknown"
  fi

  # One pass over main + subagents: tokens per model, CO2 and cost, the main transcript's
  # dominant model, its git branch at session end (last non-empty gitBranch, feeds
  # /carbon-pr), its first timestamp, and the last timestamp across all files.
  # Already parsed by the workflow pass: its result stands
  if [ "$PARSED" != "1" ] || [ -z "$USAGE" ]; then
    [ "$EXISTS" -gt 0 ] && take_end
    USAGE="$(session_usage "$JSONL_FILE" "$SESSION_ID")" || { ERRORS=$((ERRORS + 1)); continue; }
  fi
  cc_parse_usage "$USAGE"
  NEW_TOKENS="$((CC_U_IN + CC_U_CR + CC_U_OUT))"
  FIRST_TS="$CC_U_FIRST_TS"
  LAST_TS="$CC_U_LAST_TS"
  GIT_BRANCH="$CC_U_BRANCH"

  # Skip empty sessions
  if [ "$CC_U_IN" = "0" ] && [ "$CC_U_OUT" = "0" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Main model for display
  MODEL_RAW="$CC_U_MODEL"

  # Excluded flag (based on the session's dominant model)
  EXCLUDED=0
  if cc_is_excluded_model "$MODEL_RAW" "$EXCLUDE_MODELS"; then EXCLUDED=1; fi

  # Sanitize strings for SQL (escape single quotes)
  PROJECT="${PROJECT//$CC_SQ/$CC_SQ$CC_SQ}"
  MODEL_RAW="${MODEL_RAW//$CC_SQ/$CC_SQ$CC_SQ}"
  FIRST_TS="${FIRST_TS//$CC_SQ/$CC_SQ$CC_SQ}"
  LAST_TS="${LAST_TS//$CC_SQ/$CC_SQ$CC_SQ}"
  GIT_BRANCH="${GIT_BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"

  # Refresh a stale row. It keeps when it started and which path first recorded it, and
  # ends when its transcripts were last written (the main one or any agent's, read before
  # the parse): that is also what the refresh and workflow checks compare against, so the
  # same session is not parsed again on the next rescan. Nothing is written if the row
  # changed since it was read (UNCHANGED): a Stop hook recorded it meanwhile, and an older
  # one left it unstamped for the next rescan. A row holding more tokens than this parse
  # (a Stop hook saw more of the session) is kept, and only takes the new end, so a
  # transcript that now yields less is not parsed at every rescan; a legacy row, which
  # over-counted, is the exception. A statement that fails
  # (a lock held past the timeout, for one) stops sqlite3, which exits with the transaction
  # open, so nothing is written; -bail keeps that true should the SQL ever come through
  # stdin.
  if [ "$EXISTS" -gt 0 ]; then
    take_end
    # Without a modification time (stat unusable), the last timestamp in the transcripts
    if [ "$END_EPOCH" -gt 0 ] 2>/dev/null; then
      LAST_TS="$(cc_sql :memory: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', ${END_EPOCH}, 'unixepoch');" 2>/dev/null)" || LAST_TS="$CC_U_LAST_TS"
    else
      LAST_TS="$CC_U_LAST_TS"
    fi
    if [ "$LEGACY" = "1" ] || [ "$ROW_TOKENS" -le "$NEW_TOKENS" ]; then
      KEEP="(SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND ${UNCHANGED}) = 1"
      WROTE="$(cc_sql -bail -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
$(cc_session_models_sql "$SESSION_ID" "$USAGE" "$KEEP")
INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch, agents_collected) SELECT '${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${CC_U_IN}, ${CC_U_OUT}, ${CC_U_CR}, ${CC_U_CW}, ${CC_U_CW1H}, ${CC_U_OCTX}, ${CC_U_COST}, ${CC_U_CO2}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SESSION_ID}'), '${FIRST_TS}'), '${LAST_TS}', COALESCE((SELECT source FROM sessions WHERE session_id='${SESSION_ID}'), 'backfill'), ${METHODOLOGY_VERSION}, ${EXCLUDED}, '${GIT_BRANCH}', ${CC_AGENTS_COLLECTED} WHERE ${KEEP};
SELECT changes();
COMMIT;" 2>/dev/null)" || { ERRORS=$((ERRORS + 1)); continue; }
    else
      sqlite3 -cmd ".timeout 5000" "$DB_PATH" "UPDATE sessions SET ended_at = MAX(COALESCE(ended_at, ''), '${LAST_TS}') WHERE session_id='${SESSION_ID}' AND ${UNCHANGED};" >/dev/null 2>&1 || { ERRORS=$((ERRORS + 1)); continue; }
      WROTE=0
    fi
    # Counted once written, under the legacy rebuild or the workflow pass when either was
    # the cause
    if [ "$WROTE" = "1" ]; then
      if [ "$LEGACY" = "1" ]; then
        REBUILT=$((REBUILT + 1))
        REBUILT_FROM="$(LC_ALL=C awk -v a="$REBUILT_FROM" -v b="${LEGACY_G%$'\r'}" 'BEGIN { printf "%.3f", a + b }')"
        REBUILT_TO="$(LC_ALL=C awk -v a="$REBUILT_TO" -v b="$CC_U_CO2" 'BEGIN { printf "%.3f", a + b }')"
      elif [ "$WF_TRIGGER" = "1" ]; then WORKFLOWS=$((WORKFLOWS + 1))
      else REFRESHED=$((REFRESHED + 1)); fi
    fi
    continue
  fi

  # Insert into DB. Its child rows only if no row appeared meanwhile (a Stop hook), which
  # INSERT OR IGNORE then keeps whole.
  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
$(cc_session_models_sql "$SESSION_ID" "$USAGE" "NOT EXISTS (SELECT 1 FROM sessions WHERE session_id='${SESSION_ID}')")
INSERT OR IGNORE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch, agents_collected) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${CC_U_IN}, ${CC_U_OUT}, ${CC_U_CR}, ${CC_U_CW}, ${CC_U_CW1H}, ${CC_U_OCTX}, ${CC_U_COST}, ${CC_U_CO2}, '${FIRST_TS}', '${LAST_TS}', 'backfill', ${METHODOLOGY_VERSION}, ${EXCLUDED}, '${GIT_BRANCH}', ${CC_AGENTS_COLLECTED});
COMMIT;" >/dev/null 2>&1 || { ERRORS=$((ERRORS + 1)); continue; }

  ADDED=$((ADDED + 1))

done < <(find "${CONFIG_DIR}/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null)

# The usage cache: a session's file unused for 45 days (its transcripts are gone by then),
# and the temporary files an interrupted write left
if [ -d "$CC_USAGE_CACHE_DIR" ]; then
  find "$CC_USAGE_CACHE_DIR" -maxdepth 1 -type f \( -name '*.jsonl' -mtime +45 -o -name '*.tmp.*' -mmin +60 \) \
    -exec rm -f {} + 2>/dev/null || true
fi
echo "  Backfill complete: ${ADDED} sessions added, ${SKIPPED} skipped, ${ERRORS} errors."
if [ "$REFRESHED" -gt 0 ]; then
  echo "  Refreshed ${REFRESHED} session(s) whose transcript grew after they were last recorded."
fi
# Said only when the figure moved: the total drops, and /carbon-update shows this line
if [ "$REBUILT" -gt 0 ]; then
  # In kgCO2 from a kilogram on, one decimal, as the status line writes it
  co2_text() { printf '%sCO₂' "$(LC_ALL=C awk -v g="$1" 'BEGIN { if (g >= 1000) printf "%.1f kg", g / 1000; else printf "%.1f g", g }')"; }
  REBUILT_FROM="$(co2_text "$REBUILT_FROM")"
  REBUILT_TO="$(co2_text "$REBUILT_TO")"
  if [ "$REBUILT_FROM" != "$REBUILT_TO" ]; then
    echo "  Rebuilt ${REBUILT} session(s) recorded with the method used before June 2026, from their transcripts: ${REBUILT_FROM} → ${REBUILT_TO}. That method counted replayed messages more than once."
  fi
fi
if [ "$WORKFLOWS" -gt 0 ]; then
  echo "  Counted the workflow agents of ${WORKFLOWS} session(s) recorded without them."
fi
if [ "$SPLIT" -gt 0 ]; then
  echo "  Split ${SPLIT} existing session(s) by model from their transcripts; their CO2 and cost are now the sum over their models."
fi
if [ "$REPAIRED" -gt 0 ]; then
  echo "  Repaired the cache-write TTL split on ${REPAIRED} existing row(s); run 'scripts/recompute.sh --with-cost' to re-price them."
fi
if [ "$FILLED" -gt 0 ]; then
  echo "  Filled the decode-context sum (output_context_sum) on ${FILLED} existing row(s); no recompute needed."
fi
