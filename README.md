# claude-carbon

Track the carbon footprint of your Claude Code sessions.

```
🟢 Opus 4.6 (1M context) ░░░░ 6% | $3.20 | 145g CO₂ | claude cowork
```

## What it does

- Adds a live CO2 estimate to the Claude Code status line
- Persists each session to a local SQLite database on Stop
- Backfills historical data from existing `~/.claude` transcripts
- Exposes a `/claude-carbon:report` skill for a full emissions breakdown

## Install

```bash
git clone https://github.com/gwittebolle/claude-carbon.git ~/code/claude-carbon
bash ~/code/claude-carbon/scripts/setup.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": "echo '$CLAUDE_CODE_STATUS' | ~/code/claude-carbon/scripts/statusline.sh",
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

## Emission factors

Factors from [Jegham et al. 2025](https://arxiv.org/abs/2505.09598), measured on AWS infrastructure.

| Model | Input (gCO2e/Mt) | Output (gCO2e/Mt) |
|-------|-----------------|------------------|
| Opus | 500 | 3000 |
| Sonnet | 190 | 1140 |
| Haiku | 95 | 570 |

Mt = million tokens. See [METHODOLOGY.md](METHODOLOGY.md) for the full explanation.

## Usage

**Automatic:** The status line updates on every tool call. Session data is saved when Claude Code stops.

**Report:** Type `/claude-carbon:report` in any Claude Code session to get a full breakdown: totals by day/year/all-time, equivalences, top sessions, and per-project stats.

## Dependencies

- `jq` - JSON parsing
- `sqlite3` - local database

```bash
brew install jq sqlite3
```

## Why

Every Claude Code session uses real compute, real energy, real emissions. The number is small per session, but it adds up. Making it visible is the first step to owning it.

## License

MIT
