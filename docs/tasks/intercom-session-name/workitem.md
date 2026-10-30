---
title: "intercom: «почтовая сессия» → «сессия intercom» в том, что доходит до владельца"
slug: intercom-session-name
description: "Переименовать mail session в строках и текстах, которые читает владелец: путается с Gmail"
status: in-progress
session-type: maintenance
created: 2026-10-28
last-updated: 2026-10-29
---

# intercom: «почтовая сессия» → «сессия intercom» в том, что доходит до владельца

> Вырос из письма echelon 28.10 (`intercom-session-name`). Письмо пересказано, не скопировано; адрес — в DL #1.
> Заведён сессией intercom этого репозитория для основной сессии владельца: переименование меняет код и тексты
> `plugins/vdm/`, а сессия intercom код не правит.

## Назначение

Слово владельца, переданное echelon 28.10. Echelon назвал при нём сессию `vdx ai --intercom` «почтовой», и владельцу
пришлось спросить, о чём речь: *«Давай только не назвать может быть это "почтовой" - сильно похоже на gmail я потому
и спросил у тебя о чем речь.»* В мире владельца почта — это Gmail: у echelon есть `mail_search`, `mail_draft`,
`mail_send`, у штабов `mail.yaml`, в листе дня строки почты. «Mail session» и «почтовая сессия» читаются как сессия,
которая разбирает Gmail.

Echelon у себя уже пишет «сессия intercom»: так же называются флаг `vdx ai --intercom` и признак `VDX_INTERCOM=1`.
Он предлагает то же имя нам (англ. «intercom session»), в строках, которые доходят до владельца. Ключ конфига и поле
конверта оставляет нам: это вопрос совместимости.

Критерий: ни одна строка, которую печатают скрипты intercom, ни текст скилла, откуда ассистент берёт слово, ни наши
письма и кристаллы не называют эту сессию «mail session» или «почтовой». Владелец не путает её с Gmail.

## Текущая модель

Состояние 2026-10-29, рабочее дерево vdm 2.65.0 (не закоммичено). Замер 28.10, с которого начинали: 17 строк скилла,
18 печатаемых строк в трёх скриптах, 29 строк тестов.

- **Печатаемое и скилл — «intercom session».** `intercom.sh`, `intercom-common.sh`, `intercom-identity-check.sh`
  (строки и комментарии), раздел скилла «Intercom sessions — the inbox is their work», README, `docs/model/suite.md`.
  Скилл называет прежнее имя одной фразой: старые письма и транскрипты говорят «mail session».
- **Строка 📮 — ещё и сигнал.** `_intercom_transcript_machine` узнаёт режим сессии на другой машине по её стартовой
  строке в транскрипте и принимает обе формулировки, «📮 Intercom session» и «📮 Mail session».
- **Ключ.** `intercom.session` печатают строка 📨 при старте и `sent`. `_intercom_mail_clone` читает оба ключа, и
  заданный `session` решает. Старый ключ стоит в конфигах 7 проектов, закоммичен в 5 (замер DL #3). Echelon и vdx
  ключ в коде не читают.
- **Машинные имена не тронуты:** поле конверта `session: mail`, функции `intercom_mail_session`,
  `intercom_mail_switched_on`, режим `mail` в списке живых сессий.
- **Чужие тексты с прежним именем.** vdx: строка старта «this is the project's mail session», `cli/src/ai.ts` и его
  скилл `vdx-ai` — бриф vdx в Next actions. Echelon: README (`intercom.mail-session: true`) и его память — назовёт
  итог.

## Decision Log

### #1 / 2026-10-28 / Письмо паркуется кристаллом; до переименования наши тексты пишут «сессия intercom»

**Source:** assistant
**Basis:** observed
**Basis-detail:** письмо echelon `intercom-session-name`, 28.10, ящик intercom `ai-dev-plugins/_done/`; пересказано,
не скопировано (в публичном репозитории письмо другого агента пересказывают). Строка старта сессии intercom 28.10:
«Work that changes the code is left for the owner's main session as a crystal». Места термина — замер в Текущей
модели.
**Context:** переименование задевает 3 скрипта, тесты и скилл, это правка `plugins/vdm/` с поднятием версии.
Ответить echelon можно было, дав имя и сделав замену здесь, или заведя кристалл.
**Why:** сессия intercom делит рабочее дерево с основной, и её правка уехала бы в чужой коммит. Само имя от кода не
зависит, поэтому письма и кристаллы этого репозитория пишут «сессия intercom» уже сейчас: иначе термин продолжит
утекать к владельцу через наши письма, пока код ждёт.
**Implication:** статус `ready`, синглтон `letter-versions` не тронут. Промежуточный итог echelon ушёл 28.10,
окончательный — последний пункт Next actions.

### #2 / 2026-10-29 / Имя — «сессия intercom» / «intercom session»

**Source:** user
**Basis:** user-stated
**Basis-detail:** ответ владельца в основной сессии 2026-10-29 на вопрос с двумя вариантами: «сессия intercom»
(рекомендован) и «сессия входящих».
**Context:** Next actions требовали подтвердить имя, предложенное echelon.
**Why:** совпадает с флагом `vdx ai --intercom`, признаком `VDX_INTERCOM=1` и словом, которое echelon уже пишет.
Минус назван владельцу при вопросе: intercom есть в каждой сессии, и эту отличает только слово «сессия».
**Implication:** во всём, что печатают скрипты, в скилле, `docs/model`, README, наших письмах и незакрытых
кристаллах — «intercom session» по-английски и «сессия intercom» по-русски. Закрытые кристаллы и записи
`PROJECT_CHANGELOG.md` — история, их не трогают.

### #3 / 2026-10-29 / Ключ — `intercom.session`, старый `intercom.mail-session` читается; поле конверта `session: mail` остаётся

**Source:** user
**Basis:** user-stated
**Basis-detail:** ответ владельца 2026-10-29 на вопрос «переименовать, старый читать» (рекомендован) или «оставить».
Посылки вопроса замерены перед ним. Ключ `intercom.mail-session` стоит в конфигах 7 проектов из 12 конфигов
рабочих клонов, найденных по путям реестра intercom на lft, и закоммичен в 5. `git grep` по vdx нашёл термин
только в его собственных строках (`cli/src/ai.ts`), ключ он не читает.
**Context:** строка 📨 печатает JSON-фрагмент ключа и просит предложить его владельцу. В нём осталось бы
«mail», то самое слово, которое путается с Gmail.
**Why:** новый ключ виден владельцу, и в нём нет «mail». Старый ключ закоммичен в пяти проектах, поэтому читается
и дальше: без этого их сессии intercom молча перестали бы запускаться. Поле конверта `session: mail` владелец
не видит. Конверты лежат в хранилище, которое синхронизируется между машинами, и их читают старые версии vdm
на других машинах, так что переименование поля ломало бы счёт цепочки без пользы для владельца.
**Implication:** `intercom_mail_switched_on` читает оба ключа. Если задан `intercom.session`, решает он,
иначе решает `intercom.mail-session`: так `session: false` выключает сессию, даже когда старый `true` остался в
конфиге. Строка 📨 и скилл называют только `intercom.session`. Тесты держат оба ключа и их старшинство.

## Sidetracks

### #1. «Почтовая сессия» в наших незакрытых кристаллах

**Возникло в:** Текущая модель → откуда русское «почтовая»
**Описание:** корень «почтов» есть в шести незакрытых кристаллах: `intercom-mail-candidates` (9 строк, в том числе
заголовок), `intercom-focused-topic` (7), `held-ball-after-pickup` (5), `letters-premature-ask`, `letter-versions`,
`wrap-skill` (по 1). Владелец их читает. Закрытый `intercom-session-wake` (53 строки) — история, его не трогают:
подгонка закрытого кристалла под новый термин подделывает запись.

**Status:** resolved 2026-10-29 — заменено в 9 незакрытых кристаллах: `held-ball-after-pickup`,
`intercom-focused-topic`, `intercom-mail-candidates`, `intercom-taken-by-gone-session`, `letter-versions`,
`letters-mail-over-meetings`, `shell-var-before-non-ascii`, `crystal-wake`, `wrap-skill`. «Почтовый клиент» в
`letter-versions` — о почте и остался. Закрытый сегодня `letters-premature-ask` — история, не тронут.

- [x] Sidetrack #1 — в незакрытых кристаллах заменить «почтовая сессия» на «сессия intercom» там, где речь о сессии

### #2. `close` теряет письмо, оставленное владельцу прошлой сессией intercom

**Возникло в:** разбор ящика 28.10, после ответа echelon
**Описание:** `cmd_close` (`intercom.sh`, около строки 1106) считает в `--waiting <n>` только письма с `taken:` этой
сессии. Письмо `focused-topic-letters` оставила владельцу сессия intercom 27.10 (`…-a8`). 28.10 записи этой сессии
в `sessions/` на машине уже не было, а `check` всё равно говорил про письмо «leave it to that session». Следующая
сессия intercom оставила бы письмо как есть и закрылась бы с `--waiting 0`, и число у владельца для письма, которое
его всё ещё ждёт, пропало бы. 28.10 обойдено вручную: `take --force` в сессию `…-ed`, после чего `close` его считает.
Исправление: в `close` считать и письма, взятые сессией, которой больше нет. А `check` для такой отметки называть
`take --force`, а не «leave it».

**Status:** migrated → [[intercom-taken-by-gone-session/workitem|intercom-taken-by-gone-session]] (2026-10-29): там
`check`, `sent` и `take` при пометке ушедшей сессии, и тот же предикат жизни нужен `close`; перенесён как Sidetrack #3

- [x] Sidetrack #2 — `close` считает письма мёртвых сессий; `check` различает живую и ушедшую отметку. Тест в `tests/intercom.test.sh`

## Next actions

- [x] Подтвердить имя: «сессия intercom» / «intercom session», как у echelon и флага `vdx ai --intercom`. Записать
      решением в Decision Log — владелец 2026-10-29, DL #2
- [x] Строки скриптов: `intercom-identity-check.sh`, `intercom.sh`, `intercom-common.sh` (места — Текущая модель) и
      `tests/intercom.test.sh` — 2026-10-29, вместе с комментариями; парсер строки 📮 (`_intercom_transcript_machine`)
      принимает обе формулировки; сьют 625/625
- [x] Скилл intercom: раздел «Mail sessions» и остальные упоминания. Найти остальные тексты, которые называют термин:
      `grep -rniE 'mail session|почтов' plugins docs/model docs/llm README.md` — 2026-10-29: скилл (с прежним именем
      для старых писем), README, `docs/model/suite.md` (и абзац о границе переименования); в `docs/llm` термина нет
- [x] Ключ `intercom.mail-session` и поле `session: mail`: оставить или переименовать. Ключ доходит до владельца через
      строку 📨 (Текущая модель). При переименовании старый ключ читается и дальше: он закоммичен в проектах —
      владелец 2026-10-29, DL #3: ключ `intercom.session`, старшинство нового, поле конверта осталось
- [ ] Бриф vdx: в его строке старта сессии intercom то же «mail session». Отправить, когда имя подтверждено
- [ ] Outcome to `echelon` — окончательный. Промежуточный ушёл 28.10 (`intercom-session-name-outcome`), поэтому slug
      свой: intercom reply intercom-session-name --slug intercom-session-name-result --done "<what was done>" --link <url> --ball "<who holds the ball — what ⏰ date>"

## References

- Письмо echelon `intercom-session-name`, 28.10, ящик intercom `ai-dev-plugins/_done/`. Продолжает цепочку
  `mail-session-candidate-signal` (`/vdm:intercom chain intercom-session-name`).
- [[intercom-mail-candidates/workitem|intercom-mail-candidates]] — его сигнал владельцу назовёт эту сессию; имя оттуда
  берётся отсюда.
- [[intercom-session-wake/workitem|intercom-session-wake]] — где сессия появилась (закрыт).
