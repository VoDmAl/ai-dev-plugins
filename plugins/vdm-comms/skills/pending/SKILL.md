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
(`**research team**`, `` `product` ``, `**agent product**`, `**legal**`), or
"we"/"мы" for something on our side (`**We (platform team)**` — the parenthesis
qualifies, it does not rename).

**The owner opens the item.** A person linked further into the head is the one
being told, asked or written to — «Tell [[…|Petrov]] that the check passed»,
«Ask [[…|Petrov]] about TLS», «Second letter to [[…|Petrov]]: …» — and the ball
is ours. Put the owner first, or the summary will file the item under whoever
the sentence mentions. Flags before the owner (`🔴`, `🆕`, a date marker) are
stepped over, and so is an event marker together with its event:
`⏰ после: доступ подтверждён — **echelon** — …` is owned by `echelon`. An event
with nothing after it names what we wait for, not who owns the item.

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
    "owners": ["research team", "legal", "product", "John"],
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
| `pending-draft-days` | age at which an unsent draft is reported — any `*/comms/*.md` whose frontmatter says `draft: true` or `sent: false` and carries no `sent:` value; `0` switches it off |
| `pending-transcript-days` | window for "held, no transcript yet": a meeting in the last N days (today's excluded) with no `transcript*` file beside it and no `transcript:` in its `index.md`. Default `0` — off |

Once `pending-paths` is set, the **queue of every declared series**
(`<meetings-dir>/<series>.md` for each name in `comms.series`) is read too — a
promise made at a meeting waits there for the next one. It comes from the
declared list, not a glob: `meetings/*.md` would also match the directory's
README, whose prose explains the marker.

`owners` is a whitelist for a measured reason: across 304 live items a bold
fragment was the **subject** at least as often as the owner
(`**Decide the fate of PROJ-5168**`), and no structural rule separates the two.
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

A second line names **sent letters edited since their commit**: a file in a
`comms/` directory whose frontmatter carries `sent:` (outgoing or inbound) and
whose working tree differs from `HEAD` — modified or deleted, with `+N/−M`. A
sent letter is the record of what went out. An edit that syncs it with what was
really sent is made in the same turn and committed with it; an edit that
outlives the session is almost always an accident. Field case (2026-10-06): the
name of another letter landed in a sent one from an editor, past every hook,
and lay there 20 days while every session committed around the ` M`. When the
line appears: `git diff -- <path>`, then commit the sync or restore the
accident (`git checkout -- <path>`). A new letter staged and never committed is
not named — that is usually another session's work in flight. This line does
not need `pending-paths`.

**After a write** the contract is checked on **new lines only** — lines that are
not in `HEAD` — and a violation is returned to the assistant as feedback. The
old tail is deliberately out of scope: every repository that keeps open items
has one, it predates the contract, and re-reporting it on every edit is how a
linter becomes background noise. Fix the tail as a migration, not as a hook.

Both hooks stay silent in a project that has not set `pending-paths`, except
for the line about edited sent letters. The
blocking one fails **closed**: if it could not run, it says `NOT CHECKED` and
blocks rather than exiting quietly, because "the check failed" and "the check
did not run" are different events and only the first is what a clean exit means.

## The live `now.md`

A project that declares `comms.now` gets `signals/now.md` — the owner's state,
rebuilt from the same items this skill reads, so the owner opens one file instead
of asking what hangs:

```json
{ "comms": { "now": {
    "owner": ["владелец"],
    "instructions": "docs/how-to-work.md",
    "path": "signals/now.md"
} } }
```

`owner` names what the items call the owner — the one thing the order of
`owners` cannot tell. `instructions` is the file that says how to work with
`now.md`; it becomes the first line. `path` defaults to `signals/now.md`.

What goes where:

- **Your move** — items owned by the owner; another owner's item whose date has
  passed, lifted and saying whose it was; every unsent draft, since what goes out
  in the owner's name waits for the owner; and the collector's tasks on the
  owner's turn (`echelon mine`: Jira mentions, MRs, chats, letters) — they bypass
  the homes. A task an owner's item already carries is not shown twice.
- **Today and tomorrow** — the calendar (`echelon soon`): the machine's time
  first, Moscow in brackets; the project's meetings in bold, the rest dimmed, a
  cancelled one struck; then every item due on those two days.
- **Led by others** — the rest, by owner.

An item shows its start, not its paragraph (owner, 2026-09-30): the first
sentence, at most about 200 characters, marked «…», its date kept — the full text
is one click away, in the home. An incomplete collection says so in its block;
an empty calendar from an incomplete collection is not "no meetings".

echelon is found at `ECHELON_BIN`, else `comms.now.echelon` (a path; `false`
switches it off for the project), else `$ECHELON_HOME/bin/echelon`, else as the
agent whose intercom directory entry declares the role `access-layer` —
`bin/<its identity>` in its checkout on this machine (the vdm plugin's
`/vdm:intercom role access-layer --path` answers the same). When it cannot be
reached the build still runs and the file says what is missing.

Build it with `"${CLAUDE_PLUGIN_ROOT}/scripts/comms-now.sh"` (`--stdout` to look
without writing). It is a command, not a hook — the plugin's hooks write no
project files: the collector runs it after a pass (`after_pass` of the project),
and a session runs it when told `now.md` is behind. The frontmatter carries
`built:` and `your-move:`, which the session-start line reads, and `homes:` — a
digest of the open items and drafts it was built from. `now.md` is never edited
by hand: an item's text lives in its home.

**Behind.** After a write that changed the items of a home, the hook says
`now.md is behind the homes — rebuild it`; session start says the same when the
homes changed outside a session (a box ticked in Obsidian). Rebuild when told.
The comparison is by content: touching a file, or editing prose that holds no
item, is not a change. `comms-now.sh --check` asks the same question by hand.

**Block ids.** An item links to its line when the line ends with a block id —
`^a3f`: a letter, then two letters or digits, unique in the project, so the
owner can write "a3f: …" in the chat. When you write or edit an item in a
project with `comms.now`, end it with one:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-now.sh" --new-id        # a free one; --new-id 5 for five
```

The linter names a new or edited item without an id, and an id used twice in
the project. An item without an id shows in `now.md` as `file:line`.

The items that are already open are marked once, **on the owner's word** — it
writes the homes, and the diff shows every line it touched:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-now.sh" --assign-ids --dry-run   # how many, where
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-now.sh" --assign-ids
```

Only the lines that get an id change; a closed item and a table row are left
alone.

**Replies.** The owner may answer straight in `now.md`: a line starting `>>@ai`
under an item. A rebuild keeps it under the item with the same id; when that
item is gone, it moves to the top, under «replies without an item». Answer it as
a chat message about that item, then delete the line.

## What it does not do

- **It does not read your tracker.** A ticket status on the line is what was
  written there, not what the tracker says now.
- **It does not judge whether an item is still meaningful** — only whether it
  can fire. An item pointing at a letter that already carries `sent:` is
  reported as suspicious, not closed.
- **It does not translate.** What it writes into the repository is governed by
  `comms.labels`; what it prints to you is a diagnostic and stays in English.
- **It does not migrate formats.** `⏰` and `(due:)` both stay as written.
