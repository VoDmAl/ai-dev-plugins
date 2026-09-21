---
title: "fffd в vdm-git: проверка U+FFFD внутри git-guard-prepare и скриптом pre-commit"
slug: fffd-two-surfaces
description: "Перенести check-fffd-bytes из трёх репозиториев в vdm-git на обе поверхности коммита"
status: ready
session-type: prd-prep
created: 2026-09-21
last-updated: 2026-09-21
relates-to:
  - "[[comms-plugin/workitem|comms-plugin]]"
---

# fffd в vdm-git: проверка U+FFFD внутри git-guard-prepare и скриптом pre-commit

> Ломоть решения `comms-plugin` DL #11 (2026-09-21). Независим от `vdm-comms`; заведён в
> `ready` по слову владельца «всё по порядку». Самый маленький ломоть — три агента просили
> его первым.

## Назначение

**Цель.** Проверка «в staged-файлах нет U+FFFD» живёт в `vdm-git` на двух поверхностях:
(а) внутри `git-guard-prepare` — хелпер отказывается готовить коммит и перечисляет файлы
и строки; (б) скрипт pre-commit по образцу `crystal-precommit-check.sh` — для коммитов из
IDE и руками, активация — свойство клона (`vdx doctor`, правило `git-hooks`).

**Ограничение.** Никакого `|| true` вокруг `git diff --cached`: пустой список из-за упавшего
`git diff` должен быть отказом, не «чисто» (теоретическая дыра `space-hq` §2).

**Критерий успеха.** Файл с `\xef\xbf\xbd` в staged → `git-guard-prepare` выходит с 1 и
называет файл и строку; тот же файл → pre-commit скрипт блокирует с тем же текстом; без
порчи оба молчат; три репозитория сняли симлинки на свои копии после установки.

## Текущая модель

**Исходник:** `global-auth-gap/.claude/hooks/check-fffd-bytes.sh` — 46 строк, bash,
`grep -l $'\xef\xbf\xbd'` по `git diff --cached -z --name-only --diff-filter=ACM`, exit 1
с перечнем и подсказкой `--no-verify`. Байт-в-байт одинаков у `gag` и `space-hq`
(эстафета §3); у `t23b` — правило 11 в `CLAUDE.md` без механизма. Происхождение —
`ff78039` (2026-04-24): батч-запись по многим `notes.md`, 21 точка порчи в 11 файлах,
замечено через три недели.

**Куда кладётся половина (а):** `plugins/vdm-git/bin/git-guard-prepare` уже перечисляет
staged-файлы (`git diff --cached --name-only -z --no-renames`, строка 372) и умеет
отказывать (`exit 1`, «nothing staged», «working tree differs»). Проверка встаёт рядом.

**Куда кладётся половина (б):** `plugins/vdm-git/scripts/crystal-precommit-check.sh` —
образец: сам резолвит путь до кешированной копии плагина, говорит в stderr, если не нашёл.
`suite.md` § «Две поверхности»: механизм, требующий установки, выпадает из формы; замер
установленности делать по резолву цепочки, не по наличию файла.

**Что не наше:** активация `core.hooksPath` / симлинка в чужом клоне — `vdx`.

## Decision Log

### #1 / 2026-09-21 / Заведён как ломоть в `ready`; обе поверхности решены в `comms-plugin` DL #11

**Source:** user
**Basis:** user-stated
**Basis-detail:** «всё по порядку» — ответ на предложение завести кристаллы-ломти. Выбор
«обе поверхности» сделан владельцем в grill-интервью 2026-09-21 (`comms-plugin` DL #11).
**Context:** три агента просили вынести fffd первым и отдельно.
**Why:** ломоть в другом плагине (`vdm-git`) и с собственной версией — отдельный кристалл.
**Implication:** `ready`; при старте — `in-progress`, `prd-work`; бамп `vdm-git`, зеркало
в marketplace, строка в `PROJECT_CHANGELOG.md`.

## Sidetracks

Пока нет.

## Next actions

- [ ] `git-guard-prepare`: после проверки «tree == index» — скан staged-файлов на
      `\xef\xbf\xbd`; отказ с перечнем файлов и первых строк; `git diff` без `|| true`
- [ ] `scripts/fffd-precommit-check.sh` по образцу `crystal-precommit-check.sh`; текст
      отказа тот же; сниппет установки в `README`/`SKILL.md` `guard`
- [ ] Красные тесты в `tests/`: staged-файл с U+FFFD → оба блокируют; чистый → оба
      молчат; сломанный `git diff` → отказ, не «чисто»
- [ ] `vdm-git/skills/guard/SKILL.md`: описать обе поверхности и что активация — `vdx doctor`
- [ ] Бамп `plugins/vdm-git/.claude-plugin/plugin.json`, зеркало в
      `.claude-plugin/marketplace.json`, `PROJECT_CHANGELOG.md`; `/vdm:docs-sync`
- [ ] Сообщить `space-hq`, `global-auth-gap`, `t23b-program`: снять симлинки на копии
      после установки

## References

- Родитель: `[[comms-plugin/workitem|comms-plugin]]` DL #11, Sidetrack #6;
  `references/intercom-brief-t23b-program-relay.md` §Б §2, §10, §12 §5.5.
- Исходник: `/Users/vdm/AI Projects/global-auth-gap/.claude/hooks/check-fffd-bytes.sh`
  (симлинк `.git/hooks/pre-commit`); у `space-hq` — своя обёртка `pre-commit`.
- Место: `plugins/vdm-git/bin/git-guard-prepare`, `plugins/vdm-git/scripts/crystal-precommit-check.sh`.
- `docs/model/suite.md` § «Две поверхности, намеренно продублированные».
