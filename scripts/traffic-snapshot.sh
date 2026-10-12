#!/usr/bin/env bash
# traffic-snapshot.sh: persist GitHub traffic data (14-day rolling window)
# and npm daily downloads into stats/, merging per-day entries so the series
# survives the window.
# Runs weekly via .github/workflows/traffic.yml; can be run locally too
# (uses your gh auth; in Actions, GH_TOKEN must be a PAT with
# repository Administration read permission - the traffic API requires it).
# The npm downloads API is public: no token.
set -euo pipefail

REPO="${TRAFFIC_REPO:-gwittebolle/claude-carbon}"
NPM_PACKAGE="claude-carbon"
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

# npm downloads per day, last 365 days (the API's day ends at UTC midnight).
# Same upsert as the views: the latest fetch wins, so a rerun never counts a day
# twice. The zero days before the package first appears are left out.
NPM_FILE="$STATS_DIR/npm.json"
[ -f "$NPM_FILE" ] || echo '{"downloads":{}}' > "$NPM_FILE"
# A failed fetch, or an answer that is not the expected JSON, skips npm and keeps
# the GitHub snapshot, whose window is short. No temp file is left for the
# workflow's `git add stats/` to commit.
if NPM="$(curl -fsS --max-time 30 "https://api.npmjs.org/downloads/range/last-year/$NPM_PACKAGE")" \
  && jq --argjson n "$NPM" '
    ([(.downloads | keys | min), ($n.downloads | map(select(.downloads > 0)) | .[0].day)]
      | map(select(. != null)) | min) as $from
  | .downloads = (.downloads + ($n.downloads
      | map(select($from != null and .day >= $from) | {(.day): {count: .downloads}})
      | add // {}))
  ' "$NPM_FILE" > "$NPM_FILE.tmp"; then
  mv "$NPM_FILE.tmp" "$NPM_FILE"
else
  rm -f "$NPM_FILE.tmp"
  echo "npm downloads: fetch failed or unexpected answer, skipped" >&2
fi

echo "Snapshot done: $(jq '.views | length' "$FILE") days of views, $(jq '.clones | length' "$FILE") days of clones, $(jq '.downloads | length' "$NPM_FILE") days of npm downloads."
