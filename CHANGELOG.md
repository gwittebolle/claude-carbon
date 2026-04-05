# Changelog

## 2026-04-05

### feat: statusline.sh
Reads Claude Code status JSON from stdin. Outputs formatted status line with color dot (green/yellow/red), 10-block progress bar, cost, CO2 in adaptive g/kg units, and project name.

### feat: setup.sh
Init script: checks jq/sqlite3 deps, creates ~/.claude/claude-carbon/carbon.db with sessions schema + index, runs backfill, prints CO2 summary (total + current year), and next-steps guide for settings.json.

### feat: backfill.sh
Parses all historical ~/.claude/projects/*/*.jsonl transcripts. Aggregates tokens per session, estimates cost by model family, calculates CO2 using factors.json, inserts into DB with source='backfill'. Skips non-UUID filenames, subagents/ and vercel-plugin/ dirs, and already-processed sessions.

### feat: persist-session.sh
Stop hook: reads statusline JSON from stdin, calculates CO2, INSERT OR REPLACE into carbon.db with source='live'. Completely silent on all failures (missing DB, missing session_id, jq/sqlite3 errors).

### feat: skills/carbon-report/SKILL.md
/claude-carbon:report skill. Inline bash script queries carbon.db and displays today/year/all-time totals, equivalences (car km, Google searches, TGV km), top 5 sessions by CO2, and per-project breakdown.

### feat: plugin.json + hooks.json
plugin.json declares plugin metadata, statusLine command, and skills directory. hooks.json wires persist-session.sh to the Stop hook.

### docs: README.md + METHODOLOGY.md + LICENSE
README covers install, emission factors, usage, and dependencies. METHODOLOGY documents the Jegham et al. 2025 source, formula, infrastructure parameters (PUE/CIF/WUE), per-model factors, and limitations. LICENSE is MIT 2026.
