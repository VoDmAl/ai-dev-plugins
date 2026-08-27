#!/usr/bin/env bash
# verify-hook-index-leak-2.sh — second attempt, after v1 failed to reproduce.
#
# WHAT v1 ESTABLISHED
#   Part 1 confirmed the mechanism exists: git exports GIT_INDEX_FILE to hooks,
#   and in pathspec mode it points at a TEMPORARY index —
#     bare      → GIT_INDEX_FILE=.git/index
#     pathspec  → GIT_INDEX_FILE=…/.git/next-index-45410.lock
#   Part 2 then failed to corrupt anything, so the mechanism was shown to be a
#   hazard but not shown to be the cause.
#
# WHAT v1 GOT WRONG
#   Its fake hook mimicked only the harness's opening moves (`git add -A` inside
#   the clone, reached by `cd`). The real harness does something else 28 times:
#
#     restore() { git -C "$CLONE" reset --quiet HEAD -- . 2>/dev/null; \
#                 git -C "$CLONE" checkout --quiet -- . 2>/dev/null; \
#                 git -C "$CLONE" clean --quiet -fd 2>/dev/null; }
#
#   `-C` changes the working directory; it does NOT change GIT_INDEX_FILE, which
#   is still the OUTER repo's pending index. So `reset HEAD -- .` writes the
#   CLONE's HEAD tree into the commit the outer git is in the middle of making —
#   and the clone's HEAD was built after `rm -rf tests`.
#
#   Errors are sent to /dev/null, so nothing would ever be seen.
#
#   v1's part 3 was worse than useless: it "verified the fix" against a scenario
#   that never broke, so its green meant nothing. Green on a clean tree proves
#   nothing — the exact failure this repo keeps a document about. Here the fix
#   check RUNS ONLY IF the break reproduces, and says so otherwise.
#
# PREDICTION
#   tests/ vanish from the commit, and unrelated.txt is swept in at its working
#   tree state despite being in neither the index nor the pathspec — which is
#   precisely what commit 02faf7f contains.
#
# Run: bash docs/tasks/git-guard-explicit-file-list/references/verify-hook-index-leak-2.sh
#
# @see tests/gates.test.sh — restore(), line 117
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — Sidetrack #4

set -u

lab=$(mktemp -d "${TMPDIR:-/tmp}/hook-leak2.XXXXXX")
printf 'git version: %s\nlab: %s\n\n' "$(git --version)" "$lab"

# The harness, faithfully — including restore() reached via `git -C`.
write_hook() {
  # write_hook <path> <unset:yes|no>
  {
    echo '#!/bin/sh'
    [ "$2" = yes ] && echo 'unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY'
    cat <<'HOOK'
CLONE=$(mktemp -d)/clone
mkdir -p "$CLONE"
git ls-files -z --cached --others --exclude-standard | tar -cf - --null -T - \
  | ( cd "$CLONE" && tar -xf - ) 2>/dev/null
( cd "$CLONE" || exit 0
  rm -rf tests
  git init --quiet .
  git config user.email h@h; git config user.name h
  git add -A >/dev/null 2>&1
  git commit --quiet -m baseline >/dev/null 2>&1 )

# restore(), verbatim in shape — 28 of these run in the real harness
restore() {
  git -C "$CLONE" reset --quiet HEAD -- . 2>/dev/null
  git -C "$CLONE" checkout --quiet -- . 2>/dev/null
  git -C "$CLONE" clean --quiet -fd 2>/dev/null
}
i=0; while [ $i -lt 5 ]; do restore; i=$((i+1)); done
exit 0
HOOK
  } > "$1"
  chmod +x "$1"
}

run_case() {
  # run_case <name> <unset:yes|no> -> prints "<tests> <unrelated>"
  local d="$lab/$1"
  mkdir -p "$d/.githooks"
  (
    cd "$d" || exit 1
    git init -q .; git config user.email l@l; git config user.name l
    git config core.hooksPath .githooks
    mkdir -p tests
    printf 'keep\n' > tests/t1.sh
    printf 'keep\n' > tests/t2.sh
    printf 'src\n' > src.txt
    printf 'unrelated-v1\n' > unrelated.txt
    git add .
    git commit -qm base >/dev/null

    write_hook .githooks/pre-commit "$2"

    printf 'src-changed\n'  > src.txt
    printf 'unrelated-v2\n' > unrelated.txt   # NOT staged, NOT in the pathspec
    git add src.txt
    git commit -qm "touch only src.txt" -- src.txt >/dev/null 2>&1

    if git cat-file -e HEAD:tests/t1.sh 2>/dev/null; then t=intact; else t=DELETED; fi
    if [ "$(git show HEAD:unrelated.txt 2>/dev/null)" = "unrelated-v2" ]; then
      u=SWEPT; else u=intact; fi
    printf '%s %s' "$t" "$u"
  )
}

printf '\033[1m=== A. харнесс как есть (GIT_* унаследованы) ===\033[0m\n'
read -r a_tests a_unrel <<<"$(run_case leak no)"
printf '  tests/    : %s\n  unrelated : %s\n' "$a_tests" "$a_unrel"

broke=no
[ "$a_tests" = DELETED ] && broke=yes
[ "$a_unrel" = SWEPT ]   && broke=yes

if [ "$broke" = no ]; then
  printf '\n\033[33m  НЕ ВОСПРОИЗВЕЛОСЬ.\033[0m Гипотеза утечки индекса не подтверждена и этим\n'
  printf '  прогоном. Проверку лечения НЕ запускаю: она бы вернула зелёное на\n'
  printf '  несломанном сценарии и не значила бы ничего — ошибка v1.\n'
  printf '\n  Причина Sidetrack #4 остаётся неустановленной.\n  lab: %s\n' "$lab"
  exit 0
fi

printf '\n\033[31m  ВОСПРОИЗВЕЛОСЬ.\033[0m Утечка GIT_INDEX_FILE портит коммит, который хук охраняет.\n'

printf '\n\033[1m=== B. лечится ли `unset GIT_*` в начале харнесса ===\033[0m\n'
read -r b_tests b_unrel <<<"$(run_case fixed yes)"
printf '  tests/    : %s\n  unrelated : %s\n' "$b_tests" "$b_unrel"

printf '\n\033[1m=== ИТОГ ===\033[0m\n'
printf '  без unset : tests=%s unrelated=%s\n' "$a_tests" "$a_unrel"
printf '  с unset   : tests=%s unrelated=%s\n' "$b_tests" "$b_unrel"
if [ "$b_tests" = intact ] && [ "$b_unrel" = intact ]; then
  printf '  \033[32m→ unset GIT_* устраняет дефект\033[0m\n'
else
  printf '  \033[31m→ unset GIT_* НЕ помогает — лечить надо иначе\033[0m\n'
fi
printf '\n  lab: %s\n' "$lab"
