#!/bin/bash
# fffd-precommit-check.sh — refuse a commit whose staged content carries
# U+FFFD, the replacement character.
#
# U+FFFD is what a truncated multi-byte codepoint decodes to. A batch write
# across many files is how it arrives: one interrupted Cyrillic letter becomes
# two of these, everything around it looks fine, and nothing reports it.
# Origin incident (commit ff78039, 2026-04-24): 21 corruption points across 11
# files, noticed three weeks later.
#
# Two surfaces, on purpose:
#
#   * `git-guard-prepare` carries the same check, and covers every commit the
#     assistant prepares — which is where the corruption is produced. It has no
#     installation step.
#   * this script covers the other side: a commit made by hand or from an IDE,
#     which the helper never sees. It DOES need installing, once per clone, and
#     that is its weakness: an uninstalled hook looks exactly like a clean one.
#     Whether the chain resolves is a property of the machine, not of the
#     repository — check it with a tool that inspects clones.
#
# Usage in a downstream project's `.githooks/pre-commit`:
#
#   "$HOME"/.claude/plugins/*/vdm-git/*/scripts/fffd-precommit-check.sh || exit 1
#
# or, resolving the installed path yourself and keeping the failure loud.
#
# Behavior: scans `git diff --cached` for added/changed files, reads the STAGED
# blob (never the working tree — the staged content is what would be committed),
# and blocks on any match.
#
# A file git itself treats as binary (`-` in `--numstat`) is not read: in a PDF
# or an image the bytes EF BF BD are data, not a decoded letter, and a gate that
# blocks a legitimate attachment is one that gets `--no-verify` as a habit. The
# verdict is git's own — the same one `git diff` prints as "Binary files differ"
# — so a project that needs a text-looking file skipped marks it `binary` in
# `.gitattributes`, and git and this check agree by construction.
#
# Renames are split with `--no-renames`: a `git mv` shows up as R, and a filter
# of `ACM` without it drops the destination — a file moved and damaged in the
# same commit went through unread.
#
# Exit: 0 clean / 1 corruption found.

set -u

command -v git >/dev/null 2>&1 || {
  echo "fffd-precommit-check: git not found — cannot inspect the index" >&2
  exit 1
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "fffd-precommit-check: not a git repository" >&2
  exit 1
}
cd "$repo_root" || exit 1

# Two properties are needed at once here, and the obvious way to get one
# destroys the other:
#
#   * `-z` so a path containing a newline cannot split into two names, and
#   * the EXIT STATUS of `git diff`, because an empty list from a failed
#     command is the exact shape of a check that silently did not run.
#
# `staged=$(git diff … -z …)` gives the status and DROPS every NUL, silently
# concatenating the file names into one string that matches no file — the check
# then passes on a corrupt index. (It was written that way first; the test that
# stages a second file is what caught it, while the single-file case passed by
# luck.) A pipeline preserves the NULs but hides the status behind `grep`. So:
# via a temporary file, which keeps both.
list=$(mktemp 2>/dev/null) || {
  echo "fffd-precommit-check: cannot create a temporary file — refusing" >&2
  exit 1
}
trap 'rm -f "$list"' EXIT

if ! git diff --cached -z --numstat --no-renames --diff-filter=ACM > "$list" 2>/dev/null; then
  echo "fffd-precommit-check: could not read the index — refusing rather than passing" >&2
  exit 1
fi

# Each entry is `<added>\t<deleted>\t<path>`; a binary file has `-` for both.
corrupt=()
while IFS= read -r -d '' entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    -$'\t'-$'\t'*) continue ;;
  esac
  f="${entry#*$'\t'*$'\t'}"
  [ -n "$f" ] || continue
  if git show ":$f" 2>/dev/null | LC_ALL=C grep -q $'\xef\xbf\xbd' 2>/dev/null; then
    corrupt+=("$f")
  fi
done < "$list"

if [ ${#corrupt[@]} -gt 0 ]; then
  {
    echo "🔴 BLOCKED: U+FFFD (replacement character) in staged content:"
    for f in "${corrupt[@]}"; do
      echo "  • $f"
      git show ":$f" 2>/dev/null | LC_ALL=C grep -n $'\xef\xbf\xbd' 2>/dev/null \
        | head -3 | sed 's/^/      /'
    done
    echo ""
    echo "U+FFFD usually means a batch write truncated a multi-byte codepoint."
    echo "Restore the missing characters before committing."
    echo ""
    echo "If the character is genuinely part of the content: git commit --no-verify"
  } >&2
  exit 1
fi

exit 0
