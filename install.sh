#!/usr/bin/env bash
set -euo pipefail

# install.sh — One-line installer for claude-carbon.
# Usage: curl -fsSL https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh | bash

# `curl … | bash` leaves BASH_SOURCE unset, which `set -u` would treat as fatal.
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
# The installer is normally curl-piped into bash, with no clone on disk yet, so it
# carries a minimal copy of the two helpers it needs before the dependency check:
# the platform probe behind the install hints, and the Windows path conversion.
# tests/run-portability-tests.sh asserts this fallback agrees with the real
# scripts/portable-lib.sh on every input, so the two cannot drift apart.
if [ -n "$SCRIPT_SELF_DIR" ] && [ -f "${SCRIPT_SELF_DIR}/scripts/portable-lib.sh" ]; then
  # shellcheck source=scripts/portable-lib.sh
  . "${SCRIPT_SELF_DIR}/scripts/portable-lib.sh"
else
  # >>> portable-lib fallback
  case "${OSTYPE:-}" in
    darwin*)       CC_OS="darwin" ;;
    msys*|cygwin*) CC_OS="windows" ;;
    *)             CC_OS="linux" ;;
  esac
  cc_install_hint() {
    case "$CC_OS" in
      darwin) printf 'brew install %s' "$1" ;;
      windows)
        case "$1" in
          jq)      printf 'winget install jqlang.jq --source winget' ;;
          sqlite3) printf 'winget install SQLite.SQLite --source winget' ;;
          git)     printf 'winget install Git.Git --source winget' ;;
          node)    printf 'winget install OpenJS.NodeJS --source winget' ;;
          *)       printf 'winget install %s --source winget' "$1" ;;
        esac
        ;;
      *) printf 'apt install %s' "$1" ;;
    esac
  }
  cc_path() {
    local p="${1:-}"
    [ -n "$p" ] || return 0
    if [ "$CC_OS" != "windows" ]; then printf '%s' "$p"; return 0; fi
    case "$p" in
      [A-Za-z]:[\\/]*|*\\*)
        if command -v cygpath >/dev/null 2>&1; then
          cygpath -u "$p" 2>/dev/null || printf '%s' "$p"
        else
          p="${p//\\//}"
          case "$p" in
            [A-Za-z]:/*) printf '/%s%s' "$(printf '%s' "${p%%:*}" | tr 'A-Z' 'a-z')" "${p#*:}" ;;
            *) printf '%s' "$p" ;;
          esac
        fi
        ;;
      *) printf '%s' "$p" ;;
    esac
  }
  # <<< portable-lib fallback
fi

INSTALL_DIR="$(cc_path "${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}")"
# Honour Claude Code's own CLAUDE_CONFIG_DIR so a second environment
# (e.g. CLAUDE_CONFIG_DIR=~/.claude-work claude) installs into its own dir.
CONFIG_DIR="$(cc_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"

echo ""
echo "  claude-carbon installer"
echo "  Track the carbon footprint of your Claude Code sessions."
echo ""

# 1. Check dependencies
for cmd in jq sqlite3 git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." >&2
    echo "  Install with: $(cc_install_hint "$cmd")" >&2
    [ "$CC_OS" = "windows" ] && echo "  Then reopen this shell so PATH picks it up." >&2
    exit 1
  fi
done

# 2. Clone (fresh) or update (existing, dirty-safe against locally-edited data files)
WAS_UPDATE=0
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  WAS_UPDATE=1
  export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20
  # The README invites editing data/factors.json, which breaks `git pull --ff-only`.
  # Stash just those two tracked files, pull, restore; on conflict keep upstream + back up theirs.
  STASHED=0
  if [ -n "$(git -C "$INSTALL_DIR" status --porcelain -- data/factors.json data/prices.json 2>/dev/null || true)" ]; then
    if git -C "$INSTALL_DIR" stash push --quiet -m "claude-carbon-install" -- data/factors.json data/prices.json 2>/dev/null; then
      STASHED=1
    fi
  fi
  git -C "$INSTALL_DIR" pull --ff-only --quiet \
    || echo "  WARNING: could not fast-forward. Resolve with: cd $INSTALL_DIR && git status"
  if [ "$STASHED" = "1" ]; then
    if ! git -C "$INSTALL_DIR" stash pop --quiet 2>/dev/null; then
      for f in data/factors.json data/prices.json; do
        git -C "$INSTALL_DIR" show "stash@{0}:$f" > "${INSTALL_DIR}/${f}.local.bak" 2>/dev/null || true
      done
      git -C "$INSTALL_DIR" checkout --quiet HEAD -- data/factors.json data/prices.json 2>/dev/null || true
      git -C "$INSTALL_DIR" stash drop --quiet 2>/dev/null || true
      echo "  Your local factors/prices edits were saved to *.local.bak (re-apply manually)."
    fi
  fi
else
  echo "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if ! CLONE_ERR="$(git clone --quiet https://github.com/gwittebolle/claude-carbon.git "$INSTALL_DIR" 2>&1)"; then
    [ -n "$CLONE_ERR" ] && echo "$CLONE_ERR" >&2
    echo "ERROR: could not clone claude-carbon." >&2
    # Git for Windows verifies TLS against its own bundled CA list, which does not
    # know the root a TLS-inspecting proxy or antivirus re-signs HTTPS with. The
    # Windows certificate store does, or the user could not browse either.
    if [ "$CC_OS" = "windows" ] \
       && printf '%s' "$CLONE_ERR" | grep -q "unable to get local issuer certificate" \
       && [ "$(git config --get http.sslBackend 2>/dev/null || true)" != "schannel" ]; then
      echo "  Something on this machine re-signs HTTPS traffic with a root that git's bundled" >&2
      echo "  CA list does not trust. Point git at the Windows certificate store instead;" >&2
      echo "  verification stays on, only the trust store changes:" >&2
      echo "    git config --global http.sslBackend schannel" >&2
      echo "  Then rerun this installer." >&2
    fi
    exit 1
  fi
fi

# 3. Run setup (creates DB, backfills history)
echo ""
CLAUDE_CARBON_INSTALLER=1 bash "$INSTALL_DIR/scripts/setup.sh"

# 3b. On update, re-price stored history with the new factors (CO2-only; cost left intact).
if [ "$WAS_UPDATE" = "1" ]; then
  DB_PATH="$(cc_path "${CLAUDE_CARBON_DB:-${CONFIG_DIR}/claude-carbon/carbon.db}")"
  if [ -f "$DB_PATH" ]; then
    bash "$INSTALL_DIR/scripts/recompute.sh" || echo "  (history not re-priced; see message above)"
  fi
fi

# 4. Configure Claude Code settings and install the /carbon-* commands
echo ""
echo "Configuring Claude Code..."

bash "$INSTALL_DIR/scripts/configure-settings.sh"

echo ""
echo "Done. Restart Claude Code to see your CO2 in the status line."
echo ""
