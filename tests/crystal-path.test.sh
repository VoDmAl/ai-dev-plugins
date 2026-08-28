#!/bin/bash
# crystal-path.test.sh — tests for crystal root resolution, and specifically for
# the two halves of the globstar defect.
#
# `globstar` arrived in bash 4.0; macOS ships 3.2. The bare
# `shopt -s nullglob globstar` form therefore printed
#
#     shopt: globstar: invalid shell option name
#
# on stderr — and since `crystal-lint.sh --hook` runs from PostToolUse, that
# line reached the assistant as the FIRST line of the canon verdict. Noise in a
# gate's own output is how gates get switched off.
#
# The louder half is the easy one. The quiet half is the defect: without
# globstar, `**` degrades to `*` and matches exactly one level, so
# `packages/**/tasks` finds `packages/x/tasks` and misses `packages/x/y/tasks`
# — a crystal root that is simply never scanned, with nothing said. That is the
# suite's recurring failure mode (docs/model/suite.md → "механизм молча подменил
# область"), and the rule it earned is that a mechanism which narrows its own
# scope must SAY SO.
#
# So there are two things to test and they are not the same thing:
#   - the noise is gone (regression);
#   - the silence is gone too (the actual fix).
#
# Run: bash tests/crystal-path.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/lib/crystal-path.sh — _expand_globs_under_root
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — Sidetrack #6

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/plugins/vdm/lib/crystal-path.sh"
CFG="$REPO_ROOT/plugins/vdm/lib/config-read.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
expect_not_says() {
  case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac
}
expect_silent() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystalpath)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Build a project with roots at two depths, so single-level and recursive
# expansion give measurably different answers.
new_project() {
  local d="$TMP/$1"; shift
  rm -rf "$d"; mkdir -p "$d/.claude"
  mkdir -p "$d/packages/shallow/tasks" "$d/packages/deep/nested/tasks"
  # Auto-scan discovers roots through `git ls-files`, so the directories have to
  # hold something tracked. Empty directories do not exist as far as git is
  # concerned, and a fixture of empty dirs would test nothing while looking like
  # it tested everything.
  printf 'x\n' > "$d/packages/shallow/tasks/.keep"
  printf 'x\n' > "$d/packages/deep/nested/tasks/.keep"
  ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 )
  if [ $# -gt 0 ]; then
    printf '{\n  "crystal": {\n    "paths": [%s]\n  }\n}\n' "$1" > "$d/.claude/vdm-plugins.json"
  fi
  printf '%s' "$d"
}

# Resolve roots in <dir>; stdout and stderr captured separately.
resolve_out() {
  ( cd "$1" && bash -c ". '$CFG' 2>/dev/null; . '$LIB'; resolve_crystal_roots" 2>/dev/null )
}
resolve_err() {
  ( cd "$1" && bash -c ". '$CFG' 2>/dev/null; . '$LIB'; resolve_crystal_roots" 2>&1 >/dev/null )
}

printf '\n=== the noise ===\n'
# The regression: ordinary globs must not make the library complain about the
# shell it is running on. This is what reached the assistant in front of every
# canon verdict on macOS.

d=$(new_project plain '"packages/shallow/tasks"')
err=$(resolve_err "$d")
expect_not_says "no shopt complaint on a literal path" "$err" "invalid shell option"
expect_silent "literal path resolves with a clean stderr" "$err"

d=$(new_project autoscan)
err=$(resolve_err "$d")
expect_silent "auto-scan resolves with a clean stderr" "$err"

printf '\n=== the silence ===\n'
# The defect proper. On a shell without globstar, a `**` glob quietly scans one
# level. The library must say which glob is affected and what the consequence
# is — naming the glob matters, because "some root may be missing" is not
# actionable and gets ignored.

d=$(new_project starstar '"packages/**/tasks"')
err=$(resolve_err "$d")
out=$(resolve_out "$d")

if bash -c 'shopt -s globstar' 2>/dev/null; then
  # bash >= 4: `**` works, so there is nothing to warn about and both roots
  # must be found.
  expect_silent "globstar available ⇒ no warning" "$err"
  expect_says "globstar available ⇒ deep root found" "$out" "packages/deep/nested/tasks"
else
  # bash 3.2: the warning is the whole point.
  expect_says "warns that ** cannot expand" "$err" "globstar"
  expect_says "warning names the affected glob" "$err" "packages/**/tasks"
  expect_says "warning states the consequence" "$err" "NOT scanned"
  expect_says "warning offers a way out" "$err" "crystal.paths"
  expect_says "shallow root still resolves" "$out" "packages/shallow/tasks"
  expect_not_says "deep root is genuinely missed (this is what is announced)" \
    "$out" "packages/deep/nested/tasks"
fi

# A glob without `**` must never trigger the warning, whatever the shell.
d=$(new_project nostar '"packages/shallow/tasks", "packages/deep/nested/tasks"')
err=$(resolve_err "$d")
expect_not_says "globs without ** produce no warning" "$err" "globstar"
out=$(resolve_out "$d")
expect_says "explicit paths find the shallow root" "$out" "packages/shallow/tasks"
expect_says "explicit paths find the deep root" "$out" "packages/deep/nested/tasks"

# Several `**` globs must warn once, not once per glob. A warning repeated per
# entry turns a real signal into wallpaper.
d=$(new_project twostars '"packages/**/tasks", "apps/**/tasks"')
err=$(resolve_err "$d")
n=$(printf '%s\n' "$err" | grep -c 'has no `globstar`' || true)
if bash -c 'shopt -s globstar' 2>/dev/null; then
  expect_eq "globstar available ⇒ zero warnings for two ** globs" "0" "$n"
else
  expect_eq "two ** globs warn exactly once" "1" "$n"
fi

printf '\n=== resolution still works ===\n'
# Guard against a fix that silences the shell and breaks the function.

d=$(new_project functional)
out=$(resolve_out "$d")
expect_says "auto-scan finds the shallow root" "$out" "packages/shallow/tasks"
expect_says "auto-scan finds the deep root" "$out" "packages/deep/nested/tasks"

d=$(new_project absolute "\"$TMP/functional/packages/shallow/tasks\"")
out=$(resolve_out "$d")
expect_says "absolute glob is respected" "$out" "packages/shallow/tasks"

printf '\n=== the mirror ===\n'
# lib/ is mirrored across both plugins by invariant; a fix applied to one copy
# only would pass every test above and ship broken to vdm-git.
#
# Ask the gate, do not re-derive its rule: the two files differ legitimately in
# one line — the cross-reference header, where each names the OTHER copy — and a
# plain `diff -q` reports that as divergence. Restating the comparison here
# would be a second copy of the rule, which is the failure this suite keeps
# rediscovering.
if bash "$REPO_ROOT/scripts/check-lib-sync.sh" >/dev/null 2>&1; then
  ok "both plugin copies of crystal-path.sh are in sync"
else
  bad "both plugin copies of crystal-path.sh are in sync" "check-lib-sync.sh went red"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
