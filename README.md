# claude-carbon

[![GitHub stars](https://img.shields.io/github/stars/gwittebolle/claude-carbon)](https://github.com/gwittebolle/claude-carbon/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/gwittebolle/claude-carbon)](https://github.com/gwittebolle/claude-carbon/releases)

Track the carbon footprint of your Claude Code sessions.

**1. Install (or update):**

```bash
curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash
```

Same command to install and to update to the latest version.

**2. Restart Claude Code.** Your CO2 appears in the status line:

```
claude-carbon ⌥ main | 🟢 Opus 4.7 ▓▓▓░░░░░░░ 35% | $0.50 · 65g CO₂ | Use 24% ↻13:00
```

Segments, left to right: project + git branch · model + context window % · session cost + CO2 · 5h block usage % + reset time. A 🔥 prefix appears when the sustained burn rate would overshoot 100% of the limit by the end of the 5h block (after a 15 min grace window, only once usage reaches 15%).

**Setting the right token limit.** The 5h quota % is computed against a token ceiling stored in `~/.claude/claude-carbon/token-limit`. The authoritative per-plan limit is not exposed externally — Claude Code only shows it through `/usage` — so this file has to be seeded once.

Limit resolution order:

1. **Learned file** (`~/.claude/claude-carbon/token-limit`): a single number, auto-bumps whenever a block's actual token count exceeds it. Once set correctly, this is what the status line uses.
2. **`CLAUDE_CARBON_TOKEN_LIMIT` env var**: seeds the learned file on first run if the file doesn't exist. Useful to bootstrap.
3. **ccusage heuristic** (fallback): the highest-tokens block found in your local `~/.claude` history. Fine on Pro / Max 5x once you've saturated a block, but **underestimates on Max 20x until you've actually hit your ceiling** — so the displayed % runs too high.

Seed the real limit once, then the file maintains itself:

```bash
# Run /usage in Claude Code, note the real % for the current 5h block.
# Divide the tokens you've actually used by that %. Example:
# /usage says 24%, ccusage reports 131M tokens → limit ≈ 131M / 0.24 ≈ 546M.
export CLAUDE_CARBON_TOKEN_LIMIT=546000000

# Or skip the env var and write the file directly:
echo 546000000 > ~/.claude/claude-carbon/token-limit
```

The file then auto-bumps on its own: if you ever run a block that burns more tokens than the stored ceiling, the ceiling is raised to that new value. So if Anthropic increases your plan limit (or you switch plans upward), it adapts. If they decrease the limit, re-seed the file by hand.

**3. Use the slash commands:**

- `/carbon-report` - text report with totals, equivalences, top sessions
- `/carbon-card` - generate shareable PNG report cards (requires `playwright-core`, see [Dependencies](#dependencies))

## What it does

- Adds a live CO2 estimate to the Claude Code status line, next to the session cost
- Persists each session to a local SQLite database
- Backfills historical data from existing `~/.claude` transcripts
- Two slash commands: `/carbon-report` (text) and `/carbon-card` (PNG)

## Example report

<p align="center">
  <img src="docs/example-report-v2.png" alt="Claude Carbon Report" width="540">
</p>

Generate yours with `/carbon-card` in Claude Code. Exports summary and detailed PNGs to `exports/`.

<details>
<summary>Advanced options (CLI)</summary>

```bash
# Since a specific date
bash ~/code/claude-carbon/scripts/generate-report.sh --since 2026-03-01

# All time
bash ~/code/claude-carbon/scripts/generate-report.sh --all
```

</details>

<details>
<summary>Custom install directory</summary>

```bash
CLAUDE_CARBON_DIR=~/my-path/claude-carbon curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash
```

</details>

<details>
<summary>Manual install</summary>

```bash
git clone https://github.com/gwittebolle/claude-carbon.git ~/code/claude-carbon
bash ~/code/claude-carbon/scripts/setup.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/code/claude-carbon/scripts/statusline.sh"
  },
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/code/claude-carbon/scripts/persist-session.sh"
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code.

</details>

## How it works

![Data flow](docs/data-flow.png)

**Three data paths, two levels of accuracy:**

| Script               | Trigger                 | Data source           | Subagents    | Cache reads | Accuracy      |
| -------------------- | ----------------------- | --------------------- | ------------ | ----------- | ------------- |
| `backfill.sh`        | Manual / setup          | JSONL files           | Included     | Excluded    | Best estimate |
| `persist-session.sh` | Stop hook (session end) | JSONL files           | Included     | Excluded    | Best estimate |
| `statusline.sh`      | Every turn (live)       | `context_window` JSON | Not included | Included\*  | Approximate   |

**backfill** and **persist-session** parse the raw JSONL transcripts (main session + subagent files), applying per-model emission factors. Only `input_tokens` and `cache_creation_input_tokens` are counted. These feed the SQLite database used by reports.

**statusline** reads `context_window.total_input_tokens` from Claude Code at each turn. This value represents the current context size (not a cumulative total), includes cache reads, and does not account for subagent tokens. It's an indicative live display, not a data source for reports.

_\*Claude Code does not expose `cache_read_input_tokens` separately in the statusline JSON. Parsing JSONL incrementally would be too slow for a per-turn display. A proper fix would require Anthropic to expose the token breakdown in the status hook API._

## Commands

| Command          | What it does                                        |
| ---------------- | --------------------------------------------------- |
| `/carbon-report` | Text report with totals, equivalences, top sessions |
| `/carbon-card`   | Generate shareable PNG report cards                 |

<details>
<summary>Scripts (run automatically, rarely needed manually)</summary>

| Script               | What it does                                                |
| -------------------- | ----------------------------------------------------------- |
| `setup.sh`           | Init database, backfill historical sessions, show total     |
| `statusline.sh`      | Status line script (called automatically by Claude Code)    |
| `persist-session.sh` | Stop hook (saves session data on exit)                      |
| `backfill.sh`        | Re-parse all historical JSONL transcripts (incl. subagents) |
| `generate-report.sh` | Export PNG report cards (CLI, with `--since` / `--all`)     |

</details>

## Emission factors

Factors from [Jegham et al. 2025](https://arxiv.org/abs/2505.09598), a peer-reviewed study measuring energy consumption of LLM inference on AWS infrastructure.

| Model  | Input (gCO2e/Mtok) | Output (gCO2e/Mtok) | Basis                      |
| ------ | ------------------ | ------------------- | -------------------------- |
| Opus   | 500                | 3000                | Extrapolated (3x Sonnet)   |
| Sonnet | 190                | 1140                | Measured                   |
| Haiku  | 95                 | 570                 | Extrapolated (0.5x Sonnet) |

**Important: these are order-of-magnitude estimates, not precise measurements.**

- Sonnet factors are derived from Jegham et al. direct measurements. Opus and Haiku are extrapolated (no public data from Anthropic on per-model energy consumption).
- Cache read tokens are excluded from the calculation (only `input_tokens` and `cache_creation_input_tokens` are counted). Cache reads represent the majority of tokens in Claude Code but consume negligible energy.
- Carbon intensity uses AWS grid-average (0.287 kgCO2e/kWh), not real-time grid data.
- Anthropic does not publish Scope 1, 2, or 3 emissions. These estimates are independent and based on academic research, not provider data.

Factors are editable in `data/factors.json`. See [METHODOLOGY.md](METHODOLOGY.md) for the full scientific basis, formula, and equivalences.

## Dependencies

- `jq` - JSON parsing
- `sqlite3` - local database
- `git` - branch detection in status line (optional)
- `npx` (Node.js) - 5h quota usage in status line via [ccusage](https://github.com/ryoppippi/ccusage), called with aggressive cache (optional)
- `playwright-core` + Chromium - PNG export for `/carbon-card` (optional)

`jq` and `sqlite3` are pre-installed on macOS. On Linux: `apt install jq sqlite3`.

To use `/carbon-card`, install Playwright and its Chromium browser:

```bash
npm install -g playwright-core
npx playwright install chromium
```

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
