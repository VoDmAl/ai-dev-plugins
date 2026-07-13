---
title: "{{TITLE}}"
slug: {{SLUG}}
# description: <one-liner for cave/base overview>   # optional, surfaces in crystal-cave overview rows
# status: canonical taxonomy (DL #10 in crystal-multi-root)
#   Pre-work — idea, draft, ready (in cave Backlog; no singleton)
#   Active   — in-progress         (in sweeps; singleton enforced)
#   Paused   — blocked, dormant    (in cave Paused; not in sweeps)
#   Terminal — done, cancelled, superseded (hidden; `done`/`superseded` gated)
status: in-progress
session-type: {{SESSION_TYPE}}
created: {{TODAY}}
last-updated: {{TODAY}}
# superseded-by: <slug>   # required when transitioning to status: superseded
---

# {{TITLE}}

> Brief opening paragraph: what this workitem is for, why it exists, who/what
> triggered it. Keep this section terse — details belong in the body.

## Назначение

One or two paragraphs on the goal. State the problem, name the constraint,
identify the success criterion. Reference incoming context (a chat session,
a Jira ticket, a code symptom) so future-you can reconstruct intent.

## Текущая модель

<!-- The live section: what we believe to be true RIGHT NOW. The Decision Log
     below is append-only history; this block is the only place that is allowed
     to be rewritten in place — and it MUST be, whenever a DL entry supersedes
     an earlier one (see crystal-grow → "Superseding a decision").

     Without this block a cold reader (or the assistant after a compaction)
     meets the overturned decisions first, in chronological order, and has to
     reconstruct the current truth by replaying the whole log. -->

- What we know, and how we know it. Keep it short; this is the answer to
  "if I read one section, which one tells me where things actually stand?"

<!-- For session-type: brainstorm | prd-prep — keep the Decision Log section
     below. For everything else, delete it; you can add it later if reasoning
     becomes load-bearing. -->

## Decision Log

### #1 / {{TODAY}} / {{FIRST_DECISION_TITLE}}

**Source:** {{user | assistant | both}}
**Basis:** {{observed | user-stated | inferred | assumed}}
**Basis-detail:** what was actually seen, or what this was derived from. If
`inferred` / `assumed` — say explicitly what was NOT checked.
**Context:** what was the question or option set
**Why:** rationale — including what was rejected and why
**Implication:** how this shapes the work going forward
**Cross:** см. Sidetrack #N (optional)
**Supersedes:** #N, #M (only on an entry that overturns earlier ones)
**Superseded-by:** #N (only on an entry that has been overturned)

## Sidetracks

<!-- Each sidetrack is a numbered heading. The crystal-bud skill appends here.
     The crystal-cut gate sweeps `- [ ]` checkboxes in this section (and
     elsewhere in this file) and blocks done-transition while any remain. -->

### #1. {{SIDETRACK_TITLE}}

**Возникло в:** {{section name or inline anchor}}
**Описание:** one or two sentences

**Status:** open

## Next actions

Блокирующий tail — все unchecked items here block `crystal-cut` for this
workitem (Decision Log #4).

- [ ] First concrete action
- [ ] Second concrete action

## References

- `references/` — original sources (specs, screenshots, exported transcripts)
- External links (URLs, ticket IDs) go here too

<!-- Provenance rule — «чат не хранилище»: an artifact a Decision Log entry
     rests on lands in `references/` BEFORE that entry is written, not after.
     Screenshots, exports, ticket text, API response dumps, log excerpts —
     if a conclusion stands on it, it is saved at the moment it is received.
     Chat scrollback is not storage: it is truncated by compaction, and
     pasted images are the first thing to go. -->

<!-- Delete the boilerplate above once real references accumulate. -->

