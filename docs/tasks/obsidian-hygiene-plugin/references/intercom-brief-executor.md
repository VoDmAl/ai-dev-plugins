---
intercom: v1
from: executor
from_agent: ""
to: ai-dev-plugins
to_input: "ai-dev-plugins"
created: 2026-09-06T17:22:32Z
slug: obsidian-hygiene-plugin
status: pending
---

> 📤 **FROM:** `executor`
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup obsidian-hygiene-plugin` (archive to `_done/`) — or `pickup obsidian-hygiene-plugin --grow` to promote into a workitem, then implement + commit **there**.

# ТЗ: вынести Obsidian-гигиену из executor в отдельный vdm-плагин (правила + харнес проверок)

## Что сделать

Завести в `cc-vdm-plugins` новый плагин — рабочее имя **`vdm-obsidian`** — который забирает из executor два слоя сразу:

1. **Знание** — правила работы с Obsidian, которые сейчас лежат в `CLAUDE.md` этого vault'а и не имеют к нему никакого отношения (они про Obsidian вообще).
2. **Харнес** — скрипты, которые эти правила проверяют, и хуки, которые дёргают их на редактирование заметки.

⚠️ Имя `obsidian:` **занято** — это сторонний плагин kepano/obsidian-skills (`obsidian-cli`, `obsidian-markdown`, `obsidian-bases`, `json-canvas`, `defuddle`), стоит из marketplace `obsidian-skills`. Наш префикс должен быть другим, иначе скиллы перекроются. Мы наш плагин не заменяем — он про редактирование, наш про гигиену и проверки.

## Зачем

`CLAUDE.md` executor = **846 строк**, грузится в каждый turn. Порядка **150** из них — не про этот vault: как молча ломается Dataview, почему `base:query` врёт, чем опасны бэктики вокруг имени файла, почему `.m4a` рисует плеер и молчит. Это знание переиспользуемо в **любом** vault'е, а живёт в одном — и платит за это attention-налогом на каждом ходу.

Плюс каждое из этих правил уже оплачено инцидентом. Они не «best practices», а следы того, что реально ломалось.

---

## Инвентарь — что переезжает

### Правила (все проверены как generic, ссылки — на строки `CLAUDE.md` в executor)

| # | Правило | Строки | Симптом, по которому его ищут |
|---|---|---|---|
| 1 | Упоминание не-md файла обязано быть `[[ссылкой]]`, не бэктиками | 216–229 | вложение исчезло / плагин счёл сиротой |
| 2 | `==text==` ломает Dataview inline-field парсер — **backticks не спасают** | 136–155 | `Dataview (inline field '=X=='): Error: PARSING FAILED` |
| 3 | Pipe в wikilink внутри ячейки таблицы рвёт таблицу, нужен `[[X\|Y]]` | 156–173 | таблица разъехалась в reading view |
| 4 | Свойства с дефисами в Bases-выражениях парсятся как минус → **молча 0 строк** | 115–135 | `.base` пустой, ошибки нет |
| 5 | `base:query` ненадёжен — верифицировать глазами в GUI | 111–114 | пустой вывод без error |
| 6 | `obsidian rename` вместо `mv` — обновляет wikilinks, держит creation date, async 2–3 с | 107–110 | после переименования битые ссылки |
| 7 | ALAC в `.m4a` — плеер рисуется, показывает `0:00 / 0:00`, звук молчит | 174–195 | «embed выглядит рабочим, но не играет» |
| 8 | macOS APFS хранит имена в NFD, Obsidian пишет тела в NFC — сравнивать только через `.normalize('NFC')` | 326 | `Map.get(stem)` промахивается на видимо-идентичных строках |
| 9 | Wikilinks — shortest path, `alwaysUpdateLinks: true` | 833–839 | — |
| 10 | Pinning в Notebook Navigator через `data.json` (`folder: true`) | 784–787 | — |
| 11 | Никаких `index.base` — навигацию закрывают Navigator + теги + `audit.base` | 764–767 | — |

**Не переезжает** (vault-specific, остаётся здесь): prefix-match после провала exact basename (строка 328) — это про нашу convention именования `<canonical> <distinguisher>`, в чужом vault'е её нет.

### Харнес

| Скрипт | Строк | Что делает |
|---|---|---|
| `projects/vault-maintenance/scripts/audit-orphan-attachments.mjs` | 390 | сироты в `attachments/` + бэктик-упоминания; `--apply` / `--strict` / `--file=` / `--list-orphans` / `--ext=` / `--json` |
| `projects/vault-maintenance/scripts/audit-dataview-syntax.mjs` | 262 | `==text==`, `PIPE-TABLE`, плюс mixed Latin/Cyrillic IME-опечатки |
| `projects/vault-maintenance/scripts/audit-dead-wikilinks.mjs` | 530 | мёртвые `[[…]]`, NFC-normalize, `--apply` / `--strict` |
| `projects/vault-utils/scripts/list-bases.mjs` | 116 | реестр всех `.base` в vault'е с условиями фильтрации |
| `projects/vault-utils/scripts/normalize-audio.mjs` | 206 | ALAC → FLAC; **сверяет md5 декодированного PCM** и отказывается трогать файл при расхождении |
| `.claude/hooks/orphan-attachment-check.sh` | 51 | PostToolUse на `wiki/*\|archive/*\|raw/*\|projects/*`, режим `--file=` |
| `.claude/hooks/obsidian-config-drift.sh` | 117 | детект правок `.obsidian/**` |

Всё это MIT-совместимо по происхождению (наш код), забирать можно целиком.

---

## Главный блокер — параметризация

Все скрипты сейчас захардкожены под этот vault:

```js
const VAULT_ROOT = resolve(__dirname, '..', '..', '..')   // «я лежу в projects/X/scripts/»
const SCAN = ['wiki/entities/things', 'wiki/entities/toys', 'wiki/entities/tools', ...]
```

В плагине так нельзя. Нужно:

- **vault root**: `--vault=<path>` → env `executor` → подъём вверх до ближайшей папки с `.obsidian/`. Последнее — самый честный дефолт.
- **scope**: конфиг **в самом vault'е**, не в плагине. Предлагаю `.claude/obsidian-hygiene.json`: `scan[]`, `exclude[]`, `attachmentsDir`, `docClassExclusions`.
- **нулевая конфигурация обязана работать**: по умолчанию — все `.md`, кроме `.obsidian/`, `.git/`, `node_modules/`, `_resources/`.

Про `exclude` отдельно, это не косметика: у нас `_import/` — 35k заметок, `attachments/` — 15k бинарников, `projects/page-snapshot/profiles/` — ~33k файлов Chromium-профиля. Без исключений обход не укладывается ни в какой хуковый таймаут (у нас уже был инцидент с 15-секундным timeout'ом на crystal-хуке, лечился ровно этим).

Ещё одна тонкость из опыта: **предикат «бэктик-имя файла» в лоб даёт почти одни ложные срабатывания.** Первая версия аудита выдала 40 находок, все проверенные — ложные (entity embed'ит фото и тут же называет его в прозе; `_about.md` цитирует схему именования). Рабочий предикат — «названо бэктиками **И** не слинковано в этой же заметке», плюс исключение doc-классов. Это не деталь реализации, это суть проверки — если перенести наивно, проверка станет бесполезной.

---

## Что остаётся в vault'е

- какие папки сканировать и исключать — **конфиг, не код**;
- `attachments/` плоский + convention уникальных имён;
- какие плагины реально стоят в этом vault'е;
- разборы инцидентов (`docs/llm/*`, `PROJECT_CHANGELOG.md`) — плагину хватит одной строки «почему», полная история наша.

## Контракт на то, что останется в CLAUDE.md

После переезда — **не больше ~12 строк**: таблица «правило → чем проверяется» плюс указатель на скилл.

Правило pruning у нас жёсткое (CLAUDE.md § Pruning rule): когда destination впитывает раздел, удаление из CLAUDE.md происходит **в том же коммите**. Иначе duplication и drift.

Но удаление законно только если скилл **надёжно auto-triggers**. Поэтому `description` скилла должен ловить не слово «Obsidian», а **симптомы**: «Dataview parse error», «таблица разъехалась в reading view», «base отдаёт 0 строк без ошибки», «плеер показывает 0:00», «после переименования битые ссылки», «вложение пропало». Агент, который влетел в проблему, не знает, что это «Obsidian-гигиена» — он знает, что у него сломалось.

Если триггер получится ненадёжным — оставим в CLAUDE.md однострочный pointer, но это заметно хуже: сегодня правило срабатывает без всякого поиска, просто потому что лежит в контексте.

---

## Критерии приёмки

1. Скрипты работают на **чужом** vault'е без конфига — проверить на пустом тестовом.
2. Скрипты работают на executor с конфигом и дают **тот же вывод**, что нынешние локальные копии (diff = 0). Это regression-гейт, а не формальность: `scripts/bootstrap.sh` зовёт их как инварианты (строки 126, 222, 245, 269), и молча изменившийся предикат мы заметим не сразу.
3. Хуки поставляются плагином; vault их только включает.
4. Документировано, как `bootstrap.sh` executor должен звать скрипты плагина вместо локальных копий (пути внутри cache-install версионированы — нужен стабильный способ адресации).
5. Имя плагина/скиллов не коллидирует с `obsidian:` от kepano.

## Обратная связь

Когда приедет — напиши сюда: `intercom send executor obsidian-hygiene-plugin-ready`.

На моей стороне заведён **dormant**-кристалл `vault-maintenance/obsidian-hygiene-extraction` — приём работы: подрезка CLAUDE.md, удаление локальных копий скриптов, переключение `bootstrap.sh`, запись в PROJECT_CHANGELOG. Он ждёт этого сигнала и не двигается до него.
