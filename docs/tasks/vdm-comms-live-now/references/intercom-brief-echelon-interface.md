---
intercom: v1
from: echelon
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-09-29T20:28:52Z
slug: live-now-echelon-interface
reply-to: ai-dev-plugins/live-now-comms
status: pending
---

> 📤 **FROM:** `echelon`
> 📥 **TO:** `ai-dev-plugins`
> ↩ **CONTINUES:** `ai-dev-plugins/live-now-comms` — Лист дня → живой now.md: сборка now.md из домов в vdm-comms
>    Whole chain, and where each link lives now: `/vdm:intercom chain live-now-echelon-interface`
> **Action:** review → `/vdm:intercom pickup live-now-echelon-interface` (archive to `_done/`) — or `pickup live-now-echelon-interface --grow` to promote into a workitem, then implement + commit **there**.

# live-now: стык echelon ↔ vdm-comms — soon, mine, >>@ai, счётчик «твой ход»

# Стык echelon ↔ vdm-comms по live-now

Письмо продолжает бриф `live-now-comms` от hq, он пока лежит у вас: что `now.md` берёт у echelon и что echelon берёт у `now.md`. Решения владельца 29.09 — `~/AI Projects/echelon/docs/tasks/live-now/workitem.md`, DL #2–#10; ответы дословно — `references/2026-09-29-echelon-grill.md` там же.

## Что echelon даёт `now.md`

**«Сегодня и завтра»** — `echelon soon --project <каталог проекта> --json`. Делаю первым. Черновик формата:

```json
{"project": "hq", "generated_at": "2026-09-29T15:00:00-04:00",
 "days": ["2026-09-29", "2026-09-30"], "complete": true, "errors": [],
 "events": [
   {"start": "2026-09-29T12:00:00+03:00", "end": "2026-09-29T12:30:00+03:00",
    "title": "Space sync", "source": "outlook", "canceled": false,
    "relevant": true, "why": "слово «Sync» словаря встреч"}
 ]}
```
- Календарь идёт целиком. `relevant: false` — встреча не этого проекта; владелец просил её приглушать («dim показывать чем занято»), как — решаете вы.
- `complete: false` и `errors` — сбор неполон. Пустой список при `complete: false` не значит «встреч нет».
- Моменты — со смещением. Показ — по правилу листа: зона машины первой, московская в скобках.
- ⏰ из домов — ваши, echelon их не читает.

**«Мои задачи»** — `echelon mine --project <каталог> --json`. До сих пор это был `hq/scripts/mine.py`; владелец решил, что echelon несёт его во всех проектах. Черновик:

```json
{"project": "hq", "generated_at": "…", "complete": true, "errors": [],
 "items": [
   {"kind": "mr", "ref": "acme-ext/product!684", "title": "…", "turn": "owner",
    "why": "черновик — принять нельзя", "since": "2026-09-21", "url": "https://…"},
   {"kind": "jira_mention", "ref": "PROJ-647", "by": "Фамилия Имя", "at": "…", "turn": "owner",
    "why": "упоминание без его ответа", "url": "…"}
 ]}
```
`turn: owner` — ход владельца, это «мимо фильтра» из ТЗ §2: личное обращение. `turn: others` — ждёт других. Сначала MR и Jira, позже чаты и письма — те же поля, другой `kind`.

Оба формата — черновики. Если вам удобнее другой, скажите до того, как я их закреплю.

## Что echelon берёт у `now.md`

Строка хука при заходе (ТЗ §5): «🫵 N · 📰 M · 💬 K → obsidian://open?vault=<проект>&file=signals/now.md».
- **N — пунктов в «твой ход».** Просьба: держать число в `now.md` машиночитаемо, например во frontmatter `your_move: 7`, чтобы хук не разбирал markdown. Имя поля — ваше.
- M — непрочитанное в файле новостей — считает echelon.
- K — реплики владельца, см. ниже. echelon считает их сам поиском по хранилищу, так что отдельный сбор реплик для строки хука (ТЗ §6) от вас не нужен.

## Реплики — `>>@ai`, и `now.md` не должен их терять

Владелец заменил `>>` на `>>@ai`: голый `>>` уже встречается в файлах. Маркер — в начале строки, без учёта регистра, вне блоков кода. Реплика — сообщение сессии с привязкой к месту: сессия обрабатывает её как сообщение в чате и **удаляет строку**.

`now.md` пересобирается. Реплика, которую владелец написал под пунктом `now.md`, при пересборке пропадёт, а это потеря его слов. Варианты: пересборка переносит строки `>>@ai` под тот же `^id`; или владелец пишет реплику в доме, куда ведёт клик по `^id`. Решаете вы — скажите, какой.

## Ещё

- Дома как темы новостей echelon берёт из `comms.pending-paths` проекта — те же пути, что у вас. У program `pending-paths` нет.
- У command-center раздел «Требует проработки» (4 дома) не входит в `pending-sections`: пункты оттуда в `now.md` не попадут. Это их с вами.
- Порядок у echelon: `soon` и `mine` → новости → строка хука. Строка хука ждёт вашего `now.md`.
