---
title: "intercom reply: свой мяч считается непойманным, хотя кристалл называет письмо по slug"
slug: intercom-reply-own-ball-by-slug
description: "Сверять свой мяч в reply так же, как при pickup: по тексту или по slug письма в кристалле"
status: ready
session-type: short-bug
created: 2026-11-17
last-updated: 2026-11-17
relates-to:
  - "[[letters-recipient-tone/workitem|letters-recipient-tone]]"
  - "[[comms-sent-proof-snapshot-lag/workitem|comms-sent-proof-snapshot-lag]]"
---

# intercom reply: свой мяч считается непойманным, хотя кристалл называет письмо по slug

> Заведён сессией intercom 2026-11-17: дефект замечен на её собственных ответах. Делает основная сессия владельца:
> сессия intercom код не правит, рабочее дерево общее.

## Назначение

`reply` с мячом на себя печатает «↪ your own ball — … nothing here will remind you of it» и просит записать пункт в
кристалл, если ни один открытый пункт кристаллов здесь не держит его **текст**. Для мяча из письма, которое
забирают через `pickup`, правило шире: письмо считается удержанным, если дом называет его по slug, то есть кристалл
вырос из него или ссылается на него. Это правило ввели по замеру: из двенадцати мячей, найденных только по тексту,
почти все уже держали кристаллы своими словами.

**Готово, когда** `reply`, чей мяч держит открытый пункт кристалла, называющий slug письма-брифа, ничего не
печатает; красный тест в `tests/intercom.test.sh` на старом коде печатает; выпуск vdm вышел.

## Текущая модель

- `_ic_own_balls` в `plugins/vdm/scripts/intercom.sh` (строки 2142–2163 в рабочем дереве 2026-11-17) берёт открытые
  пункты всех кристаллов и ищет в них `grep -F` ядро текста мяча (до ⏰). Slug не проверяется.
- `_intercom_balls_left` в `plugins/vdm/scripts/intercom-common.sh` (комментарий у строки 2820) считает письмо
  удержанным по slug и по ушедшему итогу брифа, а по тексту — только после этого.
- Случай 2026-11-17: три ответа сессии intercom (`letters-polite-no-deadline-pressure`,
  `comms-draft-shows-recipient-tone`, `comms-sent-check-snapshot-lag`) напечатали эту строку. Пункты «Итог
  отправителю ответом на `<slug>`» в [[letters-recipient-tone/workitem|letters-recipient-tone]] и
  [[comms-sent-proof-snapshot-lag/workitem|comms-sent-proof-snapshot-lag]] были записаны до ответов и называют все
  три slug'а.

## Decision Log

### #1 / 2026-11-17 / Принять slug брифа как удержание и в reply

**Source:** assistant
**Basis:** observed
**Basis-detail:** вывод трёх `reply` в сессии intercom 2026-11-17 (строка «your own ball» на каждом); оба кристалла
лежали в `docs/tasks/` до ответов; код прочитан в рабочем дереве 2026-11-17.
**Context:** у одной проверки «держит ли дом мой мяч» две реализации: широкая при `pickup` и узкая при `reply`.
**Why:** ложная строка «ничто не напомнит» толкает записать второй пункт рядом с первым, и тогда в кристалле
обязательство живёт дважды. Правило `pickup` уже прошло замер, повторять его не нужно — нужно применить и здесь.
Возможно, `_ic_own_balls` стоит заменить вызовом `_intercom_balls_left`; решать при реализации.
**Implication:** правка одной функции и тест.

## Sidetracks

## Next actions

- [ ] `_ic_own_balls`: открытый пункт кристалла, называющий slug письма-брифа, держит мяч — так же, как в
      `_intercom_balls_left`; красный тест в `tests/intercom.test.sh` (сначала проверить, коммитит ли набор, — память
      `feedback_git_verification_scripts_are_handed_off`)
- [ ] SKILL intercom § «Closing a brief with its outcome» — строка про `reply` называет оба признака
- [ ] Версия vdm, marketplace, changelog

## References

- Вывод `reply` — в транскрипте сессии intercom 2026-11-17; переписан в «Текущей модели», копировать нечего.
