#!/bin/bash
# suites-for.sh — which test suites own the given files.
#
# A suite is named after what it tests. tests/<name>.test.sh owns
#   plugins/*/{scripts,lib,bin}/<name>[.<ext>]
# and every file there whose name starts with "<name>-" — intercom-common.sh
# and intercom-identity-check.sh belong to intercom, fffd-precommit-check.sh to
# fffd. A staged suite owns itself. A file can have several owners
# (comms-pending.py → comms-pending, comms); each is printed once, in the order
# first met.
#
# Why a rule and not a list (2026-09-25): nine of twenty-one suites were run by
# no gate, and a list is exactly what goes quiet on the first suite nobody adds
# to it — gate 8 of .githooks/pre-commit says the same about helpers. The rule
# lives here once: the pre-commit calls it to decide what to run, and
# tests/suite-wiring.test.sh calls it to prove that every suite has a trigger.
#
# What it does not see: a suite's SECONDARY subjects. crystal-migrate-scan's
# suite also exercises crystal-dates.sh, and nearly every suite reads
# lib/config-read.sh; a change to those runs gate 7's broad list, not these.
#
# Except for a helper under bin/. A helper is run by its path, so a suite that
# runs it under another name says so in code: `bin/<name>` on a line that is not
# a comment. That suite owns the helper too. Found 2026-10-06: vdm-git 2.17.0
# changed git-guard-prepare, gate 8 re-ran tests/git-guard-prepare.test.sh, and
# tests/fffd.test.sh — which prepares four times in one fixture — went out red,
# run by nobody. One grep over tests/, not one per suite.
#
# Usage: paths as arguments, or one per line on stdin (repo-relative).

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

seen=" "
emit() {
  case "$seen" in *" $1 "*) return 0 ;; esac
  seen="$seen$1 "
  printf '%s\n' "$1"
}

owners() {
  local path="$1" base p
  case "$path" in
    tests/*.test.sh)
      p="${path#tests/}"
      p="${p%.test.sh}"
      if [ -f "$ROOT/tests/$p.test.sh" ]; then emit "$p"; fi
      return 0 ;;
    plugins/*/scripts/*|plugins/*/lib/*|plugins/*/bin/*) ;;
    *) return 0 ;;
  esac
  base="${path##*/}"
  base="${base%.*}"
  p="$base"
  while [ -n "$p" ]; do
    if [ -f "$ROOT/tests/$p.test.sh" ]; then emit "$p"; fi
    case "$p" in
      *-*) p="${p%-*}" ;;
      *)   p="" ;;
    esac
  done
  case "$path" in
    plugins/*/bin/*)
      local t name="${path##*/}"
      name="${name//./\\.}"
      while IFS= read -r t; do
        t="${t##*/}"
        emit "${t%.test.sh}"
      done < <(grep -lE "^[^#]*bin/${name}([\"'}[:space:]]|\$)" "$ROOT"/tests/*.test.sh 2>/dev/null || true)
      ;;
  esac
}

if [ $# -gt 0 ]; then
  for a in "$@"; do owners "$a"; done
else
  while IFS= read -r a; do
    [ -n "$a" ] && owners "$a"
  done
fi
exit 0
