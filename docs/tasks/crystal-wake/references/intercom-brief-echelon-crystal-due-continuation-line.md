---
intercom: v1
from: echelon
from_agent: ""
to: ai-dev-plugins
to_input: "vdm"
created: 2026-09-25T22:08:10Z
slug: crystal-due-continuation-line
status: pending
---

> 📤 **FROM:** `echelon`
> 📥 **TO:** `ai-dev-plugins`
> **Action:** review → `/vdm:intercom pickup crystal-due-continuation-line` (archive to `_done/`) — or `pickup crystal-due-continuation-line --grow` to promote into a workitem, then implement + commit **there**.

# Срок (due:) на строке-продолжении невидим: не считается ни просроченным, ни сломанным

## Что наблюдали — vdm 2.35.0, echelon, 25.09

В `docs/tasks/echelon-v1/workitem.md` пункт выглядел так (сокращено):

```markdown
- [ ] п. 4, command-center. При заходе видна очередь встреч: … Подтверждения command-center после перезапуска 25.09 (…):
  - `git status` чист;
  - …

  Первую настоящую дельту SSO/Beta command-center подтвердит после следующего сбора. Сам не проверяю — решение владельца 25.09 (due: 2026-09-28)
```

Проверки на этом файле:
- `list_overdue <файл> 2026-09-29` — пусто;
- `list_overdue <файл> 2026-10-03` — только другой пункт, со сроком 02.10;
- `audit_malformed_due <файл>` — пусто;
- `crystal-lint.sh` — `ok`.

Срок написан правильно, но стоит не на строке `- [ ]`. Поэтому детектор не считает его просроченным и не называет сломанным. Проверка молча сузила свою область, и заметить это было нечем. Ровно об этом ваш раздел «Сломанный срок — нарушение, отсутствующий — нет». Такой пункт с момента записи не мог всплыть ни разу.

## Что предлагаю — выбор за вами

- либо засчитывать срок из блока-продолжения пункта — строк с отступом до следующего пункта;
- либо называть правильно написанный `(due:)` вне строки чекбокса сломанным: «срок не на строке чекбокса — детектор его не видит». Тогда его покажут `crystal-cave` и `crystal-lint`.

Как обошли у себя: срок перенесён на строку чекбокса.

Связано: `crystal-paused-wake` — второе письмо echelon от 25.09.
