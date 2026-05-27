---
name: crystal-bud
description: "Append a sidetrack (побег) to an active or routed-dormant crystal. Use proactively whenever a session surfaces an observation, deferred follow-up, or implicit dependency that isn't the current main goal — capturing now prevents loss under context pressure. Continuous capture is the assistant's job; the user reviews periodically."
license: MIT
---

# crystal-bud - Capture a Sidetrack

## Purpose

Records a побег (sidetrack) into a crystal workitem's `## Sidetracks`
section. The assistant captures continuously (no `AskUserQuestion`
confirmation per побег — that creates UX friction and Decision Log #3
chooses hybrid capture: assistant writes, user revises later in
`/vdm:docs-sync` Phase 0 or by editing the file directly).

Capture early, capture cheap. The cost of a redundant sidetrack is one line
in the file; the cost of a missed sidetrack is the entire reason the
crystal-* suite exists.

## When to bud (proactive triggers)

Bud whenever the conversation surfaces any of:

- An observation about adjacent code/behavior that isn't the current goal.
- A "we should also..." or "later we'll need to..." statement.
- An implicit dependency the assistant noticed while reading code.
- A reject/defer decision worth remembering (often pairs with a Decision
  Log entry — see `crystal-cave` for the format).
- A failed attempt with a useful diagnosis that doesn't fit the current step.

If unsure whether to capture — capture. False positives are cheap; the user
can mark them `cancelled` during review.

## Sidetrack card format (DL #5)

Each sidetrack is a numbered heading in `## Sidetracks`:

```markdown
### #N. <short title>

**Возникло в:** <section name or inline anchor in this workitem>
**Описание:** <one or two sentences>

**Status:** open
```

The status line uses one of the six lifecycle states from Decision Log #9:

| State                          | Meaning                                                |
|--------------------------------|--------------------------------------------------------|
| `open`                         | Captured, awaiting decision                            |
| `resolved`                     | Done within this workitem                              |
| `migrated → <slug>`            | Moved to another workitem (cross-link required)        |
| `cancelled (reason: ...)`      | Explicitly dropped via HITL with rationale             |
| `deferred (deadline: YYYY-MM-DD)` | Postponed until a target date                       |
| `promoted-to-stem (→ <sibling>)`  | Promoted into a sibling crystal (workitem split)    |

The `crystal-cut` gate recognizes all six as "closed enough" — only `open`
blocks done-transition (the gate actually checks `- [ ]` checkboxes; see
the inline marker convention below).

## Inline marker + bi-link (DL #5)

When the побег surfaced inline in the workitem text, leave a marker at the
spot of origin and back-link from the sidetrack card:

In the body of the workitem, where the побег came up:

```markdown
- [ ] см. Sidetrack #N
```

This `- [ ]` is the checkbox the `crystal-cut` gate counts. Resolving the
побег means flipping `[ ]` → `[x]` AND updating the sidetrack card's
`**Status:**` line.

In the sidetrack card itself, the `Возникло в:` line points back to the
section where the marker lives. Together they form a footnote/endnote pair.

## Routing (DL #16)

When the repo has one active crystal — append there, done.

When the repo has dormant crystals (Decision Log #11: `1 active + N dormant`),
classify the побег by topic before appending:

1. Match the побег's topic against each dormant crystal's `title` and
   recent sidetracks. If a high-confidence match exists → append to that
   dormant crystal and note `Routed to: <slug>` in the card.
2. Low confidence → default to active. Safe default: don't lose anything.

Misroutes are fixable post-hoc with `/vdm:crystal-bud --to <slug>` or by
manually moving the card.

The card always includes the routing decision explicitly, so the user can
see where it landed and revert:

```markdown
**Routed to:** auth-refactor (auto, confidence high)
```

## Behavioral protocol

When `/vdm:crystal-bud [text]` is invoked (or proactively triggered):

### Step 1: Locate target crystal

Resolve the crystal root via `${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh`,
find workitems with `status: in-progress` (singleton invariant — usually
one). If `--to <slug>` was supplied, target that workitem directly. If no
active crystal exists, propose `crystal-grow` first.

### Step 2: Determine next sidetrack number

Read the target workitem's `## Sidetracks`, find the highest `### #N`
heading, use `N + 1`. If the section doesn't exist yet, create it and
start at `#1`.

### Step 3: Append the card

Write the sidetrack card to the end of `## Sidetracks` using the format
above. Set `**Status:** open`. Add `**Routed to:**` only when routing into
a dormant crystal (i.e. not the singleton active).

### Step 4: Place the inline marker (when applicable)

If the побег surfaced inside the workitem's body text — typically inside
a Decision Log entry or a Next-actions discussion — insert
`- [ ] см. Sidetrack #N` at the spot of origin. Skip this step when the
побег came from outside the workitem (e.g. from a code observation
mid-implementation); in that case just `Возникло в: implicit (round N)`
in the card.

### Step 5: TaskCreate (DL #21)

Add a Task mirroring the new sidetrack as ephemeral visualization. Tasks
sync events for the crystal suite are: `crystal-grow` populates initial,
`crystal-bud` adds one, `crystal-cut` reconciles at close. File remains
source of truth — UI ticks don't write back.

### Step 6: Brief confirmation

One line, no fanfare:

> 🌿 Sidetrack #N → `<slug>`: <short title>

## Examples

### Example 1: Proactive capture mid-implementation

Assistant is implementing a feature, reads adjacent code, notices a stale
TODO. Without waiting for user prompt, bud:

> 🌿 Sidetrack #4 → auth-refactor: legacy TODO in `Token::refresh()` mentions a removed flag

Card written, Task added, work continues on the main thread. User reviews
in next `/vdm:docs-sync` Phase 0.

### Example 2: Explicit user invocation with routing

User: `/vdm:crystal-bud --to billing-rewrite пересмотреть rounding для multi-currency`

Card lands in `docs/tasks/billing-rewrite/workitem.md` (dormant) rather
than the active `auth-refactor`. `**Routed to:** billing-rewrite (explicit)`.

### Example 3: Auto-route to dormant by topic

User mentions a Stripe webhook issue while assistant is working on the
active `auth-refactor` crystal. Dormant `stripe-webhook-rewrite` exists.
Assistant routes there with confidence note:

> 🌿 Sidetrack #2 → stripe-webhook-rewrite (auto-routed): retry-after header parsing

## Quality gates

- [ ] Card has all four required lines (heading, Возникло в:, Описание:, Status:)
- [ ] Inline `- [ ] см. Sidetrack #N` placed when the побег surfaced in the body
- [ ] Routing decision explicit in `**Routed to:**` whenever non-default
- [ ] TaskCreate fired for the new sidetrack
- [ ] `last-updated:` frontmatter date bumped to today

## Configuration

Shares the `crystal` config section with the other three crystal-* skills.
See `/vdm:crystal-grow` for sub-commands. Disabling via `crystal off`
silences the auto-promotion proposal but does **not** suppress
`crystal-bud` — capture is the cheap operation; the gate is the expensive
one.
