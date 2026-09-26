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
# Sourced form: `. crystal-dates.sh` exposes derive_dates() and, for a list of
# files under one directory, derive_dates_batch() — without running.
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
  #
  # One `git log` answers both, run from the file's directory so the path
  # resolves regardless of the caller's CWD: the first commit it lists is the
  # last to touch the file, and the oldest one whose status for the file is A
  # is the one that added it — what `git log -1` and `--diff-filter=A | tail`
  # answered as two logs, a work-tree probe, a tail, a dirname and a basename
  # (Sidetrack #15, cc-vdm-plugins → docs/tasks/crystal-wake/workitem.md). The
  # log is read NUL-separated, token by token: headers, then a status and its
  # path in turn (a merge that changes the file lists a header and nothing
  # else). The path is never compared — with one file in the pathspec every
  # status is about that file — and it is skipped by position, not by spelling,
  # so a name that starts with `@` is still a name. A `\n` that git puts before
  # the first status of a commit is dropped there. Outside a work tree git
  # answers nothing, and the filesystem does, as before.
  local file="$1" created="" updated="" dir base tok date="" st="" want=status
  [ -f "$file" ] || { printf '\t\n'; return 0; }
  case "$file" in
    */*) dir="${file%/*}"; [ -n "$dir" ] || dir="/" ;;
    *)   dir="." ;;
  esac
  base="${file##*/}"
  if command -v git >/dev/null 2>&1; then
    while IFS= read -r -d '' tok; do
      if [ "$want" = path ]; then
        want=status; [ "$st" = A ] && created="$date"; continue
      fi
      tok="${tok#$'\n'}"
      case "$tok" in
        @*) date="${tok#@}"; [ -n "$updated" ] || updated="$date" ;;
        ?*) st="$tok"; want=path ;;
      esac
    done < <(git -C "$dir" log -z --format='@%as' --name-status -- "$base" 2>/dev/null)
  fi
  # Fall back per-field: an untracked file inside a git repo yields empty git
  # dates, so the filesystem still has to answer.
  [ -z "$created" ] && created=$(_fs_birth "$file")
  [ -z "$updated" ] && updated=$(_fs_mtime "$file")
  printf '%s\t%s\n' "$created" "$updated"
}

derive_dates_batch() {
  # derive_dates_batch <dir> — reads paths under <dir> on stdin, spelled as
  # "<dir>/<rel>" (crystal-migrate-scan's enumerate), and prints
  # "<path>\t<created>\t<last-updated>" for each, in order: derive_dates's
  # answers, without a process per file where that stays exact.
  #
  # Exact where the history reachable from HEAD has no merge. There git has
  # nothing to simplify, so the commits that touch a file are the same whether
  # the log is asked about the file or about its directory; renames are off,
  # and an add is an add in both, as it is for a one-file pathspec, which never
  # sees the other half of a rename. A merge breaks this in practice, not only
  # in theory: a merge that changes a file prints no status line, so the
  # directory's log has nothing to date the file by, while the file's own log
  # names the merge as its last change. Forced through the ten repositories
  # with merges on this machine, the batch moved last-updated for 2 files of
  # 522. Every other file — history with a merge (92 of 170 repositories here
  # have one), a nested repository, a file git has no history for — is
  # answered by derive_dates itself.
  local dir="$1" f line out prefix="" nested="" answers=""
  local files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  if command -v git >/dev/null 2>&1 \
     && out=$(git -C "$dir" rev-parse --show-toplevel --show-prefix 2>/dev/null) \
     && [ -z "$(git -C "$dir" rev-list --merges --max-count=1 HEAD 2>/dev/null)" ]; then
    case "$out" in *$'\n'*) prefix="${out#*$'\n'}" ;; esac
    nested=$(find "$dir" -mindepth 2 \( -name node_modules -o -name vendor \) -prune \
               -o -name .git -prune -print 2>/dev/null)
    # The log comes NUL-separated, so no name is quoted, and one `tr` in the C
    # locale turns it into lines: NUL ends a token, and a newline — git's own,
    # before the first status of a commit, or one inside a name — becomes \001.
    # A token is then a header, a status, or the path that follows a status;
    # the \001 is dropped only where a status or a header stands, so a name is
    # compared exactly as git spelled it.
    answers=$(_VDM_DIR="$dir" _VDM_PREFIX="$prefix" _VDM_NESTED="$nested" LC_ALL=C awk '
      BEGIN {
        dir = ENVIRON["_VDM_DIR"]; prefix = ENVIRON["_VDM_PREFIX"]
        nn = split(ENVIRON["_VDM_NESTED"], nest, "\n")
        for (i = 1; i <= nn; i++) sub(/\/\.git$/, "/", nest[i])
      }
      FILENAME == ARGV[1] {
        if (want_path) {
          want_path = 0
          if (!($0 in upd)) upd[$0] = date
          if (st == "A") cre[$0] = date
          next
        }
        tok = $0; if (substr(tok, 1, 1) == "\001") tok = substr(tok, 2)
        if (substr(tok, 1, 1) == "@") { date = substr(tok, 2); next }
        if (tok != "") { st = tok; want_path = 1 }
        next
      }
      {
        f = $0; key = ""
        if (substr(f, 1, length(dir) + 1) == dir "/") key = prefix substr(f, length(dir) + 2)
        for (i = 1; i <= nn; i++) if (nest[i] != "/" && substr(f, 1, length(nest[i])) == nest[i]) key = ""
        if (key != "" && (key in upd) && (key in cre)) print f "\t" cre[key] "\t" upd[key]
        else print f "\t?"
      }
    ' <(git -C "$dir" log -z --no-renames --format='@%as' --name-status -- . 2>/dev/null \
          | LC_ALL=C tr '\n\0' '\001\n') \
      <(printf '%s\n' "${files[@]}"))
  else
    answers=$(printf '%s\t?\n' "${files[@]}")
  fi
  while IFS= read -r line; do
    case "$line" in
      *$'\t?') f="${line%$'\t?'}"; printf '%s\t%s\n' "$f" "$(derive_dates "$f")" ;;
      *)       printf '%s\n' "$line" ;;
    esac
  done <<<"$answers"
}

# Executed directly (not sourced) → act as a CLI over $1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -ge 1 ] || { echo "usage: crystal-dates.sh <file>" >&2; exit 2; }
  derive_dates "$1"
fi
