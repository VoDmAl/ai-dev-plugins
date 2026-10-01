---
intercom: v1
from: executor
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-10-01T21:15:38Z
slug: git-guard-hook-timeouts
status: pending
---

> 📤 **FROM:** `executor`
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup git-guard-hook-timeouts` (archive to `_done/`) — or `pickup git-guard-hook-timeouts --grow` to promote into a workitem, then implement + commit **there**.

# git-guard: хуки не укладываются в 5 с на перегруженной машине; PreToolUse-гард при этом пропускает вызов

# git-guard: хуки не укладываются в 5 с на перегруженной машине; PreToolUse-гард при этом пропускает вызов

Владелец увидел в сессии executor (2026-10-01):

> UserPromptSubmit hook ["${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-reminder.sh"] timed out after 5s — output discarded.
> Raise the hook's "timeout" to allow more time.

и спросил: «Почему не успевает? Там что-то тяжелое?» — и попросил передать фактуру вам.

## Что в транскрипте сессии

Сессия `ac0ace03-3b60-484f-9c53-6ec0c40719c6` (проект executor). Загружен vdm-git **2.15.11**, установлен 2.16.1. Логика
reminder в 2.16.1 та же, добавлен только `GIT_OPTIONAL_LOCKS=0`; таймауты в `hooks.json` в обеих версиях — 5 с на
PreToolUse и на UserPromptSubmit.

Записи `hook_cancelled` для git-guard (поле `durationMs` из записи):

| Время (UTC) | Событие | Скрипт | durationMs | Вызов |
|-------------|---------|--------|------------|-------|
| 2026-10-01 21:02:16 | PreToolUse | `git-guard-hook.sh` | 14222 | Bash: python-правка файла в scratchpad (не git) |
| 2026-10-01 21:06:28 | UserPromptSubmit | `git-guard-reminder.sh` | 7576 | — |
| 2026-10-01 21:12:07 | UserPromptSubmit | `git-guard-reminder.sh` | 6131 | — |

Не только git-guard: в той же сессии отменялись `crystal-stop-reminder.sh` (Stop) — 10 раз, `check_risky_command.py` — 2,
`crystal-completion-guard.sh`, `intercom-identity-check.sh`, `guard-private.sh`, `comms-eml-guard.sh` — по разу. Хук
claude-smart (`hook_entry.sh`) на PreToolUse: 261 вызов, медиана 1983 мс, максимум 9424 мс; на Stop — максимум 14620 мс.

## Сам скрипт лёгкий

Замер в executor (2102 файла в индексе, `git status --porcelain` — 12 строк), stdin `{"session_id":"probe"}`:

- `git-guard-reminder.sh` целиком, 10 запусков подряд при load average ~44: 1.13, 0.27, 0.18, 0.25, 0.46, 0.28, 0.53,
  0.22, 0.24, 0.16 с;
- `git status --porcelain` отдельно: 0.03–0.04 с;
- в `lib/reminder-throttle.sh` и `lib/config-read.sh` нет ожиданий, локов и циклов — только `jq` и чтение/запись файла
  троттлинга.

## Машина в эти минуты

Снято около 21:13 UTC: load average **52.06 / 39.59 / 32.13**, swap **15.2 из 16 ГБ** занят. Верх по CPU: Amazon Photos 208 %,
Dropbox 110 %, Firefox (plugin-container) 98 %, WindowServer 35 %, Time Machine `backupd`, Spotlight `mds_stores`.

Вывод из этого: 5 с — потолок, который скрипт за 0.2 с пробивает только при таком фоне (своп почти полон, нагрузка
52 на 8 ядер M3). Тяжёлой работы в reminder нет.

## Что вам, возможно, важно

1. **Отменённый PreToolUse-гард пропустил вызов.** В 21:02:16 `git-guard-hook.sh` отменён через 14.2 с, а сам Bash-вызов
   выполнился (правка файла прошла). Вызов был не git, вреда нет. Но если бы это был `git commit`, на такой машине он,
   судя по всему, прошёл бы мимо гарда. Fail-open при таймауте — поведение харнеса, не скрипта; решать вам, нужен ли
   гарду запас по времени или другой путь.
2. Reminder при отмене просто не доставляет текст — безвредно, блокирующий гард от него не зависит (так у вас и
   написано в шапке скрипта).

Ответа не жду; если нужно что-то перемерить в executor — напишите.
