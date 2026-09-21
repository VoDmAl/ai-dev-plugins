---
title: "vdm-comms 0.1.0: линтер встреч, конфиг, дрифт-сигнал реестра и страж черновиков"
slug: vdm-comms-core
description: "Собрать первый ломоть vdm-comms и подключить к нему три репозитория"
status: ready
session-type: prd-prep
created: 2026-09-21
last-updated: 2026-09-21
relates-to:
  - "[[comms-plugin/workitem|comms-plugin]]"
  - "[[obsidian-profile-skill/workitem|obsidian-profile-skill]]"
---

# vdm-comms 0.1.0: линтер встреч, конфиг, дрифт-сигнал реестра и страж черновиков

> Ломоть №1 решений кристалла `comms-plugin` (2026-09-21). Заведён в `ready` по слову
> владельца «всё по порядку»; работа не начата. Все решения формы — там (DL #4–#10), здесь
> — только исполнение. Перед первым коммитом перечитать `comms-plugin` целиком: его
> `## Текущая модель` содержит таблицу разреза и инвентарь на 2026-09-21.

## Назначение

**Цель.** Выпустить `plugins/vdm-comms/` версии 0.1.0 и подключить к нему `global-auth-gap`,
`space-hq` и `t23b-program`: их копии `lint-meetings.py`, `check-meeting-format.sh` и
`check-draft-comms.sh` снимаются, вместо них — секция `comms` в `.claude/vdm-plugins.json`.

**Ограничения.** Форма контракта — минимальный конфиг + зашитый пол (`comms-plugin` DL #8);
парсер frontmatter вендорен, stdlib (DL #10); гейт при отказе блокирует с текстом «файл НЕ
проверен» (DL #10); плагин не пишет файлы проекта сам — дрифт-сигнал + скилл по команде
(DL #9); точки расширения нет (DL #6); текст скиллов без имени модели.

**Критерий успеха.** В каждом из трёх репозиториев: линтер плагина проходит на живых файлах
с тем же вердиктом, что их копия (расхождения объяснены); дрифт-сигнал реестра
срабатывает после правки встречи и гаснет после `/vdm-comms:index`; пересборка
воспроизводит текущий `INDEX.md` байт-в-байт либо с объяснённым диффом; страж черновиков
блокирует новый `-out.md` с `sent:` под всеми корнями из конфига; копии в
`.claude/hooks/` удалены, `settings.json` от них очищен.

## Текущая модель

**Исходник для порта** (инвентарь 2026-09-21, `comms-plugin` DL #3): `global-auth-gap/.claude/hooks/lint-meetings.py`
— 502 строки, PyYAML, функции `split_fm`, `lint_series`, `lint_meeting`, `meeting_dirs`,
`registry_rows`, `render_table`, `replace_between`, `meeting_source`, `render_pointer`,
`write_track_pointers`, `regenerate`; `check-draft-comms.sh` — 49 строк, `jq`;
`check-meeting-format.sh` — 29 строк, `|| true`. Копия у `space-hq` (20 КБ, 13.09)
разошлась: `TRACK_RE`, тексты ошибок, фикс кода возврата. У `t23b-program` копии нет.

**Что различается между репозиториями и уходит в конфиг** (эстафета §А1, §4, §5):
корни треков (`gaps|org|incidents` / `tracks` / шесть пространств глубиной 1–3, половина —
файлы); список серий (у `t23b` — `troop` не объявлен). Всё остальное — одна модель.

**Что в поле, а не в конфиге** (пол): `type:` как класс файла (`meeting` / `meeting-series` /
`index` / `readme`); роли по имени файла (`index|prep|agenda|pitch`); `date` обязательна;
`index.md` только при `date` в прошлом; `series` из списка, без файла — предупреждение;
трек существует как `<p>/` или `<p>.md`, регистр не нормализуется; «встреча — трек
встречи» допустимо; тела серий не проверяются; `migrated_from:` — тело не проверяется;
счётчик откладываний не инвариант; без `meetings/` — тихий выход.

**Реестр как синтез** (DL #9): сравнение `INDEX.md` + блоков «Встречи серии» + указателей
`<track>/comms/<дата>-<slug>-meeting.md` (метка `generated:`) с множеством встреч; сигнал
в PostToolUse и SessionStart; пересборка — только скиллом. Указатели для треков-файлов —
открытый вопрос (дефолт: не создавать, перечислять в отчёте).

**Два гейта репозитория захардкожены на два плагина** (`obsidian-profile-skill`
Sidetrack #6): `scripts/check-lib-sync.sh` и `scripts/check-skill-paths.sh:53`. Третий
плагин сужает их молча. Общий хвост с `vdm-obsidian`; чинится один раз, до первого
коммита любого из них.

**Инвентарь протухает еженедельно** (DL #3): перед стартом — повторить.

## Decision Log

### #1 / 2026-09-21 / Заведён как ломоть в `ready`; форма решена в `comms-plugin`

**Source:** user
**Basis:** user-stated
**Basis-detail:** «всё по порядку» — ответ на предложение завести кристаллы-ломти под
принятые решения (`comms-plugin` Next actions). Решения D1–D6 приняты там 2026-09-21 в
grill-интервью и здесь не пересматриваются.
**Context:** один кристалл на всё против кристалла на ломоть; `comms-plugin` — кристалл
разреза, без кода.
**Why:** ломоть — единица выпуска с собственной версией и приёмкой; смешивать его с 0.2 и
0.3 значило бы держать один кристалл открытым месяцами.
**Implication:** статус `ready`, singleton не занят. При старте — `status: in-progress`,
`session-type: prd-work`, повторный инвентарь первым действием.

## Sidetracks

Пока нет. Побеги родительского кристалла, относящиеся сюда: `comms-plugin` #4 (гейты на
два плагина) и #9 (лишние ключи серии у `space-hq` — контракт как пол).

## Next actions

- [ ] Повторный инвентарь трёх репозиториев: версии `lint-meetings.py`, `check-*.sh`,
      `settings.json`; всё, что изменилось после 2026-09-21
- [ ] Обобщить `scripts/check-lib-sync.sh` и `scripts/check-skill-paths.sh` на `plugins/*/`
      (общий хвост с `vdm-obsidian`) — **до** первого коммита `plugins/vdm-comms/`
- [ ] Скелет: `plugins/vdm-comms/.claude-plugin/plugin.json` 0.1.0, запись в
      `.claude-plugin/marketplace.json`, `hooks/hooks.json`, `README.md`; решить, нужен ли
      `lib/` (чтение секции `comms`) и как он зеркалится
- [ ] Вендорить парсер frontmatter (stdlib): переиспользовать `split_frontmatter` из
      `crystal-lint.py` или вынести общий модуль
- [ ] Порт линтера → `scripts/comms-lint.py`: конфиг `track-roots` / `series` /
      `meetings-dir`; резолвер `<p>/` или `<p>.md`; `type:` — селектор; фаза по `date`;
      серия из списка; тела серий и `migrated_from:` не проверять; тихий выход
- [ ] Хук PostToolUse `comms-lint.sh`: «провалена ≠ не выполнена» — линтер не отработал →
      `exit 2` «файл НЕ проверен: <причина>»; префильтр по подстроке пути в stdin без
      парсера; `jq` не использовать
- [ ] Дрифт-сигнал реестра и указателей (тот же PostToolUse + SessionStart): «реестр отстал
      на N встреч / M указателей → `/vdm-comms:index`»; сравнение без состояния
- [ ] Скилл `skills/index/SKILL.md`: пересборка по команде, отчёт (что изменено, какие
      треки-файлы без указателя), маркеры `<!-- registry:start/end -->` как точка вставки
- [ ] Страж черновиков PreToolUse на `*/comms/*-out.md` под корнями из конфига; та же
      rc-семантика
- [ ] Красные тесты на фикстурах с разорванной корреляцией: три раскладки треков, будущая
      встреча без `index.md`, трек-файл, `areas/INDEX` с заглавными, серия без файла,
      встреча-трек-встречи; отсутствие `python3` → `exit 2`, не 0 и не 127
- [ ] Подключить три репозитория: конфиг, снятие копий и записей в `settings.json`, маркеры
      в `INDEX.md` у `t23b`, сверка пересборки с текущим `INDEX.md`
- [ ] Версия, каталог, `PROJECT_CHANGELOG.md`; `/vdm:docs-sync`; ответ трём агентам о
      выходе 0.1.0 через `/vdm:intercom send`

## References

- Родитель: `[[comms-plugin/workitem|comms-plugin]]` — DL #4–#10, таблица разреза,
  `references/intercom-brief-t23b-program-relay.md` (§А9 — 13 требований),
  `references/intercom-brief-global-auth-gap-addendum.md` (§1 — указатели).
- Исходники: `/Users/vdm/AI Projects/global-auth-gap/.claude/hooks/{lint-meetings.py,check-meeting-format.sh,check-draft-comms.sh}`,
  `/Users/vdm/AI Projects/space-hq/.claude/hooks/{lint-meetings.py,check-meeting-format.sh}`
  (эталон фикса кода возврата), `meetings/README.md` в каждом.
- Прецедент формы: `plugins/vdm/scripts/crystal-lint.py` (stdlib-линтер, парсер frontmatter),
  `plugins/vdm/hooks/hooks.json`, `docs/model/suite.md` § «Один сигнал».
- Гейты на два плагина: `[[obsidian-profile-skill/workitem|obsidian-profile-skill]]` Sidetrack #6.
