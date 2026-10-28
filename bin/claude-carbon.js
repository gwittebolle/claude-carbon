#!/usr/bin/env node
// npx claude-carbon — thin wrapper around the git-based installer.
// Downloads the installer from the repo and runs it; the plugin itself
// lives in a git clone, not in this npm package.

"use strict";

const { spawnSync } = require("node:child_process");
const { mkdtempSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const pkg = require("../package.json");

// macOS and Linux run install.sh through bash. Windows runs install.ps1, the same
// bootstrap as `irm ... | iex`: it finds Git Bash, checks for the jq and sqlite3 that
// Git for Windows does not ship, printing the winget command for each missing one,
// then hands over to install.sh. Running install.sh straight from here stopped at
// the first missing one.
const WINDOWS = process.platform === "win32";

const INSTALL_URL = WINDOWS
  ? process.env.CLAUDE_CARBON_INSTALL_PS1_URL ||
    "https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.ps1"
  : process.env.CLAUDE_CARBON_INSTALL_URL ||
    "https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh";

const arg = process.argv[2];

if (arg === "--version" || arg === "-v") {
  console.log(pkg.version);
  process.exit(0);
}

if (arg === "--help" || arg === "-h") {
  console.log(`claude-carbon ${pkg.version}
Track the carbon footprint of your Claude Code sessions.

Usage: npx claude-carbon [--dry-run]

Downloads and runs the installer from:
  ${INSTALL_URL}

Options:
  --dry-run   Download the installer and print its path without running it
  --version   Print the wrapper version
  --help      Show this help

Docs: ${pkg.homepage}`);
  process.exit(0);
}

if (arg !== undefined && arg !== "--dry-run") {
  console.error(`Unknown option: ${arg}\nTry: npx claude-carbon --help`);
  process.exit(2);
}

async function main() {
  const res = await fetch(INSTALL_URL);
  if (!res.ok) {
    console.error(
      `Could not download the installer (HTTP ${res.status}): ${INSTALL_URL}`,
    );
    process.exit(1);
  }
  let script = await res.text();

  const file = join(
    mkdtempSync(join(tmpdir(), "claude-carbon-")),
    WINDOWS ? "install.ps1" : "install.sh",
  );
  // Windows PowerShell 5.1 reads a script file without a BOM in the ANSI code page
  if (WINDOWS && !script.startsWith("﻿")) script = `﻿${script}`;
  writeFileSync(file, script, { mode: 0o700 });

  if (arg === "--dry-run") {
    console.log(`Downloaded installer to ${file} (not run: --dry-run)`);
    process.exit(0);
  }

  // -ExecutionPolicy Bypass for this one process only, as `irm | iex` already is:
  // the default Restricted policy refuses any script file.
  const [cmd, args] = WINDOWS
    ? [
        "powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file],
      ]
    : ["bash", [file]];
  const { status, error } = spawnSync(cmd, args, { stdio: "inherit" });
  if (error) {
    console.error(`Could not run ${cmd}: ${error.message}`);
    process.exit(1);
  }
  process.exit(status ?? 1);
}

main().catch((err) => {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
});
