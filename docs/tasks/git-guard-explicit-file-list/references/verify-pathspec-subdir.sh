#!/usr/bin/env bash
# verify-pathspec-subdir.sh — why did the pathspec form emit an EMPTY commit?
#
# Observed in cc-vdm-plugins on 2026-08-27: `git commit -F <msg> -- 'tests/a.sh'
# 'tests/b.sh' …` produced a commit whose tree was byte-identical to its parent,
# even though all seven paths were staged (`A`) and present in the working tree.
# The same form is asserted to work by tests/git-guard-prepare.test.sh, which
# passes 40/40.
#
# The difference between the two is the thing to find. Candidates, in order of
# suspicion:
#
#   1. SUBDIRECTORY. Every path in the test suite is at the repo root
#      (`a.txt`, `f1.txt`, `кириллица.md`). The failing case is the first one
#      whose paths live in a subdirectory — and one that does not exist in HEAD
#      at all. That gap is real regardless of the outcome here: the suite never
#      exercised a nested path.
#   2. DIRECTORY ABSENT FROM HEAD, as opposed to merely the files.
#   3. A pre-commit hook being active (core.hooksPath). The test repos have none;
#      the real repo runs six gates, one of which materialises a whole clone.
#
# Each scenario below stages a file and commits it with an explicit pathspec,
# then asks the only question that matters: is it in HEAD afterwards?
#
# Runs entirely in mktemp -d. Prints a verdict table.
#
# Run: bash docs/tasks/git-guard-explicit-file-list/references/verify-pathspec-subdir.sh
#
# @see docs/tasks/git-guard-explicit-file-list/workitem.md

set -u

lab=$(mktemp -d "${TMPDIR:-/tmp}/pathspec-subdir.XXXXXX")
printf 'git version: %s\nlab: %s\n\n' "$(git --version)" "$lab"

RESULTS=""

scenario() {
  # scenario <name> <setup-fn>
  local name="$1" setup="$2" d="$lab/$1"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q .
    git config user.email lab@lab
    git config user.name lab
    git config commit.gpgsign false
    printf 'base\n' > .keep
    git add .keep
    git commit -qm base
    "$setup"
  )
}

verdict() { RESULTS="${RESULTS}  ${1}\n"; }

# --- 1. root-level new file — what the test suite already covers -------------
s_root() {
  printf 'x\n' > new.txt
  git add new.txt
  git commit -qm "root" -- new.txt 2>/dev/null
  git cat-file -e HEAD:new.txt 2>/dev/null && echo COMMITTED || echo MISSING
}

# --- 2. new file in a subdirectory that ALSO does not exist in HEAD ----------
s_newdir() {
  mkdir -p sub
  printf 'x\n' > sub/new.txt
  git add sub/new.txt
  git commit -qm "newdir" -- sub/new.txt 2>/dev/null
  git cat-file -e HEAD:sub/new.txt 2>/dev/null && echo COMMITTED || echo MISSING
}

# --- 3. new file in a subdirectory that DOES exist in HEAD ------------------
s_existingdir() {
  mkdir -p sub
  printf 'old\n' > sub/old.txt
  git add sub/old.txt
  git commit -qm "seed subdir"
  printf 'x\n' > sub/new.txt
  git add sub/new.txt
  git commit -qm "existingdir" -- sub/new.txt 2>/dev/null
  git cat-file -e HEAD:sub/new.txt 2>/dev/null && echo COMMITTED || echo MISSING
}

# --- 4. several new files in a new subdirectory, as in the real case ---------
s_multi() {
  mkdir -p sub
  for i in 1 2 3; do printf '%s\n' "$i" > "sub/f$i.txt"; done
  git add sub
  git commit -qm "multi" -- sub/f1.txt sub/f2.txt sub/f3.txt 2>/dev/null
  local n
  n=$(git ls-tree -r --name-only HEAD | grep -c '^sub/')
  [ "$n" -eq 3 ] && echo COMMITTED || echo "MISSING ($n/3)"
}

# --- 5. same as 4, but with an active pre-commit hook -----------------------
s_hook() {
  mkdir -p .githooks sub
  printf '#!/bin/sh\nexit 0\n' > .githooks/pre-commit
  chmod +x .githooks/pre-commit
  git config core.hooksPath .githooks
  for i in 1 2 3; do printf '%s\n' "$i" > "sub/f$i.txt"; done
  git add sub
  git commit -qm "hook" -- sub/f1.txt sub/f2.txt sub/f3.txt 2>/dev/null
  local n
  n=$(git ls-tree -r --name-only HEAD | grep -c '^sub/')
  [ "$n" -eq 3 ] && echo COMMITTED || echo "MISSING ($n/3)"
}

# --- 6. does git even refuse the resulting empty commit? --------------------
s_empty() {
  printf 'x\n' > tracked.txt
  git add tracked.txt
  git commit -qm "seed"
  # pathspec naming a path with nothing to change
  if git commit -qm "empty?" -- tracked.txt 2>/dev/null; then
    echo "ACCEPTED (git created a commit with no change)"
  else
    echo "REFUSED (git declined, as expected)"
  fi
}

for s in root newdir existingdir multi hook empty; do
  out=$(scenario "$s" "s_$s" 2>&1 | tail -1)
  printf '  %-14s %s\n' "$s" "$out"
  verdict "$(printf '%-14s %s' "$s" "$out")"
done

printf '\nlab kept at: %s\n' "$lab"
