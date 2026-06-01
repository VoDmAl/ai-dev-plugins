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

<!-- For session-type: brainstorm | prd-prep — keep the Decision Log section
     below. For everything else, delete it; you can add it later if reasoning
     becomes load-bearing. -->

## Decision Log

### #1 / {{TODAY}} / {{FIRST_DECISION_TITLE}}

**Source:** {{user | assistant | both}}
**Context:** what was the question or option set
**Why:** rationale — including what was rejected and why
**Implication:** how this shapes the work going forward
**Cross:** см. Sidetrack #N (optional)

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
