# Changelog

## 2026-07-20

### feat: `--until` for closed reporting periods

`generate-report.sh` could only report from a start date up to today, so a card for a finished period (a semester, a quarter) was impossible: the headline number always swept in the current month. `--until` takes an exclusive upper bound, and everything that implicitly meant "now" is re-anchored on it.

- SQL window gets an upper bound (`started_at < UNTIL`).
- The annual projection and the trailing-30-day trend measure to the period end instead of today. Without this, a January-June card extrapolated its run rate from July sessions.
- The label under the headline states the bound. "823 sessions depuis janvier" otherwise reads as "up to now" while the number says otherwise.
- The filename carries the window (`claude-carbon-summary-fr-2026-01-01_2026-06-30.png`), so two runs over different periods no longer overwrite each other.
- The generation date in the top-right corner is dropped on a closed period: it says nothing useful and contradicts the stated window.

Default behaviour is unchanged when `--until` is absent.

## 2026-07-19

### feat: weekly traffic snapshot (stats/)

GitHub's traffic API only keeps a 14-day rolling window, so `scripts/traffic-snapshot.sh` merges per-day views/clones into `stats/traffic.json` (latest fetch wins on overlapping days) and appends dated referrer/path snapshots as JSONL. Runs Mondays via `.github/workflows/traffic.yml` (workflow_dispatch too); needs a `TRAFFIC_TOKEN` fine-grained PAT secret with repository Administration read, because the traffic endpoints reject the default Actions token. Seeded with the current window: unique cloners ≈ real installs (install.sh and npx both end in `git clone`; updates are `git pull` and don't count).

### feat: `--segment` mode for embedding in other status lines

`statusline.sh --segment` prints only the cost + CO2 pair (`$0.68 · 35g CO₂`) and exits before the progress bar, the 5h-quota lookup (so never any network call) and the git branch call. Built for [ccstatusline](https://github.com/sirmalloc/ccstatusline) custom command widgets, which pass the same status JSON on stdin; documented in the README ("Using with ccstatusline"). Full mode output is byte-identical to before.

### docs: mid-2026 evidence sweep in METHODOLOGY.md

Literature check (July 2026): Jegham et al. still at v6, EcoLogits now a published paper but still parametric for Claude, no official Anthropic disclosure. Two documentation additions, no factor changes, golden vectors untouched:

- Cross-validation: added Couch (Jan 2026) as a third independent route (Epoch AI per-query estimate scaled by API price ratios, ~1,950 Wh/Mtok output vs ~2,880 here, within ~1.5x).
- Limitations: replaced the multi-region bullet with a fleet-mix limitation covering the tri-hardware fleet (AWS Trainium/GPU, Google TPU 1+ GW in 2026, Nvidia) and the ~300 MW gas-powered Memphis Colossus 1 lease (SpaceX S-1, May 2026). Weighted CIF effect ~+5-10%, flagged as a watch item.

### docs: demo GIF, social preview template, npm + CI badges

- `docs/demo.gif` at the top of the README: a scripted session replayed through the real `scripts/statusline.sh` (driver: `docs/demo/fake-session.sh`, recorder: `docs/demo/demo.tape` via vhs). Every frame is the actual renderer output; only the JSON snapshots are fabricated.
- `templates/social-preview.html`: 1280x640 GitHub social preview in the report-card visual style, rendered to `exports/social-preview.png` (local, exports/ is gitignored) for manual upload in Settings > General.
- README badges: npm version and CI workflow status next to the existing three.
- `.gitignore`: `promo/` (local marketing drafts stay out of the repo).

### docs: complete the GitHub community standards checklist

Added the five files the Community Standards page flagged as missing:

- `CODE_OF_CONDUCT.md`: Contributor Covenant 2.1, contact email for enforcement.
- `CONTRIBUTING.md`: project layout, `bash tests/run-vectors.sh`, the golden-vector rule for any `data/factors.json` / `data/prices.json` change, PR conventions, release manifest sync.
- `SECURITY.md`: private reporting (GitHub advisory or email), explicit scope (OAuth token, transcripts, installer/hooks execution, no unexpected network calls).
- `.github/ISSUE_TEMPLATE/`: bug report and feature request as YAML forms (version, install method, runtime environment fields), plus a contact link routing security reports away from public issues.
- `.github/PULL_REQUEST_TEMPLATE.md`: checklist mirroring CONTRIBUTING, with a dedicated section for methodology changes.

### feat: npm wrapper package (`npx claude-carbon`)

Published claude-carbon to npm as a thin wrapper so the package page and the registry-derived links (Socket.dev, ecosyste.ms, libraries.io, unpkg) exist, without changing the git-based distribution:

- `package.json` at the repo root (name `claude-carbon`, version synced with `plugin.json`, `files` limited to `bin/` - npm adds README/LICENSE itself; tarball is 4 files, ~8 kB).
- `bin/claude-carbon.js`: downloads `install.sh` from `main` and runs it through bash, propagating the installer's exit code. Flags: `--dry-run` (download only), `--version`, `--help`. `CLAUDE_CARBON_INSTALL_URL` overrides the source (pin a branch/fork, used by tests). Refuses Windows (the installer needs bash) and requires Node >= 18 (global `fetch`).
- README install section now offers `npx claude-carbon` next to the curl one-liner.
- Verified end-to-end against a local stub server (exit-code propagation included) and with `--dry-run` against the real GitHub URL; `npm pack --dry-run` checked for tarball contents.

Publishing (`npm publish`) is manual for now; a GitHub Action on tag can automate it later. Version bumps must keep `package.json` in sync with `plugin.json`/`marketplace.json`.

## 2026-07-15

### feat: contextual TokenClimate pointers in report and cards (1.1.1)

The OSS now routes "what about my team?" intent to the hosted layer at the moment it appears, without any ambient nagging or data collection:

- `/carbon-report` ends with a single footer line: `Team view (same methodology): tokenclimate.com`.
- The four `/carbon-card` PNG templates carry a small muted credit under the open-source badge (`vue équipe · tokenclimate.com` / `team view · tokenclimate.com`), so shared cards surface the link to viewers.
- Deliberately no status-line promo and no email capture: the update notice stays the only status-line extra, and lead capture remains on tokenclimate.com.
- The README "For teams" section documents both pointers explicitly, so the link in the output is an announced choice, not a surprise.
- Bumped the plugin version to **1.1.1** (`plugin.json` + `marketplace.json`).

## 2026-06-22

### feat: "update available" notice, one-command `/carbon-update`, and auto re-price on update

Existing installs had no way to know a new version shipped, and updating was a manual curl re-run that `git pull --ff-only` would break for anyone who had edited `data/factors.json` (which the README invites). Added a full update flow:

- **Notice**: a backgrounded, once-a-day version check (`scripts/check-update.sh`, run detached from the SessionStart hook) compares the local vs remote `plugin.json` version and writes a cached flag. The status line reads that flag locally (no network on the hot path) and shows a discreet `⬆ /carbon-update` when behind, with a 7-day staleness gate. Opt out via `CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1`. Marketplace-cache installs are skipped (they use Claude Code's native auto-update).
- **Update**: a `/carbon-update` slash command (and a hardened `install.sh`) run `scripts/update.sh`, a dirty-safe `git pull` that stashes only the two user-editable data files and, on conflict, preserves the user's version to `*.local.bak`.
- **Recompute on update**: after a pull, history is re-priced with the new factors automatically. `recompute.sh` now defaults to **CO2-only** (idempotent, no mixed-model cost drift); cost re-pricing is opt-in via `--with-cost`. Added a 5s SQLite busy-timeout (`sqlite3 -cmd ".timeout 5000"`) so a concurrent Stop-hook write doesn't fail the recompute, and the recompute now refuses non-numeric config values (they are interpolated into SQL).
- Bumped the plugin version to **1.1.0** (`plugin.json` + `marketplace.json`) so marketplace users are offered the update.

### Refine emission factors and pricing to the best available data to date (multi-source, cross-validated)

Triangulated the per-model CO2 factors and Anthropic pricing across independent sources (Jegham et al. v6 empirical AWS measurements, EcoLogits parametric LCA, third-party inference-energy studies, AWS regional grid data), with adversarial verification of the load-bearing numbers.

- CO2 (gCO2e/Mtok, usage-only, AWS region grid 0.287): **Sonnet 39/826** - a 3-point OLS fit to Jegham v6's three measured Claude 3.7 Sonnet energies (0.950 / 2.989 / 5.671 Wh), cross-validated by EcoLogits which brackets the same range. **Opus 78/1652** (2x Sonnet): the current EcoLogits Opus 4.5+ parameter ratio and the Anthropic price ratio both imply ~1.7-2x, replacing the earlier 3x; honest band 2x-5x. **Haiku 20/413** (0.5x). **Fable 156/3304** (2x Opus). Bands and unmeasured-extrapolation caveats are documented in `METHODOLOGY.md`.
- Relabeled the 0.287 kgCO2e/kWh carbon intensity as the AWS region grid (location-based), not a "US average" (the US average is ~380); kept 0.287 as the Jegham-consistent basis.
- Pricing: all USD list prices reconfirmed current (Opus $5/$25, Sonnet $3/$15, Haiku $1/$5, Fable $10/$50; cache write 1.25x 5-min tier, read 0.1x) - no drift. Added `eur_per_usd` (ECB reference rate 2026-06-22, 0.8729) for EUR display, and documented the 2x 1-hour cache-write tier.

These remain order-of-magnitude estimates and will keep being refined as measurements improve. Updated `data/factors.json`, `data/prices.json`, script fallbacks, `METHODOLOGY.md`, `README.md` and the golden vectors. Run `scripts/recompute.sh` to re-price stored rows.

### docs: note terminal/IDE-only compatibility in README

The status line and shell hooks only run in the Claude Code terminal CLI and IDE extensions, not the web (claude.ai/code) or desktop app. Added an explicit note under the install steps so users on the app don't expect CO2 tracking there.

## 2026-06-12

### feat: exclude non-Anthropic models from cost/CO2 accounting (#7)

Claude Code pointed at a local model (via `ANTHROPIC_BASE_URL`) was silently counted as Sonnet, with Sonnet datacenter factors and Anthropic API pricing. Sessions whose dominant model string does not contain `claude` (including `<synthetic>`) are now stored with raw tokens but `cost_usd = 0`, `co2_grams = 0` and a new `excluded` column set to 1, and filtered out of all reports (`/carbon-report`, `generate-report.sh`). The statusline shows 0g for those models. A user-configurable `exclude_models` pattern list in `data/factors.json` can exclude additional models by name. Schema migration is the usual idempotent `ALTER TABLE`; raw tokens are preserved so excluded rows can be re-priced by `recompute.sh` if local-model factors are ever added.

### feat: Fable 5 model family (pricing + extrapolated emission factors)

`claude-fable-5` / `claude-mythos-5` were falling into the Sonnet fallback of `resolve_family`, under-costing them by 70%. New `fable` family across all scripts (backfill, persist-session, recompute, statusline): pricing $10/$50 per Mtok (current Anthropic list price), emission factors 1000/6000 gCO2e/Mtok extrapolated from Opus by the 2x list-price ratio (no published measurement; same approach as the Opus 3x-Sonnet extrapolation, documented in METHODOLOGY.md).

### fix: LC_ALL=C in carbon-report skill awk calls (#10)

The bash script in `skills/carbon-report/SKILL.md` called awk without `LC_ALL=C`. Under comma-decimal locales (de_DE, fr_FR), awk truncated values at the decimal point (431.7045 → 431) and rendered output with commas. `export LC_ALL=C` at the top of the script covers all seven calls, mirroring the fix already applied to `scripts/*.sh`.

### fix: backfill.sh derives project name from cwd instead of directory name (#11)

`backfill.sh` took the last hyphen-separated token of the transcript directory name, which destroyed real hyphens in project names (`billing-service` → `service`) and merged distinct projects. It now reads the first `cwd` from the transcript JSONL via `jq -n 'first(inputs ...)'` (no SIGPIPE under `set -o pipefail`) and takes its basename, matching `persist-session.sh`. Previously backfilled rows keep their old names; delete and re-run backfill to normalize (noted in README).

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
