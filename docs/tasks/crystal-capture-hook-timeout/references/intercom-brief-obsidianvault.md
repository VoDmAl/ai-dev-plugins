---
intercom: v1
from: obsidianvault
from_agent: "ObsidianVault"
to: ai-dev-plugins
to_input: "vdm"
created: 2026-09-04T22:24:05Z
slug: crystal-capture-hook-timeout
status: pending
---

> 📤 **FROM:** `obsidianvault` (ObsidianVault)
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup crystal-capture-hook-timeout` (archive to `_done/`) — or `pickup crystal-capture-hook-timeout --grow` to promote into a workitem, then implement + commit **there**.

# crystal-capture-reminder: 10.7 с на холодном старте при лимите 15 с; троттл не держит без срабатывания

**Что сделать**

- [ ] `crystal-capture-reminder.sh`: взводить троттл после каждого **скана**, а не только при срабатывании. Сейчас `_vdm_reminder_throttle_touch` стоит после `[ "$fire" = "yes" ]`, и в тихом случае (ничего новее workitem'ов) полный скан идёт на каждый prompt — то есть дороже всего именно тогда, когда сказать нечего.
- [ ] Один `find` вместо N: `-newer` по **самому старому** активному workitem'у даёт тот же ответ, что цикл по всем пяти.
- [ ] `filter_status`: один проход `awk` по всем кандидатам (`FNR==1` сбрасывает состояние) вместо `awk` на файл. 51 кандидат → 51 процесса; это главная статья расходов, и от размера репо она не зависит.
- [ ] По умолчанию не спускаться в gitignored-каталоги проекта, или хотя бы задокументировать, что `crystal.capture-exclude` принимает glob'ы `find -path` (`projects/*/data` работает, но об этом нигде не сказано).
- [ ] `hooks.json`: `timeout` 15 → 30 как страховка, после правок выше можно вернуть.
- [ ] SessionStart identity-check: когда identity выведена из basename (нет remote), печатать готовую команду `register --name "<Basename>" --describe "<первая строка README>"`, а не только инструкцию «выведи имя сам». См. § Регистрация ниже.
- [ ] `whoami`: в строке «address you as» identity печатается дважды, если имя после folding совпадает с ней (`obsidianvault, obsidianvault, obsidian vault`).

**Симптом.** В `obsidianvault` (Obsidian-хранилище, ~80 000 файлов вне `_import/attachments/raw`, 5 активных кристаллов) на каждом prompt'е: `UserPromptSubmit hook timed out after 15s — output discarded`.

**Замер 2026-09-04** (все UserPromptSubmit-хуки из `installed_plugins.json`, stdin с payload, два прогона подряд):

| хук | лимит | холодный | тёплый |
|---|---|---|---|
| vdm `crystal-capture-reminder.sh` | 15 с | **10.7 с** | 1.5 с |
| vdm `docs-sync-reminder.sh` | 5 с | 1.0 с | 0.2 с |
| vdm остальные пять | 5 с | ≤ 0.4 с | ≤ 0.2 с |
| reflexio `user-prompt` | 15 с | 0.9 с | 0.8 с |

Это при уже настроенном `crystal.capture-exclude: ["_import","attachments","raw"]`. На занятой машине (в тот день системный диск на 100%, рядом качался Chromium) холодные 10.7 с уходят за 15.

**Куда уходит время** (фазы хука по отдельности, с prune'ами):

| фаза | холодная | тёплая |
|---|---|---|
| resolve roots | 0.07 с | 0.04 с |
| `find_workitems` (51 кандидат) | 0.39 с | 0.29 с |
| `filter_status` по 51 файлу | **5.56 с** | 1.88 с |
| 5 × `find -newer` (по числу активных кристаллов) | 1.88 с | 0.53 с |

`filter_status`: `_apply_status_alias` кэширован правильно (51 вызов = 0.12 с), дорог `extract_frontmatter_field` — отдельный `awk` и холодное чтение на каждый файл, ~35 мс тёплый и ~110 мс холодный на кандидата.

`find`: с исходными prune'ами обход — 80 569 файлов, ~1.8 с тёплый, и он повторяется по каждому активному workitem'у. Из этих файлов 33 068 лежали в `projects/page-snapshot/profiles/` (профиль Chromium) и 10 642 в `projects/receipt-pipeline/data/` — оба каталога в `.gitignore`, но хук об этом не знает. У себя добавил в `capture-exclude` glob'ы `projects/*/data` и `projects/*/profiles`: обход 80 569 → 62 777 файлов, хук целиком 10.7 → 5.4 с холодный, 2.2 с тёплый. Половину дороги закрывает конфиг, вторую половину только код.

**Под нагрузкой.** Тот же замер через 17 минут после перезагрузки машины (load average 101 / 58 / 42: Spotlight, restic, пост-бутовый шторм), с расширенным `capture-exclude`:

| фаза | прогон 1 | прогон 2 |
|---|---|---|
| `find_workitems` | 1.26 с | 1.05 с |
| `filter_status` по 51 файлу | **15.30 с** | **9.92 с** |
| один полный `find` (25 641 файл) | 2.04 с | 0.83 с |

Хук целиком: 15.4 с и 9.1 с. Обход файлов от нагрузки почти не зависит, а 51 запуск `awk` масштабируется с load average почти линейно: именно эта фаза одна выходит за лимит. Значит, конфигом на стороне проекта проблему не закрыть — нужен один проход `awk` по всем кандидатам.

**Регистрация в реестре — что произошло.** Identity-check при старте сессии сказал: «регистрация неполная, выведи имена из README / имени папки / того, как пользователь называет проект, если не уверен — спроси один раз, и сделай это до другой работы». Агент (я) получил бриф на четыре чекбокса, счёл уведомление второстепенным, отложил его в конец сессии и там спросил пользователя вместо того, чтобы взять `ObsidianVault` из имени папки. Пользователь: «Странно, что он тебе не предложил дефолт по названию папки». Половина вины на агенте: инструкция была исполнима. Вторая половина в дизайне: имя папки не считается именем даже там, где оно и есть имя, а при identity из basename оно не попадает и в aliases (`aliases: (none)`), потому что его съела identity. Уведомление с готовой строкой команды агент выполнил бы, не задумываясь; уведомление «выведи сам, если уверен» — ровно то место, где агент хеджирует.

**Проверка.** Из корня `obsidianvault`: `echo '{"session_id":"x","cwd":"'$PWD'","prompt":"p"}' | time bash <plugin>/scripts/crystal-capture-reminder.sh` дважды подряд. Цель: холодный < 3 с при исходном `capture-exclude` из трёх строк; второй прогон в окне троттла ≈ 0 с независимо от того, сработал первый или нет.

**Ссылки.** `PROJECT_CHANGELOG.md` в obsidianvault, запись 2026-09-04 «crystal-capture hook»; конфиг `.claude/vdm-plugins.json` там же. Правки — в dev-репо `cc-vdm-plugins`, не в marketplace-клоне.
