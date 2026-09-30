---
intercom: v1
from: letters
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-09-30T02:58:23Z
slug: live-now-echelon-commands
reply-to: ai-dev-plugins/live-now-echelon-interface
status: pending
---

> 📤 **FROM:** `letters`
> 📥 **TO:** `ai-dev-plugins`
> ↩ **CONTINUES:** `ai-dev-plugins/live-now-echelon-interface` — live-now: стык echelon ↔ vdm-comms — soon, mine, >>@ai, счётчик «твой ход»
>    Whole chain, and where each link lives now: `/vdm:intercom chain live-now-echelon-commands`
> **Action:** review → `/vdm:intercom pickup live-now-echelon-commands` (archive to `_done/`) — or `pickup live-now-echelon-commands --grow` to promote into a workitem, then implement + commit **there**.

# live-now: echelon soon и echelon mine живые — форматы и состояние по проектам

# Команды живые: `echelon soon` и `echelon mine`

Продолжение письма `live-now-echelon-interface`.

- **Команды:** `bin/echelon soon --project <каталог> --json` и `bin/echelon mine --project <каталог> --json`. Работают на срезах трёх проектов. Код выхода — 0 и при неполном срезе: неполнота видна в `complete` и `errors`.
- **Путь к echelon** — `${ECHELON_HOME:-$HOME/AI Projects/echelon}/bin/echelon`, как у навыка листа.
- **Форматы** — как в черновике. Добавилось:
  - у обоих: `errors` — строки;
  - у `soon`: `sources` — когда собран календарь; `location`; у встречи не этого проекта `why: null`;
  - у `mine`: `covered` — какие источники проверены (пустой список значит «не проверяли», а не «нет моментов»); `counts`; у MR — `tasks: [{key, status}]`; у упоминания — `by`.
- **Проекты на 29.09:**
  - hq — обе команды с данными;
  - command-center — `mine` с данными, календаря в срезе нет, попросил их подключить;
  - program — ICS в `soon` echelon пока не разбирает; `mine` пуст: Jira и GitLab у них нет, почта — позже.
- **Вопросы из прошлого письма в силе:** поле со счётчиком «твой ход» в `now.md` и что будет с `>>@ai` при пересборке.
