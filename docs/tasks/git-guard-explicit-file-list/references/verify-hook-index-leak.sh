#!/usr/bin/env bash
# verify-hook-index-leak.sh — did the pre-commit harness corrupt the commit it
# was guarding?
#
# THE HYPOTHESIS
#
# git runs hooks with GIT_DIR and, in pathspec mode, GIT_INDEX_FILE pointing at
# the TEMPORARY index it is about to turn into the commit. Those variables are
# inherited by everything the hook spawns.
#
# `.githooks/pre-commit` Gate 6 runs `tests/gates.test.sh`, which materialises a
# copy of the working tree into a temp dir and then, inside it, runs:
#
#     rm -rf tests
#     git init --quiet .
#     git add -A
#     git commit -m 'baseline: working tree as of test start'
#
# If GIT_INDEX_FILE is still set in the environment, `git add -A` does not write
# the clone's index — it writes THE INDEX GIT IS ABOUT TO COMMIT FROM, with the
# contents of a directory where `tests` has just been deleted. The harness never
# unsets GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE; grep confirms not one of the
# test files mentions them.
#
# WHAT THIS WOULD EXPLAIN — every observation at once:
#
#   1. 02faf7f deleted all six tests/ files      ← `rm -rf tests` in the clone
#   2. …and committed .serena/project.yml, which ← `git add -A` swept the whole
#      was NOT in the emitted pathspec              working-tree copy
#   3. e46e697 produced an EMPTY commit          ← by then HEAD already lacked
#                                                   tests/, so the clone's
#                                                   content equalled HEAD
#   4. only those two commits misbehaved         ← only they staged
#                                                   tests/gates.test.sh, which is
#                                                   what triggers Gate 6
#   5. verify-pathspec-subdir.sh found nothing   ← its hook was `exit 0`; it
#                                                   never ran a git command
#
# If this is right, the pathspec change is entirely innocent and the defect is a
# pre-existing hazard in the harness, armed only when Gate 6 fires.
#
# Run: bash docs/tasks/git-guard-explicit-file-list/references/verify-hook-index-leak.sh
#
# @see tests/gates.test.sh
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — Sidetrack #4

set -u

lab=$(mktemp -d "${TMPDIR:-/tmp}/hook-index-leak.XXXXXX")
printf 'git version: %s\nlab: %s\n\n' "$(git --version)" "$lab"

# ---------------------------------------------------------------------------
# Part 1 — does git even export GIT_INDEX_FILE to a pre-commit hook?
# ---------------------------------------------------------------------------
printf '\033[1m=== 1. что хук видит в окружении ===\033[0m\n'
p1="$lab/probe"; mkdir -p "$p1/.githooks"; cd "$p1"
git init -q .; git config user.email l@l; git config user.name l
git config core.hooksPath .githooks
cat > .githooks/pre-commit <<'HOOK'
#!/bin/sh
echo "    GIT_DIR=[${GIT_DIR-unset}]" >&2
echo "    GIT_INDEX_FILE=[${GIT_INDEX_FILE-unset}]" >&2
echo "    GIT_WORK_TREE=[${GIT_WORK_TREE-unset}]" >&2
exit 0
HOOK
chmod +x .githooks/pre-commit
printf 'x\n' > a.txt; git add a.txt
echo "  -- обычный commit:"
git commit -qm "bare" 2>&1 >/dev/null | sed 's/^/  /'
printf 'y\n' > b.txt; git add b.txt
echo "  -- pathspec commit:"
git commit -qm "pathspec" -- b.txt 2>&1 >/dev/null | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Part 2 — reproduce the corruption with a hook that mimics Gate 6
# ---------------------------------------------------------------------------
printf '\n\033[1m=== 2. воспроизведение: хук делает rm -rf + git add -A в клоне ===\033[0m\n'
p2="$lab/repro"; mkdir -p "$p2/.githooks"; cd "$p2"
git init -q .; git config user.email l@l; git config user.name l
git config core.hooksPath .githooks

mkdir -p tests
printf 'keep\n' > tests/t1.sh
printf 'keep\n' > tests/t2.sh
printf 'src\n'  > src.txt
printf 'unrelated-v1\n' > unrelated.txt
git add .
git commit -qm base
echo "  база: $(git ls-tree -r --name-only HEAD | tr '\n' ' ')"

# The harness, faithfully: copy the working tree, drop tests/, re-init, add -A.
cat > .githooks/pre-commit <<'HOOK'
#!/bin/sh
clone=$(mktemp -d)
git ls-files -z --cached --others --exclude-standard | tar -cf - --null -T - \
  | ( cd "$clone" && tar -xf - )
cd "$clone" || exit 0
rm -rf tests                    # "the observer must not sit inside the observed tree"
git init --quiet .
git add -A                      # <-- with GIT_INDEX_FILE inherited, this writes
git commit --quiet -m baseline  #     the OUTER repo's pending index
exit 0
HOOK
chmod +x .githooks/pre-commit

printf 'src-changed\n' > src.txt
printf 'unrelated-v2\n' > unrelated.txt     # NOT staged, NOT in the pathspec
git add src.txt
echo "  застейджено: $(git diff --cached --name-only | tr '\n' ' ')"
echo "  в pathspec:  src.txt"
git commit -qm "should touch only src.txt" -- src.txt 2>/dev/null

echo
echo "  РЕЗУЛЬТАТ коммита:"
echo "    дерево:   $(git ls-tree -r --name-only HEAD | tr '\n' ' ')"
if git cat-file -e HEAD:tests/t1.sh 2>/dev/null; then
  printf '    tests/    \033[32mна месте\033[0m\n'; v_tests=ok
else
  printf '    tests/    \033[31mУДАЛЕНЫ хуком\033[0m\n'; v_tests=DELETED
fi
if [ "$(git show HEAD:unrelated.txt 2>/dev/null)" = "unrelated-v2" ]; then
  printf '    unrelated \033[31mЗАТЯНУТ (не был ни в индексе, ни в pathspec)\033[0m\n'; v_unrel=SWEPT
else
  printf '    unrelated \033[32mне тронут\033[0m\n'; v_unrel=ok
fi

# ---------------------------------------------------------------------------
# Part 3 — does unsetting the variables fix it?
# ---------------------------------------------------------------------------
printf '\n\033[1m=== 3. лечится ли снятием GIT_* в харнессе ===\033[0m\n'
p3="$lab/fixed"; mkdir -p "$p3/.githooks"; cd "$p3"
git init -q .; git config user.email l@l; git config user.name l
git config core.hooksPath .githooks
mkdir -p tests; printf 'keep\n' > tests/t1.sh
printf 'src\n' > src.txt; printf 'unrelated-v1\n' > unrelated.txt
git add .; git commit -qm base

sed 's|^clone=|unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY\nclone=|' \
  "$p2/.githooks/pre-commit" > .githooks/pre-commit
chmod +x .githooks/pre-commit

printf 'src-changed\n' > src.txt
printf 'unrelated-v2\n' > unrelated.txt
git add src.txt
git commit -qm "with unset" -- src.txt 2>/dev/null
if git cat-file -e HEAD:tests/t1.sh 2>/dev/null \
   && [ "$(git show HEAD:unrelated.txt 2>/dev/null)" = "unrelated-v1" ]; then
  printf '    \033[32mЛЕЧИТСЯ: tests/ на месте, unrelated не затянут\033[0m\n'; v_fix=FIXED
else
  printf '    \033[31mНЕ лечится — причина другая\033[0m\n'; v_fix=NO
fi

printf '\n\033[1m=== ИТОГ ===\033[0m\n'
cat <<SUMMARY
  tests/ удалены хуком ......... ${v_tests}
  чужой файл затянут ........... ${v_unrel}
  unset GIT_* чинит ............ ${v_fix}

  lab: ${lab}
SUMMARY
