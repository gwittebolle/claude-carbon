# claude-carbon

Track the carbon footprint of your Claude Code sessions.

```
🟢 Opus 4.6 (1M context) ░░░░ 6% | $3.20 | 145g CO₂ | claude cowork
```

## What it does

- Adds a live CO2 estimate to the Claude Code status line, next to the session cost
- Persists each session to a local SQLite database
- Backfills historical data from existing `~/.claude` transcripts (⚠️ default Claude configuration keeps only 30 days)
- Generates shareable PNG report cards for LinkedIn
- Exposes a `/claude-carbon:report` skill for a full emissions breakdown

## Example report

<p align="center">
  <img src="docs/example-report-v2.png" alt="Claude Carbon Report" width="540">
</p>

Generate yours:

```bash
# Since January 1st (default)
bash scripts/generate-report.sh

# Since a specific date
bash scripts/generate-report.sh --since 2026-03-01

# All time
bash scripts/generate-report.sh --all
```

Exports two PNGs to `exports/`: a summary card and a detailed card with per-project breakdown.

## Install

```bash
git clone https://github.com/gwittebolle/claude-carbon.git ~/code/claude-carbon
bash ~/code/claude-carbon/scripts/setup.sh
```

The setup script checks dependencies, creates the SQLite database, backfills your existing Claude Code sessions, and prints the total CO2 emitted so far.

Then add to `~/.claude/settings.json` (or `settings.local.json`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/code/claude-carbon/scripts/statusline.sh"
  }
}
```

And add the Stop hook to persist sessions (append to your existing `hooks.Stop` array):

```json
{
  "type": "command",
  "command": "~/code/claude-carbon/scripts/persist-session.sh"
}
```

Restart Claude Code. The CO2 estimate appears in the status line.

## Commands

| Command                 | What it does                                                   |
| ----------------------- | -------------------------------------------------------------- |
| `setup.sh`              | Init database, backfill historical sessions, show total        |
| `statusline.sh`         | Status line script (called automatically by Claude Code)       |
| `persist-session.sh`    | Stop hook (saves session data on exit)                         |
| `backfill.sh`           | Re-parse all historical JSONL transcripts                      |
| `generate-report.sh`    | Export shareable PNG report cards                              |
| `/claude-carbon:report` | In-session text report with totals, equivalences, top sessions |

## Emission factors

Factors from [Jegham et al. 2025](https://arxiv.org/abs/2505.09598), a peer-reviewed study measuring energy consumption of LLM inference on AWS infrastructure.

| Model  | Input (gCO2e/Mtok) | Output (gCO2e/Mtok) | Basis                      |
| ------ | ------------------ | ------------------- | -------------------------- |
| Opus   | 500                | 3000                | Extrapolated (3x Sonnet)   |
| Sonnet | 190                | 1140                | Measured                   |
| Haiku  | 95                 | 570                 | Extrapolated (0.5x Sonnet) |

**Important: these are order-of-magnitude estimates, not precise measurements.**

- Sonnet factors are derived from Jegham et al. direct measurements. Opus and Haiku are extrapolated (no public data from Anthropic on per-model energy consumption).
- Cache read tokens are counted at the same rate as fresh compute. In reality, cache reads consume less energy. This means estimates skew high.
- Carbon intensity uses AWS grid-average (0.287 kgCO2e/kWh), not real-time grid data.
- Anthropic does not publish Scope 1, 2, or 3 emissions. These estimates are independent and based on academic research, not provider data.

Factors are editable in `data/factors.json`. See [METHODOLOGY.md](METHODOLOGY.md) for the full scientific basis, formula, and equivalences.

## Dependencies

- `jq` - JSON parsing
- `sqlite3` - local database
- `playwright-core` - PNG export only (optional)

`jq` and `sqlite3` are pre-installed on macOS. On Linux: `apt install jq sqlite3`.

## Reduce your footprint

Measuring is step one. Here are concrete levers to reduce your AI carbon footprint, ranked by impact.

### Use the right model for the task

Output tokens cost 5x more energy than input tokens. Opus consumes ~3x more than Sonnet per token.

```json
{
  "env": {
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-haiku-4-5"
  }
}
```

Use Opus for architecture and planning. Sonnet for daily work. Haiku for subagents (exploration, file reading, reviews). This alone can cut your emissions by 60%.

### Install RTK (Rust Token Killer)

[RTK](https://github.com/rtk-ai/rtk) is a CLI proxy that filters noise from shell outputs (progress bars, verbose logs, passing tests) before they hit the context window. 60-90% token reduction on CLI commands, zero quality loss.

```bash
brew install rtk-ai/tap/rtk
rtk init -g
```

### Reduce thinking tokens

Claude's extended thinking can use up to 32k hidden tokens per message. Capping it reduces consumption without degrading quality on routine tasks.

```json
{
  "env": {
    "MAX_THINKING_TOKENS": "10000"
  }
}
```

### Compact earlier

By default, Claude Code compacts context at 95% usage. Compacting earlier keeps context cleaner and avoids bloated sessions.

```json
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50"
  }
}
```

### Write concise instructions

Add to your project's CLAUDE.md:

```
Be concise. No preamble, no summaries unless asked.
```

Output tokens are the most expensive in both cost and energy.

### Combined impact

| Lever                | Estimated reduction     |
| -------------------- | ----------------------- |
| Right model per task | -60% vs all-Opus        |
| RTK                  | -70% on CLI tokens      |
| Thinking cap at 10k  | -70% on thinking tokens |
| Haiku subagents      | -80% on exploration     |
| **All combined**     | **-50 to 70% total**    |

### Further reading

- [IEA - Energy and AI (2025)](https://www.iea.org/reports/energy-and-ai/) - data center projections
- [Jegham et al. - How Hungry is AI?](https://arxiv.org/abs/2505.09598) - per-model energy measurements
- [UCL/UNESCO - 90% AI energy reduction](https://www.ucl.ac.uk/news/2025/jul/practical-changes-could-reduce-ai-energy-demand-90) - frugal AI approaches
- [GreenIT.fr - AI impacts 2025-2030](https://www.greenit.fr/impacts-ia-monde-2025-2030-rapport/) - French data

## Why

Every Claude Code session uses real compute, real energy, real emissions. The number is small per query, but it adds up. Making it visible is the first step to owning it.

## Open source

claude-carbon is free and open source under the [MIT license](LICENSE). Contributions welcome.

Built by [Gaetan Wittebolle](https://github.com/gwittebolle).
