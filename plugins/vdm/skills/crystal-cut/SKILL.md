---
name: crystal-cut
description: "Attempt to close (cut) a crystal workitem — transition status:in-progress → status:done. Sweeps all unchecked `- [ ]` items; blocks if any remain (Decision Log #4). Use when work on a crystal is complete and you're ready to finalize."
license: MIT
---

# crystal-cut - Close a Crystal

## Purpose

Transitions a crystal from `status: in-progress` to `status: done`. The
crystal-completion-guard PreToolUse hook
(`${CLAUDE_PLUGIN_ROOT}/scripts/crystal-completion-guard.sh`) enforces the
gate at the tool layer: any `- [ ]` checkbox in the workitem blocks the
transition (Decision Log #4 generalizes "completion discipline" — every
unchecked checkbox is an open obligation, not only sidetracks).

This skill is the orchestration layer above the gate: it sweeps the
workitem, surfaces the open items with the five resolution paths, then
performs the flip once the user has addressed each.

## Gate behavior (defense in depth)

Three layers enforce the same invariant (Decision Log #7):

1. **Primary** — PreToolUse hook on Write/Edit/MultiEdit for workitem
   files. Works in any project regardless of git. It evaluates the
   *post-edit* content, so it also fires on the **creating** Write: a brand-new
   file written straight at `status: done` must contain zero `- [ ]`, or the
   gate blocks it. (Relevant when importing an already-complete legacy doc —
   see `crystal-grow` → Migrating legacy docs.)
2. **Stop reminder** — `${CLAUDE_PLUGIN_ROOT}/scripts/crystal-stop-reminder.sh`
   surfaces open items at end-of-turn so the assistant doesn't drift.
3. **Backup (git only)** — pre-commit hook ships with `vdm-git` for
   downstream projects with git. See `/vdm-git:guard` for activation.

The gate is intentionally cheap to circumvent only via the five
resolution paths — there is no `--force` flag and no `--no-verify` shortcut
in this skill. If the gate seems wrong for a specific case, the right move
is to use one of the five paths (most likely `cancelled (reason: ...)`),
not to bypass.

## Five resolution paths (DL #9)

Each unchecked item must be addressed by one of:

| Path                              | When to use                                            |
|-----------------------------------|--------------------------------------------------------|
| `[x]` resolved                    | Done within this workitem — flip the checkbox          |
| `migrated → <slug>`               | Belongs elsewhere — move card to an existing crystal **or a new sibling you grow on the spot**, cross-link both sides |
| `cancelled (reason: ...)`         | Explicitly dropped — record rationale                  |
| `deferred (deadline: YYYY-MM-DD)` | Postponed to a date — surfaces again on/after deadline |
| `promoted-to-stem (→ <sibling>)`  | Побег outgrew stem — split into sibling crystal        |

For `migrated` / `cancelled` / `deferred` / `promoted-to-stem`: the
sidetrack card's `**Status:**` line is updated AND the inline `- [ ]`
marker is checked (`[x]`) since the obligation has been addressed in a
defined way. The gate counts checkboxes, not statuses — keeping the two
in sync is required.

## Behavioral protocol

When `/vdm:crystal-cut [slug]` is invoked:

### Step 1: Locate the target

If `slug` is supplied, target `<root>/<slug>/workitem.md` or
`<root>/<slug>.md`. If omitted, target the singleton active workitem (the
one with `status: in-progress`). Multiple actives → singleton violation,
warn before continuing.

### Step 2: Sweep unchecked items

Read the workitem. Collect every `- [ ]` line with its line number and the
section it appears under (`## Next actions`, `## Sidetracks → ### #N`,
inline Decision-Log discussion, etc.). Group by section for readability.

### Step 3: Present the sweep

```
🔪 crystal-cut sweep: <slug>

  ## Next actions (3 open):
    L478:  - [ ] Скаффолд hook scripts
    L479:  - [ ] Регистрация в hooks.json
    L482:  - [ ] PROJECT_CHANGELOG.md entry

  ## Sidetracks (1 open):
    #6. Reflexive case — этa сессия как канонический пример (L431)

Resolve each via one of: [x] resolved | migrated → <slug> |
cancelled (...) | deferred (date) | promoted-to-stem (→ <sibling>).
```

For each open item, propose the most likely resolution path based on
context (e.g. obviously-completed items → suggest `[x]`; long-deferred
items the user mentioned punting → `deferred`). Do not auto-flip without
confirmation — the user owns each path decision.

### Step 4: Apply resolutions

For each addressed item:
- `[x]` resolved → Edit the checkbox in place
- `migrated` → create card in target crystal (cross-link both ways), flip
  this checkbox `[x]`, update sidetrack `**Status:**`
- `cancelled` → flip checkbox `[x]`, update sidetrack `**Status:**`
  with the reason
- `deferred` → flip checkbox `[x]`, update sidetrack `**Status:**` with
  the deadline
- `promoted-to-stem` → run `crystal-grow` for the sibling, transfer the
  обязательство there, flip checkbox `[x]`, update sidetrack `**Status:**`

### Step 5: Flip status

Edit the frontmatter: `status: in-progress` → `status: done`. The
PreToolUse hook will let this through because the unchecked count is now
zero. If the hook still blocks, you missed an item — re-sweep.

Also bump `last-updated:` to today.

### Step 6: Soft hints (DL #22)

After a successful close, emit two soft hints — text-only, no auto-trigger:

```
✓ Crystal `<slug>` closed (status:done).

Consider:
  - /vdm:changelog — record this workitem's outcome in PROJECT_CHANGELOG.md
```

If the close addressed `N` resolved (not migrated/cancelled/deferred)
sidetracks where `N > 0`, additionally:

```
  - /vdm:learn — N resolved sidetracks may be candidates for knowledge capture
```

These are suggestions the user runs explicitly. Never auto-invoke.

## Examples

### Example 1: Clean close

User: `/vdm:crystal-cut auth-refactor`

Sweep finds zero unchecked items. Assistant flips frontmatter, emits the
two soft hints. Done in one round.

### Example 2: Resolve via mixed paths

Sweep finds 4 open items. Assistant proposes:
- "Update README" → `[x]` (already done in the last commit)
- "Add tracing" → `migrated → observability-pass`
- "Fix typo in deprecated API" → `cancelled (API will be removed in v3)`
- "Mobile UI variant" → `deferred (deadline: 2026-06-01)`

User confirms each. Assistant applies edits + flips status + emits hints.

### Example 3: Gate fires on premature cut

User flipped `status: done` manually in IDE without using `crystal-cut`.
The PreToolUse hook intercepts and emits the blocked-diagnostic. The
assistant explains the five paths and runs the sweep above to bring the
user back on rails.

### Example 4: Done with one loose end — split it into a new sibling

The work is feature-complete except a single trailing obligation that has no
existing home — e.g. `zero-inbox` shipped, but a commented-out cron line
needs a real scheduling pass later. The sweep finds one `- [ ]`. There is no
"done but for one thing" state — and there shouldn't be; the obligation has
to land somewhere. Decide among three paths:

- date-bound ("revisit after the next release") → `deferred (deadline: ...)`
- genuinely dropped → `cancelled (reason: ...)`
- a real follow-up with no home → **`migrated → <new-sibling>`**

The third is the case worth spelling out, because the target doesn't exist
yet:

1. `crystal-grow cron-scheduling-pass` — create the sibling first (it starts
   `status: in-progress`; this is fine, the singleton you're closing is about
   to go `done`).
2. Move the obligation into the new crystal's `## Next actions` (or a
   sidetrack card), and cross-link: the source card's `**Status:**` becomes
   `migrated → cron-scheduling-pass`, the new crystal notes `migrated from:
   zero-inbox`.
3. Flip the source `- [ ]` → `[x]` (the obligation is addressed — it now
   lives elsewhere).
4. Re-sweep: zero unchecked → flip `status: done`. Cut succeeds.

Don't grow a whole sibling for something that's really a `deferred` or
`cancelled` — a one-line follow-up rarely earns its own crystal. Reach for
migrate-to-new only when the loose end is itself a unit of work.

## Quality gates

- [ ] All `- [ ]` checkboxes addressed (gate would block otherwise)
- [ ] Sidetrack `**Status:**` lines match their checkbox resolutions
- [ ] `migrated` items have cross-links in both source and target
- [ ] Frontmatter `status: done` AND `last-updated: <today>`
- [ ] Two soft hints emitted (always changelog; learn if N>0 resolved sidetracks)

## Configuration

Shares the `crystal` config section with the other three crystal-*
skills. See `/vdm:crystal-grow` for sub-commands. Disabling
(`crystal off`) silences the reminder hooks but does **not** disable the
PreToolUse gate — the gate is unconditional. To fully disable, uninstall
the plugin.

## Reflexive case

`docs/tasks/crystal-design/workitem.md` was closed via this exact protocol
when the crystal-* suite reached v1. The act of closing it validated the
gate, the sweep, and the hint emission end-to-end. Read its final state
for a worked example of a clean cut.
