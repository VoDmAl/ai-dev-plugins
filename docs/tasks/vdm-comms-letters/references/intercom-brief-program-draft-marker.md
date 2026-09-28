---
intercom: v1
from: program
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-09-26T21:23:49Z
slug: comms-draft-marker-and-channel-template
status: pending
---

> 📤 **FROM:** `program`
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup comms-draft-marker-and-channel-template` (archive to `_done/`) — or `pickup comms-draft-marker-and-channel-template --grow` to promote into a workitem, then implement + commit **there**.

# vdm-comms: наши драфты (sent: false) плагину не видны; нет заготовки письма под канал

Два наблюдения из program, оба проверены на vdm-comms 0.6.0 в этой сессии (26.09.2026).

## 1. Наши драфты для плагина не существуют

**Что видно.** `comms-pending.py --all --json` на репозитории program выдаёт пустой вывод, хотя в `**/comms/` лежат четыре неотправленных письма. `comms-pending.py --lint <файл>` на новом SMS-драфте — exit 0, ни одного замечания.

**Почему.** `letter_flags()` в `scripts/comms-pending.py` (≈стр. 593–607) считает драфтом только `draft: true`:

```python
return keys.get("draft") is True, keys.get("sent") not in (None, "", False)
```

В program драфт с первого дня помечается `sent: false` — это закон проекта (CLAUDE.md, правило 3: «Пока не отправлено — `sent: false` во frontmatter»), на нём стоят наш `scripts/queue.py`, Dataview-витрина и Stop-хуки. `draft:` у нас нет ни в одном файле. Значит, `unsent_drafts`, проверка формы по каналу (`letter-form`) и draft guard нас молча пропускают — и тихий пропуск неотличим от «всё в порядке».

**Что прошу.** Любой из вариантов:
- считать драфтом и явное `sent: false` (оно уже разбирается как «не отправлено» — `False` стоит в списке); или
- ключ проекта в `comms` — например `draft-marker: "sent: false"` / `draft-when: sent-false`; или
- хотя бы предупреждение при старте, если в `comms/` есть `*-out.md` с `sent: false` и ни одного `draft: true`: «по этим файлам плагин ничего не проверяет».

**Критерий готовности:** на program `comms-pending.py` показывает те же четыре письма, что наш `python3 scripts/queue.py` (секция 📮), и `--lint` на SMS без `channel:` даёт замечание.

## 2. Нет заготовки письма под канал

SKILL.md (`meetings`, «The form of a draft, per channel») перечисляет, что драфт **должен иметь** — `channel`, `separator`, для email `subject`, — и проверяет это **после** записи. Заготовки нет: ни шаблона, ни команды «создай драфт SMS для <кому> в <трек>».

Поэтому сегодня, делая SMS, я пошёл искать похожий файл в репозитории и скопировал его шапку. Вместе с ней переехал `goal: |` (многострочный YAML), на котором, по нашим прошлым наблюдениям, спотыкается `comms-lint`. Пример из репозитория — это копия, а копия переносит и ошибки.

**Что прошу:** заготовку по каналу — шаблон в плагине или скрипт вида `comms-new --channel sms --to <slug> --track <path>`. Он кладёт файл с правильной шапкой по `letter-form` проекта: однострочный `goal:`, маркер драфта в той форме, в какой его понимает сам плагин (см. п. 1), и разделитель.

## Контекст

- Прошлая записка про тот же плагин: `comms-eml-guard-apostrophe-heredoc` (26.09).
- Где видно на нашей стороне: `meetings/2026-09-14-first-troop-meeting/comms/2026-09-26-john-doe-out.md` — новый SMS-драфт, по которому плагин ничего не сказал.

