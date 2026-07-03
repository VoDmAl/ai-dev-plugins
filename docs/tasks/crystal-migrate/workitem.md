---
title: "Crystal-migrate: batch legacy-doc migration skill + cross-project lessons"
slug: crystal-migrate
description: "Design + ship /vdm:crystal-migrate; accumulate lessons across project migrations"
status: dormant
session-type: prd-prep
created: 2026-06-03
last-updated: 2026-07-03
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

(пусто — наполняется по ходу design'а)

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

**Status:** open
- [ ] см. Sidetrack #1

## Next actions

### Phase A — Design (HITL pass с user'ом)

- [ ] Закрыть scope-вопрос: standalone skill `/vdm:crystal-migrate`, или
      subcommand `/vdm:crystal-grow migrate` (расширение существующего)
- [ ] Ответить на 5 design-questions из Sidetrack #1
- [ ] Определить input contract: что skill считывает (auto-detect legacy
      structures? explicit glob? user-confirmed list?) и output contract
      (создаёт сколько workitem'ов, какие references-папки, etc.)

### Phase B — Implement

- [ ] Скаффолд `plugins/vdm/skills/crystal-migrate/SKILL.md` (или субблок
      crystal-grow, в зависимости от Phase A scope-decision)
- [ ] Реализовать orchestration logic
- [ ] Тесты на synthetic legacy structures (несколько вариантов: vault-like,
      monorepo-like, mixed)

### Phase C — Field-test

- [ ] Прогнать на следующем проекте, который user будет мигрировать
- [ ] Накопить findings обратно сюда как DL entries / новые побеги

## References

(пусто — добавятся по ходу)
