---
title: "Гейты суиты при отсутствии зависимости: аудит fail-open и закон «провалена ≠ не выполнена»"
slug: gate-fail-closed-audit
description: "Проверить, какие гейты vdm/vdm-git молча пропускают без python3/jq, и записать закон в suite.md"
status: ready
session-type: prd-prep
created: 2026-09-21
last-updated: 2026-09-21
relates-to:
  - "[[comms-plugin/workitem|comms-plugin]]"
---

# Гейты суиты при отсутствии зависимости: аудит fail-open и закон «провалена ≠ не выполнена»

> Вырос из побега `comms-plugin` #1 и решения DL #10 (2026-09-21): класс отказа, ради
> которого затевалась эстафета трёх агентов, обнаружен в собственных гейтах суиты —
> по замыслу. Заведён в `ready` по слову владельца «всё по порядку».

## Назначение

**Цель.** Для каждого **блокирующего** хука `vdm` и `vdm-git` установить наблюдением (не
чтением), что происходит без `python3`, без `jq` и при падении скрипта; привести гейты к
закону «проверка провалена и проверка не выполнена — разные события, для гейта второе тоже
блокирует»; напоминания оставить fail-open. Закон — в `docs/model/suite.md` (пересборка,
не дописывание — `docs-distill`), тест — в `tests/gates.test.sh`.

**Ограничение.** Гейт без зависимости не должен блокировать **все** записи подряд: область
хука определяется до вызова зависимости (префильтр по подстроке пути в stdin), «не
проверено» — только для файлов в области.

**Критерий успеха.** Таблица «хук → без python3 → без jq → при падении» с `Basis: observed`
на каждую клетку (замер подстановкой ломаного бинаря в `PATH`, как делал `gag` §2); ни один
гейт не возвращает 0 или 127 там, где должен 2; `suite.md` пересобран, дрифт-сигнал
молчит; `gates.test.sh` краснеет на возврате к старому поведению.

## Текущая модель

**Гипотеза, ещё не проверенная** (`comms-plugin` Sidetrack #1, `Basis: inferred` — чтение
скриптов, запуском не проверено):

| Хук | Тип | Что видно в коде |
|---|---|---|
| `crystal-completion-guard.sh` (PreToolUse) | гейт | `python3 "$simulator"; exit $?` — без `python3` → 127 ≠ 2, запись проходит; шапка: «Fail-open by design» |
| `crystal-lint.sh --hook` (PostToolUse) | гейт | `[ -f "$LINTER" ] \|\| exit 0`, далее `python3` |
| `orphan-guard-hook.sh` (PostToolUse) | гейт | не читался |
| `vdm-git` `git-guard-hook.py` (PreToolUse) | гейт | не читался; `jq`? |
| `crystal-precommit-check.sh`, `.githooks/pre-commit` gate 4–5 | гейт (git) | не читались |
| `lib/config-read.sh` | библиотека | «absence of jq must never break the hook pipeline» — fail-open, верно для напоминаний |
| `*-reminder.sh`, `crystal-hydrate.sh`, `intercom-identity-check.sh` | напоминания | fail-open — норма |

**Предел, который надо назвать честно:** без `python3` `crystal-completion-guard` не может
даже прочитать JSON со stdin. Отказ «не проверено» тогда должен опираться на префильтр
без парсера (подстрока `/tasks/` и `workitem.md` в сыром stdin) — иначе гейт либо молчит,
либо блокирует всё.

**Поле у `gag`** (эстафета §1, §2): тот же дефект был в `check-meeting-format.sh` (`||
true`, `rc=0` при `ModuleNotFoundError`) и в `check-draft-comms.sh` (`jq` → 127 → запись
проходит). Фикс `space-hq` — различать код возврата и наличие `✖`.

## Decision Log

### #1 / 2026-09-21 / Заведён отдельным кристаллом, не внутри ломтя `vdm-comms`

**Source:** user
**Basis:** user-stated
**Basis-detail:** «всё по порядку» — включая пятый кристалл «аудит fail-open гейтов суиты»
из списка хвостов; решение DL #10 `comms-plugin` предписало «аудит — отдельным
кристаллом, не в ломте».
**Context:** можно было чинить гейты `vdm` попутно в `vdm-comms-core`.
**Why:** правка гейтов суиты задевает `lib/` (зеркальный инвариант, оба бампа) и
`suite.md` (пересборка); смешивать с выпуском нового плагина — два риска в одном коммите.
**Implication:** `ready`; порядок относительно ломтей `vdm-comms` — на усмотрение
владельца; закон в `suite.md` нужен **до** 0.1.0, чтобы новый плагин на него ссылался.

## Sidetracks

Пока нет.

## Next actions

- [ ] Замер: для каждого блокирующего хука — прогон с ломаным `python3`, с ломаным `jq`, с
      падающим скриптом; таблица с кодами возврата, `Basis: observed`
- [ ] Решить по каждому: fail-closed с префильтром области / оставить fail-open с
      обоснованием (записать в DL)
- [ ] Починить гейты; `lib/` — с двумя бампами и зеркалом (памятка репозитория);
      напоминания не трогать
- [ ] `tests/gates.test.sh`: красные тесты «без зависимости → exit 2, не 0 и не 127»
- [ ] `docs/model/suite.md`: закон «провалена ≠ не выполнена» в § «Один закон» или
      соседнем — пересборкой через `/vdm:docs-distill`, дрифт погасить в том же коммите
- [ ] `docs/llm/soft-guidance-vs-deterministic-gates.md`: анти-паттерн «гейт, молча
      выключенный отсутствием зависимости» рядом с «wired because its file is present»
- [ ] Версии, каталог, `PROJECT_CHANGELOG.md`, `/vdm:docs-sync`

## References

- Родитель: `[[comms-plugin/workitem|comms-plugin]]` Sidetrack #1, DL #10;
  `references/intercom-brief-t23b-program-relay.md` §Б §1–§2 (воспроизведение дефекта у
  `gag`), §12 §1 (фикс `space-hq`).
- Код: `plugins/vdm/scripts/crystal-completion-guard.sh`, `plugins/vdm/scripts/crystal-lint.sh`,
  `plugins/vdm/lib/config-read.sh`, `plugins/vdm-git/scripts/git-guard-hook.py`,
  `.githooks/pre-commit`, `tests/gates.test.sh`.
- Закон и его место: `docs/model/suite.md` § «Один закон», § «Дублирование лечится
  конформансом»; `docs/llm/soft-guidance-vs-deterministic-gates.md` § «Anti-patterns».
