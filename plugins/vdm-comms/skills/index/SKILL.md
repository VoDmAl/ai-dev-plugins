---
name: index
description: "Rebuild the generated layer over a meetings tree: the INDEX.md registry, the per-series meeting lists, and the pointer each track's comms/ gets for a meeting that touched it. Use when the session-start signal says artefacts are behind, after adding or editing a meeting, or when a track's chronology is missing a meeting. Triggers include: «реестр встреч», «пересобрать индекс», «указатели встреч», «INDEX.md отстал», meeting registry, rebuild index, meeting pointers."
license: MIT
---

# index — the generated layer over a meetings tree

## Purpose

Three artefacts are derived from the meetings and go stale the moment one
changes:

| Artefact | What it is |
|----------|------------|
| `<meetings-dir>/INDEX.md` | the registry of every meeting |
| `<meetings-dir>/<series>.md` | the list of that series' meetings |
| `<track>/comms/<date>-<slug>-meeting.md` | a pointer, so the meeting appears in the chronology of each track it touched |

The third is the one that is easy to miss and the reason the others are worth
having. A track's `comms/` is where its correspondence lives and where a
reader looks for "what happened on this". A meeting that leaves no trace there
is invisible exactly where someone would go looking.

## The rule: proposed, never applied behind your back

`--check` compares what is on disk with what the meetings say. `--write`
applies it and prints every path it touched. Nothing is written by a hook.

That is a deliberate split, and it is what makes the signal trustworthy:

- A generator that runs silently leaves a registry that is **confidently
  wrong** when it half-fails. A registry that is visibly behind is a worse
  look and a better state.
- The comparison itself cannot go stale. It is recomputed from the meetings
  every time it is asked, so there is no state to migrate and nothing to
  invalidate.

Field evidence for why the signal is needed at all: in one repository the
regeneration was a documented last step after every meeting, and it was
forgotten **within a day** of the last meeting. The step did not need a better
memory; it needed something that compares.

## Use

```bash
# what is behind?
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --check

# apply it, then read the diff before committing
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --write
```

At session start a hook prints one line when something is behind, and nothing
otherwise. It never fires per-write: every edit to a meeting file makes the
registry stale by definition, so a per-write reminder would be permanently on,
and a reminder that is always on is one nobody reads.

## The wording is yours

Everything this generator writes into the project — table headers, the "no
meetings yet" placeholder, the pointer's sentence — comes from `comms.labels`:
`"en"` (default), `"ru"`, or an object overriding individual keys, merged over
English. Titles, topic names and dates are the project's own data and are never
translated.

Set it before the first `--write`, or the first rebuild lands in a language the
repository does not use and the second one rewrites every generated file again.

## Link style and columns

`.claude/vdm-plugins.json` → `comms`:

| Key | Values | Default |
|-----|--------|---------|
| `link-style` | `markdown` \| `wikilink` | `markdown` |
| `registry-columns` | any of `date`, `meeting`, `series`, `people`, `tracks`, `topics`, `materials`, in the order wanted | `date`, `meeting`, `series`, `tracks` |
| `series-columns` | the same set, for the table in each series file | `date`, `meeting` |

`wikilink` is for a repository kept as a note vault, where a code span or a
markdown link is not an edge of the graph: the meeting, each track (its
`index.md`, or `<track>.md`), each person (`<people-dir>/<slug>.md`, when the
profile exists), the series and every material become `[[…]]` links, with the
pipe escaped inside tables. In `markdown` mode tracks stay code spans, as they
always were — switching a project's output because another project asked for a
vault mode would be the plugin deciding something that was not its call.

`people` lists the meeting's `people:`, `topics` counts topics and says how many
are tails (`6 (+1 tail)`), `materials` links the other role files and the
transcript. An unknown column name is reported, not silently dropped.

## Insertion markers

Tables are written **between explicit markers** — nothing is guessed, and a
file without them is reported rather than rewritten:

```markdown
<!-- registry:start -->
<!-- registry:end -->
```

```markdown
<!-- meetings:start -->
<!-- meetings:end -->
```

`registry:*` goes in `INDEX.md`, `meetings:*` in a series file. Where the
table belongs inside those files is the project's call, so:

- **no `INDEX.md`** → reported as a note, never created. Whether the project
  wants a registry file is its decision.
- **`INDEX.md` without markers** → reported, never rewritten. Add the markers
  where the table should go.
- **first run on a repository that already generated its own tables** → the
  first `--write` reformats them to this plugin's columns. Expected, and worth
  saying out loud to the user before running it.

## Pointers

For every meeting × every track in its `tracks:`, when that track resolves to a
**directory**:

```
<track>/comms/<date>-<slug>-meeting.md
```

with `type: meeting-link`, the meeting's date, a link back to the meeting's
source file, a line of its other materials (agenda, prep, pitches, transcript),
and this track's topics. The source is `index.md` when it exists, otherwise
`agenda.md`, otherwise `prep.md` — so a meeting that has not happened yet still
gets a pointer, aimed at its agenda.

**Every link is computed from the directory of the file it is written into.** A
track can sit one, two or three segments deep, and a prefix like `../../` is
right for exactly one of those depths — the first version wrote it into every
pointer, and in a repository whose tracks are two segments deep every pointer
opened nothing (in a note vault, a click on one created an empty file). If a
pointer's link does not open, that is a defect to report, not a thing to patch
by hand: the next `--write` would put it back.

In `wikilink` mode a topic links to its own section — `[[…/index#Topic 3.
<name>|<name>]]` — when the meeting's body has that heading. The anchor is the
heading as written, read from the body, never composed; a topic without a
matching heading stays plain text.

Two rules keep this from damaging anything:

- A track that resolves to a **file** (`<track>.md`) gets no pointer — there is
  no `comms/` to put one in. It is named in the report instead, so the gap is
  visible rather than silent.
- A pointer file that this plugin did **not** generate (no `generated:
  vdm-comms` marker) is never touched, and is named in the report. Removing a
  stale pointer is likewise limited to files carrying that marker.

## Order of operations

1. `/vdm-comms:meetings` first if the linter is reporting errors — the
   generator reads the same frontmatter, so a broken meeting produces a broken
   row.
2. `--check`, and read it.
3. `--write`, then look at the diff.
4. Commit the generated files with the change that caused them, not separately:
   a registry committed on its own is a commit nobody can review.
