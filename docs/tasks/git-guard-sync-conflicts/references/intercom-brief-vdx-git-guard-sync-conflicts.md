---
intercom: v1
from: vdx
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-09-30T16:48:16Z
slug: git-guard-sync-conflicts
status: pending
---

> 📤 **FROM:** `vdx`
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup git-guard-sync-conflicts` (archive to `_done/`) — or `pickup git-guard-sync-conflicts --grow` to promote into a workitem, then implement + commit **there**.

# git-guard-prepare: отказ, пока в .git лежат конфликтные копии Syncthing

**Что нужно.** `git-guard-prepare` отказывает, если в `.git` репо лежат конфликтные копии Syncthing (`*.sync-conflict-*`), и называет их. Для копии ссылки ветки (`refs/heads/<ветка>.sync-conflict-…`) — называет коммит из неё и говорит, есть ли он в ветке. Коммит не в ветке — это выпавший коммит: его надо вернуть раньше, чем сверху ляжет новый. Решение владельца 30.09.

**Почему.** `~/AI Projects` и `~/PhpstormProjects` синхронизирует Syncthing вместе с `.git`, и владелец работает в одном репо с двух машин одновременно. Когда обе машины пишут один файл в `.git`, Syncthing оставляет одну версию, а другую кладёт рядом как `*.sync-conflict-*`. Сейчас этого никто не видит:

- hq, 11.09: `refs/heads/main.sync-conflict-20260911-095658-N223K43` — коммит `b15fb45` выпал из `main`. Копия лежит до сих пор, git показывает её как ветку.
- vdx, 30.09: `.git/index.sync-conflict-20260930-120918-N223K43` — в живом индексе остался `cli/package.json` 0.13.0 при HEAD 0.13.1, `git status` показывал `MM`. Помогло `git reset -- cli/package.json` и удаление копии.

На lft 30.09 нашлось 22 такие копии внутри `.git` в 6 репо.

**Готово, когда:**

- есть копия в `.git` → `git-guard-prepare` выходит с ненулевым кодом, ничего не готовит, печатает пути копий и что делать;
- для копии ссылки в выводе есть коммит и «в ветке / не в ветке»;
- копий нет → поведение прежнее.

Остальная защита — у executor: настройка git против гонки за индекс, оповещение о копиях, уборка накопленного.

Решение и замеры: `vdx/docs/tasks/vdx-ai/workitem.md`, DL #17.
