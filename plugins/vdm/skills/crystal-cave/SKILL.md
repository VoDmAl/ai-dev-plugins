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
| `/vdm:crystal-cave`              | Overview — Active / Paused / Backlog tiers (Terminal hidden) |
| `/vdm:crystal-cave --all`        | Overview + Terminal tier (done / cancelled / superseded)     |
| `/vdm:crystal-cave <slug>`       | Detail — full workitem state with sidetrack and DL summaries. In multi-root mode pass qualified slug (`<root>/<slug>`) |
| `/vdm:crystal-cave --sidetracks` | Filter — all open sidetracks across all crystals |

No file edits. Pure presentation, except for the `alias permanently` action
in the Non-canonical triage section which patches `.claude/vdm-plugins.json`
(same surface as `/vdm:crystal-grow status-alias add`).

## Why "cave" not "list"

Decision Log #14: ювелирная огранка (cut) is paired with геологические
кристальные пещеры (cave) — "let's go look inside." The slight inversion
forces a half-second pause that helps recall versus the autopilot
`/list` / `/show` commands. Same reason `bud` beats `branch` and
`cut` beats `close`.

## Overview mode

`/vdm:crystal-cave` (optionally with `--all`) is rendered by a dedicated
script — `${CLAUDE_PLUGIN_ROOT}/scripts/crystal-cave.sh`. The assistant
invokes it once and prints its stdout verbatim. Do **not** improvise an
ad-hoc `for f in **/workitem.md; do ...` loop — the script knows about
the resolver, hidden-segment exclusion, alias resolution, tier ordering,
and column alignment in a way the assistant should not re-derive on the
fly.

Layout is **by-root grouping** with status icons, no per-row path lines:

Single-root example:
```
🔮 Crystals in docs/tasks · 1 active · 0 paused · 2 backlog · 5 done
   /vdm:crystal-cave --all   /vdm:crystal-cave <slug>

  ● auth-refactor       prd-work    2026-05-12
  ○ migrate-redis       task        2026-05-10
  ◦ legacy-cleanup                  2026-04-30

Done: 5 crystals (use /vdm:crystal-cave --all for details)

Legend: ● active · ⏸ paused · ○ ready · ◦ idea
```

Multi-root example (each root that has visible workitems gets a group
header; alphabetical between groups, alphabetical between rows):
```
🔮 9 roots · 2 active · 6 paused · 18 backlog · 8 done
   /vdm:crystal-cave --all   /vdm:crystal-cave <slug>

amazon-orders (1 paused · 1 ready)
  ⏸ orders-pipeline   prd-work      2026-05-31
  ○ relink-pass-v2    maintenance   2026-05-25

receipt-pipeline (1 active · 2 ready)
  ● finansy-migration         prd-work      2026-05-31
  ○ relink-receipt-cards      maintenance   2026-05-30
  ○ rerun-existing-archives   maintenance   2026-05-30

statement-pipeline (1 active · 2 paused · 3 ready · 1 idea)
  ● phase-2-gap-fill               prd-work    2026-05-31
  ⏸ tax-form-migration-extension   prd-work    2026-06-01
  ⏸ multi-account-refactor         prd-work    2026-05-31
  ○ citi-structured-parsing        short-bug   2026-05-27
  ◦ peo-vs-employer-modeling                   2026-05-26

Done: 8 crystals (use /vdm:crystal-cave --all for details)

⚠ Non-canonical statuses: 14 workitems. The assistant will offer remap targets.

Legend: ● active · ⏸ paused · ○ ready · ◦ idea
```

Each row carries: icon (status-tier) · short slug · type · `last-updated`.
The qualified slug (`<root>/<short-slug>`) is implicit — the group header
supplies the prefix, the indented icon row supplies the suffix. Paths are
not printed; users open files through their editor's go-to-file by slug.

**Within-group ordering:** active first, then paused (most-recent first),
then ready/draft, then idea — date desc inside each tier so the line you
care about is near the top of each group. Group-level ordering is
alphabetical so the same root appears in the same place between runs.

**Icons & tier mapping:**

| Icon | Tier     | Statuses                          | In Overview        | Singleton |
|------|----------|-----------------------------------|--------------------|-----------|
| ●    | Active   | `in-progress`                     | Always             | Enforced (per derive_singleton_mode) |
| ⏸    | Paused   | `blocked`, `dormant`              | Always             | No        |
| ○    | Pre-work | `ready`, `draft`                  | Always             | No        |
| ◦    | Pre-work | `idea`                            | Always             | No        |
| ✓    | Terminal | `done`, `cancelled`, `superseded` | Only with `--all`  | No        |
| !    | Non-canonical | anything else                | Separate section   | Audit required |

**Which date to show (rule, not judgment):** overview rows uniformly show
`updated` (the `last-updated:` frontmatter value) across all tiers —
recency is the "what do I resume?" signal. `created:` is shown only in
**detail mode**, which prints both (`Created: … Updated: …`).

**Description rendering (optional field):** when a workitem's frontmatter
carries the optional `description:` one-liner (added in vdm v2.5.2), the
script appends it after the row as `  — "<description>"`. When absent or
empty, the row stays unchanged — no placeholder, no quotes.

**Type column hidden for idea rows:** `idea` rows skip the `type` column
(the status implies the type) so the date stays aligned across the group.
If every row in a group is `idea`, the script collapses the column away
entirely.

All counts and tier classifications come from the same helpers the hooks
use (`${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh` — `count_unchecked`,
`extract_frontmatter_field`, `derive_status_tier`, `_apply_status_alias`).

### Singleton violations

A multi-active state surfaces as a header line scoped by singleton mode
(`derive_singleton_mode`):

```
  ⚠ Singleton (global) violation: 2 active crystals (should be 1)
    auth-refactor
    billing-rewrite
```

In per-root mode (multi-root setups), the violation is reported per
affected root:

```
  ⚠ Singleton (per-root) violation: root `auth` has 2 active workitems
    auth/refactor-jwt
    auth/session-cleanup
```

### Non-canonical section

Any workitem whose `status:` falls outside the canonical taxonomy (after
status-alias resolution) gets a dedicated triage section with proposed
remap targets:

```
⚠ Non-canonical (requires resolution):

  projects/x/tasks/foo.md: status="WIP"
    → [in-progress] [ready] [blocked] [skip] [alias permanently: WIP=in-progress]

  projects/y/tasks/bar.md: status="archived"
    → [done] [cancelled] [superseded] [skip] [alias permanently: archived=done]
```

The user chooses one path per file. `alias permanently` writes
`status-aliases.<from> = <to>` to `.claude/vdm-plugins.json` and the
workitem stays untouched (the alias resolves at read time across all
crystal-* skills and hooks). `skip` defers — the file stays non-canonical
until next audit. The skill itself never silently rewrites status.

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

- No args (or `--all`) → Overview (script-rendered)
- `--sidetracks` flag → Sidetracks-only (assistant-rendered, see below)
- Single positional arg matching an existing slug → Detail mode (assistant-rendered)
- Single positional arg with no match → "no such crystal" + nearest-match hint

### Step 2: Overview → invoke the script, print verbatim

For Overview mode (with or without `--all`), run
`${CLAUDE_PLUGIN_ROOT}/scripts/crystal-cave.sh [--all]` and print its
stdout verbatim. The script handles resolver, tier classification,
icons, alignment, group ordering, singleton warnings, and the
non-canonical drift footer.

**Do not** re-implement this in the chat with `for f in ...; do echo`
loops, `find ... -name workitem.md`, or per-file `head` of frontmatter.
Those bypass the resolver's exclusion rules and produce non-deterministic
output between sessions.

After printing, if the script's output included a non-canonical drift
warning (line beginning with `⚠ Non-canonical statuses:`), the assistant
follows up with the Non-canonical triage section below — surfacing each
non-canonical file with remap options, one decision per file. This is
the only part of Overview mode that needs assistant interaction beyond
verbatim print.

### Step 3: Detail / Sidetracks → assistant-rendered

`detail` mode (slug argument) and `--sidetracks` mode stay assistant-
rendered for now. Use the lib helpers (`extract_frontmatter_field`,
`count_unchecked`) on the resolved workitem path. The templates above
specify the layout. Future iteration may push these into the script too.

### Step 4: No edits

This skill writes nothing. If the user wants to act on what they see,
they invoke `/vdm:crystal-bud`, `/vdm:crystal-cut`, or edit the workitem
directly.

## Examples

### Example 1: Resume after a week away

```
User: /vdm:crystal-cave

🔮 Crystals in docs/tasks · 1 active · 0 paused · 0 backlog · 3 done
   /vdm:crystal-cave --all   /vdm:crystal-cave <slug>

  ● auth-refactor   brainstorm   2026-05-19

Done: 3 crystals (use /vdm:crystal-cave --all for details)

Legend: ● active · ⏸ paused · ○ ready · ◦ idea
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
