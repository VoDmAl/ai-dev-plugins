---
title: "Crystal multi-root: auto-scan of tasks/ directories"
slug: crystal-multi-root
status: in-progress
session-type: prd-prep
created: 2026-05-31
last-updated: 2026-05-31
---

# Crystal multi-root: auto-scan of tasks/ directories

> Расширить resolver crystal-* и docs-sync Phase 0, чтобы они работали с
> репозиториями, где задачи раскиданы по нескольким `tasks/` директориям
> (Obsidian-vault с `projects/<project>/tasks/`, монорепы с
> `packages/*/tasks/`). Хардкодим leaf `tasks/`, авто-скан с дефолт-exclude
> скрытых сегментов, конфиг становится опциональным.

## Назначение

Текущий resolver (`plugins/vdm/lib/crystal-path.sh`) знает один root,
который читается из `vdm_config_read "crystal" "path" "docs/tasks"`. Это
ломается на двух классах структур:

1. **Obsidian-vault** (`/Volumes/Working/ObsidianVault`): задачи в
   `projects/<project>/tasks/<file>.md`, flat-файлы с префиксами (`idea-`,
   `task-`, `PRD`, `prompt-`, `subagent-`). Активных параллельно — десяток.
2. **Monorepo** (гипотетический `packages/*/tasks/`): аналогичный паттерн.
   Часто гибрид с cross-cutting `docs/tasks/`.

Singleton invariant и одиночный root не отражают эту реальность.

Цель: сделать так, чтобы из коробки (без конфига) crystal-* и docs-sync
находили все `tasks/` директории под project root, кроме скрытых
(`.git/`, `.stversions/`, `.obsidian/`, `.trash/`, `.serena/`, `.claude/`)
и стандартных «мусорных» (`node_modules/`, `vendor/`).

Success criterion:
- `cd /Volumes/Working/ObsidianVault && bash list-open-crystals.sh` находит
  всё в `projects/*/tasks/` и игнорирует `.stversions/...`.
- `cd cc-vdm-plugins && ...` продолжает работать как раньше.
- Никаких миграций для существующих установок.

## Decision Log

### #1 / 2026-05-31 / Hardcode leaf `tasks/`, не делать настраиваемым

**Source:** user
**Context:** Агент предложил configurable multi-name strategy (option B) для
покрытия `tickets/`, `issues/`, `workitems/`. User отверг.
**Why:** Strong opinionated default лучше flexible system. "Всем мил не
будешь — если мы сказали `**/tasks/*`, значит так тому и быть. tickers,
issues и т.д. — пусть ищут другой скилл." Scope discipline (cs:s2-604).
**Implication:** Конфиг знает только про root paths, не про leaf names.
Один меньше параметр → меньше edge cases в resolver и в hooks.
**Cross:** см. DL #2 (leaf hardcoded → автоскан становится viable).

### #2 / 2026-05-31 / Default-exclude скрытых сегментов делает автоскан безопасным

**Source:** user
**Context:** Агент опасался автоскана из-за `.stversions/projects/.../tasks/`
в vault'е, `.git/...`, `node_modules/...`. Предлагал explicit `paths:`
конфиг как primary mechanism.
**Why:** User предложил дефолт-exclude любых path сегментов начинающихся
с точки. Это convention `rg`/`fd`, элиминирует основную причину «автоскан
небезопасен». Конфиг становится опциональным escape hatch.
**Implication:** `find . -type d -name tasks -not -path '*/.*/*'` —
основной механизм discovery. `paths:` остаётся для нестандартных layout'ов
(если в нестандартном месте `tasks/` нужно вытащить из exclude, или
наоборот добавить root, где `tasks/` не называется `tasks/` — но второе
DL #1 запретил, так что только первое).
**Cross:** см. cs:s1-605.

### #3 / 2026-05-31 / Frame: option C с sane defaults побеждает option B

**Source:** both
**Context:** Изначально агент рекомендовал B (explicit `paths:` array,
обязательный). После DL #1 и DL #2 модель схлопнулась к C (auto-scan с
дефолтами) + B как override.
**Why:** B сводился к C, когда: (a) leaf hardcoded; (b) hidden-segment
exclusion дефолтный. Дополнительная гибкость B не нужна, так как
покрываемый scope уже зафиксирован.
**Implication:** Resolver получает три ветки: explicit `paths` (если
задан) → explicit `path` (legacy single, если задан) → auto-scan.
**Cross:** см. DL #4 (config schema).

### #4 / 2026-05-31 / Config schema — `enabled: true` единственный обязательный дефолт

**Source:** user
**Context:** Обсуждали, должна ли скилла требовать хоть какой-то ключ в
конфиге.
**Why:** Полное отсутствие `crystal` секции = `enabled: true`, автоскан.
Никаких других обязательных полей. Минимум церемонии для типового кейса.
**Implication:** Существующие установки с `path: "docs/tasks"` продолжают
работать без правок (backward compat ветка). Новые установки могут вообще
не трогать конфиг.
**Schema:**
```json
{
  "crystal": {
    "enabled": true,
    // опционально, все три ниже:
    "paths": ["docs/tasks", "packages/*/tasks"],   // override автоскана
    "exclude": ["legacy", "archive"],              // плюс к hidden defaults
    "singleton": "global|per-root|off"             // override авто-деривации
  }
}
```

### #5 / 2026-05-31 / Singleton — авто-деривация из формы конфига

**Source:** assistant, accepted by user
**Context:** В монорепе/vault'е "один активный crystal на весь репо" не
имеет смысла. В classic репе — имеет.
**Why:** Деривация без явного override:
- Resolver нашёл 1 root → `singleton: global` (текущее поведение).
- Resolver нашёл ≥2 root → `singleton: per-root`.
- Explicit `singleton:` в конфиге override'ит.
**Implication:** Backward compat для `path: "docs/tasks"` — один root,
global singleton, никаких изменений в восприятии. Vault автоматически
получает per-root.
**Cross:** см. DL #4.

### #6 / 2026-05-31 / Уникальность slug в multi-root режиме = `<parent>/<file>`

**Source:** assistant, accepted by user
**Context:** Если в `projects/auth/tasks/refactor-jwt.md` и
`projects/billing/tasks/refactor-jwt.md` лежат разные workitem'ы, slug
`refactor-jwt` неоднозначен.
**Why:** Slug = parent сегмент tasks/-листа + имя файла без `.md`. Т.е.
`auth/refactor-jwt` и `billing/refactor-jwt`. В single-root режиме slug
остаётся как раньше (просто имя файла / папки).
**Implication:** `extract_slug()` нужно две ветки. Cave/docs-sync вывод
становится более информативным в multi-root.
**Cross:** см. Next actions.

### #7 / 2026-05-31 / Grow в multi-root — auto-detect по CWD + HITL при низкой уверенности

**Source:** assistant, accepted by user
**Context:** `/vdm:crystal-grow <slug>` нужно знать, в какой root писать.
**Why:** Таблица confidence:

| Сигнал CWD | Confidence | Действие |
|------------|------------|----------|
| `pwd` под одним из найденных корней | high | grow в этот root молча |
| `pwd` parent одного `<x>/tasks/` (e.g. в `packages/auth/`) | high | grow в `<x>/tasks/` |
| `pwd` у project root, ≥2 корня | low | HITL: «Куда: auth/billing/payments?» |
| `pwd` вне всех корней | low | HITL обязательно |

**Implication:** Никакого `--in <project>` флага в v1 (YAGNI). Auto-detect
покрывает большинство кейсов; HITL — explicit safety net.

### #8 / 2026-05-31 / Performance — benchmark на vault'е перед shipping

**Source:** assistant
**Context:** `find` по vault'у с 7650 файлами в `attachments/` и большим
`.stversions/` может быть медленным.
**Why:** Известный риск, не дизайн-блокер. Hidden-exclude уже отрежет
основные горячие точки. Если `find` >500ms — fallback на `git ls-files |
grep '/tasks/'` когда git доступен (cs:p3-85f4 — не в каждом репо есть
git, поэтому именно fallback, не primary).
**Implication:** В Next actions добавлен benchmark step. Если порог
превышен — отдельный sub-task на caching/git-ls-files.

### #9 / 2026-05-31 / Backward compat — `path` (singular, string) сохраняется

**Source:** assistant, implicit user agreement
**Context:** Существующие установки с `{"crystal": {"path": "docs/tasks"}}`
не должны ломаться.
**Why:** Никаких миграций для пользователей. Резолюция:
1. `paths` (plural, array) задан → используем строго его.
2. Иначе `path` (singular, string) задан → один root, legacy.
3. Иначе → auto-scan.
**Implication:** Если оба заданы — `paths` побеждает, warning в stderr
хука (один раз за session-start, не на каждый вызов).

### #14 / 2026-05-31 / Inline `- [ ]` маркер обязателен для каждого `Status: open` sidetrack

**Source:** user
**Context:** Пришли к закрытию crystal-multi-root, обнаружили: Sidetrack #5
имеет `Status: open` в карточке, но без inline `- [ ]` маркера в теле
workitem'а — gate её не видит, `crystal-cut` молча пропустит. User: «как
же task закроется если есть 1 sidetrack в статусе open?»
**Why:** Discipline опирается на checkbox-count (cs:p3-700d — verifiable
hook check), а не на `Status:` text. Без inline маркера sidetrack
невидим для tooling. Раньше crystal-bud SKILL.md описывал inline-маркер
как «when applicable» — это и создало гэп.
**Implication:**
- `crystal-bud` SKILL.md обновлён: inline `- [ ]` маркер MANDATORY для
  каждого нового sidetrack с `Status: open`. Если побег вне body —
  маркер ставится в `## Next actions` как `- [ ] см. Sidetrack #N`.
- Текущая crystal-multi-root получает inline маркеры для #5 и #6 в новой
  «Pending sidetracks» секции внутри Next actions.
- Quality gate в `crystal-bud` SKILL.md дополнен: «Every `Status: open`
  sidetrack has an inline `- [ ]` marker in body».
- Sidetrack #6 заведён под автоматизацию этого правила (audit-script,
  параллель audit_non_canonical).
**Cross:** см. Sidetrack #5 (теперь имеет маркер), Sidetrack #6.

### #13 / 2026-05-31 / docs-sync Phase 0 / SessionStart output — group-by-root в multi-root, flat в single-root

**Source:** assistant, accepted by user
**Context:** Текущий one-liner `→ Open crystals: foo (3), bar (2)`
становится нечитаемым в монорепе с 10+ активными workitem'ами по
разным проектам.
**Why:** В multi-root режиме mental model пользователя — «по проектам».
Группировка совпадает. В single-root никакой регрессии — flat остаётся.
Format derives из того же `derive_singleton_mode` сигнала (1 root →
flat, ≥2 → group).
**Format в multi-root:**
```
→ Open crystals:
  - auth: foo (3), qux (1)
  - billing: bar (2)
  - payments: baz (1)
```
**Format в single-root (без изменений):**
```
→ Open crystals: foo (3), bar (2)
```
**Sorting:** alphabetical внутри group и сам group — стабильный output
между запусками. Hot-first → отдельная фича `crystal-cave --sort
activity` если понадобится.
**Implication:** `list-open-crystals.sh`, `crystal-hydrate.sh` оба
выбирают формат по числу resolved roots. Multi-line `additionalContext`
в SessionStart hook уже поддерживается.
**Cross:** см. Sidetrack #4 (resolved), Phase B (next actions).

### #12 / 2026-05-31 / Один канонический layout — folder-stem; flat-prefix не поддерживается

**Source:** user
**Context:** Sidetrack #3 рассматривал поддержку flat-prefix модели
(множество файлов на одном уровне, type в префиксе). User объяснил:
vault — это просто отсутствие подхода; миграция в crystal приведёт его
в канон. Образец канона — `telegram.vorobyev.name/docs/tasks/`:
6 crystal'ов, каждый = папка `<slug>/` с `workitem.md` + `references/`.
**Why:** Один data model даёт детерминированный resolver, чистый gate,
прозрачную семантику для пользователя. Flat-prefix — это organic mess,
не контракт. Поддерживая две модели одновременно мы платим сложностью
ради временного состояния, которое всё равно мигрируется.
**Implication:**
- `find_workitems()` остаётся как сейчас — folder-style (`<slug>/workitem.md`)
  + legacy flat (`<slug>.md`) для тривиальных one-file случаев.
- Filename-prefix parsing — **out of scope**. Type-role живёт во
  frontmatter (`type:` field), не в имени.
- Artifact vs workitem rule — **out of scope**. Артефакты по канону в
  `<slug>/references/`, физически не попадают под scan workitem'ов.
- Vault получает migration playbook (см. Sidetrack #5), не автоматический
  importer.
**Cross:** см. Sidetrack #3 (resolved), Sidetrack #5 (migration playbook).

### #11 / 2026-05-31 / Полный набор crystal-grow subcommands в v1 (не defer)

**Source:** user
**Context:** Sidetrack #2 предлагал отложить `paths add/remove/list/set` и
аналогичные subcommands до v2 (YAGNI argument: low frequency edits).
User отверг: «Давай добавим субкомманды для этого чтобы сразу закрыть
направление развития».
**Why:** Single self-contained release лучше двух итераций. Стоимость
импла subcommands низкая (JSON manipulation через Edit, парсинг
декларативно в SKILL.md). Закрываем surface разом.
**Implication:** В v1 идёт полный набор:
- `paths add/remove/list/set/clear`
- `path <value>` (legacy) + `path clear` (migration helper)
- `status-alias add/remove/list/clear` (с валидацией `<to>` против canon)
- `singleton <global|per-root|off|auto>`
- `config` (расширить — показывать resolved state)
- `enable/disable/reset` (существующие, без изменений)

**Mixed-config policy:** explicit refusal при попытке смешать `path`
(singular) и `paths` (plural). Force user action — не writing-and-warning.
**Cross:** см. Sidetrack #2 (resolved), Phase E (next actions).

### #10 / 2026-05-31 / Canonical status taxonomy (4 tier) + audit non-canonical

**Source:** user (направил), assistant (разложил)
**Context:** Vault использует `status: idea` помимо `in-progress`. User:
«Конечно strict. Но у нас разные статусы. active/in-progress это то на
что уникальность навешивается. А так могут быть done, могут быть разные
до того как начали работать, ... Все что не попадает - должно выводиться
в рамках аудита и приводиться к порядку».
**Why:** Нужна fixed taxonomy для предсказуемого поведения hook'ов;
self-healing audit для случаев когда workitem'ы пришли с произвольной
терминологией (vault, импорт, разные команды).

**Канонические статусы — 4 tier:**

| Tier | Status | Семантика |
|------|--------|-----------|
| **Pre-work** | `idea` | Зафиксировал мысль. Может никогда не дойти. |
|  | `draft` | Спека пишется, не утверждено. |
|  | `ready` | Утверждено, в очереди, можно брать. |
| **Active** | `in-progress` | Работаем сейчас. Singleton tier. |
| **Paused** | `blocked` | Остановлено, ждём внешнее. |
|  | `dormant` | Параллельная активная задача (DL #11 crystal-design vocab) — сохраняется отдельно от `blocked` для семантической чистоты. |
| **Terminal** | `done` | Завершено. Gate срабатывает на переход. |
|  | `cancelled` | Явно отменено с rationale (в теле). Gate НЕ фaйрится. |
|  | `superseded` | Заменено — требует `superseded-by: <slug>` в frontmatter (новая валидация). Gate НЕ файрится. |

**Singleton invariant:** только `in-progress`. Pre-work и Paused tier
свободны от singleton (12 идей + 5 ready + 3 blocked = OK).

**Видимость по tier:**

| Контекст | Pre-work | Active | Paused | Terminal |
|----------|----------|--------|--------|----------|
| `list-open-crystals.sh` | ✗ | ✓ | mention only | ✗ |
| `crystal-cave` default | ✓ (Backlog section) | ✓ (top) | ✓ (Paused section) | ✗ |
| `crystal-cave --all` | ✓ | ✓ | ✓ | ✓ |
| Completion gate (`done`) | — | — | — | trigger only on `done` |

**Audit non-canonical:** при invoke любого crystal-* skill'а или hook'а:
1. `audit_non_canonical()` lib-функция возвращает список файлов со
   статусами вне канона.
2. Hook output (SessionStart, Phase 0) добавляет одну строку, если
   результат непустой:
   `⚠ Non-canonical statuses: N workitems. /vdm:crystal-cave to triage.`
3. `crystal-cave` показывает секцию «Non-canonical (требует решения)» с
   предложением remap'а.
4. Optional `status-aliases: {"WIP": "in-progress"}` в конфиге для
   постоянного маппинга устоявшейся терминологии проекта.

**Implication:** taxonomy зафиксирована, новые добавления требуют DL
entry. Vault'у нужно одной правкой выбрать: либо переименовать `idea`
файлы по мере готовности (всё уже legal), либо добавить status-aliases
если хочет сохранить нестандартное имя.

**Cross:** см. Sidetrack #1 (resolved).

## Sidetracks

<!-- Capture findings/follow-ups that aren't on the main spine. -->

### #1. Status vocabulary mismatch (vault использует `status: idea`)

**Возникло в:** Назначение / vault analysis
**Описание:** Vault frontmatter использует `status: idea` (и потенциально
`status: draft`, `status: ?`). Crystal-completion-guard срабатывает только
на `done`, так что `idea`-файлы он молча игнорирует — это OK для гейта,
но `crystal-cave` и `list-open-crystals.sh` фильтруют по
`status: in-progress`, т.е. `idea`-файлы там не появятся. Решение:
расширить «активный» до `{in-progress, idea, draft}` через
`active-statuses: [...]` в конфиге, либо оставить как есть и заставить
vault переходить через `in-progress`. Defer до реализации основного scope.

**Status:** resolved — см. DL #10. Принята fixed 4-tier taxonomy (Pre-work / Active / Paused / Terminal). Singleton только на `in-progress`. Pre-work и Paused tier видимы в `crystal-cave`, но не в active sweep'ах. Audit non-canonical через one-line warning + cave-секцию + опциональный `status-aliases` mapping.

### #2. Crystal-grow `path` subcommand — что с ним делать после multi-root?

**Возникло в:** DL #4 / config schema
**Описание:** Сейчас `/vdm:crystal-grow path <value>` устанавливает
`path: "<value>"` (singular). Нужны ли подкоманды `paths add <glob>`,
`paths remove <glob>`, `paths list`? Или достаточно сказать «правьте
JSON руками для multi-root»? Defer до реализации — посмотрим, насколько
часто будут менять.

**Status:** resolved — см. DL #11. Решено: полный набор subcommands в v1 (paths add/remove/list/set/clear, path clear, status-alias add/remove/list/clear, singleton override, расширенный config). Mixed-config refused explicitly.

### #3. Имена файлов с префиксами в vault (`idea-*`, `task-*`, `PRD*`, `prompt-*`)

**Возникло в:** Назначение / vault analysis
**Описание:** Vault использует префиксы как type-marker. Текущий
`extract_slug` снимет `.md` — slug будет `idea-recipe-role-property`. Cave
будет читаемой, но если хотим парсить префикс в `type` отдельно — это
доп. фича. Defer — не блокирует основной scope.

**Status:** resolved — см. DL #12. Vault — анархия, не data model для поддержки. Канон: folder-stem `<slug>/workitem.md` + `references/`. Filename-prefix parsing out of scope. Type-role во frontmatter. Vault получает migration playbook (Sidetrack #5), не автоматический importer.

### #5. Migration playbook для vault: flat-prefix → folder-stem

**Возникло в:** DL #12 / Sidetrack #3 resolution
**Описание:** Vault имеет ~20 файлов в `projects/*/tasks/` с
type-prefix именами и mixed frontmatter (`status: idea`, `type: idea`,
итд). Нужна документированная процедура миграции в канон
`<slug>/workitem.md` + `<slug>/references/`.

Открытые вопросы для migration playbook:
1. Drop type-prefix из имени (`idea-recipe-role-property` →
   `recipe-role-property/workitem.md`) — type уже во frontmatter,
   дублирование вредно. Принять как правило?
2. Для `PRD.md` и `PRD-sanitize.md` — это spec'и, не workitem'ы в
   рабочем смысле. Сделать их `references/original-prd.md` под new
   workitem'ом, или они *становятся* workitem'ами с status:done?
3. `prompt-*.md`, `subagent-*.md` — это artifacts. Под какой workitem
   их сложить? Один общий `<project>-prompts/workitem.md` или к каждой
   связанной задаче?
4. Сохранять ли historic dates (DL #?: «dates reflect real history») —
   `created:` из file birthtime, `last-updated:` из git log если git
   доступен (cs:p3-85f4 — fallback к mtime если нет git).
5. Где жить playbook'у: `docs/llm/vault-migration-playbook.md` в
   cc-vdm-plugins (универсальный гайд) ИЛИ
   `/Volumes/Working/ObsidianVault/docs/llm/crystal-migration.md` (vault-local
   one-shot)? Скорее первое — пригодится и другим монорепам.

Migration **не автоматизируется** — judgment-driven move per file, как
в crystal-grow «Migrating legacy docs». Playbook = чеклист + примеры.

**Status:** open — резолвится отдельно (после v1 multi-root shipped и
протестирован на не-vault репах).

### #6. Enforcement script для mandatory inline-маркеров (DL #14)

**Возникло в:** DL #14 / closure review
**Описание:** DL #14 объявляет правило «каждый open sidetrack обязан
иметь inline `- [ ]` маркер», но enforcement пока текстовый
(crystal-bud SKILL.md). Per cs:p3-700d текст в SKILL.md ненадёжен —
нужен deterministic check: скрипт сканит каждую sidetrack-карточку с
`Status: open`, ищет соответствующий `- [ ] см. Sidetrack #N`
маркер в файле, отсутствие → warning (или blocker).

Кандидаты на интеграцию:
- `crystal-cut` Step 2 sweep: добавить проверку «open sidetracks без
  inline маркера» с предложением создать секцию `## Pending sidetracks`
  с маркерами.
- `crystal-bud` Step 4: после write проверить что маркер реально
  поставлен (поверх SKILL.md дисциплины).
- Hook PostToolUse на workitem write: audit карточки + предложить fix.
- Параллель `audit_non_canonical` в lib/crystal-path.sh:
  `audit_sidetracks_without_markers()`.

**Status:** open — отложено до отдельного workitem'а (вероятно
`crystal-discipline-strict` или включить в migration playbook crystal).

### #4. docs-sync Phase 0 в multi-root становится шумнее

**Возникло в:** Назначение / docs-sync impact
**Описание:** Сейчас вывод `→ Open crystals: <slug-1> (N open), ...` — одна
строка. В vault'е с 10 активными crystal'ами по разным проектам — длинная
строка. Возможно стоит group by project: `→ Open crystals: auth: [a, b
(3)], billing: [c]`. Defer — реализуем после того, как multi-root
заработает и появятся реальные жалобы.

**Status:** resolved — см. DL #13. Group-by-root в multi-root, flat в single-root. Auto-derive из числа resolved roots (тот же сигнал, что singleton). Alphabetical sorting внутри группы и для самих групп — стабильный output между запусками.

## Next actions

Блокирующий tail — все unchecked items здесь блокируют `crystal-cut`.

### Phase A — Resolver

- [x] Spec `resolve_crystal_roots()` (plural) в `lib/crystal-path.sh`:
      три ветки (paths / path / auto-scan), bash glob expansion через
      `shopt -s nullglob`
- [x] Implement `resolve_crystal_roots()` + сохранить `resolve_crystal_root()`
      как wrapper (первый элемент списка)
- [x] Update `find_workitems()` — итерация по всем roots
- [x] Update `extract_slug()` — multi-root ветка `<parent>/<file>`
- [x] Tier-aware `filter_status` — принимает массив статусов (или
      tier-имя `active`/`pre-work`/`paused`/`terminal`), а не одну строку
- [x] Mirror все изменения в `plugins/vdm-git/lib/crystal-path.sh`
      (check-lib-sync.sh enforce)

### Phase B — Hook scripts

- [x] `crystal-completion-guard.py` — `CRYSTAL_ROOTS` (colon-separated env)
      + iterate, membership check across all roots
- [x] Update `crystal-completion-guard.sh` (bash wrapper) — passes
      `CRYSTAL_ROOTS` env to Python
- [x] `list-open-crystals.sh` — output формат (DL #13): group-by-root в
      multi-root (`- <root>: slug1 (N), slug2 (M)`), flat в single-root;
      alphabetical sorting внутри группы и для самих групп
- [x] `crystal-hydrate.sh` — same output формат через
      multi-line `additionalContext`
- [x] `crystal-stop-reminder.sh` — same

### Phase C — Singleton derivation

- [x] Добавить `derive_singleton_mode()` в lib (одна функция, читает
      explicit override → fallback к деривации из числа roots)
- [x] Update `crystal-hydrate.sh` warning header — учитывает per-root vs global

### Phase D — Grow auto-detect

- [x] Update `crystal-grow` SKILL.md — Step 2 расширить таблицей
      confidence (см. DL #7)
- [x] Сам resolver auto-detect делается ассистентом, не скриптом
      (no script change нужен — это behavioral)

### Phase E — Config schema & subcommands (расширено DL #11)

- [x] Update `crystal-grow` SKILL.md — config subcommands table
      (полная таблица с DL #11): paths add/remove/list/set/clear,
      path clear, status-alias add/remove/list/clear, singleton override,
      расширенный config
- [x] Implement `paths add <glob>` — idempotent, warning «matches 0 dirs»
      если пусто, всё равно writes
- [x] Implement `paths remove <glob>` — warning if not found, empty array
      → удаление ключа
- [x] Implement `paths list` — pretty-print + resolved roots после glob
      expansion; empty → «auto-scan active» + список
- [x] Implement `paths set <glob1> <glob2> ...` — space-separated, overwrite
- [x] Implement `paths clear` — удалить ключ → fallback к `path` или
      auto-scan
- [x] Implement `path clear` — migration helper
- [x] Implement `path <value>` mixed-config refusal: error если `paths`
      задан (force `paths clear` first)
- [x] Implement `status-alias add <from>=<to>` — валидация `<to>` против
      `CANONICAL_STATUSES`, error на несуществующий canonical
- [x] Implement `status-alias remove/list/clear`
- [x] Implement `singleton <mode>` — `global`/`per-root`/`off`/`auto`;
      `auto` удаляет ключ (возврат к деривации)
- [x] Расширить `config` / `status` — diagnostic output: configured
      paths/path/aliases/singleton + resolved roots + derived singleton +
      counts (active / pre-work / paused / terminal / non-canonical)
- [x] Update «Defaults when the section is missing» в SKILL.md
      (enabled: true, всё остальное → auto-scan / деривация)
- [x] JSON manipulation strictly через Edit (без `jq`) — правило #4 в
      Patching rules сохраняется

### Phase F — Documentation & onboarding

- [x] Update `crystal-grow/SKILL.md` — Storage layout section (multi-root)
- [x] Update `crystal-cave/SKILL.md` — output формат для multi-root
- [x] Update `crystal-cut/SKILL.md` — slug разрешение в multi-root
- [x] Update `docs-sync/SKILL.md` — Phase 0 output формат
- [x] Update root `README.md` если упоминает single-root
- [x] `PROJECT_CHANGELOG.md` entry (v2.5.0 — MINOR, новая возможность)

### Phase G — Versioning & release

- [x] Bump `plugins/vdm/.claude-plugin/plugin.json` (PATCH → MINOR)
- [x] Bump `plugins/vdm-git/.claude-plugin/plugin.json` (mirror)
- [x] Bump `.claude-plugin/marketplace.json` versions
- [x] Self-test: `cd /Volumes/Working/ObsidianVault && list-open-crystals.sh`
      возвращает sensible вывод

### Phase H — Performance validation

- [x] Benchmark `find . -type d -name tasks -not -path '*/.*/*' -prune`
      на vault'е, измерить wall-clock
- [x] Если >500ms: реализовать `git ls-files` fallback (cs:p3-85f4 — git
      может отсутствовать, поэтому именно fallback)
- [x] Если <500ms: closed, fallback не нужен; добавить sidetrack #5
      «optimization deferred»

### Pending sidetracks (inline markers — DL #14)

Inline `- [ ]` markers for every `Status: open` sidetrack. Without these
the crystal-cut gate cannot see the obligation (it counts checkboxes, not
status text). Resolving a sidetrack means flipping the marker AND updating
the sidetrack card's `**Status:**` line.

- [ ] см. Sidetrack #5 — migration playbook для vault (отдельный workitem после shipping v1)
- [ ] см. Sidetrack #6 — enforcement-script для mandatory inline-markers

### Phase I — Taxonomy & audit (DL #10)

- [x] Добавить константы `CANONICAL_STATUSES`, `TIER_PRE_WORK`,
      `TIER_ACTIVE`, `TIER_PAUSED`, `TIER_TERMINAL` в `lib/crystal-path.sh`
- [x] Implement `audit_non_canonical()` — возвращает список файлов со
      статусами вне канона
- [x] Implement `derive_status_tier(status)` — мапит статус в tier (с
      учётом `status-aliases` из конфига)
- [x] Update `crystal-completion-guard.py` — gate срабатывает **только**
      на `done` (не на `cancelled`/`superseded`)
- [x] Новый gate: при `status: superseded` валидировать наличие
      `superseded-by: <slug>` в frontmatter; блокировать переход иначе
- [x] Update `list-open-crystals.sh`, `crystal-hydrate.sh` — добавить
      one-line audit warning если `audit_non_canonical()` непустой
- [x] Update `crystal-cave/SKILL.md` — новые секции «Backlog» (Pre-work),
      «Paused», «Non-canonical (требует решения)» с remap workflow
- [x] Update `crystal-cave/SKILL.md` — флаг `--all` показывает Terminal tier
- [x] Update `crystal-grow/SKILL.md` config subcommands — документировать
      `status-aliases` (optional)
- [x] Update `workitem-template.md` — комментарий перечисляющий валидные
      статусы по tier
- [x] Mirror lib changes в `plugins/vdm-git/lib/`

## References

- `references/` — пока пусто, при необходимости положим original-spec
- Vault sample: `/Volumes/Working/ObsidianVault/projects/*/tasks/`
- Existing resolver: `plugins/vdm/lib/crystal-path.sh`
- Existing gate: `plugins/vdm/scripts/crystal-completion-guard.py`
- Mirror file: `plugins/vdm-git/lib/crystal-path.sh`
- Sync check: `scripts/check-lib-sync.sh`
- Crystal design: [[crystal-design]] (parent — overall suite design)
