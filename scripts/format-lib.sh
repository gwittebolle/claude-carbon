#!/usr/bin/env bash
# format-lib.sh — shared CO2 quantity formatting.
# Sourced by scripts/generate-report.sh and scripts/generate-badge.sh.
# Callers are expected to have exported LC_ALL=C already; the pipelines below
# pin it anyway so a stray comma-decimal locale cannot corrupt the output.

# Echoes "<value> <unit>" for a gram amount, unit adapting to the magnitude:
# "432 g", "12.4 kg", "1240.0 kg", "12.4 t". One decimal above the gram tier.
#
# The tonne tier starts at 10 t, not 1 t. A year of heavy Claude Code use lands
# around one tonne, and "1.0 t" reads as a rounding artefact next to "1016.3 kg";
# the small number undersells the quantity it stands for. Staying in kilograms
# until 10 t keeps the figure legible as a quantity for every plausible personal
# and small-team total, and the tonne tier is left for fleet-scale numbers where
# four or five digits of kilograms would be the harder read.
TONNE_TIER_GRAMS=10000000

format_co2() {
  local grams="$1"
  if (( $(echo "$grams >= ${TONNE_TIER_GRAMS}" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000000}') t"
  elif (( $(echo "$grams >= 1000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.0f", $1}') g"
  fi
}
