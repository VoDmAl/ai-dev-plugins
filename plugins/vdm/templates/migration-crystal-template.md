---
title: "Migration: legacy docs → crystal format"
slug: migration
description: "First-run migration of legacy task docs into the crystal folder-stem layout"
status: in-progress
session-type: maintenance
created: {{TODAY}}
last-updated: {{TODAY}}
---

# Migration — legacy docs → crystal format

> The first crystal in this project. `/vdm:crystal-migrate` created it as the
> runbook, progress tracker, and decision log for one-time onboarding: turning a
> pre-crystal pile of task docs into the canonical `<slug>/workitem.md` layout.
> Close it with `/vdm:crystal-cut migration` once every row below is resolved —
> then activate the project's real current workitem.

## Назначение

Restructure + audit, not a plain file-move (design-home DL #5). Every legacy
doc is triaged into one of three buckets and either migrated, attached as a
reference, or left in place with a note. Historic dates are preserved from the
source (design-home DL #6). This crystal holds the single **active** slot during
setup so the singleton invariant isn't violated by migrated in-progress items —
those come in paused/pre-work and get re-activated after the cut.

## Buckets (from the scan)

Filled in from `crystal-migrate-scan.sh`, refined by content read, confirmed by
the human in one review pass:

- **Workitems** (N) → `<slug>/workitem.md`, dates + `migrated-from` stamped.
- **References** (M) → `<owner-slug>/references/*`, `reference-for:` back-link.
- **Out-of-scope** (K) → reported, left in place (reusable assets, not task work).

## Decision Log

<!-- Local, per-project migration decisions. Slug choices, status remaps,
     reference attachments, link-rewrite scope. Cross-project lessons belong in
     the design-home crystal in cc-vdm-plugins, not here. -->

### #1 / {{TODAY}} / Migration scope + slug decisions

**Source:** both
**Context:** what the scan found; which slugs were chosen and why
**Why:** slug is a deliberate rename, not derived from old filenames (design-home DL #2)
**Implication:** `migrated-from` carries provenance for backward traceability

## Triage findings (require human decision)

<!-- The audit pass (design-home DL #5) surfaces these — each is a `- [ ]` so the
     crystal-cut gate blocks closing migration until every one is resolved. -->

- [ ] Non-canonical statuses to remap: <list>
- [ ] Stale in-progress / abandoned work to reclassify: <list>
- [ ] Orphan references (no owner workitem): <list>
- [ ] Link-integrity: references to migrated files that need rewriting (design-home Sidetrack #2)

## Next actions

- [ ] Migrate the workitem bucket (batch)
- [ ] Attach the reference bucket under owners
- [ ] Resolve every triage finding above
- [ ] `/vdm:crystal-cut migration`, then activate the real current workitem

## References

- `references/` — the scan output, any exported legacy artifacts worth keeping
- Design-home crystal: `cc-vdm-plugins` → `docs/tasks/crystal-migrate/workitem.md`
