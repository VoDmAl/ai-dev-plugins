---
title: "comms: `sent-proof:` для письма, которое владелец отправил сам из почты"
slug: comms-sent-proof-hand-sent
description: "Принять Message-ID письма, отправленного руками, когда его видно в почте проекта"
status: blocked
session-type: prd-prep
created: 2026-10-30
last-updated: 2026-11-02
relates-to:
  - "[[outgoing-ladder/workitem|outgoing-ladder]]"
  - "[[vdm-comms-mail/workitem|vdm-comms-mail]]"
---

# comms: `sent-proof:` для письма, которое владелец отправил сам из почты

## Назначение

**Входящее.** Бриф агента рабочего проекта от 2026-10-30 (intercom, slug
`comms-sent-proof-reply-quote`). Случай: владелец отправил письмо контрагенту сам, из
почтового клиента. На следующий день пришёл ответ контрагента: в `In-Reply-To` стоит
Message-ID нашего письма, в цитате наш текст. Агент поставил в `-out.md` `sent:` и
`sent-proof: <наш Message-ID>`, и `comms-draft-guard` отказал: «в журнале echelon нет
отправки … от <проекта>». Осталось два выхода: id из журнала или `sent-proof: owner`.
Файл так и остаётся `draft: true`, пока владелец не скажет своё слово, хотя
доказательство уже лежит в почте проекта.

**Цель.** Письмо, отправленное руками, получает проверяемое доказательство вместо слова
владельца, когда его видно в почте проекта: оно лежит в «Отправленных» с этим
Message-ID, или входящее отвечает на этот Message-ID.

**Ограничение.** Гейт по-прежнему не принимает id, которого никто не видел: «нет»
остаётся «нет», если письма нет ни в журнале, ни в почте проекта.

**Критерий успеха.** Повтор случая из брифа: `sent-proof: <Message-ID письма, отправленного
руками>` проходит гейт без слова владельца, а выдуманный Message-ID по-прежнему получает
отказ.

## Текущая модель

- Гейт плагина (`plugins/vdm-comms/scripts/comms_sent_proof.py`, `journal_says`) спрашивает
  `<access layer> sent <каталог письма> <id>` и отказывает только на код 1.
- `echelon sent` (`runtime/echelon/sent.py` в его checkout'е) читает **только журнал
  отправок** echelon с диска, без сети. Message-ID, которого нет в журнале, получает 1
  («нет»). Письмо, которое владелец отправил руками, в журнал не попадает никогда.
- Записи почты у echelon (`runtime/echelon/mail.py`, словарь `rec`) несут `message_id`,
  `sent` (ярлык `\Sent`) и `in_reply_to`. Поля `references` в записи нет.
- Значит, исправление на стороне echelon: перед ответом «нет» на Message-ID смотреть в почту
  проекта. Письмо с этим Message-ID и `sent: true` означает, что его отправили руками.
  Входящее с `in_reply_to`, равным этому id, означает, что на него ответили. Форма поля
  в плагине остаётся прежней (DL #1).
- Записи на диске есть (проверено 2026-10-30): `data/snapshot/mail.json` в checkout'е access
  layer, `messages` — 1065 писем за 2026-09-30…2026-10-30, у каждого `message_id`, `sent`,
  `in_reply_to` и `for` (проекты по `mail.yaml`). Окно снимка — 30 дней: письмо старше
  так не найдётся.
- echelon принял исправление (outcome `sent-hand-sent-mail-outcome`, 2026-10-30), реализация
  в его очереди. По его словам: строки FOUND — «отправлено руками, в Отправленных: <дата>
  <тема>» и «на него ответили: <дата> <от кого>»; строка ABSENT будет называть окно
  снимка; `References` хранить не будут. Пока не сделано, `sent` на такой id отвечает 1.
- Проверено 2026-11-02: не сделано. Кристалл echelon `sent-hand-sent-mail` в `ready`, все его пункты открыты, `sent.py` не менялся
  с 2026-10-13. Здесь до его итога работы нет, поэтому статус `blocked`.

## Decision Log

### #1 / 2026-10-30 / Проверку расширяет echelon; в плагине одна форма поля, без `sent-proof: reply …`

**Source:** assistant
**Basis:** observed
**Basis-detail:** прочитано 2026-10-30 в checkout'е access layer: `runtime/echelon/sent.py`
(`check`: только `data/journal/mcp-*.jsonl`, Message-ID не из журнала → `ABSENT`) и
`runtime/echelon/mail.py` (`rec` с `message_id`, `sent`, `in_reply_to`). **Не проверено:**
лежат ли эти записи на диске как почта *проекта* (срез или зеркало, по `mail.yaml`), так
что `sent` сможет их прочесть без сети. Не проверено и то, открыта ли почта проекту из
брифа. `References` в записи нет, поэтому ответ глубже в ветке (его `In-Reply-To` указывает
на более позднее письмо) так не найдётся.
**Context:** бриф предлагал третий вид доказательства: `sent-proof: reply <message_id ответа>`
или наш Message-ID с проверкой по входящим проекта, через `mail_message` echelon или по
comms-файлу входящего.
**Why:** почта есть только у echelon, поэтому при любой форме поля спрашивать придётся его.
Если echelon сам ищет Message-ID в почте проекта, у плагина не появляется третьего
синтаксиса, а хуки старых версий получают исправление без обновления. Поиск в
«Отправленных» закрывает и письма, на которые ещё не ответили, а этого «ответ» не умеет.
Comms-файл входящего не годится как источник: формат входящих `-in.md` не канонизирован
(`vdm-comms-mail` в `ready`), а агент сам пишет его, в том числе и `in_reply_to`.
**Implication:** бриф echelon'у. На стороне плагина остаются только тексты: подсказки
отказа, SKILL и заметка RECONCILE: письмо, найденное в «Отправленных», даёт свой Message-ID
вместо `owner`. Форма `reply …` нужна, только если echelon откажется.

## Sidetracks

## Next actions

- [x] Бриф echelon: `sent` на Message-ID, которого нет в журнале, ищет в почте проекта:
      письмо с этим Message-ID и `sent: true`, или входящее с `in_reply_to` (и, если
      появится, `references`), равным ему. Найдено → 0 со строкой «отправлено руками: в
      Отправленных / на него ответили <id>». Отправлен 2026-10-30, intercom
      `echelon/sent-hand-sent-mail`; запущена intercom-сессия echelon на `lft`
- [x] Ответ echelon на `sent-hand-sent-mail` — пришёл 2026-10-30, intercom
      `sent-hand-sent-mail-outcome`: принято, кристалл `sent-hand-sent-mail` у echelon, код
      правит его основная сессия; итог обещан отдельным письмом (см. «Текущая модель»)
- [ ] Итог echelon по реализации в `sent.check` — when: в ящике `ai-dev-plugins` лежит его
      второе письмо по `sent-hand-sent-mail` (без даты, по очереди основной сессии echelon);
      check: `intercom check`, затем `intercom chain <slug>`
- [ ] Тексты плагина, когда echelon пришлёт итог (не раньше: до него `sent` отвечает 1) —
      when: пункт выше закрыт. Править `HOWTO` и `NOT_IN_JOURNAL` в `comms_sent_proof.py`,
      `meetings` SKILL § Outgoing letters, `letters` SKILL (абзацы про `sent-proof:`) и
      README. В RECONCILE: письмо, найденное в «Отправленных», даёт свой Message-ID вместо
      `owner`. В отказе: письмо старше окна снимка (30 дней) — только `owner`; строки
      FOUND/ABSENT сверить с тем, что `sent` выводит в итоге. Версия vdm-comms,
      marketplace, changelog
- [ ] Второй outcome агенту рабочего проекта, приславшему бриф, когда тексты выйдут:
      `intercom reply comms-sent-proof-reply-quote --slug comms-sent-proof-reply-quote-shipped --done "…" --ball "…"`
      (`reply` берёт письмо и из `_done/`)

## References

- Бриф не скопирован: в нём реальные имена, Message-ID и пути чужого рабочего репозитория,
  а этот репозиторий публичный (Critical Rule 7). Адрес: intercom-store, ящик
  `ai-dev-plugins`, slug `comms-sent-proof-reply-quote`, после ответа в `_done/`.
- Происхождение `sent-proof:` и проверки по журналу: [[outgoing-ladder/workitem|outgoing-ladder]], DL #2–#7.
