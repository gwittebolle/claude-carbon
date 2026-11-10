#!/usr/bin/env bash
# run-quota-tests.sh: the subscription quota at the end of the status line. Assert that:
#   1. the 5-hour window shows when Claude Code passes it, even beside the weekly one;
#   2. without a 5-hour window (a verified Ultra account has none) the weekly one shows,
#      "Use 41% 7d", its reset as a weekday while more than a day away, as a time after;
#   3. rate_limits on stdin without any window show nothing and never call the API;
#   4. a window whose reset has passed is over, from stdin or from an old API cache;
#   5. with no rate_limits on stdin the API is asked at most once a minute, answered or
#      refused (429), and a window it reports without a reset time is left out;
#   6. 🔥 follows the burn rate over the window shown, with a day of grace for a week.
#
# curl is a shim that answers from a fixture and counts its calls: no network, and the
# token is a dummy one passed through CLAUDE_CODE_OAUTH_TOKEN, so the keychain is never
# read. Throwaway HOME and CLAUDE_CONFIG_DIR; the real ~/.claude is never read or written.
# bash 3.2 compatible. Dependencies: jq.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STATUSLINE="${REPO_DIR}/scripts/statusline.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

# shellcheck source=scripts/portable-lib.sh
. "${REPO_DIR}/scripts/portable-lib.sh"
TMPROOT="$(mktemp -d "$(cc_tmpdir)/claude-carbon-quota-tests.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
    */claude-carbon-quota-tests.*) rm -rf "$TMPROOT" ;;
    *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PASSED=0
FAILED=0
check() {
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1)); echo "PASS $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"
  fi
}

CFG="${TMPROOT}/cfg"
CACHE="${CFG}/claude-carbon/oauth-usage.json"
ATTEMPT="${CFG}/claude-carbon/oauth-usage.attempt"
mkdir -p "${CFG}/claude-carbon" "${TMPROOT}/home" "${TMPROOT}/shim"
FIXTURE="${TMPROOT}/api-answer.json"
CALLS="${TMPROOT}/curl-calls"
: > "$CALLS"
cat > "${TMPROOT}/shim/curl" <<EOF
#!/usr/bin/env bash
echo call >> "$CALLS"
cat "$FIXTURE"
EOF
# The macOS keychain answers nothing: a check that unsets the token reads no real one
printf '#!/usr/bin/env bash\nexit 44\n' > "${TMPROOT}/shim/security"
chmod +x "${TMPROOT}/shim/curl" "${TMPROOT}/shim/security"

NOW="$(date +%s)"
H=3600
D=86400
# local <epoch> <format>: the way the status line formats a reset
local_time() { LC_ALL=C date -r "$1" "$2" 2>/dev/null || LC_ALL=C date -d "@$1" "$2"; }
iso() { date -u -r "$1" "+%Y-%m-%dT%H:%M:%S.123456+00:00" 2>/dev/null || date -u -d "@$1" "+%Y-%m-%dT%H:%M:%S.123456+00:00"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
# rl <window> <used %> <reset epoch, or -> ...: a rate_limits object, built by jq (bash 3.2
# reads \" inside "$( )" differently from bash 5, so no hand-written JSON in a check)
rl() {
  local out='{}'
  while [ $# -ge 3 ]; do
    if [ "$3" = "-" ]; then
      out="$(printf '%s' "$out" | jq -c --arg w "$1" --argjson p "$2" '. + {($w): {used_percentage: $p}}')"
    else
      out="$(printf '%s' "$out" | jq -c --arg w "$1" --argjson p "$2" --argjson r "$3" '. + {($w): {used_percentage: $p, resets_at: $r}}')"
    fi
    shift 3
  done
  printf '%s' "$out"
}
# quota <rate_limits JSON, or "" for none> [token]: the quota segment the status line ends
# with, "" when it has none, "crash (rc N)" when the status line did not draw (a crash
# would otherwise pass for "no quota")
quota() {
  local input out rc
  if [ -n "$1" ]; then
    input="$(jq -cn --argjson r "$1" '{session_id: "q", model: {id: "claude-opus-5-5", display_name: "Opus 5.5"}, workspace: {current_dir: "/"}, rate_limits: $r}')"
  else
    input='{"session_id":"q","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"workspace":{"current_dir":"/"}}'
  fi
  out="$(printf '%s' "$input" \
    | PATH="${TMPROOT}/shim:$PATH" HOME="${TMPROOT}/home" CLAUDE_CONFIG_DIR="$CFG" \
      CLAUDE_CARBON_DB="${CFG}/claude-carbon/carbon.db" CLAUDE_CODE_OAUTH_TOKEN="${2-dummy}" \
      CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1 CLAUDE_CARBON_NO_CARD_NUDGE=1 \
      bash "$STATUSLINE" 2>/dev/null)"
  rc=$?
  case "$rc:$out" in
    0:*gCO*) ;;
    *) echo "crash (rc $rc)"; return ;;
  esac
  printf '%s\n' "$out" | awk -F' [|] ' '{ for (i = 1; i <= NF; i++) if ($i ~ /Use [0-9]/) print $i }'
}

# ---------------------------------------------------------------- 1. the 5-hour window
R5=$(( NOW + 2 * H ))
R7=$(( NOW + 3 * D ))
check "5-hour window, beside the weekly one" "Use 23% ↻$(local_time $R5 +%H:%M)" \
  "$(quota "$(rl five_hour 23.4 $R5 seven_day 41.2 $R7)")"
check "5-hour window without a reset" "Use 7%" "$(quota "$(rl five_hour 7 -)")"
check "capped at 100 (and burning)" "🔥 Use 100% ↻$(local_time $R5 +%H:%M)" \
  "$(quota "$(rl five_hour 104 $R5)")"

# ---------------------------------------------------------------- 2. the weekly window
check "no 5-hour window: the weekly one, its reset a weekday" "Use 41% 7d ↻$(local_time $R7 +%a)" \
  "$(quota "$(rl seven_day 41.2 $R7)")"
RSOON=$(( NOW + 5 * H ))
check "weekly reset within a day: its time" "Use 41% 7d ↻$(local_time $RSOON +%H:%M)" \
  "$(quota "$(rl seven_day 41.2 $RSOON)")"
check "weekly beside the gateway spend limit" "Use 41% 7d ↻$(local_time $R7 +%a)" \
  "$(quota "$(rl seven_day 41.2 $R7 spend_limit 90 $R7)")"

# ---------------------------------------------------------------- 3. no window at all
check "rate_limits without a window: nothing" "" "$(quota '{}')"
check "and the API is never called while rate_limits are on stdin" "0" "$(calls)"

# ---------------------------------------------------------------- 4. a reset that passed
PAST=$(( NOW - 60 ))
check "a 5-hour window already reset gives way to the weekly one" "Use 41% 7d ↻$(local_time $R7 +%a)" \
  "$(quota "$(rl five_hour 90 $PAST seven_day 41.2 $R7)")"

# ---------------------------------------------------------------- 5. the API fallback
rm -f "$CACHE" "$ATTEMPT"
: > "$CALLS"
# What the endpoint gave a verified Ultra account on 2026-10-31: a 5-hour window with no
# reset time, the weekly one with its own
R7API=$(( NOW + 2 * D + 3 * H ))
jq -n --arg r "$(iso $R7API)" '{five_hour: {utilization: 0.0, resets_at: null}, seven_day: {utilization: 52.0, resets_at: $r}}' > "$FIXTURE"
check "no rate_limits: the API, its 5-hour window without a reset left out" "Use 52% 7d ↻$(local_time $R7API +%a)" "$(quota "")"
check "one call" "1" "$(calls)"
check "a second render within the minute reads the cache" "Use 52% 7d ↻$(local_time $R7API +%a)|1" "$(quota "")|$(calls)"

# An old cache whose windows have all reset, and an endpoint that refuses (429)
jq -n --arg r "$(iso $PAST)" '{five_hour: {utilization: 0.0, resets_at: null}, seven_day: {utilization: 52.0, resets_at: $r}}' > "$CACHE"
touch -t 202001010000 "$CACHE"
rm -f "$ATTEMPT"
echo '{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}' > "$FIXTURE"
: > "$CALLS"
check "an old cache with every window reset, a refused call: nothing" "" "$(quota "")"
check "the refused answer does not replace the cache" "true" "$(jq '.seven_day.utilization == 52' "$CACHE")"
check "a refused call is not retried within the minute" "1" "$( quota "" >/dev/null; calls )"
touch -t 202001010000 "$ATTEMPT"
check "and is retried after it" "2" "$( quota "" >/dev/null; calls )"

# A cache the endpoint has refused to refresh for 20 minutes is not shown, even with its
# weekly window still open
jq -n --arg r "$(iso $R7API)" '{seven_day: {utilization: 20.0, resets_at: $r}}' > "$CACHE"
touch -t "$(date -r $(( NOW - 20 * 60 )) +%Y%m%d%H%M 2>/dev/null || date -d "@$(( NOW - 20 * 60 ))" +%Y%m%d%H%M)" "$CACHE"
rm -f "$ATTEMPT"
check "a cache over 15 minutes old, a refused call: nothing" "" "$(quota "")"

# No token in the environment, an empty keychain, a credentials file that does not parse:
# no call, and the status line still draws
rm -f "$ATTEMPT"
: > "$CALLS"
echo 'not json' > "${CFG}/.credentials.json"
check "unreadable credentials: no crash, no call" "|0" "$(quota "" "")|$(calls)"
rm -f "${CFG}/.credentials.json"

# ---------------------------------------------------------------- 6. 🔥
# 82% after 4 h of 5: past 100% by the end (exactly 100% would hang on the second the
# script reads its clock)
R1=$(( NOW + H ))
check "🔥 on a 5-hour window" "🔥 Use 82% ↻$(local_time $R1 +%H:%M)" \
  "$(quota "$(rl five_hour 82 $R1)")"
check "no 🔥 when the pace stays under the limit" "Use 50% ↻$(local_time $R1 +%H:%M)" \
  "$(quota "$(rl five_hour 50 $R1)")"
# 52% after 3.5 days of 7: past 100% by the end
R7HOT=$(( NOW + 3 * D + 12 * H ))
check "🔥 on a weekly window" "🔥 Use 52% 7d ↻$(local_time $R7HOT +%a)" \
  "$(quota "$(rl seven_day 52 $R7HOT)")"
# 20% after 12 h of a week projects past 100%, but a day of grace has not gone by
R7NEW=$(( NOW + 6 * D + 12 * H ))
check "no 🔥 on the first day of a week" "Use 20% 7d ↻$(local_time $R7NEW +%a)" \
  "$(quota "$(rl seven_day 20 $R7NEW)")"

echo ""
echo "passed: ${PASSED}   failed: ${FAILED}"
[ "$FAILED" -eq 0 ] || exit 1
