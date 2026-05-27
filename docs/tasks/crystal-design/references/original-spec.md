# Original spec — `vdm:promises` (rejected baseline)

**Source:** ТЗ от другого агента, переданное user'ом в brainstorm-сессии 2026-05-27.
**Status:** rejected as baseline (см. `../workitem.md` Decision Log #1).
**Reason for keeping:** provenance — обоснование почему мы пошли другим путём; защита от будущего «давайте сделаем как в groove/promises» — открываем этот файл и видим уже рассмотренные альтернативы.

**Key differences from chosen design (`crystal-*` suite):**

| Аспект | Этот spec (rejected) | Crystal (chosen) |
|---|---|---|
| Central concept | `promise` (formal deferred commitment) | `workitem` с sidetracks (любые branches) |
| Storage | `~/.claude/projects/<cwd>/memory/promises/` | `docs/tasks/<slug>/workitem.md` in-repo |
| Capture trigger | regex на фразы-маркеры + AskUserQuestion | continuous offload assistant'ом + periodic user review |
| Enforcement | surface при старте сессии (информативно) | hard gate при close через PreToolUse hook |
| Closing semantic | manual `--resolve N` per promise | `- [ ]` blocks status:done transition globally |
| Provenance/reasoning | не предусмотрено | `## Decision Log` секция для brainstorm-type |

---

## Оригинальный текст ТЗ (как был передан)

> Создать skill `vdm:promises` для устранения «потери концов» в чате

### Контекст и проблема

В рабочих сессиях с длинными разговорами регулярно теряются **отложенные обещания** — фразы типа «сохраню после X», «обработаю позже», «вернёмся к Z потом». Они живут только в тексте чата. Под нагрузкой (3+ раундов с другим топиком) обещание выпадает из working memory модели и забывается полностью.

**Конкретный инцидент 2026-05-27**: пользователь дал текст письма для сохранения в `comms/`, я ответил «сохраню после того как разберёмся с Володькиным», провёл 5 раундов про Володькина, обновил два index.md, и не вспомнил про обещание. Пользователь поймал, был раздражён: «ты мне зачем нужен если забываешь такие концы».

`TaskCreate` доступен, но я его не использовал — рассчитывал на чат как хранилище. Это **не разовая ошибка**, а структурный паттерн.

### Референсы

Полнофункциональный фреймворк `andreadellacorte/groove` (222 installs на skills.sh) решает ровно эту проблему через 3 связанных skill:

1. **`groove-utilities-memory-promises`** — capture / list / resolve.
   - `/groove-utilities-memory-promises <text>` — захватить
   - `--list` — показать открытые
   - `--resolve N` — закрыть #N
   - Хранение: tasks в backend (`beans`) под milestone «Groove Memory» → epic «Promises»

2. **`groove-work-compound`** — auto-detect в конце workflow:
   > "After the workflow learning step, scan the conversation for deferred items — phrases like 'we'll come back to', 'do this later', 'next time', 'TODO', 'skip for now', 'won't fix today'. If any are found: list them and ask 'Capture any of these as promises? (numbers, or enter to skip)'."

3. **`groove-daily-start`** — surface при старте сессии:
   > "If open promises: show inline note: `→ N open promise(s) — run /groove-utilities-memory-promises --list to review`"

**Почему не ставлю готовый groove**: требует beans backend + ломает уже существующую экосистему `vdm:*` skills у пользователя. Берём идею, не код.

### Что нужно построить

Skill (или связка skills) `vdm:promises` в стиле и инфраструктуре, совместимой с существующими `/vdm:learn`, `/vdm:docs-sync`, `/vdm:changelog`. Storage в плоском markdown, без внешних backends.

#### Функциональные компоненты

**1. Explicit capture / list / resolve (slash command)**
- `/vdm:promises <текст>` — захватить с auto-date stamp
- `/vdm:promises --list` — показать открытые в виде numbered list
- `/vdm:promises --resolve N` — пометить N как resolved
- `/vdm:promises --resolve-all` — c подтверждением

**2. Auto-detect (assistant hook или behavioural rule)**

Триггер — конец «значимого блока работы». Сканировать **assistant response text** последних N turns на фразы-триггеры:

Русские: `сохраню|создам|обновлю|сделаю|обработаю|вернёмся` рядом (в пределах ~30 символов) с `позже|потом|после|далее|когда|пока`.

Английские: `I['']ll|will|let's` рядом с `later|after|come back|once|when`.

Также явные маркеры: `TODO`, `FIXME`, «потом разберёмся», «отложим», «позже вернёмся».

При совпадении — **не молча захватить, а спросить**:
> Обнаружено N отложенных обещаний:
> 1. «...» (контекст: ...)
> 2. «...»
> Захватить как promise? (номера через запятую, или enter — пропустить)

**3. Surface при старте сессии (или периодически)**
- (а) UserPromptSubmit hook — при первом сообщении сессии показывает `→ N открытых обещаний — /vdm:promises --list` (тихо если 0)
- (б) Inline в существующих hook'ах (рядом с `[learn]`, `[changelog]`)
- (в) Часть `/vdm:docs-sync` — если есть открытые promises, упоминать

#### Storage layout

Per-project memory: `~/.claude/projects/<encoded-cwd>/memory/promises/`

Формат — один файл на promise или единый `OPEN.md`/`RESOLVED.md`.

Каждый promise содержит:
- ID (slug + date)
- Дата capture
- Дата resolve (если resolved)
- Текст обещания
- Optional context
- Status: open / resolved / cancelled

#### Behavioural rule (фолбэк)

Добавить в global `~/.claude/CLAUDE.md` hard rule:

> **Promise = TaskCreate immediately.** Любая фраза «сделаю/сохраню/создам/обновлю/обработаю **позже/после/потом/далее**» в моём ответе пользователю → mandatory `TaskCreate` (или `/vdm:promises <text>`) в том же ходу, **до** перехода к следующему действию.

### Acceptance criteria

1. Можно вручную захватить promise: `/vdm:promises Сохранить письмо Тавасиевой 27.05`
2. `/vdm:promises --list` показывает promise с ID и датой
3. `/vdm:promises --resolve 1` закрывает promise
4. Auto-detect срабатывает на phrase «сохраню после Y» — выводит suggestion с вопросом capture
5. Surface при старте сессии — пользователь видит непустой список при возврате после паузы
6. Не дублирует существующую функцию `TaskCreate` (in-session) — promises **переживают сессии**, tasks нет
7. Совместимо с обоими языками (RU primary, EN ok)
8. Не требует внешних зависимостей (нет `beans`, нет GitHub backend)
9. Поведение `if 0 promises → skip silently` — не быть навязчивым

### Constraints

- Storage только в markdown
- Per-project, не global
- Не ломает существующие `/vdm:learn`, `/vdm:docs-sync`, `/vdm:changelog`
- TaskCreate = in-session todo, vdm:promises = cross-session deferred
- Не использовать emoji в коде skill
- UI и сообщения на русском, slug'и/ID/имена файлов на латинице
- Auto-detect должен быть **подтверждающим, не автоматическим**

### Open questions для дизайнера

1. Один skill `/vdm:promises` или два (`/vdm:promises` + `/vdm:promises-scan`)?
2. Где именно делать auto-detect — UserPromptSubmit hook или часть существующих vdm hook'ов?
3. Хранить per-project или global со scope-метой?
4. Включать ли priority/deadline в schema, или promise = плоский todo?
5. Нужен ли expiry? («открыт > 30 дней — предложить cancel»)

### Не делать

- Не строить весь groove-style backend (beans, milestone, epic) — overkill
- Не делать ML-классификацию promises — regex + AskUserQuestion достаточно
- Не молча захватывать без подтверждения — будут false positives
- Не блокировать tool calls на основе detection — это раздражает; suggestion-only
