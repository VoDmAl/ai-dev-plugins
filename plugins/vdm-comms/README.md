# vdm-comms

Meetings and correspondence discipline for a repository that keeps them as
files. One home for a tool three repositories had each copied and drifted.

## What it does

| Piece | Kind | When |
|-------|------|------|
| meeting contract linter | `PostToolUse` hook + CLI | after any write into the meetings tree |
| a project's own meeting rules | same linter, `comms.meeting-rules` | only the rules the project named |
| who reads which meeting file | same linter | a pitch names the agenda's topics by `name`, and an agenda topic with `pitch: true` has a pitch that lists it; with `comms.meeting-rules`, no speech marker in the agenda and no internal marker in the pitch or a topic name |
| meeting templates | `templates/meeting/` | agenda, prep, pitch and index, split by who reads them — copied when a meeting file is started |
| attachment checklist of a letter | same linter | after a write to an unsent `*/comms/*-out.md` that attaches something |
| pending-item linter | `PostToolUse` hook + CLI | after a write into a `pending-paths` file — **new lines only** |
| outgoing-draft guard | `PreToolUse` hook | on a write to `*/comms/*-out.md` — new file or edit: refuses one that makes the letter sent without `sent-proof:`, or with an id the access layer's journal of sends does not have for the project, and hands a new draft the checklist of `/vdm-comms:letters` |
| sent-without-proof check | `PostToolUse` hook | after a Bash command that names `comms`, an `-out.md` or writes `sent:` — names every outgoing letter left sent without `sent-proof:`, or with an id the journal does not have, that HEAD does not have sent |
| letter versions | `PreToolUse` (Bash) and `PostToolUse` hook, inside the two above + CLI | before and after a write to `*/comms/*-out.md`, and before and after a Bash command that names one — keeps each new text of the letter, with the owner's turn that led to it, in `~/.claude/vdm/letter-versions/` (outside the repository); never blocks. Read with `comms-versions.py list\|diff <letter>` |
| draft scaffold | `scripts/comms-new.py` | on request: a new `*/comms/*-out.md` with the header the project's `letter-form` asks of the channel, and what `people/` says about the recipient |
| who may write to a person | `scripts/comms-people.py` | on request: `trust` and the From pairs from the profile, and the next step for this project — a hand writes to `team` and `peer` only |
| form of an outgoing draft | the meeting linter | after a write to a draft (`draft: true` or `sent: false`) — per `channel:`, from `comms.letter-form`; a declared draft outside `comms/` is named |
| one paragraph, one line | the meeting linter + `scripts/comms-unwrap.py` | after a write to a draft whose channel keeps line breaks (every one but `comms.markdown-channels`, default `intercom` and `gitlab`): hard-wrapped paragraphs of the text it sends, with the command that joins them |
| raw `.eml` guard | `PreToolUse` hook | a `Write`, or a `cp`/`mv`/`>`/… in Bash, that puts an `.eml` into `comms/` or the meetings tree |
| generated-layer drift signal | `SessionStart` hook | once per session, and only when something is behind |
| overdue signal | `SessionStart` hook | once per session, and only when something is due, unsent or untranscribed |
| `/vdm-comms:meetings` | skill | the contract, configuration, onboarding |
| `/vdm-comms:index` | skill | rebuild the registry, series lists and track pointers |
| `/vdm-comms:pending` | skill | who owes what, to whom, and by when |
| `/vdm-comms:letters` | skill | the communications skill: what an outgoing text — letter, message, SMS, ticket comment — carries and what stays out of it |

## The model

```
meetings/
  INDEX.md                          generated registry (markers required)
  <series>.md                       type: meeting-series — body never checked
  <YYYY-MM-DD>-<slug>/
    prep.md  agenda.md  index.md    role files — under contract
    transcript.md, handout.md       raw material — left alone
<track>/comms/
  <date>-<slug>-out.md              a letter; `draft: true` until a person sends it;
                                    files to attach listed as `## 📎 …` checkboxes
  <date>-<slug>-meeting.md          generated pointer back to a meeting
<any file in pending-paths>
  - [ ] **<what>** — … [who:: <slug>] [state:: ask] [due:: 2026-09-26]
                                    an obligation that can fire: who moves now, its state, its date
  - [ ] **<what>** — … [who:: <slug>] [state:: sent] ⏰ after: <event>
                                    …when the signal arrives on its own
  - [ ] **<owner>** — <what> ⏰ 2026-09-26        the old form, read during the transition
  - [ ] <what> (due: 2026-09-26)                 the crystal suite's own form
```

The contract is a **floor**: extra keys, extra sections and a project's own
file classes are never violations. Only what is missing or self-contradictory
is reported.

## Configuration

`.claude/vdm-plugins.json` → `comms`:

```json
{
  "comms": {
    "meetings-dir": "meetings",
    "track-roots": ["projects", "teams", "incidents"],
    "series": ["weekly", "steering"],
    "topic-sections": false,
    "labels": "en",
    "meeting-rules": { "max-must": 2, "people-profiles": true },

    "link-style": "markdown",
    "registry-columns": ["date", "meeting", "series", "tracks"],
    "series-columns": ["date", "meeting"],
    "generate": ["registry", "series", "pointers"],

    "pending-paths": ["projects/*/index.md", "docs/tasks/*/*.md"],
    "pending-sections": { "waiting": ["Waiting on"], "action": ["Our actions"] },
    "owners": ["research team", "legal", "John"],
    "people-dir": "people",
    "pending-draft-days": 3,
    "pending-transcript-days": 0,

    "register": "peer",
    "language": "en"
  }
}
```

`meeting-rules` is where a project names its own conventions above the floor —
the full list is in `/vdm-comms:meetings`. `link-style: wikilink` makes every
generated link an Obsidian `[[…]]`, for a repository kept as a note vault; the
column lists add participants, topic counts and materials to the tables — see
`/vdm-comms:index`.

Only what genuinely differed between the three field repositories is
configurable. `track-roots` is a list of allowed **first segments**, not a path
template: real track paths run one to three segments deep, some contain
capitals, and half of one repository's tracks resolve to `<path>.md` rather
than a directory.

`pending-paths` is empty by default, and that switches the whole pending half
off. It is the one thing that genuinely cannot be guessed: the three field
repositories keep their open items in `gaps|org|incidents/*/index.md`, in
`tracks/*/index.md` and in `docs/tasks/<key>/<slug>.md`. Declaring a section in
`pending-sections` is what makes everything under that heading an obligation —
elsewhere, only a line already carrying a date marker is an item at all.

A **hand** — a project that keeps no `people/` — reads its HQ's. Which HQ is
not configured here: it is recorded once, at the access layer, and asked
(`<access layer> hq <project root>`; the layer is the agent whose intercom entry
declares the role `access-layer`). The checkout comes from the intercom
directory, the directory name from the HQ's own `people-dir`. An empty answer,
or no access layer on the machine, means the project is its own HQ; a layer that
cannot answer makes everyone `careful` until it can. Two fields in a profile decide who may write and from which address —
`trust: team | peer | careful | exec` (none = `careful`; the former `top` reads as `exec`) and `mail_from` pairs —
and a third, `addressed_as`, is the form of address the draft is told when it is born;
the format is in `/vdm-comms:letters` → *People profiles*.

`labels` is the wording of the files the generator writes **into your
repository** — `"en"` (default), `"ru"`, or an object overriding individual
keys (`{"col-meeting": "Созвон"}`), merged over English. It exists because a
table headed in the plugin author's language appearing in your document is the
plugin deciding something that was never its call.

## Dependencies

`python3`, standard library only. No PyYAML, no `jq` — the frontmatter reader
is vendored (`scripts/comms_frontmatter.py`) precisely so that installing this
plugin does not add the first third-party dependency to a project that has
none.

When a blocking hook cannot run it says `NOT CHECKED` and blocks, instead of
exiting quietly: "the check failed" and "the check did not run" are different
events, and only the first is what a clean exit means. The drift signal, being
a reminder rather than a gate, does the opposite and stays silent.

## Manual use

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --all             # lint the tree
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --print-contract  # print the floor
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --check          # what is behind?
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --write          # rebuild, printing every path
${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh               # what is overdue, due soon, waiting on an event
${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --owner       # …grouped by who owes it
${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --lint        # items outside the contract
${CLAUDE_PLUGIN_ROOT}/scripts/comms-people.py where          # whose people/ this project reads
${CLAUDE_PLUGIN_ROOT}/scripts/comms-people.py show <who>     # may we write to them, and from which address
```
