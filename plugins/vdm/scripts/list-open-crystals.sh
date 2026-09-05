#!/bin/bash
# list-open-crystals.sh — CLI helper for /vdm:docs-sync Phase 0 sweep.
# Implements the integration described in Decision Log #22 (point 1) and the
# multi-root output format from crystal-multi-root DL #13.
#
# Not a hook. Plain stdout text — formatted for inclusion in the docs-sync
# Phase 0 visibility section. Exit 0 always (visibility-only, never blocks).
#
# Output (single-root):
#   → Open crystals: <slug-1> (N open), <slug-2> (M open)
#
# Output (multi-root):
#   → Open crystals:
#     - <root-1>: <slug-a> (N), <slug-b> (M)
#     - <root-2>: <slug-c> (K)
#
# An audit line appears when any workitem has a non-canonical status:
#   ⚠ Non-canonical statuses: N workitems. /vdm:crystal-cave to triage.
#
# Empty output when no active crystals AND no non-canonical drift — Phase 0
# then skips the section entirely.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

# Warm the root cache in THIS shell before anything fans out into subshells.
# The memo inside resolve_crystal_roots is process-scoped, and every use of it
# below sits inside `$(...)`, `< <(...)` or a pipeline — a subshell inherits the
# cache but cannot fill it. Without this line the tree is rescanned once per
# call site (measured: 7× per hook run on an 11-root vault).
if command -v vdm_prime_crystal_roots >/dev/null 2>&1; then
  vdm_prime_crystal_roots
fi

all_items=$(find_workitems)
[ -z "$all_items" ] && exit 0

active=$(printf '%s\n' "$all_items" | filter_status "in-progress")
non_canon_count=$(printf '%s\n' "$all_items" | audit_non_canonical | grep -c '.' 2>/dev/null || true)
non_canon_count=${non_canon_count:-0}

if [ -n "$active" ]; then
  summary=$(printf '%s\n' "$active" | format_active_summary)
  if [ -n "$summary" ]; then
    case "$summary" in
      "  - "*)
        # Multi-root multi-line format
        printf '→ Open crystals:\n%s\n' "$summary"
        ;;
      *)
        # Single-root flat format
        printf '→ Open crystals: %s\n' "$summary"
        ;;
    esac
  fi
fi

if [ "$non_canon_count" -gt 0 ]; then
  printf '⚠ Non-canonical statuses: %d workitems. /vdm:crystal-cave to triage.\n' "$non_canon_count"
fi

exit 0
