#!/bin/bash
# run-suites.sh — run test suites side by side, report them in the order named.
#
# Usage: scripts/run-suites.sh <suite>...     (a suite is tests/<suite>.test.sh)
#
# Why it exists. Once no gate spent its time in a loop (Sidetrack #4), the
# pre-commit's CPU was spread evenly over a dozen and a half suites that ran one
# after another while the other cores waited (Sidetrack #6,
# docs/tasks/crystal-wake/workitem.md). The suites were written to be independent
# — each builds its fixture under its own mktemp — and what two of them could
# still share is taken apart here rather than trusted: every suite runs with its
# own TMPDIR, which is where the reminder throttles and git-guard's prepared
# messages live. The suites that touch the intercom store or the shared rules
# move HOME or the store root themselves.
#
# Output: for a suite that passed, one line — its last non-empty line, the
# "N passed, 0 failed" summary; for one that failed, everything it printed. In
# the order the suites were named, whatever order they finished in. Exit 0 when
# every suite passed, 1 otherwise — a suite that could not start is a failure,
# not a silence.
#
# SUITES_JOBS caps how many run at once (default: the number of CPUs).
# SUITES_DIR is where the suites live (default: tests); the runner's own test
# points it at fixtures.
set -u

dir="${SUITES_DIR:-tests}"
jobs="${SUITES_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
[ "$#" -gt 0 ] || exit 0

out=$(mktemp -d 2>/dev/null || mktemp -d -t run-suites) || exit 1
trap 'rm -rf "$out"' EXIT

# One worker per suite. The status goes to its own file after the suite ends:
# a worker that dies before writing it leaves no file, and no file reads as a
# failure below.
printf '%s\n' "$@" | xargs -P "$jobs" -I{} bash -c '
  mkdir -p "$2/$1.tmp" &&
  TMPDIR="$2/$1.tmp" bash "$3/$1.test.sh" < /dev/null > "$2/$1.log" 2>&1
  echo $? > "$2/$1.rc"
' _ {} "$out" "$dir"

failed=0
for s in "$@"; do
  rc=1
  [ -f "$out/$s.rc" ] && read -r rc < "$out/$s.rc"
  if [ "$rc" = 0 ]; then
    awk 'NF { last = $0 } END { print last }' "$out/$s.log"
  else
    failed=1
    printf '✗ %s/%s.test.sh exited %s:\n' "$dir" "$s" "$rc" >&2
    cat "$out/$s.log" >&2 2>/dev/null
  fi
done
exit "$failed"
