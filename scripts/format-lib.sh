#!/usr/bin/env bash
# format-lib.sh — shared CO2 quantity formatting.
# Sourced by scripts/generate-report.sh and scripts/generate-badge.sh.
# Callers are expected to have exported LC_ALL=C already; the pipelines below
# pin it anyway so a stray comma-decimal locale cannot corrupt the output.

# Echoes "<value> <unit>" for a gram amount, unit adapting to the magnitude:
# "432 g", "12.4 kg", "1.2 t". One decimal above the gram tier.
format_co2() {
  local grams="$1"
  if (( $(echo "$grams >= 1000000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000000}') t"
  elif (( $(echo "$grams >= 1000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.0f", $1}') g"
  fi
}
