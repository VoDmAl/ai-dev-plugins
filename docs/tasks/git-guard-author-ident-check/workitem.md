---
title: "git-guard-prepare: проверить автора коммита до строки"
slug: git-guard-author-ident-check
description: "Отказывать в строке коммита, когда git не знает автора репозитория"
status: ready
session-type: short-bug
created: 2026-11-04
last-updated: 2026-11-04
---

# git-guard-prepare: проверить автора коммита до строки

> Бриф echelon 05.11 (UTC): `git-guard-prepare` подготовил строку первого коммита в
> новом репозитории, где git не знает автора, и строка упала у владельца. Принят
> сессией intercom в кристалл; код не тронут.

## Назначение

`git-guard-prepare` готовит строку `git commit -F … -- …` и не спрашивает, сможет ли
git записать коммит. На машине владельца в `~/.gitconfig` стоит
`user.useconfigonly true` без глобального `user.email`: автор у каждого репозитория
свой, в его `.git/config`. В новом репозитории (`git init`, без remote) автора ещё
нет, и строка падает с «Author identity unknown … fatal: no email was given and
auto-detection is disabled». Владелец узнаёт это, только запустив строку.

**Готово, когда** в репозитории без автора `git-guard-prepare` отказывает с причиной,
называет команды `git config user.name … && git config user.email …` для этого
репозитория и строку не пишет. С автором ведёт себя как раньше. Итог — письмом
echelon с версией vdm-git.

## Текущая модель

- Проверки автора в `plugins/vdm-git/bin/git-guard-prepare` нет: grep по `IDENT`,
  `user.email`, `user.name` пуст (vdm-git 2.26.0, 04.11).
- `git var GIT_AUTHOR_IDENT` и `git var GIT_COMMITTER_IDENT` различают два случая:
  без автора при `user.useconfigonly true` — код 128 и тот же текст, что у
  `git commit`; с `user.name`/`user.email` в репозитории — код 0 и
  `Имя <адрес>` (DL #1). Проверка ничего не пишет, это одно чтение конфига.
- Строка не должна мешать тому, кто задаёт автора окружением (`GIT_AUTHOR_*`):
  `git var` читает и его, поэтому проверка честная и там.

## Decision Log

### #1 / 2026-11-04 / Проверка — `git var GIT_AUTHOR_IDENT` и `GIT_COMMITTER_IDENT` до подготовки

**Source:** both
**Basis:** observed
**Basis-detail:** Воспроизведено 04.11 в scratchpad сессии intercom (git 2.56.0):
`git init`, `HOME` на пустой каталог, `GIT_CONFIG_NOSYSTEM=1`, `GIT_AUTHOR_*` /
`GIT_COMMITTER_*` / `EMAIL` сняты, `git config --global user.useconfigonly true`.
`git var GIT_AUTHOR_IDENT` → rc=128, «Author identity unknown … fatal: no email was
given and auto-detection is disabled»; `GIT_COMMITTER_IDENT` → rc=128,
«Committer identity unknown»; после `git config user.name/user.email`
(вымышленные) → rc=0. Каталог удалён. Бриф echelon —
`intercom: ai-dev-plugins/_done/git-guard-author-ident-check.md`, пересказан, не
скопирован. На самом `git-guard-prepare` не проверялось — кода ещё нет.
**Context:** Как заранее узнать, что `git commit` упадёт на авторе: разбирать
`git config` по ключам (`user.email`, `user.useconfigonly`, `EMAIL`, окружение) или
спросить git.
**Why:** `git var` отвечает тем же механизмом, что и `git commit`, — с окружением,
`includeIf`, `useconfigonly` и автоопределением. Разбор ключей повторил бы логику
git и разошёлся бы с ней на первом же случае, который не учтён. Предложение
отправителя.
**Implication:** В `git-guard-prepare` — одна проверка до записи файла сообщения,
в том числе в `--check` и `--supersede`. Тест — фикстура без автора (только `git add`,
без коммита) и контроль с автором.

## Sidetracks

### #1. Короткий вызов строки удаляет себя и после неудачи

**Возникло в:** бриф echelon, разбор случая
**Описание:** Скрипт короткого вызова (`~/.local/state/vdm-git/sh/<id>.sh`) несёт
`trap 'rm -f "$0"' EXIT` (`plugins/vdm-git/bin/git-guard-prepare`, около строки 1596)
и удаляет себя, даже когда `git commit` упал. Владельцу пришлось ждать новую строку
через `--supersede`, хотя файл сообщения был жив и полная строка сработала бы после
`git config`. Решить: удалять скрипт только при коде 0, или оставить как есть и
печатать полную строку в тексте отказа. После DL #1 случай с автором уйдёт, но
другие отказы (pre-commit) останутся.

**Status:** open

## Next actions

- [ ] Проверка автора в `git-guard-prepare` по DL #1: отказ с причиной и командами `git config user.name … && git config user.email …`, файл сообщения не пишется; тест в `tests/git-guard-prepare.test.sh` (RED без проверки, контроль с автором); bump vdm-git, marketplace, changelog
- [ ] Решить Sidetrack #1 — удалять короткий вызов только при успешном коммите или нет
- [ ] Outcome to `echelon`: intercom reply git-guard-author-ident-check --done "<what was done>" --link <url> --ball "<who holds the ball — what ⏰ date>"

## References

- Бриф echelon — в хранилище intercom: `ai-dev-plugins/_done/git-guard-author-ident-check.md`
  (вне репозитория; пересказан выше, не скопирован — письмо другого агента).
- Код: `plugins/vdm-git/bin/git-guard-prepare`.
