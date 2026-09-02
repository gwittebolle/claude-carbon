#!/usr/bin/env bash
# equiv-lib.sh — shared locale detection for the report equivalence sets.
# Sourced by scripts/generate-report.sh and the /carbon-report skill; the
# factors themselves live in data/factors.json ("equivalences", one set per
# locale). Policy: METHODOLOGY.md "Locale detection".

# shellcheck source=scripts/portable-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-lib.sh"

# Echoes the equivalence set for this user: "fr", "us" or "world".
# CLAUDE_CARBON_LOCALE forces a set (accepts a set name or a locale string).
# Must run before any `export LC_ALL=C`, which would mask the user's locale.
detect_equiv_set() {
  local candidate resolved=""
  for candidate in "${CLAUDE_CARBON_LOCALE:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    case "$candidate" in
      # C and POSIX are sentinels scripts export to stabilize parsing, not
      # user locales: skip them so a real locale further down still speaks.
      "" | C | C.* | POSIX | POSIX.*) continue ;;
      *) resolved="$candidate"; break ;;
    esac
  done
  if [ -z "$resolved" ]; then
    # Hooks and GUI-launched shells often carry no LANG at all, and no Windows
    # shell sets one: fall back to the OS-level locale (AppleLocale on macOS,
    # the International registry key on Windows).
    resolved="$(cc_system_locale)"
  fi
  # Windows and macOS spell the locale with a hyphen ("fr-FR", "en-US") where a
  # POSIX LANG uses an underscore; the patterns below accept both spellings.
  case "$resolved" in
    # An undetected locale falls back to the French set, this tool's original
    # default: a detection failure must reproduce the pre-locale behavior, not
    # silently switch factor sets. Non-France francophone locales (fr_BE,
    # fr_CA, fr_CH) deliberately fall through to the world set.
    "" | fr | fr.* | fr_FR* | fr-FR*) echo "fr" ;;
    us | US | *_US* | *-US*) echo "us" ;;
    *) echo "world" ;;
  esac
}
