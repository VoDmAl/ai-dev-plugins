---
title: "Crystal-migrate: batch legacy-doc migration skill + cross-project lessons"
slug: crystal-migrate
description: "Design + ship /vdm:crystal-migrate; accumulate lessons across project migrations"
status: done
session-type: prd-prep
created: 2026-06-03
last-updated: 2026-07-04
---

# Crystal-migrate — batch legacy migration skill + cross-project lessons

> Design and ship `/vdm:crystal-migrate`. When invoked in a fresh project,
> the skill creates a "migration" crystal **inside that project** as its
> first crystal — that local crystal acts as the migration runbook,
> progress tracker, and decision log for the per-project work. **This**
> design-home crystal (in `cc-vdm-plugins`) accumulates lessons across
> every project migration the user runs (2 done so far, dozens ahead),
> feeding them back into the skill design.

## Происхождение

Migrated from `[[crystal-multi-root/workitem|crystal-multi-root]]` Sidetrack #5
("Migration playbook для vault: flat-prefix → folder-stem"). Reframed per
user direction: «это скорее скилл помогающий миграции, отвечающий на разные
вопросы с которыми будут сталкиваться. Не надо лочиться на one-specific vault
structure. Я мигрировал 2 проекта из десятков, каждый будет приносить что-то
новое и мы будем улучшаться». См. оригинальную карточку для исторического
контекста — там же и первые наблюдения из vault-миграции, послужившие
основой для пяти design-вопросов в Sidetrack #1 ниже.

## Назначение

Двухуровневая модель:

1. **Per-project «migration» crystal.** При первом запуске
   `/vdm:crystal-migrate` в virgin-проекте skill:
   - сканирует legacy-структуры (flat-prefix, `PRD.md`, `prompt-*.md`,
     mixed-frontmatter — каждый проект приносит свой набор);
   - создаёт `docs/tasks/migration/workitem.md` (или `<root>/migration/`)
     как первый crystal в этом проекте, `status: in-progress`;
   - каждый legacy-файл становится позицией в его `## Next actions`,
     migration-решения попадают в локальный `## Decision Log`;
   - когда чек-боксы закрыты — `crystal-cut`, миграция done как
     исторический артефакт первого set-up.

2. **Design-home crystal (this).** Сюда копятся cross-project уроки —
   DL entries и побеги, появившиеся при миграции конкретных проектов.
   Эти уроки feedback'ом улучшают skill для будущих миграций.

Skill = batch orchestrator, **не** per-file invocation: «не по одному
файлу, а фигачит все» (user direction).

## Decision Log

### #1. Scope — standalone skill, не сабкоманда

**Дата:** 2026-07-03
**Решение:** `/vdm:crystal-migrate` — отдельный скилл, sibling к grow/bud/cut/cave.
НЕ сабкоманда `crystal-grow migrate`.
**Рационал:**
- Suite уже verb-per-skill (grow/bud/cut/cave) — sibling консистентен.
- Разные триггеры: grow = начать **один** кристалл; migrate = virgin-проект
  с legacy-деревом → **много** кристаллов. Слияние размывает trigger-описание grow.
- migrate переиспользует grow-логику (даты, folder-stem) композицией, не слиянием.
**Отвергнуто:** сабкоманда — меньше surface, но размытый триггер сразу у обоих.

### #2. Slug при миграции свободно пересматривается; provenance через `migrated-from`

**Дата:** 2026-07-03
**Решение:** Отвергнута механическая prefix-логика (R1/R2/R3 из B1). Слаг при
миграции **свободно пересматривается** — не выводится алгоритмически из старого
имени (префикс ≠ идентичность). Провенанс — frontmatter-массив
`migrated-from: [<original relative path>, …]` для обратной отмотки/поиска.
**Следствия:**
- `migrated-from` — новое опциональное frontmatter-поле мигрированного
  workitem'а; аналог changelog move-breadcrumb (оба конца, immutable запись).
- Нет таблицы `prefix→status`; статус выставляется по смыслу файла, не по префиксу.
- «Свободно пересматривается» ⇒ контракт миграции (Phase A / C) должен иметь
  шаг ревизии предложенных слагов: batch-scan → mapping → HITL-review → apply,
  не per-file прерывания.
**Открыло:** Sidetrack #2 (link-integrity шире md-файлов).

### #3. PRD/spec-файлы → references/ (T1 дефолт); own status:done workitem — fallback (T2)

**Дата:** 2026-07-03
**Решение:** PRD/spec по природе спека (артефакт), не work-unit.
- **T1 (дефолт):** PRD → `<slug>/references/original-prd.md` под workitem'ом
  (создаётся если нет; статус = по факту работы: done/ready/idea; `reference-for:` назад).
- **T2 (fallback):** осиротевший исторический PRD без дома (работа отгружена,
  трекинга не было) → тонкий `status:done` workitem, PRD как reference/body.
  Не основной путь.
- Классификацию предлагает skill, человек подтверждает (как B1).
**Прецедент:** та же ось «артефакт vs work-unit» ведёт в B3.

### #4. Scan-классификация: три корзины {workitem, reference, out-of-scope} (B3 → D3)

**Дата:** 2026-07-03
**Решение:** не всё в legacy-дереве — task-артефакт. Scanner раскладывает каждый
файл в три корзины:
- **workitem** — единица работы → `<slug>/workitem.md`.
- **reference** — спека/скаффолд под задачу → `<slug>/references/*` + `reference-for:`.
- **out-of-scope** — переиспользуемый ассет (prompt/subagent-темплейты, не
  привязанные к задаче) → **репортится, не мигрируется силой**; остаётся на
  месте / решает человек.
**Отвергнуто:** D1 (нет дома осиротевшим), D2 (fake-workitem-бакет забивает tasks ассетами).

### #5. Миграция = реструктуризация + аудит/триаж, не только file-move

**Дата:** 2026-07-03
**Контекст:** до crystal-подхода дисциплины не было, drift случался постоянно;
миграция гарантированно вскроет незавершённое, подвисшие артефакты,
non-canonical статусы.
**Решение:** миграция — повод пересмотреть каждый таск. Skill включает
audit/triage-проход как first-class выход:
- **drift/completeness:** пометить work, зависшую in-progress / без апдейтов, неявно заброшенное.
- **orphans:** references без владельца, подвисшие артефакты (ср. out-of-scope из DL #4).
- **status-аудит:** значения вне канон-таксономии → warning + реклассификация.
- **singleton-триаж:** легаси-drift часто держит несколько «активных» разом →
  форс-свести к одному in-progress (per-root), остальное → blocked/dormant/ready.
- выход — не «всё ✅», а **отчёт-триаж**: чисто перенесено vs требует решения человека.

### #6. Historic dates — reuse grow «Two rules that bite» + non-git fallback (B4)

**Дата:** 2026-07-03
**Решение:** migrate не изобретает date-логику — опирается на grow:
1. Даты = реальная история, не момент импорта: `created` ← первый коммит файла,
   `last-updated` ← последний реальный touch; из **исходного** legacy-файла, не `now()`.
2. Готовый док → `status: done` с нулём `- [ ]` (completion-guard бьёт на создающий Write).
**Связь:** правило #2 = тот же audit-гейт (DL #5) — дрейфнувший in-progress с
открытыми боксами не может молча стать done, форсит триаж.
**Дополнение:** non-git fallback (birthtime/mtime) → Sidetrack #3.

### #7. Где живёт гайд — self-contained SKILL.md (B5)

**Дата:** 2026-07-03
**Решение:** вопрос закрыт архитектурой, не выбором.
- **Исполняемая процедура** → только SKILL.md (+ опц. `scripts/`/`templates/` под
  `${CLAUDE_PLUGIN_ROOT}`): `docs/llm/*.md` не шипается в user-проект, skill не
  может его исполнять в рантайме.
- **Уроки/рационал** → `## Decision Log` этого crystal'а (двухуровневая модель).
  Опциональный `docs/llm/crystal-migration.md` — только dev-time рационал
  (+ discovery-hook по правилу репо #2), не runtime-зависимость.
**Итог:** self-contained SKILL.md.

### #8. Input/output contract (C) + git mv history-continuity

**Дата:** 2026-07-03
**Input:** auto-scan `tasks/`-root(ов) через `lib/crystal-path.sh` (git ls-files /
find, hidden+deps excluded) → классификация в 3 корзины (DL #4) → **migration
plan**, не сразу apply.
**HITL-gate:** один review-проход (не per-file): предложенные слаги (DL #2),
классификация (DL #4), drift/status/singleton-аномалии (DL #5) → человек правит → apply.
**Output:**
- per-project `migration`-crystal (`docs/tasks/migration/workitem.md`, in-progress) — runbook + progress + local DL;
- N workitem'ов folder-stem; даты из source (DL #6); `migrated-from` (DL #2);
- references под владельцами (DL #3), `reference-for:` назад;
- out-of-scope — репорт, не тронуто (DL #4);
- triage-отчёт (DL #5), скрипт-backed рендер;
- всё batch, не per-file.
**git mv:** в git-проекте перемещение через `git mv` (history-continuity для blame);
в non-git — обычное. **Важно:** даты (DL #6) читаются из **исходного пути на
plan-этапе, до move** — стемпятся в frontmatter, поэтому rename-detection `git mv`
на них не влияет. `git mv` — best-effort future-continuity; при тяжёлом
frontmatter-edit git может увидеть delete+add (косметика blame, не корректность).

### #9. Scan input — explicit dir(s) → resolve_crystal_roots → ask (Phase B)

**Дата:** 2026-07-03
**Источник:** assistant (implementation-level, closed by architecture)
**Контекст:** DL #8 сказал «auto-scan `tasks/`-root(ов)», но Назначение требует
сканировать и legacy вне `tasks/` (root-level `PRD.md`, `prompts/`,
mixed-frontmatter). Виргин-проект вообще может не иметь `tasks/`-дерева.
**Решение:** `crystal-migrate-scan.sh` резолвит цель тремя ветками: (1) явные
`<dir>`-аргументы; (2) иначе `resolve_crystal_roots`; (3) иначе (нет root) —
пустой вывод, skill спрашивает у человека, где живут legacy-доки, и пере-сканит с
явным путём. Scanner остаётся механическим; «где» — judgment, отдан skill/HITL.
**Следствие:** scanner переиспользуем на произвольных деревьях (docs/, vault-папка),
не залочен на `tasks/`.

### #10. Даты — единый helper `crystal-dates.sh`, git→fs fallback (resolves Sidetrack #3)

**Дата:** 2026-07-03
**Источник:** assistant
**Контекст:** DL #6 переиспользует grow-правило дат, но grow «Two rules that bite»
кодифицировал **только git** (`git log`). Sidetrack #3: non-git проектам нужен
fallback; проверить grow — не покрывает → back-port.
**Решение:** дата-деривация вынесена в один shared скрипт
`scripts/crystal-dates.sh` (git first-commit/last-touch → `stat` birthtime/mtime
для non-git). Живёт в `scripts/`, **не в `lib/`** — mirrored-lib не нужен (guard в
vdm-git даты не использует), значит нет vdm-git-бампа. `crystal-migrate-scan.sh`
его source'ит; grow «Two rules that bite» теперь зовёт его же → паритет migrate↔grow.
**Следствие:** Sidetrack #3 закрыт конструкцией — обе точки входа (batch-scan и
single-import) деривят даты одинаково, git или нет. Проверено тестом (non-git
ветка: birthtime/mtime непусты).

### #11. Link-integrity — two-tier (auto intra-crystal / surface+policy extra-crystal) — resolves Sidetrack #2

**Дата:** 2026-07-04
**Источник:** both (brainstorm с user'ом)
**Контекст:** Sidetrack #2 — переименование слага рвёт входящие ссылки. Универсального
rewrite-framework нет (каждый проект линкует по-своему), и skill заранее не знает, как
в целевом проекте заведено обращаться с артефактами/ссылками.
**Решение:** split по «знаемости» — одну конвенцию skill ЗНАЕТ, свою собственную:
- **Tier 1 (auto):** intra-crystal граф (`reference-for:`/`relates-to:`/`superseded-by:`/
  `migrated-from:`/`[[slug/workitem|slug]]`). Хит в файле **под crystal-root** → авто-rewrite
  в том же batch. Tiering **location-primary**, не по bucket-label (YAML block-array item
  `relates-to:` читается как wikilink, но под root'ом → всё равно Tier 1). Diff перед apply.
- **Tier 2 (surface+detect+policy):** всё вне root'ов (код, README, vault-заметки, трекеры).
  `crystal-refscan.sh detect` → доминантный стиль; `find <old-id>` → blast-radius по бакетам.
  Авто-rewrite только где стиль однозначен И user подтвердил; иначе — triage `- [ ]` +
  per-project link-integrity policy (DL в migration-кристалле). Трекеры (Jira/GH) — репорт,
  но out-of-scope для rewrite.
**Реализация:** `scripts/crystal-refscan.sh` (detect/find + бакетинг по стилю), SKILL Step 3.6
+ 5.6, template (policy-DL slot + Tier2 triage). Тест `crystal-refscan.test.sh` 12/12. Ключ:
skill **не** rewriter — он вскрывает и делегирует то, что не определял сам.
**Следствие:** Sidetrack #2 закрыт как resolved (реализовано в скилле), а не отложен.

### #12. Phase C (field-test) снят с build-scope этого кристалла

**Дата:** 2026-07-04
**Источник:** both
**Контекст:** «нет вечного кристалла» (user). Phase C — прогнать на реальном проекте +
накопить findings — это *эксплуатация* готового скилла, касается любой задачи
(«сделали → погонять → улучшить»), event-triggered, не build-обязательство.
**Решение:** снять Phase C с build-scope. Каждая реальная миграция само-документируется в
своём per-project migration-кристалле (двухуровневая модель); если полевой прогон вскроет
дефект скилла — это свежий crystal/bug тогда, а не вечно открытый пункт здесь. L276/L277 →
cancelled при cut.
**Следствие:** кристалл честно закрывается как «skill designed + shipped + tested». Dormant
не нужен — критерий user'а («момент рассмотрен, но не реализован, и оцениваем высоко») тут
не выполняется: Phase C — это usage, не unimplemented design.

## Sidetracks

### #1. Открытые design-вопросы (унаследованы из crystal-multi-root Sidetrack #5)

**Возникло в:** migrated from `[[crystal-multi-root/workitem|crystal-multi-root]]` Sidetrack #5
**Описание:** Пять открытых вопросов изначально формулировались под одну
конкретную vault-структуру; сейчас переосмысливаются как general migration
questions, на которые должен ответить skill (или его per-project workflow):

1. **Slug renaming rule** — дропать ли type-prefix
   (`idea-recipe-role-property` → `recipe-role-property`). Type уже во
   frontmatter, дублирование вредно. Принять как правило для skill'а?
2. **`PRD.md` и spec-файлы** — это спеки, не workitem'ы в рабочем смысле.
   Класть как `references/original-prd.md` под новый workitem, ИЛИ они
   *становятся* workitem'ами с `status: done` как историческими записями?
3. **`prompt-*.md`, `subagent-*.md` artifacts** — это побочные artifacts
   проектов. Один общий `<project>-prompts/workitem.md` для них, или
   распределить по связанным задачам?
4. **Historic dates preservation** — `created:` из file birthtime,
   `last-updated:` из `git log` (fallback to mtime). Уже codified в
   `crystal-grow/SKILL.md` «Two rules that bite»; skill должен на это
   опираться при per-file migration.
5. **Где жить gait'у для generic migration** — `docs/llm/crystal-migration.md`
   в этом репо как универсальный гайд + skill его исполняет, ИЛИ skill
   самодостаточен (всё в SKILL.md)?

**Status:** resolved (все 5 вопросов закрыты → DL #2–7)
- [x] см. Sidetrack #1

### #2. Link-integrity при миграции — project-specific, шире md-файлов

**Возникло в:** резолюция B1 (Sidetrack #1 Q1, slug-renaming) — user поднял
вопрос целостности ссылок
**Описание:** В каждом проекте свой подход к целостности ссылок. Миграция
`docs/tasks` может требовать не только перемещения/переименования
md-workitem'ов, но и переписывания ссылок на них в других местах (код, доки,
кросс-vault wikilinks, frontmatter `relates-to`/`reference-for`). Skill не
может считать миграцию чистым file-move: per-project migration-crystal должен
учитывать rewrite ссылок; объём может сильно превышать «только md-файлики».

**Status:** resolved → DL #11. Two-tier: Tier 1 (intra-crystal граф) авто-rewrite
location-primary; Tier 2 (extra-crystal) — `crystal-refscan.sh` detect+find →
surface + per-project policy, авто только по подтверждённому однозначному стилю.
Реализовано в скилле (Step 3.6/5.6, refscan, тест 12/12), не rewriter.

### #3. Non-git date fallback — паритет migrate ↔ grow

**Возникло в:** B4 (даты при миграции) — grow codifies git-only date-derivation
**Описание:** grow «Two rules that bite» выводит `created`/`last-updated` через
`git log`. В non-git проектах (у user'а такие есть) git-источника нет → нужен
fallback: `created` ← birthtime (`stat`), `last-updated` ← mtime. crystal-migrate
обязан иметь этот fallback. Проверить, покрывает ли его grow; если нет — back-port,
чтобы grow-import в non-git тоже работал.

**Status:** resolved → DL #10. Вынесено в shared `scripts/crystal-dates.sh`
(git first-commit/last-touch → `stat` birthtime/mtime). migrate-scan его source'ит;
grow «Two rules that bite» теперь зовёт его же (паритет). Проверено тестом.

## Next actions

### Phase A — Design (HITL pass с user'ом)

- [x] Закрыть scope-вопрос: standalone skill `/vdm:crystal-migrate`, или
      subcommand `/vdm:crystal-grow migrate` (расширение существующего) → DL #1: standalone
- [x] Ответить на 5 design-questions из Sidetrack #1 → DL #2–7
- [x] Определить input contract: что skill считывает (auto-detect legacy
      structures? explicit glob? user-confirmed list?) и output contract
      (создаёт сколько workitem'ов, какие references-папки, etc.) → DL #8

### Phase B — Implement

- [x] Скаффолд `plugins/vdm/skills/crystal-migrate/SKILL.md` — standalone (DL #1),
      self-contained (DL #7)
- [x] Реализовать orchestration logic — `scripts/crystal-migrate-scan.sh`
      (механический scan → TSV сигналы) + `scripts/crystal-dates.sh` (shared
      git→fs дата-helper, DL #10) + `templates/migration-crystal-template.md`
- [x] Тесты на synthetic legacy structures — `tests/crystal-migrate-scan.test.sh`
      23/23: git-tree (flat-prefix vault-like), non-git fallback, multi-target
      (monorepo-like/mixed)

### Phase C — Field-test — cancelled (снята с build-scope, DL #12)

- [x] ~~Прогнать на следующем проекте~~ — cancelled: usage готового скилла, не
      build-обязательство; каждая миграция само-документируется в своём
      migration-кристалле (DL #12)
- [x] ~~Накопить findings обратно сюда~~ — cancelled: полевой дефект → свежий
      crystal/bug тогда, не вечно открытый пункт (DL #12)

### Pending sidetracks

- [x] см. Sidetrack #2 — link-integrity → DL #11 (two-tier, реализовано в скилле)
- [x] см. Sidetrack #3 — non-git date fallback (migrate ↔ grow паритет) → DL #10

## References

(пусто — добавятся по ходу)
