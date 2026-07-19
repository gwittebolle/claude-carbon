# Contributing to claude-carbon

Thanks for taking the time to contribute. This document covers how the project
is laid out, how to test changes, and what a good pull request looks like.

## Project layout

claude-carbon is plain bash + jq + awk. There is no build step and no runtime
dependency to install (only `/carbon-card` needs `playwright-core`, see the
README).

| Path                | What it is                                                            |
| ------------------- | --------------------------------------------------------------------- |
| `hooks/`            | Claude Code status line + shell hooks (the live CO2 estimate)         |
| `scripts/`          | Report, card generation, backfill, update logic                       |
| `skills/`           | The `/carbon-report`, `/carbon-card`, `/carbon-update` slash commands |
| `data/factors.json` | Emission factors (per-model energy, PUE, carbon intensity)            |
| `data/prices.json`  | Per-model token prices                                                |
| `tests/`            | Golden vectors for the methodology + the runner                       |
| `install.sh`        | The installer (also what `npx claude-carbon` runs)                    |
| `METHODOLOGY.md`    | How every number is derived                                           |

## Running the tests

```bash
bash tests/run-vectors.sh
```

This replays the golden vectors in `tests/methodology-vectors.json` against
`data/factors.json` and `data/prices.json`. CI runs the same script on every
push and pull request. It only needs bash, jq, and awk.

## Changing the methodology (factors or prices)

This is the sensitive part of the project. Any change to `data/factors.json` or
`data/prices.json` must ship in the same PR as:

1. An update to `tests/methodology-vectors.json` so the golden vectors encode
   the new expected outputs.
2. An update to `METHODOLOGY.md` explaining the derivation. Every number must
   be reproducible from a cited source; "it looks right" is not a derivation.

PRs that change factors or prices without both of these will not be merged.

## Pull requests

- Branch from `main`, open the PR against `main`.
- Keep commits in English, conventional format: `feat:`, `fix:`, `refactor:`,
  `chore:`, `docs:`, `test:`.
- Add an entry to `CHANGELOG.md` (date-stamped, see existing entries for the
  format).
- If the change is user-visible, update the README.

### Releases (maintainer notes)

A release bumps the version in three manifests, which must stay in sync:
`package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.
Then: npm publish, git tag, GitHub release.

## Reporting bugs and proposing features

Use the [issue templates](https://github.com/gwittebolle/claude-carbon/issues/new/choose).
For bugs, the environment details (OS, Claude Code version, install method)
matter a lot: the status line runs in the terminal CLI and IDE extensions only,
and quota data comes from an OAuth endpoint, so many issues are
environment-specific.

For security issues, do not open a public issue: see [SECURITY.md](SECURITY.md).

## Questions

Not sure whether something is a bug, or want to discuss an idea before writing
code? Open an issue. Small questions are fine.
