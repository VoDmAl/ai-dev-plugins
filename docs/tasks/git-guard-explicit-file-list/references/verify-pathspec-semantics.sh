#!/usr/bin/env bash
# verify-pathspec-semantics.sh — эмпирическая проверка ловушек №1–№3 из
# интерком-брифа `git-guard-explicit-file-list`.
#
# Отвечает на три вопроса, от которых зависит форма команды, выдаваемой
# `git-guard-prepare`:
#
#   №1  Берёт ли `git commit -- <paths>` содержимое РАБОЧЕГО ДЕРЕВА
#       вместо индекса? (главный — определяет, допустима ли pathspec-форма
#       по умолчанию)
#   №2  Попадают ли в индекс ОБА пути после `git mv`, и что запишет коммит,
#       если в pathspec передать только новый путь?
#   №3  Коммитится ли корректно путь, удалённый через `git rm`?
#
# Плюс контрольный сценарий брифа: не утекает ли в коммит чужой staged-файл,
# добавленный между prep и запуском.
#
# Работает в одноразовом репозитории во временном каталоге, ничего за его
# пределами не трогает. Каталог печатается в конце и остаётся для разбора.
#
# Запуск:  bash docs/tasks/git-guard-explicit-file-list/references/verify-pathspec-semantics.sh
#
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — Next actions, п.1

set -eu

lab=$(mktemp -d "${TMPDIR:-/tmp}/pathspec-lab.XXXXXX")
cd "$lab"

git init -q .
git config user.email lab@lab
git config user.name lab
git config commit.gpgsign false

hr() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

printf 'git version: %s\n' "$(git --version)"
printf 'lab: %s\n' "$lab"

# ---------------------------------------------------------------- база
printf 'v1\n' > a.txt
printf 'b\n'  > b.txt
printf 'c\n'  > c.txt
printf 'к\n'  > 'кириллица.md'
printf 's\n'  > 'с пробелом.md'
git add .
git commit -qm base
note "base commit: $(git rev-parse --short HEAD)"

# ---------------------------------------------------- №1 index vs worktree
hr "№1  git commit -- <path>: индекс или рабочее дерево?"

printf 'v2-STAGED\n'   > a.txt && git add a.txt   # в индексе: v2-STAGED
printf 'v3-WORKTREE\n' > a.txt                    # в дереве:  v3-WORKTREE (не добавлено)

note "index    : $(git show :a.txt)"
note "worktree : $(cat a.txt)"

git commit -qm "pathspec on a.txt" -- a.txt

committed=$(git show HEAD:a.txt)
note "закоммичено: $committed"

if [ "$committed" = "v3-WORKTREE" ]; then
  printf '  \033[31mПОДТВЕРЖДЕНО: pathspec берёт РАБОЧЕЕ ДЕРЕВО, staged-версия проигнорирована.\033[0m\n'
  verdict1=worktree
elif [ "$committed" = "v2-STAGED" ]; then
  printf '  \033[32mОПРОВЕРГНУТО: pathspec взял ИНДЕКС.\033[0m\n'
  verdict1=index
else
  printf '  \033[33mНЕОЖИДАННО: %s\033[0m\n' "$committed"
  verdict1=unknown
fi

note "состояние после коммита:"
git status --short | sed 's/^/    /'

# ------------------------------------------- детектор расхождения из брифа
hr "№1b  Детектор расхождения: git diff --name-only -- <paths>"
git reset -q --hard HEAD
printf 'x-STAGED\n'   > b.txt && git add b.txt
printf 'x-WORKTREE\n' > b.txt
divergent=$(git diff --name-only -- b.txt)
note "git diff --name-only -- b.txt  ->  '${divergent}'"
[ -n "$divergent" ] \
  && note "детектор РАБОТАЕТ: расхождение index/worktree видно до коммита" \
  || note "детектор НЕ сработал"
git reset -q --hard HEAD

# ------------------------------------------------------------ №2 rename
hr "№2  git mv: сколько путей в индексе, что запишет частичный pathspec?"

git mv 'кириллица.md' 'renamed.md'
note "--name-only -z (| = NUL):"
git diff --cached --name-only -z | tr '\0' '|' | sed 's/^/    /'; echo
note "--name-status -z:"
git diff --cached --name-status -z | tr '\0' '|' | sed 's/^/    /'; echo

count=$(git diff --cached --name-only -z | tr -cd '\0' | wc -c | tr -d ' ')
note "путей в индексе: $count  (2 = оба, старый и новый)"

# намеренно коммитим ТОЛЬКО новый путь — воспроизводим ошибку из брифа
git commit -qm "rename, только новый путь в pathspec" -- 'renamed.md'
if git cat-file -e "HEAD:кириллица.md" 2>/dev/null; then
  printf '  \033[31mПОДТВЕРЖДЕНО: старый путь ОСТАЛСЯ в дереве коммита — переименование записано неверно.\033[0m\n'
  verdict2=leaked
else
  printf '  \033[32mСтарый путь отсутствует в дереве коммита.\033[0m\n'
  verdict2=clean
fi
note "дерево коммита:"; git ls-tree --name-only HEAD | sed 's/^/    /'
note "рабочее дерево:"; git status --short | sed 's/^/    /'
git reset -q --hard HEAD

# ------------------------------------------------------------ №3 delete
hr "№3  git rm: коммитится ли удаление через pathspec?"

git rm -q c.txt
note "--name-status -z:"; git diff --cached --name-status -z | tr '\0' '|' | sed 's/^/    /'; echo
git commit -qm "delete c.txt via pathspec" -- c.txt
if git cat-file -e "HEAD:c.txt" 2>/dev/null; then
  printf '  \033[31mУдаление НЕ записано — c.txt всё ещё в дереве коммита.\033[0m\n'
  verdict3=failed
else
  printf '  \033[32mУдаление записано корректно.\033[0m\n'
  verdict3=ok
fi

# ----------------------------------------- контрольный сценарий из брифа
hr "Контроль: утекает ли ЧУЖОЙ staged-файл, добавленный после prep?"

printf 'mine\n'   > mine.txt
printf 'theirs\n' > theirs.txt
git add mine.txt
note "агент A застейджил mine.txt и получил команду с pathspec 'mine.txt'"
git add theirs.txt
note "агент B застейджил theirs.txt ДО того, как человек запустил команду"
note "индекс сейчас: $(git diff --cached --name-only | tr '\n' ' ')"

git commit -qm "commit only mine.txt" -- mine.txt

if git cat-file -e "HEAD:theirs.txt" 2>/dev/null; then
  printf '  \033[31mУТЕЧКА: theirs.txt попал в коммит.\033[0m\n'
  verdict4=leaked
else
  printf '  \033[32mЧужой файл в коммит НЕ попал — дефект из брифа закрывается.\033[0m\n'
  verdict4=isolated
fi
note "остаётся ли theirs.txt в индексе: $(git diff --cached --name-only | tr '\n' ' ')"

# ------------------------------------- --pathspec-from-file (порог брифа)
hr "Доп: --pathspec-from-file --pathspec-file-nul"
git reset -q --hard HEAD
for i in $(seq 1 3); do printf '%s\n' "$i" > "f$i.txt"; done
git add f1.txt f2.txt f3.txt
printf 'f1.txt\0f2.txt\0' > "$lab/paths.nul"
if git commit -qm "pathspec-from-file" \
     --pathspec-from-file="$lab/paths.nul" --pathspec-file-nul 2>/dev/null; then
  printf '  \033[32mПоддерживается.\033[0m В коммите: %s\n' \
    "$(git show --name-only --format= HEAD | tr '\n' ' ')"
  verdict5=supported
else
  printf '  \033[31mНЕ поддерживается этой версией git.\033[0m\n'
  verdict5=unsupported
fi

# ------------------------------------------------------------------ итог
hr "ИТОГ"
cat <<SUMMARY
  №1  pathspec берёт .................. ${verdict1}
  №2  старый путь при частичном mv .... ${verdict2}
  №3  удаление через pathspec ......... ${verdict3}
  контроль: чужой staged-файл ......... ${verdict4}
  --pathspec-from-file ................ ${verdict5}

  лаборатория: ${lab}
SUMMARY
