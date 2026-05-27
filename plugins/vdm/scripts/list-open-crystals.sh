#!/bin/bash
# list-open-crystals.sh — CLI helper for /vdm:docs-sync Phase 0 sweep.
# Implements the integration described in Decision Log #22 (point 1).
#
# Not a hook. Plain stdout text — formatted for inclusion in the docs-sync
# Phase 0 visibility section. Exit 0 always (visibility-only, never blocks).
#
# Output format (one line per active crystal):
#   → Open crystals: <slug-1> (N open), <slug-2> (M open)
# Empty output when no active crystals — Phase 0 then skips the section.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

active=$(find_workitems | filter_status "in-progress")
[ -z "$active" ] && exit 0

summaries=""
sep=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  slug=$(extract_slug "$f")
  n=$(count_unchecked "$f")
  summaries="${summaries}${sep}${slug} (${n} open)"
  sep=", "
done <<<"$active"

[ -z "$summaries" ] && exit 0

printf '→ Open crystals: %s\n' "$summaries"
exit 0
