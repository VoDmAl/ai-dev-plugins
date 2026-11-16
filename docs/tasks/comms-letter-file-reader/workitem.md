---
title: "vdm-comms: письмо с текстом одним вызовом comms-new и читатель файла письма в JSON для echelon"
slug: comms-letter-file-reader
description: "Дать comms-new текст письма одним вызовом и вызов «файл письма → адресаты, тема, текст, вложения» в JSON"
status: ready
session-type: prd-prep
created: 2026-11-03
last-updated: 2026-11-16
relates-to:
  - "[[comms-thread-contract/workitem|comms-thread-contract]]"
  - "[[vdm-comms-letter-form/workitem|vdm-comms-letter-form]]"
---

# vdm-comms: письмо с текстом одним вызовом comms-new и читатель файла письма в JSON для echelon

> Заведён сессией intercom 2026-11-03 по письму echelon `mail-draft-file-letter-reader`. Делает основная сессия
> владельца: это правка `comms-new.py` и новый вызов vdm-comms, а сессия intercom код не правит. Письмо
> пересказано, адрес — в DL #1.

## Назначение

**Входящее.** С 2026-11-03 echelon создаёт черновик почты (`mail_draft`) для штаба, который держит письма файлами,
только из файла письма. Так решил владелец 2026-10-29 в сессии echelon. Echelon просит у vdm-comms две вещи:

1. **Короткий ответ одним вызовом.** Сейчас даже «Спасибо, получил» требует трёх шагов: `comms-new.py`, правка файла
   руками, `mail_draft`. Слово владельца 2026-10-29, в пересказе echelon: трение у коротких ответов снимает шаблон,
   файл создаёт инструмент. Нужен вид `comms-new.py`, который сразу пишет и текст (echelon предлагает
   `--body-stdin` или `--text "…"`): файл письма с шапкой формы проекта, разделителем и текстом, без правки руками.
2. **Читатель файла письма у vdm-comms.** Принцип echelon: один контракт — один парсер. Нужен вызов «файл письма →
   адресаты (slug и адрес), копия, тема, текст, вложения» в JSON, стабильный, как `comms-pending --json`. Тогда
   echelon перейдёт на него, и разные формы `to`/`person` в проектах будет разбирать тот, кто их задаёт
   (`comms.letter-form`).

Сейчас echelon читает файл сам и минимально: шапка YAML; текст — после первого `---` за шапкой (как `comms_unwrap` и
`intercom send --body`); адресаты — `to`, у штаба программы `person`, и `cc`: slug из `people/` → `identity.email`;
тема — `subject`; вложения — `attachments`.

**Критерий успеха.** Короткий ответ пишется одним вызовом `comms-new`, и файл проходит `comms-lint` без правки.
Echelon берёт адресатов, тему, текст и вложения из одного вызова vdm-comms для писем всех трёх штабов, и тема со
строки тела не теряется. Ключи JSON закреплены тестом и описаны в скиле.

## Текущая модель

Замер 2026-11-03, vdm-comms 0.41.0 в рабочем дереве:

- **`comms-new.py`** принимает `--channel --to --track [--name] [--subject] [--project-root]`. Он пишет
  `<track>/comms/<сегодня>-<to>-out.md` по `comms.letter-form` проекта: `draft: true`, `channel:`, `register:`,
  пустой `goal:`, заголовок `# → <name>`, строку темы `**Тема**: …` в теле (если канал её требует), строку адресатов
  `**Кому:** — · **Копия:** — · **Скрытая:** —` (если проект требует `recipients`), разделитель и вместо текста
  заглушку-метку. Существующий файл не перезаписывает, потом печатает чек-лист и строку из `people/` об адресате.
  Аргумента для текста нет.
- **Где vdm-comms ищет тему и адресатов.** В строках тела, не в шапке: `comms-lint.py` проверяет тему по
  `SUBJECT_RE` (`^\*\*(Subject|Тема)\*\*:`) в части до разделителя, адресатов по `RECIPIENTS_RE`. Из шапки письма
  скрипты vdm-comms читают `draft`, `channel`, `register`, `goal`, `sent` и `attachments`. Ключи `to:`, `person:`,
  `cc:` и `subject:` в шапке не читает ни один скрипт `plugins/vdm-comms/scripts/*.py`, а echelon берёт адресатов и
  тему именно оттуда.
- **Что лежит в поле.** Счёт по 1045 файлам `*-out.md` в каталогах `comms/` трёх проектов с деревом писем
  (`references/letter_shapes.py`):

  | | файлов | тема в шапке | тема строкой тела | адресаты в шапке | адресаты строкой тела |
  |---|---|---|---|---|---|
  | штаб программы | 494 | 454 | 188 | `person:` 452, `to:` 34, `cc:` 6 | 256 |
  | второй штаб | 315 | 8 | 212 | `to:` 147, `cc:` 76 | 4 |
  | третий штаб | 236 | 0 | 76 | `to:` 185, `cc:` 26 | 1 |

  Тема живёт в шапке у одного штаба, а у двух других — строкой тела. Нынешний читатель echelon, который берёт
  `subject` из шапки, у второго и третьего штабов темы не находит. Адресаты почти везде в шапке, но под разными
  ключами (`to` или `person`). У штаба программы рядом есть и строка тела.
- **Адрес по slug.** `comms_people.find(pdir, who)` находит профиль `people/<slug>.md`, `read_profile` читает из него
  `identity:` (`email:`, пары `mail_from`). Значит, адрес для JSON можно взять из готового кода, без нового парсера
  профилей.
- **Текст после разделителя** уже выделяют два места: `comms_unwrap` (после `---` или всё тело, если разделителя
  нет) и `intercom send --body` для файла с `channel:`. Читатель должен резать текст так же, как они, иначе
  «отправлено» и «сохранено» разойдутся.

## Decision Log

### #1 / 2026-11-03 / Принять как кристалл для основной сессии, замер поля — echelon сразу

**Source:** assistant
**Basis:** observed
**Basis-detail:** письмо echelon `mail-draft-file-letter-reader` от 2026-11-03 (intercom,
`ai-dev-plugins/_done/mail-draft-file-letter-reader`), мяч: «`comms-new` с текстом одним вызовом и вызов-читатель
письма в JSON (или сказать, почему нет) ⏰ пересмотр 2026-11-10». Письмо пересказано, а не скопировано: это чужой
текст, в нём имена чужих репозиториев (Critical Rule 7). Правило сессии intercom взято из строки старта сессии:
работа, меняющая код, уходит основной сессии кристаллом. Счёт по полю — `references/letter_shapes.py`, запуск
2026-11-03 по `~/AI Projects`. Вывод с именами проектов не сохранён, штабы в таблице названы по роли.
**Context:** сессия intercom может ответить, но не может править `comms-new.py` и писать новый вызов: рабочее дерево
общее с основной сессией.
**Why:** что уже есть и как письма выглядят в поле, видно сейчас. Нынешнему читателю echelon это нужно сразу: у двух
штабов из трёх он теряет тему. Форму вызова и контракт JSON решает основная сессия.
**Implication:** echelon получает частичный итог сейчас (`reply`: принято, замер поля). Окончательный итог уходит
письмом `mail-draft-file-letter-reader-result` к дате пересмотра echelon 2026-11-10.

## Sidetracks

### #1. Нынешний читатель echelon теряет тему, записанную строкой тела

**Возникло в:** Текущая модель → «Что лежит в поле»
**Описание:** echelon берёт тему из `subject:` шапки. У второго и третьего штабов тема почти всегда записана строкой
`**Тема**:` в теле (212 из 315 и 76 из 236 писем), так что черновик почты из такого файла уйдёт без темы или с
чужой. Это код echelon, и сказано ему в частичном итоге 2026-11-03. Закрывается, когда echelon перейдёт на читатель
vdm-comms.

**Status:** open

## Next actions

- [ ] Форма `comms-new` с текстом: `--text "…"`, `--body-stdin` или `--body <file>`, как у `intercom send`. Текст
      ложится после разделителя на место заглушки; канал без разделителя — решить; чек-лист и строка `people/`
      печатаются как сейчас; файл проходит `comms-lint` без правки
- [ ] Решить, откуда читатель берёт тему и адресатов: в поле обе формы (Текущая модель). Варианты — по
      `comms.letter-form` проекта, обе с приоритетом шапки или обе с приоритетом тела. Записать в DL
- [ ] Читатель файла письма: вызов vdm-comms → JSON с адресатами (slug и адрес из `people/` → `identity.email`),
      копией, темой, текстом (разрез — как у `comms_unwrap` и `intercom send --body`) и вложениями (`attachments:`)
- [ ] Закрепить ключи JSON читателя тестом как контракт с echelon и записать в скиле `meetings`, что имена и смысл
      меняются только с письмом echelon заранее (так же, как п. 6 в
      [[comms-thread-contract/workitem|comms-thread-contract]])
- [ ] Sidetrack #1: echelon читает письма через читатель vdm-comms — сверить его вызов после выпуска
- [ ] Outcome to `echelon`: что сделано и в какой версии vdm-comms, или почему нет —
      `intercom reply mail-draft-file-letter-reader --slug mail-draft-file-letter-reader-result --done "<что>" --ball "<кто — что ⏰ дата>"`
      — срок 10.11 прошёл; 16.11 echelon сказан новый, слово владельца (DL #7
      [[comms-thread-contract/workitem|comms-thread-contract]]) (due: 2026-11-24)

## References

- Письмо echelon: intercom `ai-dev-plugins/_done/mail-draft-file-letter-reader` (2026-11-03), пересказано выше.
- `references/letter_shapes.py` — счёт тем и адресатов в шапке и в теле по файлам `*-out.md`; запуск:
  `python3 -I docs/tasks/comms-letter-file-reader/references/letter_shapes.py "~/AI Projects"`.
- Код: `plugins/vdm-comms/scripts/comms-new.py` (`render`, `main`), `plugins/vdm-comms/scripts/comms-lint.py`
  (`SUBJECT_RE`, `RECIPIENTS_RE`, проверка `attachments:`), `plugins/vdm-comms/scripts/comms_people.py` (`find`,
  `read_profile`), `plugins/vdm-comms/scripts/comms_unwrap.py`; скил `plugins/vdm-comms/skills/meetings/SKILL.md`
  (`letter-form`, «The form of a draft»).
