---
name: pending
description: "Who owes what, to whom, and by when — a summary of open items across the files a project declares, grouped by owner, with overdue and due-this-week separated out. Use when the session starts with «что висит», before preparing a recurring meeting, when closing a session, or when an item needs an owner and a review date. Triggers include: «висяки», «что висит», «кто кому должен», «просрочено», «мяч у нас», pending items, open loops, who owes what, overdue."
license: MIT
---

# pending — open items that can actually fire

## Purpose

An open checkbox has no second artefact to compare it against, so "this went
stale" is not detectable at all: the list looks current right up until someone
reads it against the record by hand. Field measurement, one repository: a manual
sweep took a whole session and produced 288 open items across 39 tracks, **263
of them with no review date** and dozens with no owner.

The missing artefact is the **date the item promised to be revisited**, written
on the same line as the promise. With it the signal becomes an ordinary
comparison, and this tool is that comparison.

## The line

```
- [ ] <flag>? **<owner>** — <what, and what we do when the date arrives> ⏰ 2026-09-26
- [ ] <flag>? **<owner>** — <what> ⏰ after: <the event that will signal>
- [ ] <what> (due: 2026-09-26)
```

**Owner.** Whose ball it is. One of: a wikilink to a profile
(`**[[../../people/ivan-petrov|Petrov]]**` — a person is always written this
way, so the summary groups by *person* rather than by how the sentence
declined their name), an emphasised name from `comms.owners`
(`**risk model**`, `` `limeflow` ``, `**agent limeflow**`, `**legal**`), or
"we"/"мы" for something on our side (`**We (platform team)**` — the parenthesis
qualifies, it does not rename).

**The owner opens the item.** A person linked further into the head is the one
being told, asked or written to — «Tell [[…|Petrov]] that the check passed»,
«Ask [[…|Petrov]] about TLS», «Second letter to [[…|Petrov]]: …» — and the ball
is ours. Put the owner first, or the summary will file the item under whoever
the sentence mentions. Flags before the owner (`🔴`, `🆕`, a date marker) are
stepped over.

**Date.** `⏰` plus an ISO date. It is a **review date, not the counterparty's
deadline**: the day we come back to this if nothing has happened. Say what we
do then — «→ followup», «→ raise at the regular», «→ escalate to X».

**An event instead of a date** — `⏰ after: <event>` — only when the signal will
arrive on its own (a transcript, a reply to a letter already sent, a ticket
shipping). If the event might never happen, put a date.

**`(due: YYYY-MM-DD)`** is the crystal suite's own form and means the same
thing. Both are read; neither is converted. `⏰ after:` cannot be written as
`(due:)`, which is why two forms exist rather than one.

**Without a date an item is a note, not a hook.** Its place is a backlog file,
not a section that promises to fire.

## Promises made at a meeting

They go into the `index.md` of the track they concern, not into the meeting record. The record
links to them. The summary reads tracks and declared series, not records, so a dated line left
in a record fires nowhere. The meetings linter reports it as an error while this summary is on
(`/vdm-comms:meetings`).

## The next meeting of a series

Each declared series may carry `next: YYYY-MM-DD` in its frontmatter — the date of its next
meeting, written by a person. The summary then shows:

- **series meetings within 7 days**, and whether each already has an `agenda.md` or `prep.md`
  in `<meetings-dir>/<that date>-*/`. A meeting tomorrow with no agenda is flagged 🔴 and named
  in the session-start line — the same weight as an overdue item;
- **a `next:` that has passed** — the field now says something false about the future; write
  the following date.

Nothing is computed from `cadence`: "as questions arise" was once read as "no more regulars",
and that is exactly the promise this field exists to make explicit.

## Counterparty items first

In a file that carries both, the section where **the ball is with them** comes
before the section where it is with us. Not cosmetic: an item waiting on someone
else decays while we do nothing, and the only thing that recovers it is being
read first. Our own actions are recoverable at any time by doing them.

The same ordering is why the owner is mandatory in a waiting section and
defaults to "us" in an action section — an action section has already said whose
ball it is, and repeating it on every line is noise.

`--owner` reads the same way: **people first, then the names in `comms.owners`
in the order listed, then us, then items nobody owns.** A name that stands for
our own side — the maintainer's — goes last in `owners`, and lands right before
"us".

## Configure before using

Nothing runs until the project says where its open items live. There is no
sensible default: three repositories keep them in three different shapes.

`.claude/vdm-plugins.json` → `comms`:

```json
{
  "comms": {
    "pending-paths": ["tracks/*/index.md", "docs/tasks/*/*.md"],
    "pending-sections": {
      "waiting": ["Ожидаем"],
      "action": ["Наши действия", "Требует действий"]
    },
    "owners": ["risk model", "legal", "limeflow", "Dmitry"],
    "people-dir": "people",
    "pending-draft-days": 3,
    "pending-transcript-days": 45
  }
}
```

| Key | What it does |
|---|---|
| `pending-paths` | globs, relative to the repository root. Empty = the whole pending half stays silent |
| `pending-sections` | headings, matched by **prefix**, so `Ожидаем` covers `## Ожидаем ответы` |
| `owners` | the names that count as owners; also the order groups appear in (your own name last) |
| `people-dir` | where profiles live, for the wikilink form (default `people`) |
| `pending-draft-days` | age at which an unsent draft is reported — any `*/comms/*.md` whose frontmatter says `draft: true` and carries no `sent:` value; `0` switches it off |
| `pending-transcript-days` | window for "held, no transcript yet": a meeting in the last N days (today's excluded) with no `transcript*` file beside it and no `transcript:` in its `index.md`. Default `0` — off |

Once `pending-paths` is set, the **queue of every declared series**
(`<meetings-dir>/<series>.md` for each name in `comms.series`) is read too — a
promise made at a meeting waits there for the next one. It comes from the
declared list, not a glob: `meetings/*.md` would also match the directory's
README, whose prose explains the marker.

`owners` is a whitelist for a measured reason: across 304 live items a bold
fragment was the **subject** at least as often as the owner
(`**Decide the fate of GA-5168**`), and no structural rule separates the two.
Names are printed in the spelling you list here, so a group does not split in
half over capitalisation.

## Two scopes, and what a section changes

* A line **inside a declared section** is under the full contract: owner and
  date are both required.
* **Anywhere else** in a `pending-paths` file, only a line that already carries
  a marker is an item at all, and the only violation available is a broken
  marker.
* **A table row carrying a marker** is an item too — a queue of topics is a
  table, and its promise sits in a cell (`| 2 | the status of X | … | our
  promise, ⏰ 22.09 |`). It is never a strict one: a table has no checkbox and no
  head for an owner. Its date is read from the marker's own cell, not from the
  next column's.

That is the suite's standing law — soft until named, binding once named —
applied to a heading. Declaring `## Ожидаем ответы` is the act that makes
everything under it an obligation. Without a declaration a checkbox is just a
checkbox, and a linter that fires on every checkbox in a repository is one that
gets switched off, which costs the real findings too.

## Use

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh"              # overdue · 7 days · by event
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --owner      # grouped by owner
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --all        # everything, including far-dated
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --lint       # contract violations, whole repo
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --json       # for scripts
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --print-contract
```

**When to run it**: at the start of a session (the first question is always
"what is waiting"), before preparing any recurring meeting, and before closing
a session.

## The two hooks

**Session start** prints one line when something is overdue, falls due within a
week, was written and never sent, or was held without a transcript (when that
window is on) — and nothing at all otherwise. A dated item
becomes overdue by the calendar turning, not by anyone writing a file, so there
is no tool call to hang it on; session start is the only moment available and
also the right one.

**After a write** the contract is checked on **new lines only** — lines that are
not in `HEAD` — and a violation is returned to the assistant as feedback. The
old tail is deliberately out of scope: every repository that keeps open items
has one, it predates the contract, and re-reporting it on every edit is how a
linter becomes background noise. Fix the tail as a migration, not as a hook.

Both hooks stay silent in a project that has not set `pending-paths`. The
blocking one fails **closed**: if it could not run, it says `NOT CHECKED` and
blocks rather than exiting quietly, because "the check failed" and "the check
did not run" are different events and only the first is what a clean exit means.

## What it does not do

- **It does not read your tracker.** A ticket status on the line is what was
  written there, not what the tracker says now.
- **It does not judge whether an item is still meaningful** — only whether it
  can fire. An item pointing at a letter that already carries `sent:` is
  reported as suspicious, not closed.
- **It does not translate.** What it writes into the repository is governed by
  `comms.labels`; what it prints to you is a diagnostic and stays in English.
- **It does not migrate formats.** `⏰` and `(due:)` both stay as written.
