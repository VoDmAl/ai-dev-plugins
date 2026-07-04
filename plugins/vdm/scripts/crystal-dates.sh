#!/bin/bash
# crystal-dates.sh — derive (created, last-updated) for a file, git-first with a
# non-git filesystem fallback. Shared by crystal-grow (single legacy-doc import)
# and crystal-migrate (batch scan) so both stamp historically-accurate dates
# rather than the import moment.
#
# Rule (crystal-grow "Two rules that bite" + crystal-migrate DL #6 / Sidetrack #3):
#   created      ← first commit that ADDED the file  (git) | birthtime (fs)
#   last-updated ← last commit that TOUCHED the file  (git) | mtime     (fs)
#
# The non-git fallback is the whole point of Sidetrack #3: the user has projects
# without git (cs:p1-85f4), so date derivation must not depend on a repo.
#
# Usage:   crystal-dates.sh <file>
# Output:  "<created>\t<last-updated>"  (YYYY-MM-DD each; either may be empty if
#          wholly underivable — the caller decides the ultimate fallback).
#
# Sourced form: `. crystal-dates.sh` exposes derive_dates() without running.
set -u

_fs_mtime() {
  # Last-modification date, YYYY-MM-DD. GNU coreutils first, then BSD/macOS.
  local f="$1" out
  if out=$(stat -c %y "$f" 2>/dev/null); then
    printf '%s\n' "${out%% *}"
  elif out=$(stat -f %Sm -t %Y-%m-%d "$f" 2>/dev/null); then
    printf '%s\n' "$out"
  fi
}

_fs_birth() {
  # Birth (creation) date, YYYY-MM-DD, with graceful degradation to mtime when
  # the filesystem can't report a birth time.
  local f="$1" out
  # GNU coreutils: %W is birth epoch; 0 (or empty) means "unknown".
  if out=$(stat -c %W "$f" 2>/dev/null) && [ "${out:-0}" -gt 0 ] 2>/dev/null; then
    if date -d "@$out" +%F 2>/dev/null; then
      return 0
    fi
  fi
  # BSD/macOS: %SB is the birth time.
  if out=$(stat -f %SB -t %Y-%m-%d "$f" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  # Birth unknown → mtime is the most honest available proxy.
  _fs_mtime "$f"
}

derive_dates() {
  # derive_dates <file> — prints "<created>\t<last-updated>".
  local file="$1" created="" updated="" dir base
  [ -f "$file" ] || { printf '\t\n'; return 0; }
  dir=$(dirname "$file")
  base=$(basename "$file")
  # git branch: run from the file's directory so both the work-tree probe and
  # the path-scoped log resolve regardless of the caller's CWD.
  if command -v git >/dev/null 2>&1 && \
     ( cd "$dir" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    created=$( cd "$dir" 2>/dev/null && git log --diff-filter=A --format=%as -- "$base" 2>/dev/null | tail -n 1 )
    updated=$( cd "$dir" 2>/dev/null && git log -1 --format=%as -- "$base" 2>/dev/null )
  fi
  # Fall back per-field: an untracked file inside a git repo yields empty git
  # dates, so the filesystem still has to answer.
  [ -z "$created" ] && created=$(_fs_birth "$file")
  [ -z "$updated" ] && updated=$(_fs_mtime "$file")
  printf '%s\t%s\n' "$created" "$updated"
}

# Executed directly (not sourced) → act as a CLI over $1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -ge 1 ] || { echo "usage: crystal-dates.sh <file>" >&2; exit 2; }
  derive_dates "$1"
fi
