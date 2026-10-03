---
title: "Гигиена Obsidian: правила и проверки из executor — в плагин vdm-obsidian"
slug: obsidian-hygiene-plugin
description: "Забрать из vault'а правила Obsidian и их проверки так, чтобы они работали на любом vault'е"
status: draft
session-type: prd-prep
created: 2026-09-25
last-updated: 2026-09-25
relates-to:
  - "[[obsidian-profile-skill/workitem|obsidian-profile-skill]]"
---

# Гигиена Obsidian: правила и проверки из executor — в плагин vdm-obsidian

> Припаркован 2026-09-25 из интерком-брифа `obsidian-hygiene-plugin` (`executor`,
> 2026-09-06), который 19 дней пролежал `pending`. Работа не начата: очередь — после
> [[obsidian-profile-skill/workitem|obsidian-profile-skill]], который заводит сам плагин (DL #1).

## Назначение

**Цель.** Забрать из executor в плагин `vdm-obsidian` два слоя сразу:

1. **Знание** — правила про Obsidian как программу, которые сейчас лежат в `CLAUDE.md`
   vault'а и к самому vault'у отношения не имеют. Каждое оплачено инцидентом.
2. **Харнес** — пять скриптов, которые эти правила проверяют, и хук, который зовёт
   проверку на правку заметки.

**Зачем.** `CLAUDE.md` vault'а грузится в каждый ход, и заметная его часть — знание,
переиспользуемое в любом vault'е. Отправитель хочет ужать его до ~12 строк: таблица
«правило → чем проверяется» плюс указатель на skill.

**Ограничения.**

- Нулевая конфигурация обязана работать: без конфига — все `.md`, кроме `.obsidian/`,
  `.git/`, `node_modules/`, `_resources/`.
- Предикат «имя файла в бэктиках» переносится **вместе с исключениями**, иначе проверка
  бесполезна. Первая наивная версия аудита дала 40 находок, и все 40 оказались ложными.
  Рабочая форма: «названо бэктиками **и** не слинковано в этой же заметке» плюс
  исключение doc-классов.
- `description` skill'а ловит **симптомы**, а не слово «Obsidian»: удалить правило из
  `CLAUDE.md` отправитель вправе, только если skill надёжно поднимается сам.

**Критерии приёмки** (из брифа, дословно по смыслу):

1. Скрипты работают на **чужом** vault'е без конфига — проверить на пустом тестовом.
2. На executor с конфигом дают **тот же вывод**, что нынешние локальные копии
   (diff = 0). Это regression-гейт: `bootstrap.sh` vault'а зовёт их как инварианты.
3. Хуки поставляются плагином; vault их «только включает» — что это значит, не ясно
   (Sidetrack #2).
4. Документировано, как `bootstrap.sh` зовёт скрипты плагина вместо локальных копий
   (Sidetrack #1).
5. Имя плагина и скиллов не коллидирует со сторонним `obsidian:` (kepano).

**Входящий контекст.** Бриф — `references/intercom-brief-executor.md`, байт в байт.
Его вторая половина живёт у отправителя: dormant-кристалл
`vault-maintenance/obsidian-hygiene-extraction` в executor ждёт письма
`obsidian-hygiene-plugin-ready`. После него они подрежут `CLAUDE.md`, снесут локальные
копии и переключат `bootstrap.sh`.

## Текущая модель

**Статус — `draft`.** Бриф разобран и сверен с диском, работа не начата. Слот singleton
не занят и не нужен. Очередь — после `obsidian-profile-skill` (DL #1). Вопросов к
отправителю не осталось: оба решены на нашей стороне (DL #4, DL #5).

**Плагин и имя уже решены — не здесь.** `vdm-obsidian`, skill'ы как
`/vdm-obsidian:<name>` — `obsidian-profile-skill` DL #7. На диске его пока нет:
`plugins/` = `vdm`, `vdm-comms`, `vdm-git`. Коллизии с kepano нет по построению: у того
префикс `obsidian:`.

### Карта Obsidian-направления

Здесь сведено всё направление: оба брифа `executor`, их кристаллы `vault-profile` и
`obsidian-hygiene-extraction` и путь через `vdx` (DL #7). Три вопроса — и у каждого один
владелец. Формула продолжает DL #10 из `vault-profile` у отправителя («плагин знает,
**когда** и **что** вызвать; vault знает **как**») и нашу границу «акт или состояние
репозитория» из `CLAUDE.md`:

| Вопрос | Владелец | Что у него |
|---|---|---|
| **Когда и что** — момент в сессии | `vdm-obsidian` | skill гигиены по симптомам, skill профиля, хук на правку заметки |
| **Как** — код проверки или раскатки | тот, вместе с чем код меняется | профиль — `executor/projects/vault-profile`, меняется с эталоном; гигиена — `vdm-obsidian/scripts`, ни от какого vault'а не зависит |
| **Где отстало** — состояние по парку | `vdx`; ось ведёт владелец кода | ось `editor-workspace`: измеритель — код возврата скрипта, remedy — его же `--apply` (O41) |

Код каждой проверки лежит в одном месте, а вызывающих несколько, и у каждого свой адрес:

| Кто зовёт | Когда | Как находит код |
|---|---|---|
| хук и skill плагина | в сессии | `${CLAUDE_PLUGIN_ROOT}` |
| skill профиля | в сессии | путь эталона из `obsidian-profile.reference` (`obsidian-profile-skill` DL #6) |
| `bootstrap.sh` vault'а | по требованию — человек или агент, неважно | `installPath` из `~/.claude/plugins/installed_plugins.json` (DL #4) |
| `vdx` | по парку, когда появится O41 | профиль — путь эталона; гигиена — тот же `installPath` |

**Что остаётся у executor:** эталон и пресеты профиля; свои соглашения — правило
№11, что именно пинить в Navigator, заметка `[[Obsidian]]` с хуком
`obsidian-config-drift.sh`; обёртка `to-agent.sh` и аудит доставки хуков; scope-конфиг
гигиены; разборы инцидентов. По строкам инвентаря — DL #6.

### Инвентарь

По заголовкам `CLAUDE.md` vault'а, не по номерам строк (DL #2). Сверено 2026-09-25:

| # | Правило | Где в `CLAUDE.md` vault'а сейчас | Куда |
|---|---|---|---|
| 1 | Упоминание не-md файла — `[[ссылкой]]`, не бэктиками | `## Вложения — упоминание файла обязано быть ссылкой` | skill + аудит |
| 2 | `==text==` ломает Dataview, бэктики не спасают | `### Highlight syntax ==text== ломает Dataview (даже в backticks)` | skill + аудит (Sidetrack #6) |
| 3 | Pipe в wikilink в ячейке таблицы — `[[X\|Y]]` | `### Pipe \| в wikilink внутри таблицы ломает таблицу` | skill + аудит |
| 4 | Свойства с дефисами в Bases — минус, молча 0 строк | `### Свойства с дефисами в Bases-выражениях` | skill |
| 5 | `base:query` ненадёжен | `### obsidian base:query — ненадёжен` | skill |
| 6 | `obsidian rename` вместо `mv` | `### obsidian rename — предпочитать для переименования` | skill |
| 7 | ALAC в `.m4a` — плеер есть, звука нет | `### ALAC в .m4a — плеер рисуется, звук молчит` | skill + `normalize-audio` |
| 8 | NFD на APFS против NFC в телах | абзац «ALWAYS `.normalize('NFC')`…» | skill + внутри аудитов |
| 9 | shortest path, `alwaysUpdateLinks: true` | `### Wikilinks` | уже в профиле, пресет `base` — вычеркнуто (DL #6) |
| 10 | пины Notebook Navigator через `data.json` | `### Pinning в Notebook Navigator` | skill — механика, условно при Navigator; что пинить — vault (DL #6) |
| 11 | никаких `index.base` | `### Никаких index.base` | остаётся в vault'е: соглашение раскладки (DL #6) |

**Харнес не менялся с отправки брифа** (DL #2): у пяти скриптов число строк совпадает с
брифом, коммитов после 2026-09-06 нет. Значит, у критерия №2 неподвижная база.

**Главный нерешённый вопрос — параметризация.** Корень зашит как
`resolve(__dirname,'..','..','..')`, список обхода (`SCAN`) — в коде. Хук
`orphan-attachment-check.sh` к тому же пропускает только `wiki/*|archive/*|raw/*|projects/*`.
Корень — как предлагает бриф: `--vault=` → env `executor` → вверх до `.obsidian/`.
Scope — не отдельный файл, как в брифе, а ключ `obsidian-hygiene` в `.claude/vdm-plugins.json`
самого vault'а (`enabled`, `exclude[]`, `docClassExclusions[]`). Папку вложений объявлять не
нужно: она уже есть в `.obsidian/app.json` → `attachmentFolderPath` (DL #5). Без исключений
обход executor в хуковый таймаут не влезает: там `_import/` (35k заметок),
`attachments/` (15k бинарников) и Chromium-профиль в `projects/page-snapshot/profiles/`
(~33k файлов).

**Граница «плагин или `vdx`»** (DL #3, DL #7): в `vdx` сейчас не уезжает ничего. Путь туда
у всего направления один — ось с remedy, — и ведёт его владелец профиля. Гигиена
встанет туда же, если её понадобится мерить по парку.

## Decision Log

### #1 / 2026-09-25 / Паркуем в `draft`, очередь — после obsidian-profile-skill

**Source:** both
**Basis:** user-stated
**Basis-detail:** рекомендация ассистента, дословно: «сначала довести profile-skill. Он
маленький, у него готовая фикстура для приёмки, и он создаёт скелет `vdm-obsidian`, куда
потом встанет гигиена. Hygiene-бриф при этом сразу поднять в кристалл через
`pickup --grow`». Ответ пользователя: «Поехали».
**Context:** оба брифа от `executor` стояли. Profile-skill — `dormant` с 2026-09-08,
ни одного шага реализации. Hygiene — `pending` в инбоксе с 2026-09-06. У profile-skill
последний блокер (его Sidetrack #6, гейты под два плагина) снялся сам 2026-09-22 вместе
с `vdm-comms` (`da4b69e`). Варианты: начать hygiene сразу; оставить бриф в инбоксе; припарковать.
**Why:** начать сразу — значит начать с главного нерешённого вопроса (параметризация
пяти скриптов) и с двух вопросов к отправителю, на которые ответа ещё нет. Оставить в
инбоксе хуже всего: для отправителя бриф, лежащий 19 дней, неотличим от непрочитанного.
Парковка отличает «прочитан и стоит в очереди» от «не прочитан», а profile-skill меньше,
проверяем целиком и создаёт дом, в который гигиена встанет.
**Implication:** статус из pre-work tier, singleton не трогаем, Tasks не заводим.
Начало работы — после первого коммита `plugins/vdm-obsidian/` (Next actions).

### #2 / 2026-09-25 / Инвентарь адресуем по заголовкам, а не по номерам строк

**Source:** assistant
**Basis:** observed
**Basis-detail:** перемерено в `/Volumes/Working/executor` 2026-09-25, всё
воспроизводится read-only командами (`wc -l`, `grep -n`,
`git log --since=2026-09-06T17:22 -- <file>`). Не скопировано: прозой счётчики и
номера передаются без потерь, а сам vault — чужой репозиторий. Результат:
`CLAUDE.md` — 879 строк против 846 в брифе. Якоря съехали: `==text==` 136→139,
`base:query` 111→114, `rename` 107→110, ALAC 174→177, NFC 326→349. `scripts/bootstrap.sh`
(358 строк) — ссылки брифа 126/222/245/269 по-прежнему указывают на
`audit-dataview-syntax`, `audit-dead-wikilinks`, `audit-orphan-attachments`,
`normalize-audio`. Скрипты — 390/262/530/116/206 строк, как в брифе, коммитов после
отправки нет. Хуки: `orphan-attachment-check.sh` задет только `c0535aa` (2026-09-11,
регистрация переехала в `.claude/settings.json`), `obsidian-config-drift.sh` не менялся.
**Context:** инвентарь брифа ссылается на правила номерами строк `CLAUDE.md`.
**Why:** `CLAUDE.md` vault'а — живой файл, за 19 дней +33 строки. Номера врут молча, а
заголовки нет. Код харнеса при этом не двигался, так что regression-гейт (критерий №2)
по-прежнему сравнивает с неподвижным образцом.
**Implication:** номера строк из брифа не использовать. Таблица правило → заголовок —
в «Текущей модели». Перед переносом — ещё раз сверить скрипты с этой базой (Next actions).

### #3 / 2026-09-25 / Всё содержимое брифа — акт; в `vdx` ничего не уезжает

**Source:** assistant
**Basis:** inferred
**Basis-detail:** выведено из чтения брифа против `CLAUDE.md` § «не всё, что мы
придумали, должно ехать отсюда». Не проверено: как хук плагина поведёт себя в vault'е —
плагина ещё нет.
**Context:** правило репозитория требует разобрать каждое улучшение до кода. В брифе
три рода вещей: правила, которые поднимаются по симптому в сессии; хук на правку
заметки (`--file=`); аудиты всего vault'а, которые зовёт `bootstrap.sh` самого vault'а.
**Why:** у первых двух есть момент — это акт. Третье похоже на «состояние
репозитория», но утверждение делает vault **о себе**, своим скриптом. Плагин поставляет
проверяющий код, а не утверждение. В `vdx` это уехало бы только в форме по парку
(«в каких моих vault'ах есть сироты»), а такого никто не просил. Требование
проволоченности — «`bootstrap.sh` зовёт плагин» — отправитель выполняет сам, в своём
кристалле. Если хуки будут включаться по наличию `.obsidian/` (Sidetrack #2), второго
шва нет вовсе.
**Implication:** брифа в `vdx` нет. Если появится запрос «по всем vault'ам» — это
постановка для `vdx`, отдельным брифом.

### #4 / 2026-09-25 / Вне сессии код находится через `installed_plugins.json`; кто запускает `bootstrap.sh` — неважно

**Source:** assistant
**Basis:** observed
**Basis-detail:** на этой машине 2026-09-25. `~/.claude/plugins/installed_plugins.json`
хранит у каждого плагина суиты `installPath` — например,
`…/cache/vodmal-claude-code-marketplace/vdm/2.35.2`. Клонов marketplace два:
`marketplaces/vodmal/` живой — на него указывает `known_marketplaces.json`, HEAD `08367d1`
от того же дня; `marketplaces/vodmal-claude-code-marketplace/` брошенный — HEAD `0de86dd`
от 2026-03-09, внутри vdm 2.1.0. `vdx` не установлен совсем: нет ни в PATH, ни в `npm -g`,
ни в shims mise. Не проверено: что `bin/` плагина недоступен в терминале пользователя —
это известно только из текста хука `git-guard`.
**Context:** Sidetrack #1 спрашивал, кто запускает `bootstrap.sh`: от этого зависело,
годится ли `bin/` плагина, который есть в PATH только у ассистента. На столе было: спросить
отправителя; `bin/`; неверсионированный клон marketplace — прецедент `vdm-git` 2.8.0 для
pre-commit (`suite.md` § «Две поверхности»); `installPath` из `installed_plugins.json`;
вызывать `vdx`.
**Why:** вопрос лучше растворить, чем задавать. Файл установок лежит на диске при любом
вызывающем, поэтому человек в терминале и агент получают один и тот же путь. Беда была не в
том, что путь версионирован, а в том, чтобы зашить его константой, — чтение в момент запуска
её снимает. Вдобавок вне сессии запускается та же установка, что харнесс грузит в сессию, а
клон marketplace может её опережать. Glob по `marketplaces/*` на этой машине неоднозначен: два
клона одного репозитория (Sidetrack #7). `bin/` отпадает — он только у ассистента; `vdx` —
его здесь нет.
**Implication:** Sidetrack #1 закрыт без письма. Критерий №4 — задокументированный резолвер на
десяток строк Node: найти запись `vdm-obsidian@…`, взять `installPath`, а если плагина нет —
громко упасть («гигиена не проверена: vdm-obsidian не установлен»), а не пропустить молча.

### #5 / 2026-09-25 / «Vault только включает» — включать нечего; конфиг только сужает

**Source:** assistant
**Basis:** observed
**Basis-detail:** все три плагина суиты стоят со `scope: user` (`installed_plugins.json`), а в
`.claude/settings.json` vault'а нет `enabledPlugins`. В `.obsidian/app.json` vault'а —
`"attachmentFolderPath": "attachments"`; у `~/Obsidian` это `_resources` (`vault-profile`
DL #9) — отсюда и `_resources/` в дефолтах брифа. В `.claude/vdm-plugins.json` vault'а уже
есть `crystal.capture-exclude`: `_import`, `attachments`, `raw`, `projects/*/data`,
`projects/*/profiles`; при этом хук гигиены vault'а проверяет `raw/*`. Что отправитель имел
в виду под «включает», не спрашивали.
**Context:** Sidetrack #2: как хук плагина станет активен в vault'е и где живёт его scope.
Бриф предлагал «vault только включает» и отдельный `.claude/obsidian-hygiene.json`.
**Why:** цель отправителя — в vault'е нет кода хука, только объявление — достигается без
выключателя. Хуки плагина харнесс регистрирует сам, а выключатель на стороне vault'а был бы
шагом установки: механизм, требующий установки, выпадает из формы суиты (`suite.md`
§ «Две поверхности»). Хук включается тем, что уже лежит на диске: над правленой заметкой
есть `.obsidian/`. Конфиг — не отдельный файл, а ключ `obsidian-hygiene` в
`.claude/vdm-plugins.json`, где суита держит настройки всех своих плагинов:
`enabled: false` выключает, `exclude[]` и `docClassExclusions[]` сужают. Папку вложений
объявлять не нужно — Obsidian уже объявил её сам в `app.json`. Список исключений свой, а не
`crystal.capture-exclude`: похож, но не тот же — `raw/` гигиене нужен, захвату кристалла нет.
**Implication:** Sidetrack #2 закрыт без письма. Нулевая конфигурация = есть `.obsidian/` и
`attachmentFolderPath` из `app.json`. В своей половине отправитель пишет ключ в
`vdm-plugins.json`, а не новый файл, — это войдёт в ответ `obsidian-hygiene-plugin-ready`.

### #6 / 2026-09-25 / Инвентарь сверен с профилем: №9 уже в пресете, №11 и хук дрейфа остаются в vault'е

**Source:** assistant
**Basis:** inferred
**Basis-detail:** наблюдено: `vault-profile/presets/base.json`, строки 15–17 —
`newLinkFormat: "shortest"`, `useMarkdownLinks: false`, `alwaysUpdateLinks: true`. Шапка
`obsidian-config-drift.sh` — по `git status -- .obsidian/` напомнить обновить заметку
`[[Obsidian]]` и `PROJECT_CHANGELOG` этого vault'а. `vault-profile` DL #8 — плагинные `data.json`
не переносятся, пины — состояние конкретного vault'а. Выведено, а не проверено: что №11
(«никаких `index.base`») — соглашение раскладки, а не свойство Obsidian. Отправитель считал
его generic.
**Context:** Sidetrack #4 (правила 9–11) и Sidetrack #5 (хук дрейфа конфига) спрашивали, что
из инвентаря на самом деле гигиена.
**Why:** №9 — настройки `app.json`, которые профиль уже раскатывает; перенос в skill дал бы
второе место для одного правила. №10 распадается надвое. **Как** пинить в Navigator
(`pinnedNotes`, `folder: true`) — знание о плагине, верное в любом vault'е, где он стоит.
**Что** пинить — состояние vault'а. Первое едет в skill условно, как №2 при Dataview. №11
описывает, чем именно этот vault закрывает навигацию (Navigator, теги, `audit.base`), — это
выбор раскладки, а не поломка Obsidian. `obsidian-config-drift.sh` обслуживает соглашение
одного vault'а, а дрейф эталона против пресетов у них уже ловит `reference-drift.mjs` в
`bootstrap.sh`.
**Implication:** в skill гигиены едут правила 1–8 и механика №10; №9 вычеркнуто; №11 и хук
дрейфа отправитель оставляет у себя. Это предложение, а не приговор: оно войдёт в ответ
отправителю, и тот может возразить.

### #7 / 2026-09-25 / Путь в `vdx` у Obsidian-направления один, и ведёт его владелец профиля

**Source:** both
**Basis:** observed
**Basis-detail:** пользователь, дословно: «Кстати там еще заход через VDX есть в эту тему.
Надо все состыковать в стройную понятную картинку». У отправителя прочитан
`projects/vault-profile/tasks/vault-profile/workitem.md`: DL #1 (vdx применяет,
недостаёт remedy при находке — O41), DL #2 (связка через исполняемый remedy, рубрика
остаётся декларативной) и открытый Next action «Вернуться в vdx: ось `editor-workspace`
(`applies_when: has_file .obsidian`) + контракт исполняемого remedy». В `vdx` прочитаны
`docs/decisions.md` — O41 открыт, триггер «после ≥1 итерации O40» — и
`docs/tasks/vdm-gates-wiring-axis/workitem.md`: O40 сдвинулся, «два shape»,
`vdx-environment.yaml`. Не проверено: возьмёт ли `vdx` такую ось — его пока никто не
спрашивал.
**Context:** один путь лежал кусками в трёх местах: наш DL #3 («в vdx ничего не уезжает»),
`obsidian-profile-skill` DL #3 с Next action «отправить постановку в vdx» и план
отправителя по оси `editor-workspace`. Это два обязательства про один бриф в двух
репозиториях.
**Why:** ось и remedy пишет тот, у кого код измерителя и `--apply`. Для профиля это
отправитель, и план у него уже есть, так что наш бриф в `vdx` его продублировал бы. Гигиена
встаёт в ту же форму без нового механизма: у трёх аудитов и `normalize-audio` уже есть
безопасный `--apply`. Но мерить гигиену по парку никто не просил, поэтому для неё это место
в схеме, а не работа.
**Implication:** DL #3 в силе: сейчас в `vdx` не уезжает ничего. Своих брифов в `vdx` мы не
шлём (`obsidian-profile-skill` DL #8). Если понадобится гигиена по всем vault'ам — ось с
remedy по тому же образцу, адрес кода — DL #4.
**Cross:** `obsidian-profile-skill` DL #8

## Sidetracks

### #1. Как `bootstrap.sh` найдёт скрипты плагина (критерий №4)

**Возникло в:** сверка критериев брифа с vault'ом, 2026-09-25.
**Описание:** установка лежит в версионированном каталоге кэша и меняется с каждым
апдейтом, зашить путь нельзя. Наблюдено: `bootstrap.sh` не зовёт ни один хук. SessionStart
vault'а — только `hook-delivery-check.sh`, а сам скрипт запускают руками
(`./scripts/bootstrap.sh`, `CLAUDE.md` § Vault bootstrap & maintenance). Кто именно —
агент через Bash или человек в терминале — из файлов не видно. От этого зависит, годится
ли `bin/` плагина: он в PATH только у оболочки ассистента (со слов хука `git-guard` этой
суиты; в терминале пользователя не проверялось). Env харнеса есть только внутри хуков.
Остаётся поиск активной версии через `installed_plugins.json` или обёртка, которую vault
кладёт себе сам. Та же проблема — Sidetrack #1 в кристалле отправителя.

**Status:** resolved 2026-09-25 — DL #4: `installPath` из `installed_plugins.json` одинаков для
человека и агента, спрашивать отправителя не нужно.

### #2. «Vault их только включает» — включать нечем, и, похоже, не нужно (критерий №3)

**Возникло в:** то же.
**Описание:** наблюдено: в `.claude/settings.json` vault'а нет `enabledPlugins`, а в
`~/.claude/plugins/installed_plugins.json` все три плагина суиты стоят со `scope: user`.
Значит, хук `vdm-obsidian`, поставленный так же, будет срабатывать **во всех** проектах,
не только в vault'ах. Любое «включение» на стороне vault'а — шаг установки, то
есть ровно тот анти-паттерн, на котором уже провалился pre-commit-бэкап
(`docs/llm/soft-guidance-vs-deterministic-gates.md`). Предложение (не решение): хук сам
проверяет, есть ли `.obsidian/` выше правленого файла, и молчит, если нет. Конфиг vault'а
только сужает область, а не включает. Что имел в виду отправитель — спросить.

**Status:** resolved 2026-09-25 — DL #5: включать нечего; конфиг — ключ `obsidian-hygiene` в
`.claude/vdm-plugins.json`, папка вложений — из `app.json`. Спрашивать не стали: цель отправителя
решение покрывает.

### #3. Уехавший хук теряет `to-agent.sh` и выпадает из аудита доставки vault'а

**Возникло в:** чтение `.claude/settings.json` и `.claude/hooks/to-agent.sh` vault'а.
**Описание:** наблюдено: `orphan-attachment-check.sh` зарегистрирован как
`to-agent.sh orphan-attachment-check.sh`. Обёртка превращает вывод в JSON
`additionalContext` — иначе PostToolUse-хук с exit 0 до агента не доходит, vault разобрал
это 2026-09-11 — и гасит повтор блока в пределах сессии. В плагин обёртка не едет:
хук плагина обязан сам говорить JSON-ом, а гашение повторов либо переносится, либо
сознательно теряется. Второе: `audit-hook-delivery.mjs` vault'а читает только
`.claude/settings.json` и `settings.local.json`, так что хук, уехавший в плагин, выпадет из
его поля зрения. Инвариант «немых хуков нет» vault'а перестанет его видеть.

**Status:** open

### #4. Правила 9–11 — настройки vault'а, а не поведение ассистента

**Возникло в:** `obsidian-profile-skill` Sidetrack #3 (2026-09-08), перенесено сюда 2026-09-25
— проверка по нему принадлежит разбору этого брифа.
**Описание:** №9 (`newLinkFormat: "shortest"`, `alwaysUpdateLinks: true` в `app.json`) —
настройка, которую раскатывает `apply.mjs` из vault-profile. Проверить, не покрыта ли она
уже пресетом `base`/`kb`; если покрыта — из инвентаря вычёркиваем, а не переносим. Если не
покрыта — это пожелание к пресетам vault-profile у отправителя, а не работа
`obsidian-profile-skill`: тот зовёт чужой инструмент и пресетов не держит (его DL #2). №10
(пины Notebook Navigator в `data.json`) в профиль не укладывается: `apply.mjs` намеренно не
переносит плагинные `data.json`, так что это остаётся правилом. №11 («никаких
`index.base`») звучит как соглашение раскладки конкретного vault'а, а не свойство
Obsidian — проверить, generic ли оно вообще.

**Status:** resolved 2026-09-25 — DL #6: №9 уже в пресете `base`, механика №10 — в skill условно,
№11 остаётся в vault'е.

### #5. `obsidian-config-drift.sh` — не гигиена

**Возникло в:** чтение шапки хука, 2026-09-25.
**Описание:** наблюдено по шапке: UserPromptSubmit-хук сравнивает `git status -- .obsidian/`
со снимком в `.claude/state/obsidian-drift.last` и напоминает обновить заметку
`[[Obsidian]]` и `PROJECT_CHANGELOG` **этого** vault'а. Он требует git, хранит состояние
и обслуживает соглашение одного vault'а. В гигиену не укладывается; скорее остаётся в
vault'е или относится к профилю. Решить при переносе, а не переносить по инерции списка.

**Status:** resolved 2026-09-25 — DL #6: остаётся в vault'е; дрейф эталона у них ловит
`reference-drift.mjs`.

### #6. Сторонний `obsidian:obsidian-markdown` учит `==text==` без оговорки про Dataview

**Возникло в:** проверка, не покрыты ли правила уже скиллами kepano, 2026-09-25.
**Описание:** наблюдено в `obsidian-skills` 1.0.1 (кэш установки): `obsidian-cli` ничего не
говорит ни про `rename`, ни про `base:query`; `obsidian-bases` молчит про дефисы в
свойствах. Значит, правила 4–6 не дублируют стороннее, и переносить их есть смысл.
Зато `obsidian-markdown` (строка 118) подаёт `==Highlighted text==` как обычный синтаксис
без оговорок. При загруженных обоих скиллах агент получит противоположные указания.
Правило №2 надо формулировать **условно** — «если в vault'е стоит Dataview» (в
executor стоит: `"dataview"` в `.obsidian/community-plugins.json`), — иначе оно будет
спорить с kepano и там, где Dataview нет.

**Status:** open

### #7. Два клона одного marketplace: glob из сниппета `vdm-git` попадает в живой по алфавиту

**Возникло в:** проверка адреса вне сессии для DL #4, 2026-09-25.
**Описание:** наблюдено: в `~/.claude/plugins/marketplaces/` лежат два клона
`VoDmAl/ai-dev-plugins`. Живой — `vodmal/`, на него указывает `known_marketplaces.json`.
Брошенный — `vodmal-claude-code-marketplace/`, HEAD от 2026-03-09, внутри vdm 2.1.0.
Сниппеты pre-commit-бэкапа в `vdm-git` (`skills/guard/SKILL.md`, строки 431–432 и 525–526)
берут первое совпадение `marketplaces/*/plugins/vdm-git/scripts/…`. Здесь живой клон
оказывается первым по алфавиту — это везение с именами, а не гарантия. На машине, где
брошенный клон окажется раньше, сниппет молча запустит старую копию. Починка — брать
`installLocation` из `known_marketplaces.json` или падать при двух совпадениях. Резолвер
гигиены (DL #4) этой ловушки не имеет: он читает `installPath`. Брошенный клон — кандидат на
удаление, но это машина пользователя, решать ему.

**Status:** resolved 2026-09-25 — пользователь: «и чинить и удалять». `vdm-git` 2.15.2: резолвер
`vdm_git_gate` берёт клон из `known_marketplaces.json`, glob — только без реестра и без угадывания
между двумя копиями; `tests/githook-snippets.test.sh` (gate 9) красный на прежнем тексте. Брошенный
клон перенесён в Корзину — всё его содержимое есть в истории репозитория. Старый сниппет остался в
`command-center/.git/hooks/pre-commit`; с одним клоном на машине он снова однозначен.

## Next actions

Блокирующий хвост. Начало — после того, как `obsidian-profile-skill` закоммитит
`plugins/vdm-obsidian/` (DL #1).

- [x] ~~Спросить `executor` про Sidetrack #1 и Sidetrack #2~~ — cancelled: решено на
      нашей стороне, DL #4 и DL #5.
- [x] Разобрать Sidetrack #4 и Sidetrack #5 до того, как инвентарь станет кодом — DL #6.
- [x] Sidetrack #7: резолвер в `vdm-git` починен (2.15.2), брошенный клон marketplace убран.
- [ ] Спроектировать резолв корня и конфиг: `--vault=` → `executor` → вверх до
      `.obsidian/`; ключ `obsidian-hygiene` в `.claude/vdm-plugins.json`; вложения — из
      `app.json` (DL #5).
- [ ] Перед переносом — снова сверить пять скриптов с базой DL #2 (строки, коммиты).
- [ ] Перенести пять скриптов с параметризацией; предикат бэктиков — с исключениями
      (см. «Назначение → Ограничения»).
- [ ] Хук правки заметки (Sidetrack #3): режим `--file=`, самоактивация по `.obsidian/`
      (DL #5), доставка JSON-ом.
- [ ] Skill гигиены (Sidetrack #6): `description` ловит симптомы на RU и EN; знание — правила
      1–8 и механика №10, причём №2 и №10 условны (DL #6).
- [ ] Приёмка 1: пустой тестовый vault без конфига.
- [ ] Приёмка 2: executor с конфигом — diff = 0 с локальными копиями по всем пяти.
- [ ] Приёмка 3: хуки приходят из плагина; в vault'е кода хука нет.
- [ ] Приёмка 4: резолвер `installPath` для `bootstrap.sh` задокументирован и без плагина
      падает громко (DL #4).
- [ ] Версии: `plugin.json` ↔ `.claude-plugin/marketplace.json` + строка в
      `PROJECT_CHANGELOG.md` (Critical Rule #1).
- [ ] Ответить `executor`: `intercom send executor obsidian-hygiene-plugin-ready`
      с `--reply-to obsidian-hygiene-plugin`, приложив карту: где конфиг, как адресовать
      скрипты, что остаётся у них (DL #4, DL #5, DL #6).

## References

- `references/intercom-brief-executor.md` — входящий бриф, байт в байт, конверт
  сохранён. Оригинал после `pickup` — `~/.claude/vdm/intercom/ai-dev-plugins/_done/`.
- Кристалл-приёмник у отправителя:
  `/Volumes/Working/executor/projects/vault-maintenance/tasks/obsidian-hygiene-extraction/workitem.md`.
- Профиль у отправителя: `/Volumes/Working/executor/projects/vault-profile/` —
  `tasks/vault-profile/workitem.md` (DL #1–#2 — путь в `vdx`, DL #8 и #14 — `data.json`, DL #10 —
  «когда/что против как»), `presets/base.json`.
- `vdx`: `/Users/vdm/AI Projects/vdx` — `docs/decisions.md` (O40, O41),
  `docs/tasks/vdm-gates-wiring-axis/workitem.md` (гейт, требующий установки; «цепочка резолвится»).
- Установки харнеса: `~/.claude/plugins/installed_plugins.json` (`installPath`),
  `~/.claude/plugins/known_marketplaces.json` (`installLocation`), `~/.claude/plugins/marketplaces/`.
- Прецедент адреса вне сессии: `plugins/vdm-git/skills/guard/SKILL.md` § Crystal pre-commit backup;
  `docs/model/suite.md` § «Две поверхности, намеренно продублированные».
- Харнес в vault'е: `projects/vault-maintenance/scripts/audit-{orphan-attachments,dataview-syntax,dead-wikilinks}.mjs`,
  `projects/vault-utils/scripts/{list-bases,normalize-audio}.mjs`,
  `.claude/hooks/{orphan-attachment-check,obsidian-config-drift,to-agent}.sh`,
  `.claude/settings.json`, `scripts/bootstrap.sh`,
  `projects/vault-maintenance/scripts/audit-hook-delivery.mjs`.
- Сосед по плагину: [[obsidian-profile-skill/workitem|obsidian-profile-skill]] — DL #7 (плагин и имя),
  Sidetrack #3 (перенесён сюда как #4).
- Граница «плагин или `vdx`»: `CLAUDE.md` § «не всё, что мы придумали, должно ехать
  отсюда»; анти-паттерн установки — `docs/llm/soft-guidance-vs-deterministic-gates.md`.
- Сторонние скиллы Obsidian: `obsidian-skills` 1.0.1 (kepano), кэш установки плагинов.
