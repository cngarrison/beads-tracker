#!/usr/bin/env bash
# scripts/release-notes.sh — Markdown release notes from the commits since the previous tag
#
# Usage:
#   ./scripts/release-notes.sh v1.2.3            # changes from the previous v* tag to v1.2.3
#   ./scripts/release-notes.sh v1.2.3 v1.2.0     # changes from v1.2.0 to v1.2.3
#   ./scripts/release-notes.sh HEAD              # preview the next release
#
# Used by .github/workflows/release.yml as the GitHub release body. Work is squashed into
# commits that each describe one change (CLAUDE.md), so each commit becomes one entry:
# grouped by its conventional prefix (feat:, fix:, perf:, ...), with its message body as the
# detail. Merge commits, version bumps and Co-Authored-By/Signed-off-by trailers are left out.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

TO="${1:?Usage: $0 <tag-or-ref> [previous-tag]}"
FROM="${2:-$(git describe --tags --abbrev=0 --match 'v*' "${TO}^" 2>/dev/null || true)}"
RANGE="${FROM:+${FROM}..}${TO}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-notes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Section order and titles; anything without a known prefix goes to "other".
SECTIONS="feat fix perf ci docs other"
title() {
  case "$1" in
    feat)  echo "Features" ;;
    fix)   echo "Fixes" ;;
    perf)  echo "Performance" ;;
    ci)    echo "Build and release" ;;
    docs)  echo "Documentation" ;;
    *)     echo "Other changes" ;;
  esac
}

for sha in $(git rev-list --no-merges --reverse "$RANGE"); do
  subject=$(git log -1 --format=%s "$sha")
  case "$subject" in "chore: bump version"*) continue ;; esac

  # "type(scope)!: text" → section + text
  type=$(printf '%s' "$subject" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p')
  text=$(printf '%s' "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //')
  case "$type" in
    feat|fix|perf|ci|docs) section="$type" ;;
    build)                 section="ci" ;;
    *)                     section="other"; [ -n "$type" ] || text="$subject" ;;
  esac
  # Capitalise the first letter, except the `bd` command name
  case "$text" in
    "bd "*) ;;
    *) text="$(printf '%s' "$text" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$text" | cut -c2-)" ;;
  esac

  # Body without trailers, indented two spaces so it continues the list item
  body=$(git log -1 --format=%b "$sha" \
    | grep -viE '^(co-authored-by|signed-off-by):' \
    | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' \
    | sed 's/^/  /; s/^  $//' || true)

  {
    printf -- '- **%s** (%s)\n' "$text" "$(git rev-parse --short "$sha")"
    if [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
      printf '\n%s\n\n' "$body"
    fi
  } >> "$WORK/$section"
done

if [ -n "$FROM" ]; then
  echo "## Changes since $FROM"
else
  echo "## Changes"
fi
found=0
for s in $SECTIONS; do
  [ -s "$WORK/$s" ] || continue
  found=1
  printf '\n### %s\n\n' "$(title "$s")"
  cat "$WORK/$s"
done
[ "$found" = 1 ] || printf '\nNo changes recorded.\n'
