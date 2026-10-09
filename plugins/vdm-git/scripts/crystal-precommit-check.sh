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
#   - Scans the staged paths for files under every resolved crystal root
#     (default docs/tasks/; `crystal.paths`, or each `tasks/` the scan finds).
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

if ! command -v resolve_crystal_roots >/dev/null 2>&1; then
  exit 0
fi

# Walk inside the repo root so git paths line up.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

# Every crystal root, relative to the repo root for matching git's output. Not
# "the" root: resolve_crystal_root is the first of them, and in a repository
# with two a `done` with open items under the second went through unchecked
# (Sidetrack #11, cc-vdm-plugins → docs/tasks/crystal-wake/workitem.md). Roots
# outside the repository cannot hold a staged path and are dropped.
rel_roots=""
while IFS= read -r r; do
  case "$r" in
    "$repo_root"/*) rel_roots="${rel_roots}${r#"$repo_root/"}
" ;;
  esac
done <<EOF
$(resolve_crystal_roots 2>/dev/null)
EOF
[ -z "$rel_roots" ] && exit 0

# -z: in line form git quotes a path holding any byte outside ASCII, and the
# quoted line matched none of the patterns below — a crystal with a Cyrillic
# slug went through as `done` with open items, unchecked. `tr` in the C locale,
# because in a UTF-8 one macOS `tr` stops at the first name that is not UTF-8
# (Sidetrack #9, cc-vdm-plugins → docs/tasks/crystal-wake/workitem.md).
staged=$(git diff --cached --name-only -z 2>/dev/null | LC_ALL=C tr '\0' '\n')
[ -z "$staged" ] && exit 0

drift=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Only candidate workitems under a crystal root, in a layout we recognize:
  # folder-style at any depth below it, flat only as a direct .md child. A path
  # that fails one root is tried against the next — a flat file directly under
  # an inner root is still below the outer one, just not a direct child of it.
  layout=""
  while IFS= read -r rel_root; do
    [ -n "$rel_root" ] || continue
    case "$f" in
      "$rel_root"/*/workitem.md) layout="folder" ;;
      "$rel_root"/*.md) [ "${f%/*}" = "$rel_root" ] && layout="flat" ;;
    esac
    [ -n "$layout" ] && break
  done <<EOF
$rel_roots
EOF
  [ -n "$layout" ] || continue
  base=$(basename "$f")

  # Read STAGED content (git show :path) — this is what's about to commit.
  staged_content=$(git show ":$f" 2>/dev/null) || continue

  # Extract status from frontmatter. A here-string, not `printf | awk`: awk
  # exits at the status line, and where SIGPIPE is ignored — seen 2026-10-02 on
  # a `!` commit from Claude Code's prompt — a printf still writing a workitem
  # larger than the pipe buffer prints "write error: Broken pipe" beside a
  # correct verdict.
  status=$(awk '
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
  ' <<<"$staged_content")
  [ "$status" = "done" ] || continue

  # Fenced blocks are excluded: a `- [ ]` inside ``` is the format being
  # documented, not a promise being made. The repo's own gate and the lib
  # learned that on 2026-09-05; this copy kept a plain grep until a machine-wide
  # hook ran it on every commit (2026-10-08). The same awk as
  # scripts/check-crystal-completion.sh, and tests/gates.test.sh holds all four
  # copies to one count. A here-string, for the reason given above.
  unchecked_count=$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ { n++ }
    END { print n+0 }
  ' <<<"$staged_content" 2>/dev/null) || unchecked_count=0
  case "$unchecked_count" in ''|*[!0-9]*) unchecked_count=0 ;; esac
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
