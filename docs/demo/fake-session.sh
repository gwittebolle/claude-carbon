#!/usr/bin/env bash
# Drives scripts/statusline.sh with a scripted session so vhs can record
# docs/demo.gif. Every frame is rendered by the real status line code; only
# the input JSON snapshots are fabricated, and the CO2 figure is tinted brand
# orange for the recording (the real status line emits no colour: it sits in
# every terminal all day, an orange segment there would be glare).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUSLINE="${REPO_DIR}/scripts/statusline.sh"

# Keep the demo line free of the update notice segment
export CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1

# resets_at 2h from now so the reset-time segment renders without a live API
RESET_EPOCH=$(( $(date +%s) + 7200 ))
ESC=$'\033'

# in_tokens out_tokens cost ctx_pct use_pct
STEPS=(
  "12000    400    0.04 3  12"
  "45000    1500   0.12 6  12"
  "120000   4200   0.31 11 13"
  "260000   9000   0.68 18 15"
  "480000   16000  1.15 26 18"
  "760000   25000  1.72 35 21"
  "1100000  36000  2.40 44 25"
  "1500000  48000  3.15 52 28"
  "1950000  62000  3.95 61 32"
)

# Wipe the typed vhs command and hide the cursor; restore on exit
printf '\033[2J\033[H\033[?25l'
trap 'printf "\033[?25h"' EXIT

printf '\033[2m> fix the flaky integration test and open a PR\033[0m\n\n'

FIRST=1
for step in "${STEPS[@]}"; do
  read -r IN OUT COST CTX USE <<<"$step"
  LINE="$(jq -n \
    --arg model_id "claude-opus-5" \
    --arg name "Opus 5" \
    --arg dir "$REPO_DIR" \
    --argjson in "$IN" --argjson out "$OUT" \
    --argjson cost "$COST" --argjson ctx "$CTX" \
    --argjson use "$USE" --argjson reset "$RESET_EPOCH" \
    '{model: {id: $model_id, display_name: $name},
      workspace: {current_dir: $dir},
      context_window: {total_input_tokens: $in, total_output_tokens: $out, used_percentage: $ctx},
      cost: {total_cost_usd: $cost},
      rate_limits: {five_hour: {used_percentage: $use, resets_at: $reset}}}' \
    | bash "$STATUSLINE")"
  # Recording-only highlight: "255g CO₂" / "1.2kg CO₂" in orange #f55c0f.
  LINE="$(printf '%s' "$LINE" | sed -E "s/([0-9.]+(g|kg) CO₂)/${ESC}[38;2;245;92;15m\\1${ESC}[0m/")"
  printf '\r\033[K%s' "$LINE"
  if [ "$FIRST" = "1" ]; then
    sleep 1.2
    FIRST=0
  else
    sleep 0.6
  fi
done

printf '\n'
sleep 10
