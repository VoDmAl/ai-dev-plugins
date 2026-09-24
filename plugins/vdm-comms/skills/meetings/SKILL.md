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
    prep.md                         before: reasoning, branches
    agenda.md                       before: what we walk through
    index.md                        after: the record
    pitch.md, pitch-v2.md           optional
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
| a series file's `slug:`, when present, disagrees with its file name | error |
| `type:` on a role file is not `meeting` | warning |
| a declared series has no `<meetings-dir>/<series>.md` yet | warning |
| a topic has neither a track nor `tail: true` | warning |
| the body of a series file | never checked |

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
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --print-contract
```

Lint by hand — one file, or the whole tree:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh path/to/meetings/2026-09-21-x/agenda.md
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --all
```

Every file named gets one of three answers, and they mean different things:

| Answer | Meaning |
|---|---|
| `✖` / `⚠` | checked, and something is wrong (an error fails the run, a warning does not) |
| `ok` | checked against a rule, and clean |
| `skipped (<why>)` | **nothing on this file was under a rule** — a letter already sent, a letter that attaches nothing, raw material, a file outside the meetings tree |

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

A file carrying `migrated_from` was imported as it was: the authoring rules
(`topic-owner`, `max-must`, `topic-track-line`) skip it, and `people-profiles` /
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
| `link-style`, `registry-columns`, `series-columns` | how the generated layer writes links and which columns it writes — see `/vdm-comms:index`. |
| `enabled` | `false` switches the whole plugin off. |

Fill `track-roots` and `series` from what the repository actually contains. The
values above are placeholders — a project's real ones are its own, and the two
lists exist precisely because no two of the field repositories agreed on them.

Only what genuinely differed between the three repositories is configurable.
Everything else is the floor, in code, identical everywhere.

## Outgoing letters

A `PreToolUse` guard refuses to **create** `*/comms/*-out.md` that already
carries `sent: <date>`. A letter is sent by a person: until then the file is a
draft (`draft: true`), and `sent:` is the record of what actually went out.

The guard keys off the **path shape**, not a list of track prefixes. The field
version matched one prefix, and by the time anyone measured it that repository
had grown two more: nineteen letters sat outside the guard, and nothing said
so — a narrowed guard looks exactly like a quiet one.

Editing an existing letter is never blocked.

### Attaching files to an outgoing letter

A letter that goes out with attachments lists them **in its body, before the
letter text**, as a section of checkboxes — one per file, each a link to the file
itself:

```markdown
## 📎 Attach before sending

- [ ] [The name the file goes out under.pdf](attachments/<file>) — what it is, why the recipient needs it, and why now
```

- one `- [ ]` per file; the link is relative to the letter and clickable;
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

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --all` and read the output
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
