---
title: "vdm-comms 0.2: висяки — линт строки с владельцем, сводка по владельцу и сроку, оба маркера срока"
slug: vdm-comms-pending
description: "Портировать pending.py в vdm-comms: владелец обязателен, ⏰ и (due:) читаются одним детектором"
status: ready
session-type: prd-prep
created: 2026-09-21
last-updated: 2026-09-21
relates-to:
  - "[[comms-plugin/workitem|comms-plugin]]"
  - "[[vdm-comms-core/workitem|vdm-comms-core]]"
---

# vdm-comms 0.2: висяки — линт строки с владельцем, сводка по владельцу и сроку, оба маркера срока

> Ломоть решения `comms-plugin` DL #12 (2026-09-21). Идёт после 0.1.0
> (`vdm-comms-core`); заведён в `ready` по слову владельца «всё по порядку». Закрывает
> вопрос `limeflow` из `wait-due-outside-crystals` (ответ отправлен 2026-09-21).

## Назначение

**Цель.** В `vdm-comms` 0.2 — порт `pending.py` из `global-auth-gap`: (а) PostToolUse-линт
**новых** строк висяков в файлах из конфига — владелец обязателен, контрагентские первыми;
(б) `/vdm-comms:pending` — сводка «кто кому что должен и к какому сроку», группировка по
владельцу; (в) SessionStart — просроченные и «7 дней». Детектор читает оба маркера срока:
`⏰ <дата>` / `⏰ после: <событие>` и `(due: YYYY-MM-DD)`.

**Ограничения.** Кристаллы `vdm` (`crystal-hydrate`, `(due:)` в `workitem.md`) не меняются;
интерком не учится «ждать ответа со сроком». Форматы не мигрируются. Та же rc-семантика
гейта, что в 0.1.0 (`comms-plugin` DL #10).

**Критерий успеха.** У `global-auth-gap` сводка плагина совпадает со сводкой их
`pending.py` на тех же файлах; у `space-hq` строки с `⏰` читаются без правок; у `limeflow`
ожидания `(due:)` в `docs/tasks/<ключ>/<slug>.md` попадают в просрочку на SessionStart
после добавления путей в конфиг; их собственный grep снят.

## Текущая модель

**Исходник:** `global-auth-gap/.claude/hooks/pending.py` (417 строк, stdlib, 12.09) —
контракт строки (их `docs/llm/pending-items.md`):
`- [ ] <флаг>? **<владелец>** — <что> ⏰ <YYYY-MM-DD | после: <событие>>`; владелец —
первый жирный фрагмент; дата — ISO или `dd.mm[.yyyy]`; зачёркнутое и `[x]` не читаются;
`--lint --changed <f>` проверяет только строки, которых нет в HEAD (хук
`check-pending-format.sh`, `|| true` + `grep '^⚠'` — тот же класс отказа).
Источники у них: разделы «## Ожидаем …» и «## Требует действий …» в `index.md` треков,
очереди серий, черновики в `comms/`, встречи без транскрипта.

**Два маркера срока** (`comms-plugin` DL #12): `⏰` у `gag` и `space-hq` (правило 5 их
`CLAUDE.md` — по письму `limeflow`, у себя не проверено), `(due:)` у `limeflow` и у
кристаллов. `⏰ после: <событие>` в `(due:)` не выражается — потому и два.

**Конфиг:** секция `comms` → `pending-paths` (глобы файлов, где живут висяки) поверх
`track-roots` из 0.1.0.

**Открыто для ломтя:** что считать «просрочено» для `⏰ после: <событие>` (событие без
даты — не просрочка, а «ждёт события»); нужен ли `--owner` как отдельный скилл или флаг.

## Decision Log

### #1 / 2026-09-21 / Заведён как ломоть в `ready`; формат и область решены в `comms-plugin` DL #12

**Source:** user
**Basis:** user-stated
**Basis-detail:** «всё по порядку»; выбор «два формата, один детектор в `vdm-comms` 0.2»
сделан владельцем в grill-интервью 2026-09-21.
**Context:** `limeflow` предлагал три пути; `gag` §10 планировал второй линтер по тому же
образцу (`open-loops-visibility`).
**Why:** ломоть после 0.1.0 — переиспользует конфиг и парсер; отдельный кристалл, чтобы
0.1.0 не ждал.
**Implication:** `ready`; старт после выхода 0.1.0; при старте — повторный инвентарь
`pending.py` (он менялся 12.09, будет меняться дальше).

## Sidetracks

Пока нет.

## Next actions

- [ ] Инвентарь: актуальные `pending.py`, `check-pending-format.sh`,
      `docs/llm/pending-items.md` у `gag`; правило 5 и `scripts/ball.py` у `space-hq`;
      ticket-doc'и `limeflow`
- [ ] Порт → `scripts/comms-pending.py`: оба маркера срока; владелец — первый жирный
      фрагмент; зачёркнутое и `[x]` игнорируются; `--json`; `--owner`
- [ ] PostToolUse-линт только новых строк (diff против HEAD) под `pending-paths`;
      rc-семантика «не проверено → exit 2»
- [ ] SessionStart: просрочено · 7 дней · «ждёт события» — коротко, не газета
- [ ] Скилл `skills/pending/SKILL.md`; правило владельца и «контрагентские первыми» — в
      текст скилла
- [ ] Красные тесты: строки с `⏰`, с маркером `due:` кристаллов, с `после:`, без
      владельца, зачёркнутые; фикстура с ≥2 владельцами (корреляцию разорвать)
- [ ] Подключить `gag`, `space-hq`, `limeflow`; снять их копии и grep; ответ через
      `/vdm:intercom send`
- [ ] Версия 0.2, каталог, `PROJECT_CHANGELOG.md`, `/vdm:docs-sync`

## References

- Родитель: `[[comms-plugin/workitem|comms-plugin]]` DL #12, Sidetrack #3;
  `references/intercom-brief-limeflow-wait-due.md`;
  `references/intercom-brief-global-auth-gap-addendum.md` §2.2.
- Исходник: `/Users/vdm/AI Projects/global-auth-gap/.claude/hooks/{pending.py,check-pending-format.sh}`.
- Формат кристаллов: `plugins/vdm/skills/crystal-grow/SKILL.md` § «Обещание со сроком».
- Отправленный ответ: `~/.claude/vdm/intercom/limeflow/wait-due-verdict.md`.
