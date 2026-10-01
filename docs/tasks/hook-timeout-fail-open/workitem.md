---
title: "Блокирующий гард, отменённый по таймауту, пропускает вызов: таймауты и matcher хуков суиты"
slug: hook-timeout-fail-open
description: "PreToolUse-гард, отменённый по таймауту, пропускает вызов — дать блокирующим гардам запас и matcher"
status: ready
session-type: prd-prep
created: 2026-10-01
last-updated: 2026-10-01
---

# Блокирующий гард, отменённый по таймауту, пропускает вызов: таймауты и matcher хуков суиты

> Бриф executor `git-guard-hook-timeouts` (2026-10-01): на перегруженной машине хуки суиты не укладываются в
> 5 с, а отменённый PreToolUse-гард `git-guard-hook.sh` не остановил вызов — Bash выполнился. Вызов был не git,
> но `git commit` прошёл бы так же. Дефект не одного гарда: все блокирующие гарды суиты стоят на 5 с.

## Назначение

**Цель.** Блокирующий гард суиты не теряет силу оттого, что машина перегружена: его таймаут — с запасом,
который ничего не стоит, пока скрипт быстрый; срабатывает он только на те вызовы, которые охраняет.

**Ограничения.** Отмена хука по таймауту и пропуск вызова — поведение харнеса, не наших скриптов; менять мы
можем только `timeout` и `matcher` в `hooks.json` и цену самих скриптов. Советующие хуки (напоминания,
Stop) при отмене просто молчат — их дефектом это не считается, пока не доказано обратное.

**Критерий успеха.** У каждого блокирующего PreToolUse-гарда `timeout` выбран замером и держится тестом на
конфиг; `git-guard-hook.sh` запускается только на нужные ему инструменты — или записано, почему на все.

## Текущая модель

Состояние на 2026-10-01:

- **Харнес пропускает вызов, если блокирующий хук отменён по таймауту** — наблюдено. Транскрипт сессии
  executor `ac0ace03-3b60-484f-9c53-6ec0c40719c6`: запись `hook_cancelled`, `hookName: PreToolUse:Bash`,
  `git-guard-hook.sh`, `timedOut: true`, `timeoutMs: 5000`, `durationMs: 14222` (21:02:16Z); результат того же
  Bash-вызова — `ok` в 21:02:29Z.
- **Таймауты в репо** (`plugins/*/hooks/hooks.json`, 2026-10-01). Блокирующие PreToolUse: `git-guard-hook.sh` —
  5 с, **без matcher** (все инструменты); `crystal-completion-guard.sh` — 5 с; `comms-draft-guard.sh` — 5 с;
  `comms-eml-guard.sh` — 5 с. Советующие: `git-guard-reminder.sh` (UserPromptSubmit) — 5 с, `reminders.sh` —
  30 с, `crystal-stop-reminder.sh` (Stop) — 5 с; PostToolUse — 5–10 с; SessionStart — 5–10 с.
- **Сам скрипт лёгкий — по письму.** Замер executor: `git-guard-reminder.sh` 0,16–1,13 с при load average
  ~44, `git status --porcelain` 0,03–0,04 с. Машина в те минуты: load average 52 / 40 / 32, swap 15,2 из 16 ГБ.
  Не перемерено здесь.
- **В той же сессии отменялись и другие хуки** — по сводке в транскрипте: `crystal-stop-reminder.sh` — 10,
  PreToolUse плагинов — 7, `check_risky_command.py` — 2, `git-guard-reminder.sh` — 2,
  `crystal-completion-guard.sh` и `intercom-identity-check.sh` — по 1.
- **Вторая поверхность.** У crystal-гейта есть pre-commit-бэкап; у `git-guard` — нет: он сам и есть охрана
  коммита. Не проверено, нет ли у git-guard другого пути, кроме PreToolUse.

## Decision Log

### #1 / 2026-10-01 / Кристалл на все блокирующие гарды, а не на git-guard

**Source:** both
**Basis:** observed
**Basis-detail:** пропуск вызова — транскрипт executor (адрес и записи в «Текущей модели»); таймауты —
`hooks.json` трёх плагинов в репо. Решение завести кристалл, а не чинить сразу, — владелец 2026-10-01:
«Сначала всё в кристаллы».
**Context:** бриф говорит о git-guard. Тот же таймаут 5 с стоит у `crystal-completion-guard.sh`,
`comms-draft-guard.sh`, `comms-eml-guard.sh` — и у каждого отмена значит пропуск.
**Why:** дефект соседнего класса чинится в той же работе (память проекта «Same-class defect: fix now»). Чинить
только git-guard — оставить три гарда с той же дырой.
**Implication:** работа — по всем блокирующим PreToolUse-гардам суиты; советующие хуки — отдельным пунктом,
решить, трогать ли.

## Sidetracks

Пока нет.

## Next actions

- [ ] Таймаут блокирующих гардов: выбрать значение замером — таймаут потолок, а не ожидание, так что запас не
      стоит ничего, пока скрипт быстрый; поднять у четырёх гардов
- [ ] `git-guard-hook.sh` без matcher: выяснить, почему (MCP-инструменты? намеренно?), и сузить, если можно —
      сейчас он платит на каждом вызове любого инструмента
- [ ] Красный тест на конфиг: блокирующие гарды в `hooks.json` несут `timeout` не ниже выбранного
- [ ] Советующие хуки (`git-guard-reminder.sh`, `crystal-stop-reminder.sh`): отмена безвредна — решить, нужен ли
      им запас
- [ ] Outcome to `executor`: intercom reply git-guard-hook-timeouts --done "<what was done>" --link <url> --ball "<who holds the ball — what ⏰ date>"

## References

- `references/intercom-brief-executor-git-guard-hook-timeouts.md` — бриф целиком (копия из инбокса
  2026-10-01). Чужих людей и данных в нём нет.
- Транскрипт — не скопирован: сессия соседнего проекта, 3,5 тыс. строк. Адрес:
  `~/.claude/projects/-Users-vdm-PhpstormProjects-git-vorobyev-name-executor/ac0ace03-3b60-484f-9c53-6ec0c40719c6.jsonl`,
  записи переписаны в «Текущую модель», прочитано 2026-10-01.
