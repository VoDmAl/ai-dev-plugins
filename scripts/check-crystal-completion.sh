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

  unchecked_count=$(printf '%s\n' "$staged_content" \
    | grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' 2>/dev/null) || unchecked_count=0
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
