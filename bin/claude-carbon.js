#!/usr/bin/env node
// npx claude-carbon — thin wrapper around the git-based installer.
// Downloads install.sh from the repo and runs it; the plugin itself
// lives in a git clone, not in this npm package.

"use strict";

const { spawnSync } = require("node:child_process");
const { existsSync, mkdtempSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const pkg = require("../package.json");

// The installer, the hooks and the status line are all bash. On macOS and Linux
// that is simply "bash"; on Windows it is the bash.exe that ships with Git for
// Windows, which is also the shell Claude Code itself spawns for hooks and the
// status line. Returns null when nothing usable is found.
function findBash() {
  if (process.platform !== "win32") return "bash";

  const candidates = [
    // Same variable Claude Code reads, so a user who already pointed Claude Code
    // at a non-default Git install does not have to say it twice.
    process.env.CLAUDE_CODE_GIT_BASH_PATH,
    join(process.env.ProgramFiles || "C:\\Program Files", "Git", "bin", "bash.exe"),
    join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Git", "bin", "bash.exe"),
    join(process.env.LOCALAPPDATA || "", "Programs", "Git", "bin", "bash.exe"),
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }

  // Last resort: ask PATH. C:\Windows\System32\bash.exe is excluded on purpose —
  // that one is the WSL launcher, and running the installer through it would set
  // claude-carbon up inside the Linux distribution instead of on Windows.
  const where = spawnSync("where.exe", ["bash"], { encoding: "utf8" });
  if (where.status === 0 && where.stdout) {
    for (const line of where.stdout.split(/\r?\n/)) {
      const path = line.trim();
      if (path && !/\\System32\\/i.test(path) && existsSync(path)) return path;
    }
  }

  return null;
}

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
  const bash = findBash();
  if (!bash) {
    console.error(
      "claude-carbon runs on bash. On Windows that means Git for Windows, which\n" +
        "Claude Code also uses for its own Bash tool.\n\n" +
        "  Install it:  winget install Git.Git\n" +
        "  Or, if it is already installed somewhere unusual, point at it:\n" +
        '    set CLAUDE_CODE_GIT_BASH_PATH="C:\\Program Files\\Git\\bin\\bash.exe"',
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

  const { status, error } = spawnSync(bash, [file], { stdio: "inherit" });
  if (error) {
    console.error(`Could not run ${bash}: ${error.message}`);
    process.exit(1);
  }
  process.exit(status ?? 1);
}

main().catch((err) => {
  console.error(err && err.message ? err.message : String(err));
  process.exit(1);
});
