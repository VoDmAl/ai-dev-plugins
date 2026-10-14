---
name: meetings
description: "Meetings and correspondence discipline for a repository that keeps them as files — meetings/<date>-<slug>/ with agenda/prep/index, per-series files, and comms/ letters on tracks. Use when writing or fixing a meeting file, when the contract linter reports a violation, when onboarding a repo that already has a meetings tree, or when the user asks what shape a meeting file should have. Triggers include: «контракт встречи», «линтер встреч», «завести встречу», «протокол встречи», «письмо в comms», «черновик письма», meeting contract, meeting lint, onboarding meetings."
license: MIT
---

# meetings — the contract over a meetings tree

## Purpose

Three repositories independently grew the same model: meetings as directories,
a file per series, letters in `comms/` beside each track. They also grew three
copies of the tool that holds it, and the copies drifted. This plugin is the
one home for that tool; this skill is what the assistant needs to work inside
it.

**The contract is a FLOOR.** Extra frontmatter keys, extra sections, extra file
classes are never violations. A project layers its own conventions on top and
the linter stays silent about them. Only what is MISSING or CONTRADICTORY is
reported.

## The shape

```
<meetings-dir>/                     default: meetings/
  INDEX.md                          registry — generated (see /vdm-comms:index)
  <series>.md                       one file per series, type: meeting-series
  <YYYY-MM-DD>-<slug>/
    prep.md                         before, for the owner: reasoning, branches
    agenda.md                       before, for the owner at the meeting: order, owners, warnings
    pitch.md, pitch-v2.md           before, for the counterpart: what is said aloud
    index.md                        after: the record
    anything-else.md                raw material — NOT under contract
```

**The role comes from the FILE NAME, not from `type:`.** `index`, `prep`,
`agenda`, `pitch[-vN]` are role files and owe the contract whatever their
`type` says; everything else in the directory is raw material (transcripts,
handouts, checklists) and is left alone. This is not a detail: one field
repository keeps thirteen transcripts with no frontmatter at all next to its
meetings, and another grew its own `type` vocabulary — keying the contract off
`type` would have shouted about both while leaving the real role files
unchecked.

## Who reads which file

The role files are split by **who reads them**, not only by phase. A file read by
two audiences at once is the defect: the owner could not use an agenda as it
stood half an hour before a meeting, because the internal and the external were
mixed in one sentence, and the clean pitch was assembled minutes before it began
(command-center, 2026-10-01).

| File | Read by | What it holds | Test |
|---|---|---|---|
| `prep.md` | the owner, before | the reasoning, objections and answers, the tree of branches | — |
| `agenda.md` | the owner, at the meeting | the order, the owners, what to do when someone is missing, warnings; internal wording is fine. No speech | would the owner mind the counterpart seeing it? It is not for them anyway |
| `pitch.md` | the counterpart | only what is said aloud or shown on the screen; headings are the topics as the counterpart knows them — from the letter, if there was one | every line can be read to them as it stands |
| `index.md` | the participants, later | the record | it may be forwarded to anyone who was there |

**The pitch is outgoing text, spoken.** It goes by `/vdm-comms:letters` line by
line: the cutting pass, no denial of motives, no reference to an unanswered
question, no internal corrections. Tactics, "what I do not say" and the record
of edits between versions go to the agenda or the prep, never into the pitch.

**A topic's `name` is neutral: the subject, as the counterpart would name it** —
no position, tactic or ball status. The one string is the heading read on the
screen, the anchor links point at, and the heading of the record that may be
forwarded. A second, "spoken" name would split the anchor in two; a neutral one
serves all three. "Passwords: the request from sales", not "Pressure on
passwords: we hold the line".

**The pitch names the agenda's topics; it is not matched by order.** Its
`topics:` is a list of the topic names it speaks, in the order spoken; an agenda
topic that is spoken says `pitch: true`. The names are plain strings: the pitch
only refers to topics the agenda declares, and `topic-sections` never asks a
pitch for `## Topic N. <name>` headings — its headings are the counterpart's:

```yaml
# agenda.md                          # pitch.md
topics:                              topics: ["Password policy"]
  - name: "Password policy"
    track: projects/auth
    pitch: true
```

**Start a meeting file from the template** — `agenda`, `prep`, `pitch` or
`index` — not from a neighbouring meeting:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/templates/meeting/agenda.md" meetings/<YYYY-MM-DD>-<slug>/agenda.md
```

The templates carry the split: the agenda's own sections for a missing owner and
for time running short, the pitch's guidance in comments of its frontmatter so
that no line of its body is anything but speech. Write them in the project's
language.

## What the linter enforces

| Rule | Level |
|------|-------|
| a meeting lives in `<meetings-dir>/<YYYY-MM-DD>-<slug>/` | error |
| `date:` present, parseable, equal to the directory's date | error |
| `index.md` exists **only if the meeting is in the past** | error |
| `series:` is one of the declared series (when the list is configured) | error |
| each track in `tracks:` resolves as `<track>/` **or** `<track>.md` | error |
| a track's first segment is a configured root (when configured) | error |
| `topics[].track` is one of this meeting's `tracks:` | error |
| a pitch's `topics:` names a topic no other role file of the meeting declares | error |
| an agenda topic says `pitch: true` and no `pitch*.md` beside it lists it | error |
| a series file's `slug:`, when present, disagrees with its file name | error |
| a series file's `next:`, when present, is not a date (`YYYY-MM-DD`) | error |
| a role file holds a **dated promise** (`⏰` / `(due:)`) while the pending summary is on and does not read that file | error (warning on a `migrated_from` record) |
| `type:` on a role file is not `meeting` | warning |
| a declared series has no `<meetings-dir>/<series>.md` yet | warning |
| a topic has neither a track nor `tail: true` | warning |
| the body of a series file | never checked |

**A dated promise does not live in a meeting record.** Promises made at a meeting — "we come
back with questions before the next regular ⏰ 17.09" — belong in the `index.md` of the track
they are about. The record keeps a link to that hook and nothing else. The reason is
mechanical: once `comms.pending-paths` is set, the pending summary reads the tracks and the
declared series, **not** the meeting records. A `- [ ] ⏰ …` left in a record surfaces nowhere.
That is how a promise to a lawyer went unseen until the evening before the meeting it was
due for, and why the next day 25 more such lines were found in the same repository. The
linter names the line and the meeting's tracks. If a project really wants its records read,
it adds them to `pending-paths`, and the rule steps aside for exactly those files.

**A series names its next meeting.** `next: YYYY-MM-DD` in the series file's frontmatter —
written by a person after each meeting, never computed from `cadence`. The pending summary
turns it into "legal — tomorrow — no agenda yet" and, when the date has passed, into "write
the next one". A series whose next meeting is written nowhere cannot be prepared for.

Two of these carry more weight than their one line suggests:

- **`index.md` only for a past meeting.** A planned meeting legitimately has
  only `prep.md` and `agenda.md`; the record is written afterwards. A linter
  demanding `index.md` unconditionally blocks every write into a perfectly
  healthy directory, and that phase is exactly the one in which the files are
  being edited.
- **A track may be a file.** In one repository half of the tracks resolve to
  `<path>.md` rather than a directory. Checking `isdir` alone rejects ten live
  tracks, so both forms are tried.

Print the floor at any time:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh" --print-contract
```

Lint by hand — one file, or the whole tree:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh" path/to/meetings/2026-09-21-x/agenda.md
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh" --all
```

Every file named gets one of three answers, and they mean different things:

| Answer | Meaning |
|---|---|
| `✖` / `⚠` | checked, and something is wrong (an error fails the run, a warning does not) |
| `ok` | checked against a rule, and clean |
| `skipped (<why>)` | **nothing on this file was under a rule** — a letter already sent, a letter that attaches nothing, raw material, a file outside the meetings tree |

After a write, the hook hands errors back as feedback (the write stands, the
assistant is told to fix it) and warnings as context that arrives with the tool
result — not blocking, but read. Until 0.9.1 warnings went to stderr, which the
harness does not show the assistant on a successful hook: every warning was read
by nobody.

Read `skipped` as "not looked at", never as "passed". The distinction exists
because a letter linted by hand used to come back empty — and 88 letters with a
broken field were taken for checked.

**Frontmatter is read as YAML**, including multi-line values written as block
scalars (`goal: |` / `goal: >`, with `-` / `+`), and `key: value  # comment`
reads the value, never the comment. A value that simply continues on the next
line without `|` is refused with a message that says so — write it as a block
scalar or on one quoted line.

A `PostToolUse` hook runs the same linter after every write into the meetings
tree, so a violation comes back within one tool call. Treat that feedback as
the contract speaking, not as noise — and fix the file rather than working
around it.

## A project's own rules — `comms.meeting-rules`

Above the floor, a repository can name its own conventions, and the linter then
enforces them. Each rule is **off until named**; none of them is part of the
floor, because none of them was shared by all three field repositories.

| Key | Value | What it enforces |
|-----|-------|------------------|
| `forbidden-keys` | list of keys | a retired key (`gap`, `sent`, …) in a meeting file or a topic is an error |
| `people-profiles` | `true` | every `people`, `absent` and `topics[].owner` has `<people-dir>/<slug>.md`; a series file's `counterparts` too — as a **warning**, the verdict of the linter this one replaced |
| `topic-owner` | list of roles, e.g. `["agenda"]` | every topic in those role files names an `owner` |
| `tail-owner` | `true` | a topic with no track names an `owner` — who holds it on their side |
| `max-must` | a number | an agenda carries at most that many `must: true` topics |
| `topic-track-line` | a prefix, e.g. `"> Track:"` | the first line under each `## Topic N.` heading starts with it and carries a link or the word *tail* / *хвост* |
| `series-slug` | `true` | every series file carries `slug:` (a slug that disagrees with the file name is an error regardless) |
| `covered-bool` | `true` | a record's `covered:` is `true` or `false` — a warning |
| `unique-topics` | `true` | a topic name does not repeat within a meeting — a warning |
| `required-keys` | list of keys | keys that must be present; `null` and `[]` count as present |
| `speech-markers` | list of marks, e.g. `["**Pitch**"]` | no line of `agenda.md` holds one: what is said aloud lives in `pitch.md` |
| `internal-markers` | list of marks, e.g. `["⚠️", "for myself", "not to say"]` | no line of `pitch.md` holds one, and no topic name does — the pitch is read to the counterpart as it stands, the name is the record's heading. Matched case-blind; `⚠` and `⚠️` are one mark |

A file carrying `migrated_from` was imported as it was: the authoring rules
(`topic-owner`, `max-must`, `topic-track-line`, the two marker lists and the
pitch's link to the agenda) skip it, and `people-profiles` /
`tail-owner` only warn. Failing a record for predating a convention reports
history as a defect.

## Configuration

`.claude/vdm-plugins.json` (or `.qwen/vdm-plugins.json`) → `comms`:

```json
{
  "comms": {
    "meetings-dir": "meetings",
    "track-roots": ["projects", "teams", "incidents"],
    "series": ["weekly", "steering"],
    "topic-sections": false,
    "labels": "en",
    "enabled": true
  }
}
```

| Key | Meaning |
|-----|---------|
| `meetings-dir` | where meetings live. Default `meetings`. |
| `track-roots` | allowed FIRST segment of a track path. Empty (default) accepts any. **Not a path template**: depth is unbounded and case is preserved, because real tracks run one to three segments deep and some contain capitals. |
| `series` | declared series slugs. Empty (default) disables the membership check. |
| `topic-sections` | also check that the body has one topic section per topic — `## Topic N. <name>` or `## Тема N. <name>`. Default `false`: body conventions differ between projects. |
| `meeting-rules` | the project's own conventions, off until named — see the section above. |
| `labels` | wording of the files the GENERATOR writes into your repository: `"en"` (default), `"ru"`, or an object overriding individual keys, merged over English. |
| `link-style`, `registry-columns`, `series-columns`, `generate` | how the generated layer writes links, which columns it writes, and which of its three artefacts are this plugin's at all — see `/vdm-comms:index`. |
| `letter-form` | what an outgoing **draft** must carry, per channel — see *The form of a draft* below. Merged over the default key by key. Default `{"email": ["subject"]}`. |
| `markdown-channels` | channels whose receiver renders Markdown, so a line break inside a paragraph is joined there; a draft on any other channel is checked for hard-wrapped paragraphs — see *One paragraph, one line* below. Added to the default. Default `["intercom", "gitlab"]`. |
| `register`, `language` | who the project usually writes to (`volunteer` \| `executor` \| `peer` \| `arbiter`) and in what language — see `/vdm-comms:letters`. A letter's own `register:` wins over the project's. |
| `enabled` | `false` switches the whole plugin off. |

Fill `track-roots` and `series` from what the repository actually contains. The
values above are placeholders — a project's real ones are its own, and the two
lists exist precisely because no two of the field repositories agreed on them.

Only what genuinely differed between the three repositories is configurable.
Everything else is the floor, in code, identical everywhere.

## Outgoing letters

Until a letter has left, its file is a draft (`draft: true`); `sent:` is the
record of what actually went out, and `sent-proof:` beside it is what shows it
left:

```yaml
sent: 2026-10-13
sent-proof: <id or link from the sending tool's answer>   # or: owner
```

The proof is the id or link the sending tool answered with — a mail's
message_id, a ticket comment's link, a chat message's id — or `owner`, when the
owner said in the conversation that they sent the letter themselves. A
project that marks drafts the other way round, `sent: false` from the first
day, is read the same: every check that asks "is this a draft?" takes both.

A `PreToolUse` guard refuses a write — a new file, an edit, a rewrite — that
makes `*/comms/*-out.md` sent without proof: not sent before (or no file yet),
`sent:` after, and no `sent-proof:`. It asks at the transition, not of the file.
A letter already sent is history and is never asked for a proof it was written
without: of 616 sent letters in three projects, about 520 carry nothing that
could serve, and nothing can be added now (2026-10-13). The field cannot tell a
real id from an invented one; what it does is turn an accidental mark into a
deliberate claim. Until vdm-comms 0.25.0 the guard watched only creation, while
`sent:` was set by an edit — the one path the skill prescribed was unwatched.

The shell is the other road, and the busier one: on this machine's transcripts,
September–October 2026, 322 Bash calls wrote `sent:` into a letter (`sed -i`, a
python `replace`, `cat >` a new file) against 163 Write and Edit. What a command
will leave on disk is not in its text, so a `PostToolUse` check on Bash
(`comms-sent-check`) looks after it: every `*/comms/*-out.md` that differs from
HEAD or is not committed yet, and is sent without `sent-proof:` while HEAD does
not have it sent, is named back with the same two ways out. It cannot undo the
write; it stops the next step — reporting the letter as sent — while the file is
there to fix. It looks only after a command that names `comms`, an `-out.md` or
writes `sent:`; outside a git work tree there is no HEAD, and it says nothing.
An edit in an editor has no tool call at all — it is named after the next such
command.

Since vdm-comms 0.27.0 the field is checked, not only seen. The access layer
writes every send it makes into its journal and answers for an id from it — its
command `sent <directory of the letter> <id>`: 0 a send with this id from this
project is there, 1 it is not (invented, or another project's), 2 cannot tell.
Both hooks ask it when a letter becomes sent with an id, and only 1 refuses: a
"no" about an id the journal never keeps — a link to a ticket comment — would
throw out a real send. What the journal keeps with an id: a mail's
`message_id` (`mail_send`), a chat message's `id` or `link` (`zulip_send`), the
`audit` id of a write into a ticket or a board (`call_write`), the `id` of what
a site created (`api_write`). `owner` is the owner's word and is never asked
about. The access layer is found as everywhere in this plugin — the agent whose
intercom entry declares the role access-layer, `bin/<its identity>` in its
checkout; with none on the machine, or no answer within ten seconds, the
presence of the field is what is checked. After a shell command only a letter
written in the last five minutes is asked about: one question costs about a
third of a second, and the uncommitted letters of a busy session would be asked
about again on every command that mentions `comms`.

The guard keys off the **path shape**, not a list of track prefixes. The field
version matched one prefix, and by the time anyone measured it that repository
had grown two more: nineteen letters sat outside the guard, and nothing said
so — a narrowed guard looks exactly like a quiet one.

A new draft that passes gets the checklist of `/vdm-comms:letters` as context —
the skill's short form, at the moment of writing; never a block.

### Start a draft from the scaffold

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-new.py" --channel email --to <slug> --name "<how you address them>" --track <track> --subject "<subject>"
```

`--to` is the file-name slug, in latin letters as in `people/`; `--name` is what
the heading says. A non-latin `--to` is refused rather than turned into a
file name.

It writes `<track>/comms/<today>-<slug>-out.md` with the header this project's
`comms.letter-form` asks of that channel — `draft: true`, `channel:`, an empty
`goal:`, the subject line and the separator where they are owed — and prints the
path. Then write the goal and the text into that file. Do not copy the header of
a neighbouring letter instead: a neighbour shows what someone once wrote, not
what the project asks for, and the copy carries its habits along. An existing
file is never overwritten.

The empty `goal:` is deliberate: the goal is the one thing a scaffold cannot
know, and in a project that switched on the `goal` element the linter reminds
you of it at the first edit.

### The letter file is the record

The file in `comms/` is the one place that says what was written, to whom, and
whether it left. Everything else that mentions a letter points at it.

- **The file first, then the chat.** A text that goes out is written into its
  file before the owner sees it, and the chat shows that file — its text or a
  link. The checks run at the write: a draft that lives only in the chat gets
  none of them, and the owner's edits have nowhere to land.
- **Every edit goes into the file.** Sent with changes — by the owner in the
  mail client, after a review — the file is first brought to what went out, and
  only then marked `sent:`. What the recipient read is what the file says.
- **The state is read from the file**: `draft:`, `sent:`. A pending item, a
  ledger line or a row in the track's index carries a link to the letter, never
  a copy of its state.
- **A letter lies in the `comms/` of the track it is about**, not where the
  thread began; a `track:` in its frontmatter, where the project writes one,
  names the same track. Correspondence with other agents may keep a folder of
  its own: there the folder is the channel, not the subject.
- **The date in the name is the day of the send.** The scaffold names a draft by
  the day it was started; a draft sent on another day is renamed in the step
  that sets `sent:`, together with the links to it.
- **A reply names what it answers**: a `> In reply to:` line in the service
  header (`> Ответ на:`) or `reply-to:` in the frontmatter, with a link to the
  previous letter; a letter that opens a subject names its context instead
  (`> Context:`, `> Контекст:`). The chain then reads back to its first request.
- **The heading says the direction**: `# → <name>` going out — the scaffold
  writes it — and `# ← <name>` coming in.
- **Where the track's `index.md` keeps a table of its correspondence**, the
  letter gets its row in the same step: the date, a link, one line of what it is
  about.
- **A withdrawn draft is deleted**, not left in `comms/`, where it would count as
  waiting to be sent. The track's notes say why it was withdrawn and where its
  obligations went.
- **The letter is a means; the matter is its own item.** Rewriting a letter does
  not close or merge the pending item it serves, and the letter's service header
  says how and why it changed.

### The form of a draft, per channel

A letter says which channel it goes out through — `channel:` in its frontmatter
(`email`, `telegram`, `express`, `intercom`, `sms`, …). The channel decides the
form: an email needs a subject line, a chat message does not. **When a text has an
outside reader, declare its channel as you create the draft** — that is the one
moment it is known, and without it no tool can tell a letter from a note.

The value is read by its first word, lowercase: `SMS (to the parents)` is `sms`,
`eXpress` is `express`. Write whatever note you need after the first word.

What each channel requires is the project's own, in `comms.letter-form`:

```json
{ "comms": { "letter-form": { "*": ["channel", "separator"], "email": ["subject"] } } }
```

| Element | What the draft must have |
|---|---|
| `channel` | a `channel:` in the frontmatter |
| `subject` | a `**Subject**: …` line (or `**Тема**:`) **on its own line**, between the `>` service header and the separator — not inside the `>` quote, where it is neither seen nor copied with the letter |
| `separator` | a `---` line after the service header, and the text to send after it — everything below the line is pasted as it stands, so it carries no quote marks, bold or other markup the channel will not show |
| `goal` | a non-empty `goal:` in the frontmatter: what should change once the letter is answered. Any YAML form — a multi-line block is read as text. If it does not fit in one sentence, the letter is not ready yet |
| `known` | when the text below the separator asks a question: a `**What we know**` (or `**Знаем сами**`) line above the separator — what the sources already hold on the subject, where it came from, and what they cannot show. A **warning**, not a failure: a question mark is a loose sign |
| `recipients` | a recipients line before the separator — `**To:** … · **Cc:** … · **Bcc:** …` (or `**Кому:** … · **копия:** … · **скрытая копия:** …`; the colon inside the bold or after it) — **with the blind-copy segment**, `—` when nobody: whoever saw the subject earlier and needs no part in what follows is in BCC of the first answer (`letters` § 5), and the segment shows that was decided. The scaffold writes the line with every segment `—` |

`*` applies to every draft, including one that declares no channel yet; a
channel's own list adds to it. The default is only `{"email": ["subject"]}` —
the one thing true of every email in every repository. A separator is a
project's convention and is opted into.

Several messages into one channel from one file go below the separator under
their own headings, `## Message 1`, `## Message 2`: a heading marks where one
message ends and is not pasted.

A draft for another agent (`channel: intercom`) goes out with `intercom send
--body <file>`, which takes the text below the separator and leaves the
frontmatter and the header in the kept copy (vdm 2.45.1 and later).

Checked **only for drafts** (`draft: true` or `sent: false`, no `sent:` date). A letter already sent is
history: fitting it to a form written later would falsify the record. Each
missing element comes back as feedback right after the write.

### One paragraph, one line

A paragraph wrapped at ~100 columns looks right in the editor — the Markdown
renderer joins its lines — and arrives broken mid-sentence in mail, SMS, a chat
or a CMS field, which keep every line break. So a draft that declares its
channel is checked for hard-wrapped paragraphs in the text it sends (after the
separator, or the whole body when there is none), on **every channel except
those whose receiver renders Markdown**: `comms.markdown-channels`, default
`["intercom", "gitlab"]`. A channel joins the list on a render of the live
receiver, not on memory: GitLab's own Markdown endpoint joined the lines, while
mail, a chat and a Jira comment showed the break (2026-10-14). A project adds its
own the same way (`["wiki"]`), and the list is added to the default. Not an
element of `letter-form`: it is on without being listed. The channel is declared
by a file, not by a section: a text to paste that sits inside a larger document
is not checked, so give it its own draft with `channel:`.

The finding names the lines and the command that joins exactly this file:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/comms-unwrap.py" --fix <draft.md>
```

It joins each paragraph into one line and writes only when the words and the
structure are as they were — the same headings, list items, `[x]` and `label:`
lines; otherwise it writes nothing and names the lines to join by hand.
Detection keeps quiet about lines that end where their author meant them to: a
heading, a `[x]` line, `label: value`, an identifier opening the line, a line
ending with a link, a colon or an arrow.

### Outgoing text outside comms/

A file anywhere that declares `channel:` and a draft marker is an outgoing draft
by its own word, and its form is checked wherever it lives. But the draft guard
and `pending` look only in `comms/`, so outside it the draft is not tracked —
the linter says so at the write. Move the text to
`<track>/comms/<date>-<slug>-out.md`, and keep the working notes where they were,
with a link.

### Incoming mail: the letter, not the .eml

A letter that arrived goes into the repository as what was read, not as the raw
mail file:

- the text of the letter or the thread → `comms/<date>-<slug>-in.md` of the track
  the letter is about, dated by the letter itself, not by the day it was filed,
  under the heading `# ← <name>`;
- the attachments that matter → extracted from the `.eml` into
  `comms/attachments/` — the documents and screenshots under discussion, not the
  logos from signatures;
- the `.eml` itself stays where it is (`~/Downloads`, the mail system). Read it
  there — python's `email` module parses it.

The text is kept as it was read: the sender's words, quotes and terms as they
stand at the source. A comment of ours goes beside it, marked as ours, never into
the text.

Why: the text is already in the `.md`; the `.eml` duplicates it in size (27 files,
22 MB in one repository, synced to three devices), in CRLF noise, and in
personal data from signatures that the `.md` never carried.

A `PreToolUse` guard refuses a raw `.eml` into `comms/` or the meetings tree — a
`Write`, and a `cp`/`mv`/`rsync`/`ditto`/`install`/`ln`/`scp`/`tee`,
`curl -o`/`wget -O` or `>` in Bash, following `cd` along the chain. Removing one
(`git rm`) is never blocked. Two limits, stated rather than hidden: it watches
only the plugin's territory — an `.eml` fixture in a code repository is
legitimate and is left alone, and so is one put anywhere else — and it reads a
Bash command by name, so a script that writes the file itself is not seen.

### Attaching files to an outgoing letter

A letter that goes out with attachments lists them **in its body, before the
letter text**, as a section of checkboxes — one per file, each a link to the file
itself:

```markdown
## 📎 Attach before sending

- [ ] [The name the file goes out under.pdf](attachments/<file>) — what it is, why the recipient needs it, and why now
```

- one `- [ ]` per file; the link is relative to the letter and clickable;
- the file lies where its subject lives — a meeting's handout in the meeting's
  folder — and in `attachments/` beside the letter when it has no other home;
- the line says what the file is and why it goes **now** — e.g. «the recipient is
  new to the thread, and attachments of the earlier letter do not carry over to a
  reply»;
- the letter text itself says the file is attached;
- the heading is in the project's language (`## 📎 Приложить при отправке`); the
  📎 is what marks the section;
- when you report the finished draft in chat, give the same files as `file://`
  links, so they open in one click.

**Why not the frontmatter, and why not a path in backticks.** A letter is sent by
a person, by hand, looking at the file in their editor. The frontmatter is the
machine layer — nobody reads it while sending. A path in backticks does not
click and blends into the header. Both were tried on a live letter, and the
attachment got lost while the text already said "attached". `attachments:` in
the frontmatter is fine as data; it does not replace the section.

The linter holds this for a letter not yet sent (`*/comms/*-out.md` without
`sent:`), once the letter itself says it attaches something: `attachments:` in
the frontmatter without a `📎` section, a section without checkboxes, an item
that is not a link, or a link to a file that does not exist next to the letter —
each comes back as feedback right after the write. A letter that attaches
nothing is never asked about attachments.

### Writing to a colleague who helps voluntarily

Someone from a neighbouring team who helps because they want to is asked, not
assigned: «your experience would help a lot here», «could you please…» — not
«this is your task from here», not «this is your field». Do not tell them where
their zone is; they chose to step into it.

## Onboarding a repository that already has meetings

1. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh" --all` and read the output
   **before changing anything**. Expect warnings; they are the diff between
   this floor and the project's own habits.
2. Fill in `comms.track-roots` and `comms.series` from what the repository
   actually contains — not from what its README says it contains. The two
   diverge; that is why the membership check exists.
3. Fix errors one file at a time. Warnings are a conversation with the user,
   not a task list: `type: meeting-agenda` on a role file may be a drift worth
   converging, or a convention worth keeping.
4. The generated layer is a separate step — see `/vdm-comms:index`.

## When the linter cannot run

A blocking hook that cannot run says `NOT CHECKED` and blocks, rather than
returning silence. "The check failed" and "the check did not run" are
different events, and only the first one is what a clean exit means. If you
see it: the linter needs `python3` (standard library only — this plugin brings
no third-party dependencies). Do not work around it by writing the file
another way.

## Integration

| Other skill | Interaction |
|-------------|-------------|
| `/vdm-comms:index` | rebuilds the registry, the series lists and the track pointers |
| `/vdm:crystal-bud` | a contract divergence worth deciding later is a побег, not a silent edit |
| `/vdm:changelog` | record a contract change in the project's own changelog |
