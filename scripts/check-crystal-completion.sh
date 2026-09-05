#!/bin/bash
# check-crystal-completion.sh — pre-commit gate for THIS dev repo's crystal
# workitems. Mirrors what vdm-git/scripts/crystal-precommit-check.sh does
# for downstream projects, but tailored to this repo:
#
#   - Crystal root is hardcoded to `docs/tasks/` (matches CLAUDE.md
#     convention). No config lookup; this repo doesn't override.
#   - No dependency on the vdm config helpers — the gate must run even if
#     the plugins' lib/ is mid-refactor.
#
# Scope: dev-time only. Runs from .githooks/pre-commit alongside
# check-lib-sync.sh, check-version-bump.sh, check-skill-paths.sh.
#
# Behavior: for each staged file matching `docs/tasks/**/workitem.md` or
# `docs/tasks/*.md`, read the STAGED version (`git show :path`) and check:
# frontmatter `status: done` + any `- [ ]` checkbox → block.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

CRYSTAL_ROOT="docs/tasks"
staged=$(git diff --cached --name-only 2>/dev/null || true)

if [ -z "$staged" ]; then
  exit 0
fi

drift=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Only candidate workitems under the crystal root.
  case "$f" in
    "$CRYSTAL_ROOT"/*/workitem.md) layout="folder" ;;
    "$CRYSTAL_ROOT"/*.md)
      # Flat layout: only direct .md children of CRYSTAL_ROOT.
      parent=$(dirname "$f")
      [ "$parent" = "$CRYSTAL_ROOT" ] || continue
      layout="flat"
      ;;
    *) continue ;;
  esac

  staged_content=$(git show ":$f" 2>/dev/null) || continue

  status=$(printf '%s\n' "$staged_content" | awk '
    BEGIN { c = 0 }
    /^---[[:space:]]*$/ { c++; if (c == 2) exit; next }
    c == 1 {
      if (match($0, /^status:[[:space:]]*/)) {
        val = substr($0, RLENGTH + 1)
        sub(/[[:space:]]+$/, "", val)
        gsub(/^["\047]|["\047]$/, "", val)
        print val
        exit
      }
    }
  ')
  [ "$status" = "done" ] || continue

  # A DELIBERATE third copy of "what is an unchecked obligation", not an
  # accident. The header of this file states the reason: this gate carries no
  # dependency on the plugins' lib/, so that it keeps working while that lib is
  # mid-refactor — and a pre-commit gate that stops working is a gate that
  # silently reports success. Sourcing lib/crystal-path.sh here would couple the
  # guard to the code it guards, which is the one coupling worth paying to avoid.
  #
  # What was actually wrong in the 2026-09-05 incident was not the duplication —
  # it was that all three copies DIVERGED FROM INTENT TOGETHER (none skipped
  # fenced examples) and nothing compared them. The fix for that is a conformance
  # test, not consolidation: tests/gates.test.sh feeds one fixture set to all
  # three implementations and fails if any disagrees.
  #
  # Fenced blocks are excluded: a `- [ ]` inside ``` is the format being
  # documented, not a promise being made.
  unchecked_count=$(printf '%s\n' "$staged_content" | awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ { n++ }
    END { print n+0 }
  ' 2>/dev/null) || unchecked_count=0
  case "$unchecked_count" in ''|*[!0-9]*) unchecked_count=0 ;; esac
  [ "${unchecked_count:-0}" -gt 0 ] || continue

  drift=1
  case "$layout" in
    folder) slug=$(basename "$(dirname "$f")") ;;
    flat)   slug=$(basename "$f" .md) ;;
  esac
  {
    printf '\n'
    printf 'crystal-completion: 🚨 %s staged with status:done but %d unchecked item(s) remain.\n' "$slug" "$unchecked_count"
    printf '\n'
    printf '  File: %s\n' "$f"
    printf '\n'
    printf '  Either:\n'
    printf '    - Address each unchecked item (Decision Log #9 five paths), re-stage.\n'
    printf '    - Revert the status flip: git checkout HEAD -- %s\n' "$f"
    printf '\n'
  } >&2
done <<<"$staged"

if [ "$drift" -eq 0 ]; then
  echo "crystal-completion: ✓ no workitem staged with status:done while unchecked items remain"
fi

exit "$drift"
