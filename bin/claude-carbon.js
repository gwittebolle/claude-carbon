#!/usr/bin/env node
// npx claude-carbon — thin wrapper around the git-based installer.
// Downloads install.sh from the repo and runs it; the plugin itself
// lives in a git clone, not in this npm package.

"use strict";

const { spawnSync } = require("node:child_process");
const { mkdtempSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const pkg = require("../package.json");

const INSTALL_URL =
  process.env.CLAUDE_CARBON_INSTALL_URL ||
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
  if (process.platform === "win32") {
    console.error(
      "claude-carbon needs bash (macOS or Linux); Windows is not supported yet.",
    );
    process.exit(1);
  }

  const res = await fetch(INSTALL_URL);
  if (!res.ok) {
    console.error(
      `Could not download the installer (HTTP ${res.status}): ${INSTALL_URL}`,
    );
    process.exit(1);
  }
  const script = await res.text();

  const file = join(
    mkdtempSync(join(tmpdir(), "claude-carbon-")),
    "install.sh",
  );
  writeFileSync(file, script, { mode: 0o700 });

  if (arg === "--dry-run") {
    console.log(`Downloaded installer to ${file} (not run: --dry-run)`);
    process.exit(0);
  }

  const { status, error } = spawnSync("bash", [file], { stdio: "inherit" });
  if (error) {
    console.error(`Could not run bash: ${error.message}`);
    process.exit(1);
  }
  process.exit(status ?? 1);
}

main().catch((err) => {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
});
