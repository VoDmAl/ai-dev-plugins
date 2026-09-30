---
name: wrap
description: "Before leaving a session for a clean one — /clear, closing the terminal, or choosing between a clean session and /compact: find what exists only in the chat, write each item where the next session will see it, prepare one commit, and name the phrase that starts the next session. Takes an optional next goal. Use when the user asks whether it is safe to move on, with or without saying what comes next. Triggers include: «можно в чистую сессию?», «можно переходить в чистую сессию», «тут что-то не переживёт?», «ничего не потеряется?», «в чате ничего не осталось?», «завершаю сессию», «новую сессию запускаю», «дай handoff», «через handoff», «идём в чистую сессию с …», «чистая сессия или compact?», clean session, wrap up, end the session, hand off, is anything lost?"
license: MIT
---

# wrap — leave for a clean session with nothing left in the chat

## Purpose

The chat is not storage. On `/clear`, everything that exists only in the chat is
gone: the user's words, the assistant's own recommendations, questions nobody
answered, promises with a date. What survives is files, git, the intercom store,
the project's memory, and crystals, which `crystal-hydrate` lists at session start.

This skill is the check the user asks for before leaving. It finds chat-only
items, gives each one a home the next session reads, commits once, and says how
to start. It adds no gate. Every item it writes becomes something an existing
mechanism already holds: a `- [ ]` the completion guard blocks on, a crystal the
start hook lists, a letter the intercom start line counts.

It is short by design. The user wants a verdict and a first phrase, not a report.

## Usage

```
/vdm:wrap                                # check only
/vdm:wrap механизм незаявленных групп    # check + the next goal
```

It also runs on the user's own phrasing (see the triggers in the description).
When the user names what comes next («идём в чистую сессию с X»), X is the
argument.

## Protocol

### 1. Snapshot — one call

```bash
git status -sb; git stash list | head -3; "${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh" check; "${CLAUDE_PLUGIN_ROOT}/scripts/list-open-crystals.sh"
```

Read it for four things:

- **Changes that are not committed or not pushed.** Separate yours from those a
  parallel session or the user made. Name theirs and don't touch them.
- **Stashes.**
- **Pending letters.** Give the count only; the next session reads them.
- **Active crystals.**

### 2. Sweep the chat — six classes

Go through the session from its start, or from the last compaction summary. For
each item, ask one question: is it in a file the next session will read? Check
with grep for a distinctive marker (a number, a name, a quoted phrase), not from
the memory of having written it.

| Class | Example | Home |
|---|---|---|
| Decisions and the user's words | «две ветки, а мелочи — вручную» | the crystal's Decision Log, with the quote verbatim in `Basis-detail` |
| Your recommendations the next step depends on | "generalize both gates to every plugin" | the crystal: a Sidetrack card or `## Текущая модель` |
| Open questions, in both directions | one you asked that got no answer; one the user put off | Next actions `- [ ]`, naming who owes the answer |
| Promises and dates | «ждём ответа X до пятницы» | Next actions with `(due: YYYY-MM-DD)` |
| Lessons and corrections | «не склеивать правку и отправку» | memory, or `/vdm:learn` when it is a rule |
| Facts obtained with effort | links, numbers, quotes found outside the repo | the crystal's `## Текущая модель` or References; `references/` under the provenance rule |

If there is no crystal and nothing fits one, lessons go to memory and the rest
goes into an intercom note to self (step 4).

### 3. Write every item — don't ask whether to

Write every item yourself. Don't end the turn with "should I add X?". The user
is leaving and the answer never comes, so the question becomes one more thing
that dies with the chat. An extra line costs a line; a lost item is lost
entirely.

Ask only what the files cannot hold without the user, and ask it before writing,
not after. Whatever the answer, it also needs a home, for example a `- [ ]`
saying the user decides.

Don't start new work during the check. Letters in the inbox, or a bug noticed on
the way, are recorded as items, not handled. Handling them is the next
session's job, and doing it here makes the answer long and the commit not the
last step.

### 4. Where the next goal lives

| Situation | Carrier | Start phrase |
|---|---|---|
| A crystal covers the goal | update its `## Текущая модель`; the first open Next action is the first step | «продолжаем кристалл `<slug>`» |
| The goal takes several steps and has no crystal | `/vdm:crystal-grow` with `status: ready` (parking; the singleton stays free) | «берём `<slug>`» |
| Small, or a mix of loose ends | a note to self: `/vdm:intercom send <this-repo> <slug> --title "…"` | `/vdm:intercom pickup <slug>` |

A note points to the crystal and does not retell it. Two retellings drift apart.

Always name the slug. With several active crystals, «продолжаем кристалл» makes
the next session guess.

### 5. One commit, at the end

Finish all writes first, then prepare one commit:

- **With `vdm-git`:** run `git add <files>` and `git-guard-prepare "<subject>"`,
  then hand off the printed line.
- **Without it:** list the files and let the user commit them.

Memory and intercom notes live outside the repository and are not part of the
commit.

If anything was written after the line was printed, the line is stale. Prepare a
new one and say that the old one no longer works.

### 6. What dies with the session

These can't be saved; name them:

- background tasks and monitors;
- cron jobs scoped to this session;
- files in the session scratchpad.

For each one whose result matters, name who checks it instead, usually a Next
action. If nothing is running, say so in one line.

### 7. The answer

Answer in the user's language, short, in this shape:

```
<Можно | Можно после коммита | Пока нельзя: причина>.

Было только в чате → записал:
- <что> → <файл>
Оборвётся с сессией: <что | ничего>.
Не моё, не трогал: <файлы | —>.

<строка коммита, если есть>

Новая сессия: «<фраза со слагом>»
```

If nothing was chat-only, say so in one line and give the start phrase. Don't
list everything that was already in files.

After the user runs the commit, verify it with `git log -1 --stat` and answer in
one line.

## Clean session or compact?

- **Choose a clean session** when the next step stands on files (a crystal, a
  note) or is a different task. Compact keeps a retelling, and a retelling loses
  detail without saying so.
- **Choose compact** when the work is in the middle of one step, and its working
  state (intermediate measurements, what was just tried) costs more to write out
  than to retell.

Either way, run steps 2–3 first. Compact loses the same things as `/clear`, just
less visibly.

## Anti-patterns seen in the field

| Pattern | Cost |
|---|---|
| Ending the last turn with a question | the user leaves, and the answer and the item are both lost |
| Preparing the commit before the writes are finished | the user runs a line that misses files |
| A start phrase without a slug | the next session guesses among active crystals |
| Handling the inbox or doing found work during the check | a long answer, a second commit, and the check stops being short |
| Saying "everything is in files" from memory | an item you believed written wasn't there; grep for it instead |
| Committing what another session staged | their work lands in your commit |

## Integration

| Skill | Role here |
|---|---|
| `/vdm:crystal-bud` | a chat-only item that is a sidetrack |
| `/vdm:crystal-grow` | the next goal needs its own crystal (`status: ready`) |
| `/vdm:intercom` | the note to a future session of this repository |
| `/vdm:learn` | a lesson that is a rule, not a fact |
| `vdm-git:guard` | the single commit at the end |

Field source: Claude Code transcripts from 2026-09-03 to 2026-09-30, about 45 of
the user's "can we move to a clean session?" asks in 10 projects. The analysis
and decisions are in `cc-vdm-plugins → docs/tasks/wrap-skill/workitem.md`
(upstream, not in your project).
