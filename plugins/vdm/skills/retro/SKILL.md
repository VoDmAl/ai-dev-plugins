---
name: retro
description: "Retrospective of the shared rules layer (~/.claude/vdm/rules.md) across every session on this machine: which rules still fail in sessions they reached, which failures repeat in two or more projects with no rule, which rules catch the same failure. Reads the owner's turns from the harness transcripts; proposes edits to the layer with the evidence. Use when the owner asks whether the rules work, before curating the layer, when it nears its byte budget, or about once a month. Triggers include: «ретро», «ретроспектива», «работают ли правила», «что повторяется», «проверь правила по диалогам», retrospective, retro, do the rules work, recurring corrections."
license: MIT
---

# retro — do the shared rules work?

## Purpose

The shared rules layer reaches every session on the machine, and a rule enters it
one field case at a time (`/vdm:learn` → "Cross-project rules"). Two questions
then have no answer from inside any session, because no session sees another:

1. **Does a rule work?** Did its failure stop where the rule was delivered?
2. **Is a failure repeating with no rule?** `learn` adds a rule when the same
   failure is caught in a second project. Seeing the second project took the
   owner's memory until now.

The harness keeps every session as a transcript, and the facts are already in
it: who typed each turn, what the assistant said before it, and which rules the
session received. The last one is the session's own `SessionStart` attachment,
not a rule's `Origin` date. On this machine the layer reached sessions only as
a harness preview from 2026-10-01 to 2026-10-07 (crystal `rules-retro`, DL #3).
A rule counted from its date would be charged with failures in sessions that
never saw it.

**What it does not see.** Successes, where a rule prevented the failure. Silent
fixes, where the owner corrected the text themselves. And a rule with no
corrections: zero, read through a sample, says nothing, so it is never by itself
a reason to remove a rule.

**The harness deletes old transcripts.** Claude Code does by `cleanupPeriodDays`,
30 days by default. Whatever falls out of that window is lost to the next
retrospective, so run it about once a month.

## Step 1 — the corpus, first pass: the owner's turns only

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/retro-corpus.py" --assistant-cap 0
```

It prints where it wrote and a table: for each rule heading, how many sessions
received it and how many of the owner's turns those sessions hold. Keep that
table. It is the denominator every count below is read against. The output
directory holds `layers.md` (each distinct set of delivered rules, `L1`, `L2`, …;
`L0` is "no layer") and `chunk-NNN.md` files. Each entry in a chunk is headed
`### <id> · <project> · <date> · <layer>`.

**The chunks hold people's names and other projects' words.** They stay in the
temp directory the script chose. Never copy one into a repository, and delete
them when the retrospective is done.

A harness whose transcripts are not in this format yields nothing. The script
says so and exits 2. Point `--projects-dir` at another store only if it has the
same records.

## Step 2 — pick the corrections

Read every chunk. Where the harness can run helpers in parallel, give each one or
two chunks, the text of the rules layer and these instructions. Otherwise read
the chunks in turn. A keyword filter is not a substitute: in the pilot it caught
about one known case in six.

A **correction** is a turn in which the owner corrects how the assistant
worked: what it claimed, asked, sent, skipped, or left to the owner. These are
not corrections:

- a task, a new instruction, or an answer to the assistant's question;
- pasted output in which a word only sounds like a reproach;
- the owner correcting themselves.

Return one line per correction, `<id> — <what was corrected, in a few words>`.
Unsure goes in with `?`. Write all lines to one file.

## Step 3 — read the picks with what they answered

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/retro-corpus.py" --only <picks file> --assistant-cap 2000
```

For each pick, decide:

- **which rule it is a failure of**, by heading, or **none**, with a theme in a
  few words;
- **whether that rule was delivered** to the session: the entry's layer id
  against `layers.md`;
- **the project and the date**, from the entry header.

The `?` picks are settled here, with the context, or dropped.

## Step 4 — the report

Write it outside any repository, next to the chunks. It names people and
projects. Every number carries its scope: "in N of the owner's turns from
<date> to <date>".

1. **Denominator.** Turns read, corrections found, picks dropped as not
   corrections.
2. **Per rule.** Sessions it reached (from Step 1). Corrections in those
   sessions, with their projects. Corrections in sessions it did not reach,
   counted apart: they show the pattern existed, not that the rule failed.
3. **Failures with no rule**, clustered by theme. For each cluster: the entries,
   the number of distinct projects, and a candidate rule in one sentence. A
   cluster in two or more projects meets `learn`'s criterion.
4. **Overlaps.** Pairs of rules whose corrections are the same failure. Name the
   entries that show it.

## Step 5 — what to change in the layer

The findings go to the deep pass of `/vdm:learn` → "Cross-project rules", as
lessons to fold: the fold may rewrite, widen or merge rules, and it shows the
owner any change to what sessions receive before it is installed. For each
finding give the fold its evidence from the report:

| Finding | What the fold is asked |
|---|---|
| a rule's failure repeats in sessions it reached | the first paragraph is all a session sees: make it catch this case |
| a cluster in two or more projects | a behaviour with no rule: widen one that is close, or add one |
| two rules catch one failure | say it once |
| a rule with no corrections | nothing; say so in the report |

The deep pass runs in the repository that ships vdm. From any other project,
brief that agent with the report's numbers (no names):
`/vdm:intercom send vdm rules-deep-pass-due`.

## Reflexive case

The first retrospective is in the crystal that built this skill:
`cc-vdm-plugins → docs/tasks/rules-retro/workitem.md` (upstream, not in your
project). Its pilot read 226 keyword-picked turns. 83 of them were corrections.
Three failures with no rule turned up in four or five projects each. And some
"repeats" of rules turned out to come from sessions those rules never reached.
