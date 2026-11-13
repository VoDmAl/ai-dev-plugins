---
name: brainstorm
description: "Think a question through with the user before doing anything about it: collect the facts yourself, name the need behind the question, lay out options that differ in kind, recommend one, put the user's decisions to them as numbered questions with a recommended answer each, and write what was decided into the crystal the work belongs to. Use when the user asks to brainstorm, to think wider, or whether a better solution exists — about a new idea or in the middle of work. Said with «grill», the questions run until no decision is left assumed. Triggers include: «через brainstorm», «brainstorm + grill», «побрейнштормим», «давай обсудим варианты», «думай шире», «а есть решение лучше?», «давай придём к идее», brainstorm, think wider, is there a better way, explore the options."
license: MIT
---

# brainstorm — think it through before doing it

## Purpose

The user stops the work and asks to think: «через brainstorm», «думай шире», «а
есть решение лучше?». They are not asking for a list of ideas. This skill was
built from ten such requests in eight projects (2026-09-27…11-05). The answers
that moved the work had the same parts: facts the assistant collected itself,
the need behind the question, options that differ in kind, and the user's
decisions put to them as questions with a recommended answer. Three of the ten
drew a correction, and each is a step below.

It replaces a framework command of the same name. That command's text promised
personas, six tool servers and memory across sessions, and none of them ran:
what the user got was the protocol below. Nothing here needs a file outside
this one. What outlives the session is a crystal, so the result goes there.

## Usage

```
/vdm:brainstorm <question or idea>
/vdm:brainstorm                        # the question already on the table
```

It also runs on the user's own phrasing (see the description). Said together
with «grill» or «grillme», it is the same protocol, and step 5 goes on until no
decision is left assumed. If a grilling skill is installed, its format governs
the rounds of step 5; steps 1–4 and 6 are still this skill's.

## Protocol

### 1. Stop doing, keep answering

Until the user decides, nothing changes on the subject: no edit, no send, no
status change. Reading and measuring are not doing, so do them.

The rest of the user's turn is still owed. When the question came as one item
of a numbered list, answer the other items first, a line each, and brainstorm
after them.

### 2. Facts first, and you collect them

Whatever can be read or measured — files, logs, counts, a decision already
recorded in a crystal — you get yourself, before the first option. Use your
tools, and a helper running beside you where the harness has one. Never ask
the user for a fact that is on disk.

Open the answer with **what is established**: each line a fact with its number
or its source. A fact you could not get is named as missing, with what hangs
on it.

### 3. The need behind the question

Say in a sentence or two what the user is trying to get, in terms of what they
will see or do, not of a mechanism. Then ask where the need comes from. «How do
we check that A matches B?» often comes from one fact kept in two places, and
the best option removes the second copy instead of checking it. If the question
on the table is not the right one, say so and name the one that is.

When the need itself is unclear — an idea with no user and no outcome yet —
that is the first question, asked alone, before any option.

### 4. Options that differ in kind

At least three, and they differ in what they are, not in a parameter. Among
them: the one that removes the need, the smallest one that answers it, and
«nothing changes» with what that costs. For each say what it is, what it gives,
what it costs, and whose zone it is: this project, another agent, the user.
Three or more attributes make a table.

Then your recommendation, with the one reason that decides it. The smallest
option that answers the need is the default; a wider one says what it buys.
Options the facts already rule out are not listed.

### 5. The user's decisions, as questions

Number them `Q1`, `Q2`, … Each carries the whole choice, readable without
scrolling up, and your recommended answer. Ask only what is the user's to
decide; a fact is yours to find (step 2).

Ask now only the questions whose prerequisites are settled. One that hangs on
another's answer waits for the next round. A round is what one reply can
answer: «Q1 — да, Q2 — нет, потому что…».

### 6. Write it down as it is decided

The result has a home before the first round goes out. In a project that keeps
crystals it is the crystal the question belongs to:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-open-crystals.sh"
```

No such crystal, and two or more questions are going to the user or work will
follow: `/vdm:crystal-grow` first. For a new idea the crystal's `## Назначение`
is the brief: what is built and for whom, what «готово» means, what is left
out. A project without crystals uses wherever it keeps decisions.

Each answer is written in the turn it is given: the decision into the Decision
Log in the user's words, the picture into `## Текущая модель`, what stays open
as a `- [ ]` in Next actions with whoever owes it. An observation off the
subject goes to `/vdm:crystal-bud`.

Act on a decision once no open question can still change it. The brainstorm is
over when no question is open, and the last answer says three things: what was
decided, what stays open and with whom, and the next step.

## Seen in the field

- **Options before the need.** The first round offered rules and folders. The
  user wanted to point at a thing and say whose it is, and said so in the next
  turn. Step 3 comes before step 4.
- **The brainstorm swallowed the turn.** The question was item 3 of five, and
  the answer covered only it: «Погоди, давай сначала я отвечу на вопросы выше».
  Step 1.
- **An open question offered as a result.** One option was to ship the document
  with the undecided points listed in it: «Никаких открытых вопросов … не должно
  быть». What cannot be decided now gets an owner and a date in Next actions,
  not a place in the deliverable. Step 6.
- **«А есть решение лучше?»** The answer that held began with where the need
  for a check came from: one fact stored twice. With one copy there was nothing
  left to check. Step 3.

## What it is not

- **Not a plan.** The plan follows the decisions.
- **Not homework for the user.** No question whose answer is on disk, and no
  option table without a recommendation.
- **Not a licence to build.** Step 1 holds until the user answers, even when
  the recommended option looks obvious.

## Integration

- **`/vdm:crystal-grow`, `/vdm:crystal-bud`** — the home of the result and of
  what was noticed on the way.
- **`/vdm:learn`** — when the brainstorm was about a failure, the cause is
  established there (its root-cause route) and the options here stand on it.
- **A grilling skill**, where installed — the rounds of step 5.
