# Changelog

## 2026-04-19

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
