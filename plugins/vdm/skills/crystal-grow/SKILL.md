---
name: crystal-grow
description: "Start (or promote) a crystal — an in-repo workitem under <root>/<slug>/workitem.md that anchors long-running sessions and prevents loss of sidetracks, decisions, and deferred promises. Roots auto-discovered (any `tasks/` dir, hidden segments excluded) or explicitly listed in config. Invoke when a session is widening into research, brainstorm, PRD work, or any flow likely to spawn 3+ branches."
license: MIT
---

# crystal-grow - Start or Promote a Crystal

## Purpose

Creates a new workitem (full crystal) under the configured crystal root, or
promotes an in-flight shadow workitem to a full file-backed one. A crystal
captures three things a chat transcript loses under context pressure:

1. **Sidetracks** — observations and follow-ups that aren't the main goal.
2. **Decisions** — what was chosen, what was rejected, and why.
3. **Open obligations** — unchecked items that must be addressed before the
   workitem is "done."

The crystal-completion-guard hook enforces that the workitem cannot
transition to `status: done` while any unchecked `- [ ]` items remain
(Decision Log #4). The other three skills (`crystal-bud`, `crystal-cut`,
`crystal-cave`) operate on the file this skill creates.

## Three levels of depth (DL #12)

Not every session needs a workitem file:

- **Plain** — simple Q&A. Nothing persisted.
- **Shadow** — assistant tracks sidetracks in working memory; no file yet.
  Ready to promote on user request or when thresholds trip.
- **Full crystal** — file exists, frontmatter `status: in-progress`, gate
  active. This is what `crystal-grow` creates.

The assistant starts in **Plain**, escalates to **Shadow** at the first
scope-creep signal, and proposes promoting to **Full** when the auto-promotion
threshold for the current session type is reached.

## Auto-promotion threshold (DL #19)

The assistant classifies the session type from the first 1–3 user messages
(ambiguous → conservative default `other`). The user can override at any
time by editing the workitem's `session-type:` frontmatter — or by stating
intent explicitly ("давай заведём", "это большая задача", "сделаем PRD"),
which immediately promotes regardless of counter state.

| Session type   | Promotion trigger (shadow → full)                  |
|----------------|----------------------------------------------------|
| `brainstorm`   | immediate (1 sidetrack OR 2 tool calls)            |
| `prd-prep`     | immediate (from the first message)                 |
| `prd-work`     | already promoted (a workitem exists)               |
| `research`     | 4+ tool calls OR 2+ sidetracks OR 15+ min          |
| `short-bug`    | 6+ tool calls OR 3+ sidetracks OR 25+ min          |
| `maintenance`  | 8+ tool calls                                      |
| `review`       | 3+ sidetracks                                      |
| `docs-only`    | 5+ tool calls AND 2+ sidetracks                    |
| `other`        | 5+ tool calls AND 2+ sidetracks (conservative)     |

Counters live in the assistant's working memory only — there's no
state file. Restarting the session resets them; an active full crystal
survives because it's in `docs/tasks/`.

When the threshold trips, propose explicitly:

> Это похоже на `<session-type>` со сложностью выше порога. Предлагаю завести
> crystal: title=`<draft>`, slug=`<kebab>`. Содержимое shadow-сайдтреков
> сразу попадёт в Sidetracks. Создавать?

## Forced-promotion signals (override the counter)

DL #19 above handles *organic scope-creep* — start small, grow past a gate.
The signals below handle the opposite case: sessions *born* as planning
work, where the counter lags and the plan ends up in chat instead of
`workitem.md`. Any one triggers immediate promotion regardless of counter
state. When two or more co-occur, propose grow *before* the substantive
answer, not after.

### (1) Trigger-phrase whitelist — immediate `prd-prep` / `prd-work`

If the user's message contains any of these, classify accordingly and
propose grow:

- **RU:** «нужен план», «дай план», «давай менять структуру», «миграция X»,
  «оценить объём», «проведём X», «оцени изменения», «сначала план»,
  «сделаем PRD», «распиши что будем менять», «разложи по этапам».
- **EN:** «I need a plan», «let me see the plan», «migrate X», «restructure»,
  «estimate scope», «walk me through the changes», «break this down»,
  «PRD this», «scope this out», «start with a plan».

The list isn't exhaustive — any phrasing demanding a plan/PRD/scope/migration
artifact *before* the work qualifies. False-positive promotion is cheaper
than false-negative loss.

### (2) Step-0 reflex — before the substantive answer

Before drafting a plan-shaped response, ask: «Если я отвечу сейчас — ответ
попадёт в `workitem.md` или останется в chat?» If "stays in chat" *and* the
response is plan-shaped, stop and propose grow first. Then write the
substantive answer *into* the new workitem, not the chat.

Temporal order matters. The DL #19 flow says "when the threshold trips,
propose explicitly" but doesn't specify *before vs. after* the first
substantive answer. The first answer *is* the plan; if it lands in chat,
the plan is born homeless and the next compaction takes it.

### (3) Plan-shape anti-pattern — ≥5 / ≥3 / ≥2

If a chat draft contains **any** of:

- ≥5 steps (numbered/bulleted procedure)
- ≥3 architectural decisions (this-vs-that with rationale)
- ≥2 HITL questions for the user

— that draft is already a workitem. Stop, propose grow, continue *in-file*.
The next compaction collapses 5 steps to one synopsis sentence, decisions
to "discussed alternatives", HITLs to "some open items remained". The cost
of *not* relocating is the cost of the next compaction.

### (4) Context-pressure escape valve

If the visible conversation crosses ~50% of the context window with no
workitem for the current line of work, auto-propose grow. Frame as
defensive, not procedural:

> Контекст наполнился ~50% без workitem'а. Следующая компактизация съест
> decisions и побеги — останется только сводка. Предлагаю завести crystal
> сейчас. Slug?

### Why "forced" matters

DL #19 is *organic-creep detection*: fires when a session that started
small grew past a counter. The four signals above are *first-sight
detection*: fire when the session was *born* as planning. Both modes are
real and need separate hooks. Field report (the session that shipped
multi-root): all four signals were overdetermined from message #1 —
explicit «давай проведём миграцию», explicit «сначала нужен план», 5+
steps in the first substantive response, 2+ HITLs in that same response.
Yet counter-based logic kept the workitem in shadow for three turns
because no *counter* threshold had ticked. The plan was drafted in chat
when it should have been in `workitem.md` from the start.

## Storage layout (DL #2, #18, #20, #12 in crystal-multi-root)

- **Roots** resolve through `resolve_crystal_roots()` in
  `${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh`, in priority order:
  1. `crystal.paths` (array of globs) — explicit override.
  2. `crystal.path` (string, legacy single root) — back-compat.
  3. **Auto-scan** — any `tasks/` directory under project root, excluding
     hidden segments (`.git/`, `.stversions/`, `.obsidian/`, etc.) and
     common dependency dirs (`node_modules/`, `vendor/`). This is the
     default and works for classic single-root setups (finds `docs/tasks/`)
     AND monorepo / vault layouts (finds `packages/*/tasks/`, etc.).
- **Folder-style** (canonical, DL #12 in crystal-multi-root):
  `<root>/<slug>/workitem.md` plus optional `<root>/<slug>/references/`,
  `<root>/<slug>/attachments/`, etc. **This is the only layout we
  recommend for new workitems.**
- **Flat-style** (legacy): `<root>/<slug>.md` — recognized for back-compat
  with pre-suite single-file notes; the gate still applies. Don't create
  new flat workitems — promote to folder-style during onboarding.
- **Leaf is `tasks/`** (DL #1 in crystal-multi-root) — not configurable.
  Projects using `tickets/`, `issues/`, `workitems/` are out of scope.

### Cross-referencing workitems (wikilink form)

After folder-migration all workitems share basename `workitem.md`. Bare
`[[<slug>]]` wikilinks don't resolve under Obsidian's shortest-path matcher
(multiple `workitem.md` candidates → resolver gives up). Use disambig form:

```
[[<slug>/workitem|<slug>]]
```

Applies to:
- body wikilinks within other workitems / references / vault notes
- frontmatter `relates-to:` arrays
- `reference-for:` pointers in `<slug>/references/<name>.md` files

Examples:
- `[[orders-pipeline/workitem|orders-pipeline]]`
- `[[pdf-archive-pipeline/workitem|pdf-archive-pipeline]]`
- `[[recipe-tag-taxonomy/workitem|recipe-tag-taxonomy]]`

In multi-root mode the qualified form (see *Multi-root slug naming* below)
composes naturally: `[[packages-auth/auth-refactor/workitem|auth-refactor]]`.

### Multi-root slug naming (DL #6 in crystal-multi-root)

When multiple roots resolve, slugs are qualified with the path segment
immediately above `tasks/` to prevent collisions across roots:

| Single-root           | Multi-root                          |
|-----------------------|-------------------------------------|
| `auth-refactor`       | `packages-auth/auth-refactor`       |
| `billing-rewrite`     | `apps-billing/billing-rewrite`      |

The qualifier comes from `basename(dirname(<root>))`. In commands that
accept a slug (`crystal-cut <slug>`, `crystal-cave <slug>`), pass the
qualified form when multi-root is active.

On first `crystal-grow` in a project without the root, create it silently
(`mkdir -p` — no confirmation prompt, per DL #20). When `paths` is set
explicitly, create only roots that match the glob.

## Slug collision policy (DL #24)

Before creating, check both layouts:

1. `<root>/<slug>/` exists → refuse: "Crystal `<slug>` already exists at
   `<path>`. Use a different slug or open the existing one with
   `/vdm:crystal-cave`."
2. `<root>/<slug>.md` exists (flat file) → refuse with hint:

   ```
   × Collision: <root>/<slug>.md уже существует (flat файл).
     Crystal требует folder structure. Варианты:
       - Использовать другой slug
       - Вручную переименовать flat файл, затем повторить grow
       - (v2) Auto-convert flat → folder — отложено
   ```

3. Neither → proceed with creation.

## Migrating legacy docs (onboarding)

Installing the suite into a repo that already has a pile of old PRDs / task
notes is the most common first-run scenario. **`crystal-grow` is not the
migration tool** — it refuses on collision by design (DL #24). Migration is a
manual, judgment-driven move you do once per legacy file, not a command.

Pick one of three paths per file:

| Path             | When                                                          | How |
|------------------|---------------------------------------------------------------|-----|
| **move-to-references** | The doc is finished/historical but its content is worth keeping verbatim (specs, hand-offs, prior reasoning). | `git mv <root>/<slug>.md <root>/<slug>/references/<original>.md`, then hand-write a fresh `workitem.md` on top that summarizes and `[[links]]` the reference. Mirrors how this suite's own design crystal keeps `references/original-spec.md`. |
| **inline-rewrite** | The doc *is* the workitem, just in a pre-crystal format. | Create `<root>/<slug>/`, write `workitem.md` adapting the old content into the schema (frontmatter + `## Next actions` + `## Sidetracks`). Carry every open `- [ ]` across unchanged. `git rm` the flat original once content is transferred. |
| **delete**         | Stale / obsolete / superseded. | Just remove it. Not every old doc earns a migration. |

Two pitfalls when choosing the path:

- **Don't carry doc-type filenames into slugs.** If the legacy filename is a
  doc-type tag (`PRD.md`, `TODO.md`, `SPEC.md`, `NOTES.md`), it carries no
  content signal — rename to a descriptive content slug based on what the
  work *does*, per the project's domain. Example: `manual-pipeline/PRD.md` →
  `pdf-archive-pipeline/workitem.md`, not `PRD/workitem.md`. Slug stays
  kebab-case lowercase regardless (so `PRD` would double-violate: caps *and*
  meaningless).
- **Brainstorm transcripts → `references/`, not sibling workitems.**
  Brainstorm transcripts, design-discussion transcripts, and historical
  decision-log artifacts often *look* like workitems by structure (they may
  even contain a `## Decision Log`) but they're frozen content with no
  future obligations. Workitem = unit with future actions. Reference =
  frozen content, no own future. Default to **move-to-references** under
  the parent workitem (`<parent>/references/<name>.md`), not
  **inline-rewrite** as a sibling — unless the doc genuinely defines
  ongoing work.

Two rules that bite during migration:

- **Dates reflect real history, not the import moment** (the agent's P4). Set
  `created:` to the doc's first commit date and `last-updated:` to its last
  real touch — e.g. `git log --diff-filter=A --format=%as -- <file>` for
  created, `git log -1 --format=%as -- <file>` for last-updated. The cave's
  recency view is only honest if it shows when work actually happened, not
  when you ran the migration.
- **Importing an already-complete doc means writing it at `status: done` —
  which must contain zero `- [ ]`.** The completion-guard fires on the
  *creating* Write too (see `crystal-cut` → Gate behavior). Convert any
  leftover unchecked boxes to `[x]` or one of the five resolution states
  *before* the Write, or the gate blocks the import.

## Behavioral protocol

When `/vdm:crystal-grow [slug]` is invoked (or auto-promotion is accepted):

### Step 1: Classify session

If `session-type` isn't supplied, infer from the conversation so far. Use
the assistant's best judgment from the first few messages; default to
`other` when unclear.

### Step 2: Resolve root and check collisions

Run `resolve_crystal_roots`. The behavior depends on how many roots resolve:

**One root** (single-root mode, classic): use that root, run the collision
check below, proceed.

**Multiple roots** (multi-root mode, monorepo/vault): select target by CWD
confidence, fall back to HITL when ambiguous (DL #7 in crystal-multi-root):

| CWD signal                                                  | Confidence | Action |
|-------------------------------------------------------------|------------|--------|
| `pwd` is under exactly one resolved root                    | high       | grow into that root silently |
| `pwd` is the parent of exactly one `<x>/tasks/`             | high       | grow into `<x>/tasks/` silently |
| `pwd` is project root with ≥2 roots resolved                | low        | HITL — ask which root: «Куда заводим? <r1>/<r2>/<r3>?» |
| `pwd` is outside all resolved roots                         | low        | HITL — same question, with resolved roots listed |
| `slug` argument already contains `<root-qualifier>/` prefix | high       | use that root, slug = portion after `/` |

Then run the collision check below in the selected root. Abort with the
appropriate message on conflict.

### Step 3: Create the workitem

Read the template at `${CLAUDE_PLUGIN_ROOT}/templates/workitem-template.md`,
substitute placeholders, write to `<root>/<slug>/workitem.md`. Frontmatter:

```yaml
---
title: "<human title>"
slug: <kebab>
description: "<one-liner for cave/base overview>"  # optional
status: in-progress
session-type: <type>
created: <YYYY-MM-DD>
last-updated: <YYYY-MM-DD>
---
```

When `session-type` is `brainstorm` or `prd-prep`, the template should
include the `## Decision Log` section by default (Decision Log #13).

### Step 4: Seed from shadow

Any sidetracks the assistant has been carrying in shadow mode go into
`## Sidetracks` as numbered `### #N. ...` entries with `Status: open` and
their `Возникло в:` provenance (Decision Log #5).

If promoting from shadow, the optional `description:` field is derived
from the shadow's tracked session intent (the one-line characterization
the assistant used to classify session-type). For explicit grow with a
slug argument, derive from the immediate invocation context or leave
commented in the template — the field is optional, blank is fine, but
filling it materially improves the cave/base overview signal-to-noise
when the workitem accumulates siblings. Keep it ≤80 chars, describe
what the work *does*, not what it *is* (verb-leaning, not noun-leaning).

### Step 5: Populate Tasks (TaskCreate)

For each unchecked item in `## Next actions` and each open sidetrack,
call `TaskCreate` so the user sees the workitem mirrored as ephemeral
visualization (Decision Log #21). The file remains source of truth — UI
ticks do **not** propagate back. Make this contract explicit when handing
off:

> ✓ Crystal `<slug>` создан. N задач помещены в Tasks как visualization;
> для resolve правьте `<root>/<slug>/workitem.md` (file = source of truth).

### Step 6: Announce

One-line confirmation with the path so the user can open it immediately:

> 🌱 Crystal `<slug>` создан: `<root>/<slug>/workitem.md`.

## Session resume

When a session starts, the SessionStart hook
(`${CLAUDE_PLUGIN_ROOT}/scripts/crystal-hydrate.sh`) lists active workitems.
On invocation, Read the listed workitem(s) before continuing if relevant to
this session. If the SessionStart hook didn't fire (disabled / replaced /
older harness), do the same Read step manually as a fallback (Decision
Log #23, Layer 2).

After context compaction: if an active crystal was in scope before the
compaction summary, re-Read its workitem.md before continuing.

## Configuration sub-commands

`/vdm:crystal-grow [subcommand]` recognizes these as the first word of
arguments. When no subcommand matches, behave as the regular grow skill
described above. Full surface in v1 (DL #11 in crystal-multi-root).

### Enable / disable / reset

| Subcommand            | Effect on `.claude/vdm-plugins.json` → `crystal` |
|-----------------------|--------------------------------------------------|
| `off` / `disable`     | Set `enabled = false` (hooks stay silent)        |
| `on` / `enable`       | Set `enabled = true`                             |
| `reset`               | Remove the `crystal` key (revert to defaults)    |
| `config` / `status`   | Diagnostic: resolved roots + derived singleton + per-tier counts + non-canonical drift |

### Root paths (multi-root, DL #11)

| Subcommand                    | Effect                                              |
|-------------------------------|-----------------------------------------------------|
| `paths add <glob>`            | Append glob to `paths`; idempotent; warns if glob matches 0 dirs but still writes |
| `paths remove <glob>`         | Remove glob; warns if not found; empties → key deleted (falls back to `path` or auto-scan) |
| `paths list`                  | Pretty-print current `paths` + resolved roots; empty → "auto-scan active" |
| `paths set <g1> <g2> ...`     | Replace entire array (space-separated, supports quoted multi-word globs) |
| `paths clear`                 | Remove the `paths` key                              |
| `path <value>`                | Legacy single-root; **refuses** if `paths` is set (force `paths clear` first or edit JSON manually) |
| `path clear`                  | Remove the `path` key (migration helper)            |

### Status aliases (project-specific vocabulary mapped to canonical, DL #10)

| Subcommand                    | Effect                                              |
|-------------------------------|-----------------------------------------------------|
| `status-alias add <from>=<to>`| Map `<from>` → `<to>`; validates `<to>` against canonical taxonomy, errors on unknown |
| `status-alias remove <from>`  | Unmap; warns if not found                           |
| `status-alias list`           | Pretty-print current aliases; empty → "no aliases configured" |
| `status-alias clear`          | Remove the `status-aliases` key                     |

### Singleton invariant override

| Subcommand               | Effect                                                      |
|--------------------------|-------------------------------------------------------------|
| `singleton global`       | Exactly 1 active workitem repo-wide                         |
| `singleton per-root`     | Exactly 1 active per resolved root                          |
| `singleton off`          | No invariant; explicit user override                        |
| `singleton auto`         | Remove key → derive from #roots (1 → global, ≥2 → per-root) |

### Mixed-config policy

Setting `path` while `paths` is already set is refused with an explicit
error rather than written-and-warned (footgun avoidance). Same in reverse:
`paths` overrides `path` and emits a warning at SessionStart hook time.
To migrate from singular to plural: `path clear` then `paths add <glob>`.

### Defaults

When the `crystal` section is absent entirely: `enabled: true`. Everything
else flows from defaults:
- Roots: auto-scan from project root.
- Singleton: derived from #roots (global if 1, per-root if ≥2).
- Status-aliases: none.

This means a fresh install with no config works correctly for both classic
single-root (`docs/tasks/`) and monorepo/vault (`packages/*/tasks/`)
layouts with zero ceremony.

### Implementation rules (patching)

1. Read the file (if missing, start with `{}`).
2. Modify only the `crystal` key — preserve `learn`, `docs-sync`,
   `changelog`, `git-guard` verbatim.
3. For `reset`, delete the `crystal` key (do not leave `"crystal": {}`).
4. Use the Edit/Write tool — **do not** invoke `jq`; users may not have it.
5. Final file must be valid JSON, 2-space indent, trailing newline.
6. Validate `status-alias add`'s `<to>` value against the canonical
   taxonomy (`crystal_canonical_statuses` in `lib/crystal-path.sh`).

The same `crystal` config section is shared by all four crystal-* skills
and by the hook scripts (completion-guard, stop-reminder, hydrate). One
section, one source of truth.

### Config file path detection

1. `project_root` = `git rev-parse --show-toplevel` (fallback: `pwd`)
2. If `<project_root>/.claude/` exists → `<project_root>/.claude/vdm-plugins.json`
3. Else if `<project_root>/.qwen/` exists → `<project_root>/.qwen/vdm-plugins.json`
4. Else create `<project_root>/.claude/` and write there.

## Examples

### Example 1: Promotion from shadow

User: "Слушай, мы уже час крутимся вокруг auth refactor, и я вижу что у тебя
накопились побеги. Давай заведём crystal."

Assistant flow:
1. Classify session as `research` (already past threshold — 4+ tool calls).
2. Resolve root → `docs/tasks/`. Check collisions for slug `auth-refactor` — none.
3. Write `docs/tasks/auth-refactor/workitem.md` from template with the 3
   shadow sidetracks already captured.
4. TaskCreate for each: 2 open sidetracks + the 1 unchecked "Next action."
5. Announce: `🌱 Crystal auth-refactor создан: docs/tasks/auth-refactor/workitem.md.`

### Example 2: Direct grow with explicit slug

User: `/vdm:crystal-grow stripe-webhook-rewrite`

Assistant flow:
1. session-type inference from the conversation so far.
2. Check `docs/tasks/stripe-webhook-rewrite/` — does not exist.
3. Write the workitem with empty `## Sidetracks`, seeded `## Next actions`
   from the user's stated goal.
4. TaskCreate as in Example 1.

### Example 3: Configurable path

User: `/vdm:crystal-grow path tasks`

Assistant updates `.claude/vdm-plugins.json`:

```json
{
  "crystal": {
    "path": "tasks"
  }
}
```

Future `crystal-grow / -bud / -cut / -cave` and all hook scripts resolve to
`<project_root>/tasks/` instead of the default `docs/tasks/`.

## Quality gates

A successful grow ends in this state:

- [ ] `<root>/<slug>/workitem.md` exists with valid frontmatter
- [ ] `status: in-progress`
- [ ] Singleton invariant respected: any other in-progress workitems were
      explicitly switched to `dormant` first (DL #11)
- [ ] TaskCreate has populated Tasks UI from the workitem's unchecked items
- [ ] User received the one-line confirmation with the path

## Integration with other skills

| Other skill        | Interaction                                                        |
|--------------------|--------------------------------------------------------------------|
| `crystal-bud`      | Append sidetracks to this workitem (or routed dormant)             |
| `crystal-cut`      | Close this workitem when all `- [ ]` are addressed                 |
| `crystal-cave`     | View this workitem + sidetracks + decision log                     |
| `/vdm:docs-sync`   | Phase 0 sweep surfaces this workitem if open                       |
| `/vdm:changelog`   | Soft-hinted by `crystal-cut` after a successful close              |
| `/vdm:learn`       | Soft-hinted by `crystal-cut` when sidetracks were resolved         |

## Reflexive case

The first crystal in this repo is `docs/tasks/crystal-design/workitem.md`
itself — the design document for this very suite was promoted to a full
crystal mid-brainstorm (Decision Log #17). Read it for a worked example of
the format and conventions; the structure described in this skill is the
structure that file follows.