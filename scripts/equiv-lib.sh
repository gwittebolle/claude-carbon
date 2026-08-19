#!/usr/bin/env bash
# equiv-lib.sh — shared locale detection for the report equivalence sets.
# Sourced by scripts/generate-report.sh and the /carbon-report skill; the
# factors themselves live in data/factors.json ("equivalences", one set per
# locale). Policy: METHODOLOGY.md "Locale detection".

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
  if [ -z "$resolved" ] && [ "$(uname)" = "Darwin" ]; then
    # Hooks and GUI-launched shells often carry no LANG at all
    resolved="$(defaults read -g AppleLocale 2>/dev/null || true)"
  fi
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
