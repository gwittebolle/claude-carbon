# Security Policy

## Supported versions

Only the latest release is supported. The installer and `npx claude-carbon`
always fetch the latest version, and `/carbon-update` brings existing installs
up to date, so there is no reason to run an older one.

## What is in scope

claude-carbon runs locally, but it touches sensitive material:

- It reads your local Claude Code transcripts in `~/.claude` to compute usage.
- The quota display can read an OAuth bearer token from the macOS Keychain,
  `CLAUDE_CODE_OAUTH_TOKEN`, or `~/.claude/.credentials.json`.
- `install.sh` is piped from GitHub into bash, and hooks execute inside your
  shell on every status line refresh.

Anything that could leak the OAuth token or transcript content, execute
unexpected code through the installer, update flow, or hooks, or send data
anywhere (the tool is expected to make no network calls other than the Anthropic
usage endpoint and GitHub for updates) is a security issue we want to hear
about.

## Reporting a vulnerability

Please do not open a public issue for security problems.

- Preferred: [open a private security advisory](https://github.com/gwittebolle/claude-carbon/security/advisories/new)
  on GitHub.
- Or email gaetan.wittebolle@gmail.com with "claude-carbon security" in the
  subject.

Include what you found, how to reproduce it, and what an attacker could do
with it. You can expect an acknowledgment within 72 hours and a fix or a
public advisory as soon as one is ready. Please give us a reasonable window to
ship a fix before disclosing publicly.
