#!/usr/bin/env bash
# persist-session.sh — Stop hook: persist session CO2 data to SQLite DB.
# Parses the session JSONL + subagent JSONLs directly (same logic as backfill):
# deduplicates assistant messages by (message.id, requestId) so replayed messages
# in resumed/compacted sessions are not double-counted, and stores the raw token
# breakdown (input, cache_write, cache_read, output) so cost/CO2 can be re-derived later
# via recompute.sh without the (30-day-purged) JSONL. Cache writes are split by TTL tier
# (cache_creation_1h_tokens is the 1-hour subset) because the two tiers are billed
# differently; see data/prices.json. output_context_sum is the per-session sum over
# assistant messages of output_tokens x (input + cache_write + cache_read): the size of
# the KV cache each generated token re-reads. No formula uses it yet; it is stored so a
# context-dependent decode term can be applied to history once one is calibrated
# (METHODOLOGY.md, "Cache read energy").
#
# Tokens are attributed to the model that produced each assistant message, main
# transcript and subagents merged, and stored per model in session_models; the
# sessions row carries the totals (its co2_grams and cost_usd are the sum over models)
# and the main transcript's dominant model. See cc_session_usage in portable-lib.sh.
# Intentionally no set -euo pipefail: this hook must exit 0 silently in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/portable-lib.sh
. "${SCRIPT_DIR}/portable-lib.sh"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
# CLAUDE_CONFIG_DIR and CLAUDE_CARBON_DB are set by the user, so on Windows they
# arrive in whatever spelling that user typed, native path included.
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"
DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}")"

METHODOLOGY_VERSION=2

# Exit silently if DB doesn't exist (plugin not set up yet)
[ -f "$DB_PATH" ] || exit 0

# Migrate schema if needed (idempotent; a single probe once migrated)
cc_ensure_schema "$DB_PATH"

# Read stdin
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

# Extract fields from Stop hook JSON
# Stop hook provides: session_id, transcript_path, cwd
# It does NOT provide: model.id, context_window, cost
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0

# Claude Code is a native binary: on Windows both of these arrive as
# "C:\\Users\\me\\...", which bash cannot open. cc_path converts them.
TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
TRANSCRIPT_PATH="$(cc_path "$TRANSCRIPT_PATH")"
CURRENT_DIR="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
CURRENT_DIR="$(cc_path "$CURRENT_DIR")"

# Find the JSONL file: use transcript_path from hook, fallback to search by session_id
JSONL_FILE=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  JSONL_FILE="$TRANSCRIPT_PATH"
else
  for DIR in "${CONFIG_DIR}/projects"/*; do
    [ -d "$DIR" ] || continue
    CANDIDATE="${DIR}/${SESSION_ID}.jsonl"
    if [ -f "$CANDIDATE" ]; then
      JSONL_FILE="$CANDIDATE"
      break
    fi
  done
fi

# Exit if no JSONL found
[ -n "$JSONL_FILE" ] && [ -f "$JSONL_FILE" ] || exit 0

# Subagent transcripts (each message priced at its own model)
SUB_FILES=()
SUBAGENT_DIR="$(dirname "$JSONL_FILE")/${SESSION_ID}/subagents"
if [ -d "$SUBAGENT_DIR" ]; then
  for SUB_FILE in "$SUBAGENT_DIR"/*.jsonl; do
    [ -f "$SUB_FILE" ] && SUB_FILES+=("$SUB_FILE")
  done
fi

# One jq pass over main + subagents: tokens per model, the main transcript's dominant
# model and its last git branch (feeds /carbon-pr); then one awk for CO2 and cost.
USAGE="$(cc_session_usage "$FACTORS_FILE" "$PRICES_FILE" "$JSONL_FILE" ${SUB_FILES[@]+"${SUB_FILES[@]}"})" || exit 0
cc_parse_usage "$USAGE"
MODEL_RAW="$CC_U_MODEL"
GIT_BRANCH="$CC_U_BRANCH"

# Project name = last path segment of cwd
PROJECT="$(basename "$CURRENT_DIR" 2>/dev/null)" || PROJECT="unknown"

# Current timestamp
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || NOW=""

# Excluded flag (based on the session's dominant model)
EXCLUDED=0
if cc_is_excluded_model "$MODEL_RAW" "$(cc_exclude_regex "$FACTORS_FILE")"; then EXCLUDED=1; fi

# Sanitize strings for SQL
SQL_SESSION_ID="${SESSION_ID//$CC_SQ/$CC_SQ$CC_SQ}"
PROJECT="${PROJECT//$CC_SQ/$CC_SQ$CC_SQ}"
MODEL_RAW="${MODEL_RAW//$CC_SQ/$CC_SQ$CC_SQ}"
NOW="${NOW//$CC_SQ/$CC_SQ$CC_SQ}"
GIT_BRANCH="${GIT_BRANCH//$CC_SQ/$CC_SQ$CC_SQ}"

# Child rows and the session row in one transaction: the SessionEnd hook's detached run
# can overlap a Stop hook on the same session, and a reader must never see one without
# the other. The busy timeout makes the second writer wait instead of failing.
# (cost = theoretical API list price, source='live')
sqlite3 -cmd ".timeout 5000" "$DB_PATH" "BEGIN IMMEDIATE;
$(cc_session_models_sql "$SESSION_ID" "$USAGE")
INSERT OR REPLACE INTO sessions (session_id, project, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_1h_tokens, output_context_sum, cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded, git_branch) VALUES ('${SQL_SESSION_ID}', '${PROJECT}', '${MODEL_RAW}', ${CC_U_IN}, ${CC_U_OUT}, ${CC_U_CR}, ${CC_U_CW}, ${CC_U_CW1H}, ${CC_U_OCTX}, ${CC_U_COST}, ${CC_U_CO2}, COALESCE((SELECT started_at FROM sessions WHERE session_id='${SQL_SESSION_ID}'), '${NOW}'), '${NOW}', 'live', ${METHODOLOGY_VERSION}, ${EXCLUDED}, '${GIT_BRANCH}');
COMMIT;" >/dev/null 2>&1 || true

exit 0
