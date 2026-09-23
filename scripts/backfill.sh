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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}")"

# Rows written by this version of the methodology (raw-token columns populated).
METHODOLOGY_VERSION=2

# Ensure schema exists and is migrated (idempotent; safe on fresh or pre-existing DBs).
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, project TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0, cost_usd REAL, co2_grams REAL, started_at TEXT, ended_at TEXT, source TEXT DEFAULT 'live', methodology_version INTEGER DEFAULT 1, excluded INTEGER DEFAULT 0, git_branch TEXT DEFAULT '', cache_creation_1h_tokens INTEGER DEFAULT 0, output_context_sum INTEGER DEFAULT 0); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
cc_ensure_schema "$DB_PATH"

# User-defined exclusion patterns (grep -E, case-insensitive), joined with |
EXCLUDE_MODELS="$(cc_exclude_regex "$FACTORS_FILE")"

ADDED=0
SKIPPED=0
REPAIRED=0
FILLED=0
REFRESHED=0
SPLIT=0
ERRORS=0

# A row is refreshed when its transcript was written more than this many seconds after
# the row's ended_at. The slack absorbs the transcript's asynchronous writes landing just
# after the Stop hook recorded the turn.
REFRESH_SLACK=60

# UUID regex pattern
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# session_usage <main.jsonl> <session_id>: cc_session_usage over the main transcript and
# its subagents (each message priced at its own model; see portable-lib.sh).
session_usage() {
  local main="$1" sid="$2" sub dir
  local subs=()
  dir="$(dirname "$main")/${sid}/subagents"
  if [ -d "$dir" ]; then
    for sub in "$dir"/*.jsonl; do
      [ -f "$sub" ] && subs+=("$sub")
    done
  fi
  cc_session_usage "$FACTORS_FILE" "$PRICES_FILE" "$main" ${subs[@]+"${subs[@]}"}
}

# parse_once: parse the current session (JSONL_FILE, SESSION_ID) the first time a repair
# pass needs it, then reuse the result. Exit 0 when the transcript yielded something.
parse_once() {
  if [ "$PARSED" = "0" ]; then
    PARSED=1
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
  EXISTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}';")"
  # Refresh check: a row whose transcript was written well after its ended_at is missing
  # the session's tail (a turn interrupted before the Stop hook, then a crash, a kill, or a
  # window closed without SessionEnd running). Such a row is re-aggregated below instead of
  # skipped. Keyed on the file's mtime, so an unchanged session costs a stat, not a parse.
  STALE=0
  if [ "$EXISTS" -gt 0 ]; then
    MTIME="$(cc_mtime "$JSONL_FILE")"
    STALE="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(methodology_version, 1) >= 2 AND ${MTIME} > COALESCE(CAST(strftime('%s', ended_at) AS INTEGER), 0) + ${REFRESH_SLACK};" 2>/dev/null || echo 0)"
  fi
  if [ "$EXISTS" -gt 0 ] && [ "$STALE" != "1" ]; then
    # Repair pass: rows captured before the git_branch column existed get their
    # branch backfilled while the transcript is still on disk (30-day window).
    BRANCH_MISSING="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(git_branch, '') = '';" 2>/dev/null || echo 0)"
    if [ "$BRANCH_MISSING" = "1" ]; then
      GIT_BRANCH="$(jq -rn '[inputs | .gitBranch? // empty | select(type == "string" and length > 0)] | last // ""' "$JSONL_FILE" 2>/dev/null)" || GIT_BRANCH=""
      if [ -n "$GIT_BRANCH" ]; then
        GIT_BRANCH="${GIT_BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"
        sqlite3 "$DB_PATH" "UPDATE sessions SET git_branch='${GIT_BRANCH}' WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
      fi
    fi

    # The transcript is parsed at most once per session below, and only when a pass needs it.
    USAGE=""
    PARSED=0

    # Split pass: a v2 row recorded before session_models existed gets its per-model
    # rows, if its transcript still yields the row's stored token totals. Token columns
    # are left as stored; co2_grams and cost_usd become the per-model sum; the 1-hour
    # cache-write subset and output_context_sum are refilled from the same parse, which
    # covers the two repair passes below.
    SPLIT_MISSING="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions s WHERE s.session_id='${SESSION_ID}' AND COALESCE(s.methodology_version, 1) >= 2 AND NOT EXISTS (SELECT 1 FROM session_models m WHERE m.session_id = s.session_id);" 2>/dev/null || echo 0)"
    if [ "$SPLIT_MISSING" = "1" ] && parse_once; then
      STORED="$(sqlite3 "$DB_PATH" "SELECT COALESCE(input_tokens, 0) || '|' || COALESCE(cache_creation_tokens, 0) || '|' || COALESCE(cache_read_tokens, 0) || '|' || COALESCE(output_tokens, 0) FROM sessions WHERE session_id='${SESSION_ID}';" 2>/dev/null || echo "")"
      case "$USAGE" in
        *"
R	"*)
          if [ "$STORED" = "${CC_U_IN}|${CC_U_CW}|${CC_U_CR}|${CC_U_OUT}" ]; then
            if sqlite3 -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
$(cc_session_models_sql "$SESSION_ID" "$USAGE")
UPDATE sessions SET cache_creation_1h_tokens = ${CC_U_CW1H}, output_context_sum = ${CC_U_OCTX}, co2_grams = ${CC_U_CO2}, cost_usd = ${CC_U_COST} WHERE session_id='${SESSION_ID}';
COMMIT;" >/dev/null 2>&1; then
              SPLIT=$((SPLIT + 1))
              SKIPPED=$((SKIPPED + 1))
              continue
            fi
          fi
          ;;
      esac
    fi

    # Repair pass: rows captured before the cache-write TTL split existed carry
    # cache_creation_1h_tokens = 0, which prices their whole cache write at the
    # 5-minute tier. Refill the raw column from the transcript while it is still
    # on disk; run `recompute.sh --with-cost` afterwards to re-derive cost_usd.
    # A genuinely 5-minute-tier session repairs to 0 and simply stays correct.
    TTL_MISSING="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(cache_creation_1h_tokens, 0) = 0 AND COALESCE(cache_creation_tokens, 0) > 0 AND COALESCE(methodology_version, 1) >= 2;" 2>/dev/null || echo 0)"
    if [ "$TTL_MISSING" = "1" ] && parse_once; then
      case "$CC_U_CW1H" in
        ''|*[!0-9]*) ;;
        0) ;;
        *) sqlite3 "$DB_PATH" "UPDATE sessions SET cache_creation_1h_tokens = MIN(${CC_U_CW1H}, COALESCE(cache_creation_tokens, 0)) WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
           REPAIRED=$((REPAIRED + 1)) ;;
      esac
    fi
    # Fill pass: rows captured before output_context_sum existed carry 0. Refill it
    # from the transcript (main + subagents) while it is still on disk. No formula
    # reads the column yet, so nothing needs re-deriving afterwards.
    OCTX_MISSING="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE session_id='${SESSION_ID}' AND COALESCE(output_context_sum, 0) = 0 AND COALESCE(output_tokens, 0) > 0 AND COALESCE(methodology_version, 1) >= 2;" 2>/dev/null || echo 0)"
    if [ "$OCTX_MISSING" = "1" ] && parse_once; then
      case "$CC_U_OCTX" in
        ''|*[!0-9]*) ;;
        0) ;;
        *) sqlite3 "$DB_PATH" "UPDATE sessions SET output_context_sum = ${CC_U_OCTX} WHERE session_id='${SESSION_ID}';" 2>/dev/null || true
           FILLED=$((FILLED + 1)) ;;
      esac
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Project name = basename of the session's cwd, matching persist-session.sh.
  # The transcript directory name encodes the full path with hyphens, so real
  # hyphens in project names cannot be recovered from it.
  PROJECT_CWD="$(jq -rn 'first(inputs | .cwd? // empty)' "$JSONL_FILE" 2>/dev/null || true)"
  if [ -n "$PROJECT_CWD" ]; then
    PROJECT="$(basename "$PROJECT_CWD")"
  else
    PROJECT="unknown"
  fi

  # One pass over main + subagents: tokens per model, CO2 and cost, the main transcript's
  # dominant model, its git branch at session end (last non-empty gitBranch, feeds
  # /carbon-pr), its first timestamp, and the last timestamp across all files.
  USAGE="$(session_usage "$JSONL_FILE" "$SESSION_ID")" || { ERRORS=$((ERRORS + 1)); continue; }
  cc_parse_usage "$USAGE"
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

  CHILD_SQL="$(cc_session_models_sql "$SESSION_ID" "$USAGE")"

  # Refresh a stale row. It keeps when it started and which path first recorded it, and
  # ends when its transcript was last written: that is also what the refresh check compares
  # against, so the same session is not parsed again on the next rescan.
  if [ "$EXISTS" -gt 0 ]; then
    LAST_TS="$(sqlite3 "$DB_PATH" "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', ${MTIME}, 'unixepoch');" 2>/dev/null)" || LAST_TS=""
    sqlite3 -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
${CHILD_SQL}
INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${CC_U_IN}, ${CC_U_OUT}, ${CC_U_CR}, ${CC_U_CW}, ${CC_U_CW1H}, ${CC_U_OCTX}, ${CC_U_COST}, ${CC_U_CO2}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SESSION_ID}'), '${FIRST_TS}'), '${LAST_TS}', COALESCE((SELECT source FROM sessions WHERE session_id='${SESSION_ID}'), 'backfill'), ${METHODOLOGY_VERSION}, ${EXCLUDED}, '${GIT_BRANCH}');
COMMIT;" >/dev/null 2>&1 || { ERRORS=$((ERRORS + 1)); continue; }
    REFRESHED=$((REFRESHED + 1))
    continue
  fi

  # Insert into DB
  sqlite3 -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
${CHILD_SQL}
INSERT OR IGNORE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch) VALUES ('${SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${CC_U_IN}, ${CC_U_OUT}, ${CC_U_CR}, ${CC_U_CW}, ${CC_U_CW1H}, ${CC_U_OCTX}, ${CC_U_COST}, ${CC_U_CO2}, '${FIRST_TS}', '${LAST_TS}', 'backfill', ${METHODOLOGY_VERSION}, ${EXCLUDED}, '${GIT_BRANCH}');
COMMIT;" >/dev/null 2>&1 || { ERRORS=$((ERRORS + 1)); continue; }

  ADDED=$((ADDED + 1))

done < <(find "${CONFIG_DIR}/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null)

echo "  Backfill complete: ${ADDED} sessions added, ${SKIPPED} skipped, ${ERRORS} errors."
if [ "$REFRESHED" -gt 0 ]; then
  echo "  Refreshed ${REFRESHED} session(s) whose transcript grew after they were last recorded."
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
