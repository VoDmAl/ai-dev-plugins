---
title: "vdm:crystal-* suite — design"
slug: crystal-design
status: done
session-type: brainstorm
created: 2026-05-27
last-updated: 2026-05-27
---

# vdm:crystal-* suite — design

> Первый crystal в репо. Документ ведётся по той же механике, которую сам описывает (eat your own dog food).
> Origin: brainstorm-сессия 2026-05-27, инициированная user'ом после получения ТЗ от другого агента (см. `references/original-spec.md`).

## Назначение

Спроектировать skill suite `vdm:crystal-*` — встроенный discipline gate в lifecycle workitem'ов, который предотвращает «потерю концов» (отложенных обещаний, неявных зависимостей, побочных наблюдений) в долгих сессиях.

Реактивная боль: контекст под давлением выталкивает мелкие побеги первыми, и они забываются без записи. ТЗ от другого агента решает узкий случай (formal promises capture); user'ская формулировка шире — нужна онтология «ствол / ветви / побеги», где gate в lifecycle ticket-like документа предотвращает закрытие при оставшихся unchecked items.

## Метафора и suite

**Crystal** — структура которая растёт через буддинг (новые направления), огранивается в финале (close), и которую можно «зайти посмотреть внутрь» (visibility). Метафора покрывает все основные операции одним словом и оставляет place под discriminators:

| Команда | Действие |
|---|---|
| `crystal-grow` | Старт нового workitem'а (explicit или promotion из shadow) |
| `crystal-bud` | Добавить побег в активный (или routed dormant) crystal |
| `crystal-cut` | Попытка close workitem'а — триггерит gate; sweep всех unchecked items |
| `crystal-cave` | View: список active+dormant crystals + их sidetracks + decision logs |

## Карта решения

Сводка всех слоёв архитектуры после 5 раундов brainstorm. Cross-refs ведут в Decision Log.

| Слой | Решение | См. |
|---|---|---|
| Метафора | crystal — растёт, буддит, огранивается, можно «зайти» внутрь | DL #10, #14 |
| Suite | grow / bud / cut / cave | DL #14 |
| Storage | in-repo `docs/tasks/<slug>/workitem.md` | DL #2 |
| Schema | yaml frontmatter + main content + `## Sidetracks` + (опц.) `## Decision Log` | DL #5, #13, #15 |
| Lifecycle побега | 6 состояний: open / resolved / migrated / cancelled / deferred / promoted-to-stem | DL #9 |
| Concurrency | 1 active + N dormant; auto-route в dormant по теме (confidence-aware) | DL #11, #16 |
| Gate primary | PreToolUse hook на Edit/Write `docs/tasks/**/*.md` — block done-transition при unchecked | DL #4, #7 |
| Gate visibility | Stop hook — silent reminder о висящих побегах | DL #7 |
| Gate backup (git) | pre-commit в `.githooks/` — duplicate primary, защита от прямой правки в IDE | DL #7 |
| Auto-promotion | Поведенческое правило assistant'а, adaptive by session-type | DL #8 |
| Tasks integration | TaskCreate = derived view of active workitem (sync, file = source of truth) | DL #12 |
| Levels of depth | Plain / Shadow / Full crystal — три уровня погружения | DL #12 |

## Decision Log

### #1 / 2026-05-27 / Не строить `vdm:promises` по спеке агента

**Source:** assistant proposed → user confirmed
**Context:** ТЗ от другого агента (см. `references/original-spec.md`) детально прописывает skill `vdm:promises` — regex-капчер фраз «сохраню позже», storage в memory, AskUserQuestion на каждый match.
**Why rejected:** спека solves узкую соседнюю проблему — formal promises (~20% случаев потери концов). User'ская формулировка шире — любые ветвления: branches, observations, implicit deps. Plus storage не в той онтологии (memory vs in-repo).
**Implication:** строим другую систему, не редакцию спеки. Спека сохранена как `references/original-spec.md` для provenance.
**Cross:** см. Sidetrack #5.

### #2 / 2026-05-27 / Storage = in-repo `docs/tasks/<slug>/`

**Source:** user explicit
**Why:** in-repo выживает клоны, виден git'у/команде/другим агентам через год, попадает в `git log`. Memory — приватный кэш машины, не источник истины.
**Implication:** skill зависит от структуры репо, не от user-level memory.

### #3 / 2026-05-27 / Capture mode = hybrid (assistant ведёт + user ревизует)

**Source:** user explicit
**Why:** continuous offload от assistant'а (нет UX-шума подтверждений), периодическое review от пользователя (фильтр от false positives). Reactive capture теряет ≥50% сигнала; continuous-with-confirm создаёт frication.
**Implication:** assistant append'ает sidetracks без AskUserQuestion; user редактирует/чистит в `/vdm:docs-sync` Phase 0 или вручную.

### #4 / 2026-05-27 / Closing trigger = `- [ ]` blocks done

**Source:** user
**Quote:** «есть unckecked checkboxes - нельзя считать документ завершенным».
**Why:** уже существующая markdown convention; formalization не требует нового формата; работает для всех unchecked items в файле, не только побегов. Это даёт generalize: gate не «про побеги», а «про дисциплину завершения» — побеги частный случай.
**Implication:** gate скрипт делает grep `- \[ \]` в файле перед done-transition; блокирует если есть совпадения.

### #5 / 2026-05-27 / Sidetracks layout = inline marker + dedicated section + bi-links

**Source:** user (combined options 1+2)
**Quote:** «1 + 2. Никто не мешает делать "линк" типа подробнее в секции `## Sidetracks ### 13`. Ну и обратный линк откуда родилось».
**Why:** контекст где возникло (inline marker) + полная карточка для review (section); footnote/endnote modеl.
**Implication:** schema требует numbered headings в `## Sidetracks` (`### #N. Title`), inline marker pattern `- [ ] см. Sidetrack #N`, обратная ссылка в карточке «Возникло в: <section/anchor>».

### #6 / 2026-05-27 / Gate scope = per-workitem

**Source:** user explicit
**Why:** granular, чёткий, естественно coalesces с тем что user видит как «один документ — один тикет».
**Implication:** gate проверяет только тот файл который сейчас edit'ится; cross-workitem обязательств нет.

### #7 / 2026-05-27 / Enforcement = hooks > CLAUDE.md

**Source:** user explicit
**Quote:** «я перестал верить в силу CLAUDE.md — только Claude hooks, только скрипты».
**Why:** soft guidance ненадёжна под давлением контекста; hard gate всегда работает. Plus продукты бывают без git → pre-commit недостаточен как primary.
**Implication:**
- **Primary:** PreToolUse hook на Edit/Write `docs/tasks/**/*.md` — работает в любом проекте.
- **Backup (git):** pre-commit hook в `.githooks/` — защита от прямой правки в IDE.
- **Visibility:** Stop hook — silent reminder про активные crystals.
- **Soft layer:** SKILL.md guidance — для поведенческих правил которые hook'ом не закрепить (auto-promotion, decision-log curation).

### #8 / 2026-05-27 / Detection model = adaptive by session-type

**Source:** user
**Quote:** «Это может быть исследование типа найти что-то как себя ведет или короткий баг или сессии по составлению PRD или работа над PRD ... ТЫ ВИДИШЬ что задача затягивается ... надо предложить завести документ».
**Why:** разные типы сессий имеют разную плотность побегов; aggressive sensitivity для research, conservative для bug.
**Implication:** главное правило skill = assistant классифицирует тип сессии в первых ходах и применяет threshold; promotion = explicit предложение «давай заведём crystal — вот предлагаемый title, sidetracks из shadow».
**Open:** sensitivity table (см. Sidetrack #1).

### #9 / 2026-05-27 / Lifecycle побега = 6 состояний

**Source:** user (выбрал обе предложенные надстройки)
**States:**
- `open` — захвачено, ожидает решения
- `resolved` — выполнено в рамках этого workitem'а
- `migrated → <target>` — перенесено в другой workitem (cross-link обязателен)
- `cancelled (reason: ...)` — явно отброшено через HITL с обоснованием
- `deferred (deadline: YYYY-MM-DD)` — отложено с датой; всплывает при достижении даты
- `promoted-to-stem (→ <sibling-crystal>)` — побег оказался важнее ствола, разделение workitem'а на siblings

**Why:** open/resolved/migrated/cancelled — basic resolution paths; deferred-deadline — для «вернёмся к дате»; promoted-to-stem — для «ствол раздвоился, побег стал new active focus».
**Implication:** каждая sidetrack-карточка хранит state как явное поле; gate распознаёт все 6 как «closed enough».

### #10 / 2026-05-27 / Naming = crystal

**Source:** user proposed
**Quote:** «давай назовем crystal? Кристаллы знаешь как растут в замысловатые формы».
**Why:** organic-метафора покрывает growth / branching / finalization; короткое имя; место под suite discriminators.
**Implication:** namespace `vdm:crystal-*`; SKILL.md лексика опирается на метафору.

### #11 / 2026-05-27 / Concurrency = 1 active + N dormant

**Source:** user
**Quote:** «отпочковать ... между ними кросслинковка, но второй документ не активный, в него может писаться то что продолжает обсуждаться в сторону».
**Why:** «ствол может раздвоиться», но focus singleton (cognitive load); параллельная работа над двумя active workitems приводит к context-switching loss.
**Implication:**
- `status: in-progress` = singleton invariant per repo
- Параллельные workitems → `status: dormant`
- Switch active/dormant — explicit action (через `crystal-grow --switch <slug>` или manual frontmatter edit)
- Cross-links между active и dormant обязательны при отпочковании.

### #12 / 2026-05-27 / Три уровня погружения

**Source:** assistant proposed
**Levels:**
- **Plain** — простая Q&A; ничего не сохраняется.
- **Shadow** — assistant ведёт побеги в working memory, файла нет; готов promote по запросу или по триггеру.
- **Full crystal** — файл создан, frontmatter `status: in-progress`, gate активен.

**Why:** не каждая мини-сессия требует workitem; shadow позволяет promote later без потери контекста; уровни — progressive enhancement.
**Implication:** assistant начинает в plain → переключается в shadow при первых признаках scope-creep → предлагает promote в full при достижении threshold (см. DL #8).
**Связь с Tasks:** в Plain и Shadow уровнях TaskCreate может использоваться как лёгкая визуализация без файла; при promotion Tasks становятся derived view of file (см. Sidetrack #3 для деталей).

### #13 / 2026-05-27 / Decision Log = first-class artifact

**Source:** user (4-й раунд follow-up)
**Quote:** «важно не ЧТО вышло, а еще и КАК вышло».
**Why:** для brainstorm-type сессий обоснование решений важнее самих решений; reasoning chain объясняет почему отброшены альтернативы; защита от будущего «давайте сделаем что-то похожее на X» — Decision Log показывает что уже рассматривали и почему выбрали другое.
**Implication:** schema получает optional секцию `## Decision Log`; auto-enabled при `session-type: brainstorm`; каждая запись содержит Source / Context / Why / Implication; cross-refs к Sidetracks и обратно.

### #14 / 2026-05-27 / Suite naming finalized = grow / bud / cut / cave

**Source:** user
**Why:**
- `bud` — organic continuation grow (буддинг = ответвление); короче и точнее чем `facet`.
- `cut` — ювелирная огранка (финал, готовый кристалл).
- `cave` — взгляд внутрь, геологическая ассоциация (кристальные пещеры); инверсия очевидного `list`/`show` — заставляет на секунду задуматься, что помогает recall.
**Implication:** skill paths = `plugins/vdm/skills/crystal-grow/`, `crystal-bud/`, `crystal-cut/`, `crystal-cave/`.

### #15 / 2026-05-27 / Decision Log placement = section + cross-refs

**Source:** user explicit
**Why:** co-location с workitem content (одна точка чтения); cross-refs внутрь sidetracks/inline content делают navigation естественной; отдельный файл = риск «с глаз долой».
**Implication:** schema = `## Decision Log` секция в том же файле что и main content; cross-ref syntax = `см. Decision Log #N` / `см. Sidetrack #M`.

### #16 / 2026-05-27 / Sidetrack routing = assistant auto-routes, confidence-aware

**Source:** user
**Quote:** «голова не резиновая».
**Why:** minimum cognitive load для user'а в моменте; в момент возникновения побега user не хочет принимать решения о routing.
**Implication:**
- При `bud` assistant классифицирует побег по теме → routes в подходящий dormant если confidence высокий.
- Fallback — в active при low confidence (safe default — не теряем).
- В карточке sidetrack явно указывается «routed to: <crystal>» — user видит и может revert.
- Misroute fix post-hoc через `crystal-bud --to <crystal-id>` или вручную.

### #17 / 2026-05-27 / Reflexive case = эта задача = первый crystal

**Source:** user
**Quote:** «я пока не вижу документа для текущего task - все только в истории с тобой».
**Why:** dog-fooding + предотвращение собственной ошибки (вся reasoning только в чате — ровно та боль которую crystal решает).
**Implication:** workitem создан до продолжения brainstorm по 5 open sidetracks; дальнейшие round'ы идут уже как updates в этот файл.

### #18 / 2026-05-27 / Folder structure для multi-file workitems

**Source:** assistant decision (без user-confirm, документируется здесь)
**Context:** существующий convention в `docs/tasks/` — flat файлы (`phase-3-hook-extensions.md`). У этого workitem'а есть `references/` (original spec от другого агента), поэтому flat не подходит.
**Why:** многофайловые workitems требуют containment; single-file workitems могут остаться flat. Convention эволюционирует: `docs/tasks/<slug>.md` для simple, `docs/tasks/<slug>/workitem.md` для multi-file.
**Implication:** разработчики/инструменты должны handle оба варианта при scan'е `docs/tasks/`.
**Open:** установить ли это как formal convention в README/CLAUDE.md? — отложено до v1 ready.

### #19 / 2026-05-27 / Adaptive sensitivity table — finalized

**Source:** user (round 6 brainstorm)
**Closes:** Sidetrack #1

**Session types (9):** `brainstorm` / `prd-prep` / `prd-work` / `research` / `short-bug` / `maintenance` / `review` / `docs-only` / `other`.

**Classification:** assistant infers from first 1-3 user messages; ambiguous → conservative default `other`. User может override через `frontmatter: session-type:` в любой момент.

**Threshold table** (promotion shadow → full crystal):

| Type | Promotion trigger |
|---|---|
| `brainstorm` | immediate (1 sidetrack OR 2 tool calls) |
| `prd-prep` | immediate (с первого хода) |
| `prd-work` | already promoted (workitem уже существует) |
| `research` | 4+ tool calls OR 2+ sidetracks OR 15+ min |
| `short-bug` | 6+ tool calls OR 3+ sidetracks OR 25+ min |
| `maintenance` | 8+ tool calls |
| `review` | 3+ sidetracks |
| `docs-only` | 5+ tool calls AND 2+ sidetracks |
| `other` | 5+ tool calls AND 2+ sidetracks (conservative default) |

**Why pure thresholds vs weighted score:** explicit числа легко объяснить в SKILL.md и тюнить per-user через override; weighted score добавляет cognitive complexity (как читать формулу?) без clear benefit для recall/explainability.

**Override path:** explicit user signal (`«давай заведём»`, `«это большая задача»`, `«сделаем PRD»`) immediately promotes независимо от counter'ов — это сильнее любой эвристики.

**Implication:**
- SKILL.md `vdm:crystal-grow` секция «Auto-promotion» содержит эту таблицу как reference
- Classification logic = behavioral instruction assistant'у; не hook
- Counters (`tool_calls`, `sidetracks`, `time`) tracked assistant'ом в shadow mode mental state — никакого state-file
- Тюнинг: per-project override через `.claude/vdm-plugins.json` (см. Decision Log #20)

### #20 / 2026-05-27 / Init behavior — auto-create silent + configurable path

**Source:** user (round 6 brainstorm)
**Closes:** Sidetrack #2

**Default:** при первом `crystal-grow` в проекте без `docs/tasks/` — папка создаётся silently. Путь по умолчанию = `docs/tasks/` (matches existing convention в `cc-vdm-plugins`).

**Override:** через existing `.claude/vdm-plugins.json`:

```json
{
  "crystal": {
    "path": "tasks"
  }
}
```

**Why:** zero-friction promotion; user уже сделал жест `grow`, лишний confirm ломает auto-promotion philosophy. Configurable path — для проектов с другими conventions (`tasks/`, `prds/`, `work/`).

**Implication:**
- `crystal-grow` делает `mkdir -p <resolved-path>/<slug>` silent
- Path resolution: env override → `.claude/vdm-plugins.json:crystal.path` → default `docs/tasks/`
- Все hook'и (PreToolUse gate, Stop reminder, pre-commit backup) используют ту же resolution
- Config schema: добавить `crystal` section в config helpers `plugins/{vdm,vdm-git}/lib/` (mirror invariant — см. CLAUDE.md Critical Rule #3)

### #21 / 2026-05-27 / TaskCreate integration — L1 ephemeral

**Source:** user (round 6 brainstorm)
**Closes:** Sidetrack #3

**Model:** Tasks как ephemeral derived view of active workitem file.

**Sync events:**
- `crystal-grow` (new или session resume): assistant populate Tasks из unchecked items (`## Sidetracks` + Next actions)
- `crystal-bud`: assistant добавляет Task для новой sidetrack-карточки
- `crystal-cut`: cycle через unchecked items в файле — block если есть; обновляю Tasks по результату
- Между этим: Tasks ephemeral, user ticks в UI **не** propagated в файл

**Conflict policy:** file wins always. Если task tick'нут в UI но file unchecked — при следующем populate task reverts (это known UX rough edge, accepted trade-off).

**Why:**
- Tasks API не cross-session — новая сессия = empty Tasks
- Нет hook'а на user ticks в UI → bidirectional sync невозможен deterministically
- Complex sync ломается; L1 minimum viable: сохраняем visualization без false promises о magical UI sync
- User explicitly verifies через CLAUDE.md что не верит в чат-state — Tasks UI попадает в эту категорию

**User communication:** SKILL.md содержит note «file = source of truth; tick'и в Tasks UI визуальные, для resolve — правьте workitem.md». Никаких иллюзий что UI-tick что-то меняет.

**Implication:**
- `crystal-grow` reads workitem → loop TaskCreate per unchecked item
- `crystal-bud` appends sidetrack + calls TaskCreate для нового item
- `crystal-cut` runs `grep -c '- \[ \]' workitem.md` → if > 0, error со списком + 5 путей (address-now / migrate / cancel / defer / promote — см. Decision Log #9)
- Session-resume protocol (см. open Sidetrack #7) включает populate-Tasks step

### #22 / 2026-05-27 / Ecosystem integration — all 4 accepted

**Source:** user (round 6 brainstorm)
**Closes:** Sidetrack #4

**Accepted integrations:**

**1. `/vdm:docs-sync` Phase 0 sweep**
- Implementation: добавить шаг в `plugins/vdm/skills/docs-sync/SKILL.md` (Phase 0) + helper `plugins/vdm/scripts/list-open-crystals.sh`
- Output format: `→ Open crystals: <slug-1> (N open sidetracks), <slug-2> (M open)`
- Behavior: visibility-only, не блокирует docs-sync flow

**2. `/vdm:changelog` soft hint at cut**
- Implementation: одна строка в `crystal-cut` SKILL.md финальный output: «✓ Crystal `<slug>` closed. Consider running /vdm:changelog for PROJECT_CHANGELOG entry.»
- Behavior: text-only, no auto-trigger

**3. `/vdm:learn` soft hint at cut**
- Implementation: conditional строка в `crystal-cut` output если N resolved sidetracks > 0: «N resolved sidetracks — candidates for /vdm:learn?»
- Behavior: text-only, no auto-trigger

**4. `/vdm:guard` pre-commit hard backup**
- Implementation: новый check в `.githooks/pre-commit` для самого `cc-vdm-plugins` репо; production version шипится через `plugins/vdm-git/scripts/`
- Logic: для каждого staged `docs/tasks/**/*.md` — если frontmatter `status: done` И есть `- [ ]` → block с диагностикой
- Behavior: hard block; defense-in-depth от IDE-edits минуя assistant

**Version bumps required:**
- `plugins/vdm/.claude-plugin/plugin.json` — MINOR (new feature: crystal-* suite; docs-sync update; changelog/learn soft hints)
- `plugins/vdm-git/.claude-plugin/plugin.json` — MINOR (new pre-commit check для crystal gates)
- `.claude-plugin/marketplace.json` — parity для обоих (CLAUDE.md Critical Rule #1)

**Implication:**
- v1 release требует updates в обоих plugins
- Documentation в README.md и CLAUDE.md update (crystal как new core mechanism)
- Mirror invariant соблюдается (CLAUDE.md Critical Rule #3) — config helper `crystal.*` поселяется в `plugins/{vdm,vdm-git}/lib/`

### #23 / 2026-05-27 / Session resume — SessionStart hook + SKILL.md init

**Source:** user (round 6 brainstorm)
**Closes:** Sidetrack #7

**Two-layer approach:**

**Layer 1 (primary): SessionStart hook**
- Script: `plugins/vdm/scripts/crystal-hydrate.sh`
- Logic: `grep -l '^status: in-progress' docs/tasks/**/workitem.md 2>/dev/null`. Для каждого найденного — count open sidetracks (`grep -c '^### #.*Status: open'` приблизительно), output:
  ```
  [crystal] → Active: <slug> (N open побегов). См. docs/tasks/<slug>/workitem.md
  ```
- Silent если нет active crystals (zero output)
- Multiple active = singleton violation → warning «N active crystals — violation of singleton invariant»
- Registers в `plugins/vdm/hooks/hooks.json`

**Layer 2 (fallback): SKILL.md init guidance**
- В каждом `crystal-*` SKILL.md — init step: «перед первым action в сессии Read active workitem(s) для context, если ещё не сделано»
- Защита от случая когда SessionStart hook не fired (disabled, replaced, etc.)

**Context-compaction handling:**
- Soft rule в SKILL.md: «если context compaction случилось и active crystal был в scope — re-Read workitem.md перед continuing»
- Heuristic для detection: после compaction в session-state artifact «[Conversation summary]» — это signal для re-load

**Что не делаем:**
- UserPromptSubmit inject — heavy, дублирует SessionStart
- Auto-Read через PreToolUse — overkill, slows down every action

**Implication:**
- Новый hook script + registration в `plugins/vdm/hooks/hooks.json`
- SKILL.md init секция во всех 4 crystal-* skills (либо shared SKILL.md prologue)
- Validated через reflexive case (this workitem) — после restart sessии должна появляться inline note

### #24 / 2026-05-27 / Slug collision — refuse + hint (v1)

**Source:** user (round 7)
**Closes:** Sidetrack #8

**Behavior at `crystal-grow <slug>` collision:**

1. Если `<resolved-path>/<slug>/` (folder) exists → refuse: «Crystal `<slug>` already exists at `<path>`»
2. Если `<resolved-path>/<slug>.md` (flat) exists → refuse с hint:
   ```
   × Collision: docs/tasks/<slug>.md уже существует (flat файл).
     Crystal требует folder structure. Варианты:
       - Использовать другой slug
       - Вручную переименовать flat файл, затем повторить grow
       - (v2) Auto-convert flat → folder — отложено
   ```
3. Иначе → create new `<path>/<slug>/workitem.md`

**Why refuse over convert:**
- v1 priority: solid foundation; не risky auto-magic
- Legacy flat файлы имеют разные форматы (inline labels vs yaml frontmatter) — auto-convert может ломать content
- Friction приемлема — collision это edge case (один collision на проект)
- Auto-convert переезжает в sidetrack для v2 (см. Sidetrack #9)

**Implication:**
- `crystal-grow` script проверяет оба paths (folder и flat `.md`) перед созданием
- Tests cover collision case
- v2 deferred sidetrack добавлен (#9)

## Sidetracks

### #1. Adaptive sensitivity table — session-type × threshold

**Возникло в:** Decision Log #8
**Описание:** Нужна явная taxonomy «тип сессии → когда assistant предлагает crystal-grow».

**Status:** resolved (см. Decision Log #19)

### #2. Init для проектов без `docs/tasks/`

**Возникло в:** implicit (round 3)
**Описание:** User может установить vdm-plugin в проект где нет `docs/tasks/` структуры. Поведение init.

**Status:** resolved (см. Decision Log #20)

### #3. TaskCreate boundary — sync direction, conflict handling

**Возникло в:** user первое сообщение («визуализация — это твои Claude Code Tasks»)
**Описание:** TaskCreate = derived view of active workitem file. Sync model.

**Status:** resolved (см. Decision Log #21)

### #4. Ecosystem integration с existing `/vdm:*`

**Возникло в:** round 2
**Описание:** Точки integration между crystal и existing `/vdm:*` skills.

**Status:** resolved (см. Decision Log #22)

### #5. Original spec из ТЗ другого агента — provenance handling

**Возникло в:** input
**Описание:** ТЗ от другого агента (`vdm:promises`) — solid baseline для других пользователей, но не наш choice (см. Decision Log #1). Варианты provenance:
- (a) положить в `references/original-spec.md` с reject-rationale в Decision Log ✓ **chosen**
- (b) только ссылка на чат-историю — fragile
- (c) ignore — теряем context для будущих сравнений

**Status:** resolved (вариант a — см. `references/original-spec.md`)

### #6. Reflexive case — эта сессия как канонический пример в SKILL.md

**Возникло в:** round 4 (наблюдение assistant'а)
**Описание:** Сама эта сессия brainstorm идеально демонстрирует value crystal: 17 decisions + 7 sidetracks за 5 раундов; без crystal — потеряется. Можно превратить в canonical example внутри SKILL.md или README.

**Status:** deferred (после v1 готов — реализация в коде заменит абстрактное описание)

### #7. Session resume / context-compaction hydration

**Возникло в:** implicit
**Описание:** Когда сессия возобновляется или случилось context compaction — как assistant hydrate active crystal state.

**Status:** resolved (см. Decision Log #23)

### #8. Slug collision с existing flat файлом

**Возникло в:** Decision Log #20 (round 6)
**Описание:** Поведение `crystal-grow` при collision со существующим flat `.md` файлом.

**Status:** resolved (см. Decision Log #24)

### #9. v2 auto-convert flat → folder

**Возникло в:** Decision Log #24 (round 7)
**Описание:** В v2 опционально добавить auto-convert при collision:
- Detect формат старого flat файла (yaml frontmatter vs inline labels vs plain)
- Move в `<slug>/workitem.md`
- Normalize frontmatter (если inline labels — преобразовать в yaml)
- Preserve content untouched
- Logging миграции в Decision Log новосозданного workitem'а

**Status:** deferred (v2, после feedback на v1 refuse behavior)

## Next actions

Блокирующий tail — все unchecked items в этом списке блокируют `crystal-cut` для этого workitem'а (см. Decision Log #4):

- [x] Brainstorm round 6 по Sidetracks #1, #2, #3, #4, #7 (закрыт — все 5 resolved через Decision Log #19-23)
- [x] Решение по Sidetrack #1 → fix в SKILL.md auto-promotion раздел (см. Decision Log #19)
- [x] Решение по Sidetrack #2 → реализация init-поведения в `crystal-grow` (см. Decision Log #20)
- [x] Решение по Sidetrack #8 → collision поведения с existing flat файлами (см. Decision Log #24)
- [x] Решение по Sidetrack #3 → TaskCreate integration в SKILL.md или отдельный helper (см. Decision Log #21)
- [x] Решение по Sidetrack #4 → коротко зафиксировать в `Implication:` каждой integration-точки + version bumps (см. Decision Log #22)
- [x] Решение по Sidetrack #7 → дизайн SessionStart hook или init-step в SKILL.md (см. Decision Log #23)
- [x] Скаффолд `plugins/vdm/skills/crystal-{grow,bud,cut,cave}/SKILL.md`
- [x] Скаффолд hook scripts: PreToolUse gate (`crystal-completion-guard.sh` + `.py` simulator), Stop reminder (`crystal-stop-reminder.sh`), SessionStart hydrate (`crystal-hydrate.sh`), docs-sync Phase 0 helper (`list-open-crystals.sh`)
- [x] Регистрация в `plugins/vdm/hooks/hooks.json` (SessionStart + PreToolUse + Stop, плюс existing UserPromptSubmit + PostToolUse)
- [x] (Опц.) pre-commit backup в `.githooks/pre-commit` для git-проектов — реализован двумя путями: `scripts/check-crystal-completion.sh` для самого репо (Gate 4) и `plugins/vdm-git/scripts/crystal-precommit-check.sh` shipping в user проекты через vdm-git
- [x] Version bump `plugins/vdm/.claude-plugin/plugin.json` 2.3.0 → 2.4.0 + `plugins/vdm-git/.claude-plugin/plugin.json` 2.3.2 → 2.4.0 + `.claude-plugin/marketplace.json` parity для обоих
- [x] `PROJECT_CHANGELOG.md` entry — single 2026-05-27 FEATURE entry с полным ref'ом на все артефакты
- [x] Update CLAUDE.md — добавлена Critical Rule #5 (Workitem completion discipline) с описанием трёх-слойного гейта
- [x] (Опц.) Update README.md → Development секция: добавлены skill commands в таблицу, новая subsection "crystal-* suite" в What It Does, Gate 4 в Pre-commit gates таблицу, обновлён "Runtime hooks" блок с полной таблицей hook events

## References

- `references/original-spec.md` — ТЗ от другого агента (rejected baseline; см. Decision Log #1)
- Brainstorm chat session 2026-05-27 (источник всех Decision Log entries)
