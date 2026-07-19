#!/usr/bin/env bash
# traffic-snapshot.sh — Persist GitHub traffic data (14-day rolling window)
# into stats/, merging per-day entries so the series survives the window.
# Runs weekly via .github/workflows/traffic.yml; can be run locally too
# (uses your gh auth; in Actions, GH_TOKEN must be a PAT with
# repository Administration read permission - the traffic API requires it).
set -euo pipefail

REPO="${TRAFFIC_REPO:-gwittebolle/claude-carbon}"
STATS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stats"
mkdir -p "$STATS_DIR"
FILE="$STATS_DIR/traffic.json"
[ -f "$FILE" ] || echo '{"views":{},"clones":{}}' > "$FILE"

VIEWS="$(gh api "repos/$REPO/traffic/views")"
CLONES="$(gh api "repos/$REPO/traffic/clones")"

# Upsert per-day entries; the latest fetch wins on overlapping days, so a
# partially-counted current day gets corrected by the next run.
jq --argjson v "$VIEWS" --argjson c "$CLONES" '
  .views  = (.views  + ($v.views  | map({(.timestamp[:10]): {count: .count, uniques: .uniques}}) | add // {}))
| .clones = (.clones + ($c.clones | map({(.timestamp[:10]): {count: .count, uniques: .uniques}}) | add // {}))
' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

# Referrers and popular paths have no per-day breakdown; store dated
# snapshots of the whole 14-day window instead.
DATE="$(date -u +%F)"
gh api "repos/$REPO/traffic/popular/referrers" | jq -c --arg d "$DATE" '{date: $d, referrers: .}' >> "$STATS_DIR/referrers.jsonl"
gh api "repos/$REPO/traffic/popular/paths" | jq -c --arg d "$DATE" '{date: $d, paths: .}' >> "$STATS_DIR/paths.jsonl"

echo "Snapshot done: $(jq '.views | length' "$FILE") days of views, $(jq '.clones | length' "$FILE") days of clones."
