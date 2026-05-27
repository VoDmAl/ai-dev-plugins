---
name: crystal-cave
description: "View — list all crystals (active + dormant) with their open sidetracks and decision-log summaries. The geological-cave naming inverts the obvious 'list/show' command (Decision Log #14) — it's the read-side counterpart to grow/bud/cut. Use when surveying repo state or resuming after time away."
license: MIT
---

# crystal-cave - Inspect Crystals

## Purpose

Read-only view across all crystals in the repo. Three modes depending on
argument:

| Invocation                       | Mode                                      |
|----------------------------------|-------------------------------------------|
| `/vdm:crystal-cave`              | Overview — all crystals, summary form     |
| `/vdm:crystal-cave <slug>`       | Detail — full workitem state with sidetrack and DL summaries |
| `/vdm:crystal-cave --sidetracks` | Filter — all open sidetracks across all crystals |

No file edits. Pure presentation.

## Why "cave" not "list"

Decision Log #14: ювелирная огранка (cut) is paired with геологические
кристальные пещеры (cave) — "let's go look inside." The slight inversion
forces a half-second pause that helps recall versus the autopilot
`/list` / `/show` commands. Same reason `bud` beats `branch` and
`cut` beats `close`.

## Overview mode

`/vdm:crystal-cave` with no arguments. Output structure:

```
🔮 Crystals in this repo (root: docs/tasks/):

  Active (1):
    auth-refactor          3 open · 2 sidetracks · brainstorm · created 2026-05-12
    └─ docs/tasks/auth-refactor/workitem.md

  Dormant (2):
    billing-rewrite        1 open · 4 sidetracks · prd-work · last-updated 2026-04-30
    └─ docs/tasks/billing-rewrite/workitem.md
    observability-pass     0 open · 0 sidetracks · research · last-updated 2026-05-22
    └─ docs/tasks/observability-pass/workitem.md

  Done (5): crystal-design, stripe-webhook-rewrite, ...
```

Counts come from the same helpers the hooks use
(`${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh` — `count_unchecked`,
`extract_frontmatter_field`).

A multi-active state (singleton violation, Decision Log #11) shows as:

```
  ⚠ Singleton violation: 2 active crystals (should be 1)
    auth-refactor
    billing-rewrite
```

## Detail mode

`/vdm:crystal-cave <slug>` — full state for one workitem:

```
🔮 auth-refactor (active · brainstorm)
   Path: docs/tasks/auth-refactor/workitem.md
   Created: 2026-05-12   Updated: 2026-05-27

   Next actions (3 open / 7 total):
     [ ] Migration script for legacy tokens
     [ ] Update OAuth callback handlers
     [ ] Add integration tests for refresh flow

   Sidetracks (2 open / 4 total):
     #1. Token validation race  — open
     #2. Remove dead AuthProvider class — open
     #3. Migrate to PKCE — deferred (deadline: 2026-07-01)
     #4. Move to JWE — cancelled (out of scope for this workitem)

   Decision Log (6 entries):
     #1 / 2026-05-12 / Use refresh-token rotation
     #2 / 2026-05-13 / In-memory session store, not Redis
     #3 / 2026-05-14 / ...
```

When the workitem has no `## Decision Log` section (typical for non-
brainstorm types), omit that block entirely rather than show an empty
section.

## Sidetracks-only mode

`/vdm:crystal-cave --sidetracks` — flatten all open sidetracks across
all crystals into one list, useful when scanning for things to address
during a review session:

```
🌿 Open sidetracks (across all active + dormant crystals):

  auth-refactor:
    #1. Token validation race
    #2. Remove dead AuthProvider class

  billing-rewrite:
    #3. Rounding for multi-currency
```

## Behavioral protocol

When `/vdm:crystal-cave [args]` is invoked:

### Step 1: Determine mode

- No args → Overview
- `--sidetracks` flag → Sidetracks-only
- Single positional arg matching an existing slug → Detail mode for that slug
- Single positional arg with no match → "no such crystal" + nearest-match hint

### Step 2: Read state

Resolve the root, run `find_workitems`, classify each by
`extract_frontmatter_field <file> status` into active / dormant / done /
other. Read enough of each to count unchecked items and parse
`## Sidetracks` headings.

### Step 3: Render

Pick the template above matching the mode. Use real file paths the user
can open. Use today's date arithmetic for "N days ago" only if helpful;
otherwise show raw `last-updated:` values.

### Step 4: No edits

This skill writes nothing. If the user wants to act on what they see,
they invoke `/vdm:crystal-bud`, `/vdm:crystal-cut`, or edit the workitem
directly.

## Examples

### Example 1: Resume after a week away

```
User: /vdm:crystal-cave

🔮 Crystals in this repo (root: docs/tasks/):

  Active (1):
    auth-refactor    3 open · 2 sidetracks · brainstorm · updated 2026-05-19

  Dormant (1):
    billing-rewrite  1 open · 4 sidetracks · prd-work · updated 2026-04-30

  Done (3): ...
```

User reads the line, decides to keep working on `auth-refactor`, opens the
workitem.

### Example 2: Drill into a specific crystal

```
User: /vdm:crystal-cave billing-rewrite

🔮 billing-rewrite (dormant · prd-work)
   Path: docs/tasks/billing-rewrite/workitem.md
   ...
```

### Example 3: Review-mode sweep

User is doing a 30-minute review. Wants the full open-sidetrack surface
area:

```
User: /vdm:crystal-cave --sidetracks
```

Output above. User then picks 2–3 sidetracks to resolve via direct edits
or migrations.

## Quality gates

- [ ] No file writes anywhere (read-only invariant)
- [ ] Counts match what hooks would report (same helpers, same data)
- [ ] Singleton violations surfaced explicitly when present
- [ ] Path lines are real and openable from the user's editor

## Configuration

Shares the `crystal` config section with the other three crystal-*
skills. See `/vdm:crystal-grow` for sub-commands. Disabling
(`crystal off`) silences the hooks but `/vdm:crystal-cave` keeps working
— the cave is for visibility and visibility should not be disabled by a
plugin toggle.
