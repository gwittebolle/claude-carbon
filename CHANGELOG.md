# Changelog

## 2026-06-05

### fix: deduplicate tokens, correct pricing, and count cache_read energy

Three correctness fixes to token accounting in `backfill.sh` and `persist-session.sh`, validated against ccusage on the same JSONL:

- **Deduplication.** `aggregate_jsonl` now dedups assistant messages by `(message.id, requestId)` keeping the last occurrence, before summing. Resumed/compacted sessions replay prior messages within a file and streaming writes the same message repeatedly; 55% of assistant lines on observed data are replays, so the previous raw sum over-counted tokens ~3x. The duplication is entirely within-file, so per-file dedup is sufficient.
- **Pricing.** Replaced the hardcoded $15/$75 (retired Opus 4.0/4.1 rate) with current Anthropic list pricing: Opus 4.6+ $5/$25, Sonnet $3/$15, Haiku $1/$5. Cost now also counts cache_write at 1.25x input and cache_read at 0.1x input. On deduplicated data `cost_usd` reconciles to within a few percent of ccusage.
- **Cache read energy.** Cache reads (90%+ of token volume) are no longer excluded from CO2. They now count at `cache_read_factor` (default 0.08) of the input factor, an engineering estimate of the decode-phase KV re-read residual, documented in METHODOLOGY.md and `data/factors.json`. This is not the 0.1x billing ratio (a price, not energy).

Schema gains a `cache_read_tokens` column (idempotent `ALTER TABLE` migration in setup/backfill/persist; new installs get it in `CREATE TABLE`). `CLAUDE_CARBON_DB` env var added to override the DB path for testing. Existing rows keep their old values until a re-backfill; new live sessions use the corrected methodology immediately.

### feat: durable raw-token storage + recompute, surviving the 30-day JSONL purge

Make the DB self-sufficient so derived metrics survive Anthropic's ~30-day transcript purge and any future methodology change, without ever needing the JSONL again.

- **Raw tokens stored, not just derived numbers.** Added `cache_creation_tokens` and `methodology_version` columns. Rows now carry the full breakdown (regular input = `input_tokens - cache_creation_tokens`, cache write, cache read, output), so cost and CO2 become pure functions of stored tokens + config.
- **`recompute.sh`** (new). Re-derives `cost_usd` and `co2_grams` for all `methodology_version >= 2` rows from `data/factors.json` + `data/prices.json`, no JSONL. Run it after any price/factor change. Mixed-model sessions recompute at the dominant model (small approximation; the insert is per-subagent accurate). `CLAUDE_CARBON_FACTORS` / `CLAUDE_CARBON_PRICES` env overrides for testing.
- **`data/prices.json`** (new). Pricing moved out of the scripts into config (Opus $5/$25, Sonnet $3/$15, Haiku $1/$5; cache write 1.25x, cache read 0.1x). A future price change is one edit + `recompute.sh`, not a code change in three scripts.
- **`safety-rescan.sh`** (new) + `SessionStart` hook. Throttled (once/day), backgrounded `backfill.sh` re-run that catches sessions the `Stop` hook missed, while their transcript is still on disk.

Verified end-to-end on a temp DB: backfill stores the raw breakdown; recompute reproduces totals from tokens alone (~$2,667 / 230 kg, matching ccusage); changing the cache_read_factor moves CO2 only; changing a price moves cost only.

## 2026-04-21

### fix: restore reset time display when stdin passes epoch

Claude Code injects `rate_limits.five_hour.resets_at` as a Unix epoch (number), while the fallback API returns ISO-8601 with fractional seconds + tz offset. The parser now branches on numeric vs string input and strips `.fraction`, `Z`, and `+HH:MM` suffixes before `date -j -u -f`. Without this, the stdin path left `END_EPOCH` empty and the `↻HH:MM` suffix silently disappeared.

### refactor: 5h quota via Anthropic OAuth API (drops ccusage heuristic)

The 5h block usage % is now pulled from `https://api.anthropic.com/api/oauth/usage` (same data as `/usage` in Claude Code), with a stdin-first path reading `rate_limits.five_hour.used_percentage` when Claude Code injects it. Removes the ccusage dependency, the learned `token-limit` file, the `CLAUDE_CARBON_TOKEN_LIMIT` env seed, the async refresh lock, and the npx cold-start latency. Accurate on Max 20x without needing to saturate a block first. OAuth token resolved from macOS Keychain, env, or `~/.claude/.credentials.json`. Response cached 60s in `~/.claude/claude-carbon/oauth-usage.json`. The 🔥 burn-rate prefix and `↻HH:MM` reset time are preserved; block start is derived as `resets_at - 5h`.

## 2026-04-19

### fix: stale lock + UTC-to-local conversion for reset time

Two bugs masked the correct 5h block reset time: (1) the async-refresh lock file could survive a crashed/killed ccusage process and block every subsequent refresh indefinitely (6h of stuck data in practice), and (2) macOS `date -j -f` without `-u` parses the UTC timestamp as local time, making `↻11:00` display when the real reset was 13:00 (or 18:00 after the block rolled over). Locks older than 60s are now broken on the next run, and both `startTime`/`endTime` are parsed as UTC then formatted in local via epoch.

### feat: learned token limit file with auto-bump

The 5h quota % is now computed against a persistent ceiling stored in `~/.claude/claude-carbon/token-limit`. The file is seeded from the `CLAUDE_CARBON_TOKEN_LIMIT` env var on first run (or can be written directly), then auto-bumps whenever an observed block exceeds it. Falls back to ccusage's heuristic if neither is set. Fixes the Max 20x case where ccusage's heuristic ceiling is far too low until a block has been saturated, inflating the displayed percentage (68% shown when `/usage` reported 24%). README explains the seeding procedure via `/usage`.

## 2026-04-17

### feat: richer status line (git branch + 5h quota usage)

Status line now shows project, git branch (`⌥ branch`), model, context window %, session cost + CO2, and 5h block quota usage with reset time (`Use X% ↻HH:MM`). A 🔥 prefix appears when usage >= 15% AND burn rate >= 50%/h since block start, with a 15 min grace window to absorb bursty session starts. Quota data fetched via `ccusage` with a 30s file cache and async background refresh to avoid blocking the status line. Strips `(1M context)` / `(200K context)` from model display name. Reordered segments left-to-right: project → model state → cost → quota.

## 2026-04-09

### docs: update README install instructions

Removed plugin marketplace install (not validated by Anthropic). Added Playwright + Chromium install instructions for `/carbon-card`.

### feat: one-line installer (install.sh)

`curl | bash` installer that clones the repo, runs setup, and auto-configures `~/.claude/settings.json` (statusLine + Stop hook). Supports custom install directory via `CLAUDE_CARBON_DIR`. Idempotent: updates existing installs with `git pull`.

### feat: plugin marketplace support

Restructured as official Claude Code plugin. Installable via `/plugin install claude-carbon` or `curl | bash`. Added `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

### chore: add GitHub badges to README

Stars, license, and release badges for social proof.

## 2026-04-05

### feat: generate-report.sh + report-card.html

PNG card generator for LinkedIn sharing. Queries carbon.db for total CO2, sessions, cost, car km equivalence, top 3 projects, and most used model. Injects into a branded HTML template (violet/orange/cream, Clash Display + Owner Text) and exports retina 2x PNG via Playwright.

## 2026-04-05

### feat: statusline.sh

Reads Claude Code status JSON from stdin. Outputs formatted status line with color dot (green/yellow/red), 10-block progress bar, cost, CO2 in adaptive g/kg units, and project name.

### feat: setup.sh

Init script: checks jq/sqlite3 deps, creates ~/.claude/claude-carbon/carbon.db with sessions schema + index, runs backfill, prints CO2 summary (total + current year), and next-steps guide for settings.json.

### feat: backfill.sh

Parses all historical ~/.claude/projects/_/_.jsonl transcripts. Aggregates tokens per session, estimates cost by model family, calculates CO2 using factors.json, inserts into DB with source='backfill'. Skips non-UUID filenames, subagents/ and vercel-plugin/ dirs, and already-processed sessions.

### feat: persist-session.sh

Stop hook: reads statusline JSON from stdin, calculates CO2, INSERT OR REPLACE into carbon.db with source='live'. Completely silent on all failures (missing DB, missing session_id, jq/sqlite3 errors).

### feat: skills/carbon-report/SKILL.md

/claude-carbon:report skill. Inline bash script queries carbon.db and displays today/year/all-time totals, equivalences (car km, Google searches, TGV km), top 5 sessions by CO2, and per-project breakdown.

### feat: plugin.json + hooks.json

plugin.json declares plugin metadata, statusLine command, and skills directory. hooks.json wires persist-session.sh to the Stop hook.

### docs: README.md + METHODOLOGY.md + LICENSE

README covers install, emission factors, usage, and dependencies. METHODOLOGY documents the Jegham et al. 2025 source, formula, infrastructure parameters (PUE/CIF/WUE), per-model factors, and limitations. LICENSE is MIT 2026.
