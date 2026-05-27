#!/bin/bash
# crystal-precommit-check.sh — backup gate (Decision Log #7) for projects
# with git. Catches the case where a workitem is flipped to status:done in
# an IDE bypassing the assistant — the PreToolUse hook never sees it, so
# this pre-commit check defends from the other side.
#
# Usage (in `.githooks/pre-commit` of a downstream project):
#
#   "$CRYSTAL_PRECOMMIT_CHECK" || exit 1
#
# Where $CRYSTAL_PRECOMMIT_CHECK points to this script in the installed
# plugin tree. See the guard SKILL.md "Crystal pre-commit backup" section
# for activation instructions.
#
# Behavior:
#   - Scans `git diff --cached --name-only` for files under the resolved
#     crystal root (default docs/tasks/).
#   - For each candidate workitem (folder-style or flat), reads the STAGED
#     version (`git show :path`) and checks: status:done + any `- [ ]` → block.
#   - Exit 0 on clean, 1 on drift (with stderr diagnostic per offending file).
#
# Fail-open at the boundaries — config errors, missing helpers, exotic
# paths: exit 0. Better to miss one commit than block legitimate work.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

# Honor enable flag.
if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

if ! command -v resolve_crystal_root >/dev/null 2>&1; then
  exit 0
fi

# Walk inside the repo root so git paths line up.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

crystal_root=$(resolve_crystal_root 2>/dev/null) || exit 0
# Convert absolute root → relative to repo root for matching git's output.
case "$crystal_root" in
  "$repo_root"/*) rel_root="${crystal_root#"$repo_root/"}" ;;
  *) rel_root="" ;;
esac
[ -z "$rel_root" ] && exit 0

staged=$(git diff --cached --name-only 2>/dev/null)
[ -z "$staged" ] && exit 0

drift=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Only consider candidate workitems under the crystal root.
  case "$f" in
    "$rel_root"/*.md|"$rel_root"/*/workitem.md) ;;
    *) continue ;;
  esac
  # Skip if not a workitem layout we recognize.
  base=$(basename "$f")
  case "$f" in
    "$rel_root"/*/workitem.md) layout="folder" ;;
    "$rel_root"/*.md)
      # flat layout: only direct .md children of $rel_root
      parent=$(dirname "$f")
      [ "$parent" = "$rel_root" ] || continue
      layout="flat"
      ;;
    *) continue ;;
  esac

  # Read STAGED content (git show :path) — this is what's about to commit.
  staged_content=$(git show ":$f" 2>/dev/null) || continue

  # Extract status from frontmatter.
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
  slug=""
  case "$layout" in
    folder) slug=$(basename "$(dirname "$f")") ;;
    flat)   slug="${base%.md}" ;;
  esac
  {
    printf '\n'
    printf 'crystal-precommit: 🚨 %s staged with status:done but %d unchecked item(s) remain.\n' "$slug" "$unchecked_count"
    printf '\n'
    printf '  File: %s\n' "$f"
    printf '\n'
    printf '  This commit would close the crystal while open obligations exist.\n'
    printf '  Either:\n'
    printf '    - Address the unchecked items (see Decision Log #9 five paths), then re-stage.\n'
    printf '    - Revert the status flip with: git checkout HEAD -- %s\n' "$f"
    printf '    - Use /vdm:crystal-cut <slug> to close interactively.\n'
    printf '\n'
  } >&2
done <<<"$staged"

exit "$drift"
