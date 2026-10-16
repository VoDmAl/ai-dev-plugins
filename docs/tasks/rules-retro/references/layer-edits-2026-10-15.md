---
reference-for: "[[rules-retro/workitem|rules-retro]]"
observed: 2026-10-15
---

# Правки слоя по первой ретроспективе

Три правки `~/.claude/vdm/rules.md` по полному проходу 2026-10-15 (DL #6). Строки таблиц и `Origin` к ним уже в
файле: в слой они не входят и места не занимают. Ждут установки vdm 2.50.0 только первые абзацы и новое правило.
Слой, который сессия получает, складывается из заголовка и первого абзаца каждого правила. Хук 2.48 держит
1 200 байт под строку о невлезшем всегда, поэтому с этими абзацами он отрезал бы три правила с конца (DL #5).

Проверено 2026-10-15 на хуке из рабочей копии (`shared-rules.sh` с починкой запаса): с тремя правками слой —
16 правил, все целиком.

## 1. «A move that lands with the user arrives prepared» — в конец первого абзаца

```
A move your own tools or a neighbouring agent can make is not the
user's at all: make it, or brief that agent.
```

Основание: 41 поправка в 9 проектах — владельца просили достать, проверить или передать то, что мог инструмент
ассистента или другой агент.

## 2. «A fact about the outside world needs a source you can name» — первая фраза первого абзаца

Было:

```
State an outside system's state, a rule, a decision, someone's plan or a name
only from a source you can point to: a document, a message on file, the user's
words, the live system. Ask "how do I know this?"
```

Стало:

```
State or act on how something stands — a system, a document, a reply, a rule,
a decision, someone's plan, a name — only from a source you can point to, read
as it is now: the document, the message on file, the user's words, the live
system. Ask "how do I know this?" before the sentence and before the step.
```

Основание: 165 поправок в 13 проектах — шаг без чтения того, что под рукой: ответа, документа, файла, живого
состояния. 52 отнесены к этому правилу, из них 15 — в сессиях, где правило было.

## 3. Новое правило — после первого

```
## A defect you notice has an owner: name it and hand it over

When something misbehaves — your tool, a skill, another agent's output, a
scheduled run — say whose it is and hand it over in the same turn: a brief to
that owner with the facts and the systemic fix you see, or the fix itself when
it is yours. A silent workaround, or a wait until the user asks "whose bug is
this?", leaves it to happen again.

| Domain | The trap | What settles it |
|---|---|---|
| A scheduled run fails half-way | report "incomplete", move on | the job's owner briefed: when, the error, a retry proposal |
| A skill or plugin gives the wrong shape | work around it here | a brief to the agent that ships it, with the case |
| Your own slip, again | apologise and continue | the fix where it recurs: a memory record, a test, a rule |

Origin: retro, 2026-10-15 — 17 corrections in 7 projects (2026-09-13 … 10-16):
«Кому передашь на фикс?», «чей косяк. Передай.», a tool limit accepted as normal.
```

Основание: 17 поправок в 7 проектах, 15 из них не легли ни на одно правило — критерий `learn` «тот же провал во
втором проекте» выполнен.
