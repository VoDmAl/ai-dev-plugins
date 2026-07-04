---
name: crystal-migrate
description: "Batch-migrate a project's legacy task docs into the crystal folder-stem layout. Use when onboarding the crystal suite into a repo that already has a pile of pre-crystal PRDs / task notes / mixed-frontmatter files — the skill scans the legacy tree, classifies every file into workitem / reference / out-of-scope, proposes a migration plan for one human review pass, then applies it (git mv, historic dates, migrated-from provenance) and drops a per-project `migration` crystal as the runbook. Not per-file: it batches the whole tree."
license: MIT
---

# crystal-migrate — Batch Legacy-Doc Migration

## Purpose

Installing the crystal suite into a repo that already has a pile of old PRDs and
task notes is the most common first-run scenario. `crystal-grow` deliberately
refuses on collision (it's the *creation* tool, not the migration tool), so
migration used to be a manual, judgment-heavy move done one file at a time. This
skill makes it a **batch** operation: «не по одному файлу, а фигачит все».

It does three things a plain file-move doesn't (design-home Decision Log #5 —
migration is *restructure + audit/triage*, not `mv`):

1. **Classifies** every legacy doc into one of three buckets — workitem,
   reference, out-of-scope (DL #4).
2. **Audits** the tree for drift the pre-crystal era accumulated — stale
   in-progress work, orphan references, non-canonical statuses, multiple
   simultaneous "active" items.
3. **Preserves history** — dates from the source file (DL #6), `git mv` for
   blame continuity (DL #8), `migrated-from` provenance for renamed slugs (DL #2).

## Two-level model

- **Per-project `migration` crystal.** On first run in a fresh project the skill
  creates `<root>/migration/workitem.md` (`status: in-progress`) as that
  project's first crystal — the runbook, progress tracker, and local decision
  log for the onboarding. Every legacy file becomes a position in its
  `## Next actions`; migration decisions land in its local `## Decision Log`.
  When the boxes are checked, `crystal-cut migration` closes it as the historic
  artifact of first set-up.
- **Design-home crystal (upstream).** In `cc-vdm-plugins`,
  `docs/tasks/crystal-migrate/workitem.md` accumulates cross-project lessons —
  each real migration feeds DL entries and побеги back into this skill. This
  SKILL.md is the executable procedure; the design rationale lives there (DL #7,
  self-contained SKILL.md — `docs/llm/` is not shipped to user projects, so the
  skill can't execute it at runtime).

## The scan (mechanical) vs. the plan (judgment)

The split mirrors `crystal-cave`'s script-backed rendering: mechanical work in a
script, judgment in the skill.

- **Scanner** (`${CLAUDE_PLUGIN_ROOT}/scripts/crystal-migrate-scan.sh`) emits one
  TSV row of *signals* per legacy `.md` file — dates, frontmatter status + tier,
  unchecked count, heading count, a filename-shape hint, and a heuristic
  `bucket_guess`. It never invents a slug and never makes the final call.
- **You (the assistant)** read those signals *plus the file content*, refine the
  bucket per DL #3/#4, and propose slugs. The **human** confirms in one review
  pass. Scanner proposes, you refine, human disposes.

Scanner columns (documented on its leading `# columns:` line):

```
path  created  updated  has_fm  status  tier  unchecked  headings  name_hint  bucket_guess
```

## Behavioral protocol

When `/vdm:crystal-migrate [<dir>...]` is invoked:

### Step 1 — Scan the legacy tree

Run the scanner:

```
${CLAUDE_PLUGIN_ROOT}/scripts/crystal-migrate-scan.sh [<dir>...]
```

Target resolution (DL #9):
1. explicit `<dir>` args → scan those;
2. else `resolve_crystal_roots` (auto-scan of `tasks/` roots) → scan them;
3. else (virgin project, no `tasks/` root yet) → scanner emits only the header.
   Ask the user where the legacy docs live (`docs/`, repo root, a vault folder),
   then re-run with that path as an explicit arg.

Read the TSV. Skip `#`-prefixed lines. Each remaining line is one candidate file.

### Step 2 — Classify into three buckets (DL #4)

Start from `bucket_guess`, then **read the file content** and correct it. The
three buckets:

| Bucket           | What it is                                             | Destination |
|------------------|--------------------------------------------------------|-------------|
| **workitem**     | A unit of work — has open obligations or was tracked   | `<slug>/workitem.md` |
| **reference**    | A spec/scaffold *for* a task (a PRD, a design doc, a frozen brainstorm transcript) | `<owner-slug>/references/<name>.md` + `reference-for:` |
| **out-of-scope** | A reusable asset not tied to one task (prompt/subagent templates) | reported, **left in place** — never force-migrated |

Content rules that override the filename heuristic:
- **PRD / spec → reference by default** (DL #3, T1). It's an artifact, not a
  work-unit. Attach it under the workitem it specifies. Only when an orphan
  historic PRD has *no* home and its work was shipped without tracking does it
  become a thin `status: done` workitem with the PRD as its body (T2 fallback).
- **Brainstorm / design-discussion transcripts → reference**, even when they
  contain a `## Decision Log`. Frozen content with no future obligations is a
  reference, not a sibling workitem.
- **Doc-type filenames carry no content signal.** `PRD.md`, `TODO.md`,
  `NOTES.md` → derive a descriptive content slug from what the work *does*, never
  `prd/workitem.md`.

### Step 3 — Choose slugs (DL #2) and build the plan

**Slug is a deliberate human decision at migration time — never derived
mechanically from the old filename.** Propose a clean kebab-case content slug for
each workitem; the human freely revises it. Provenance is preserved by a
frontmatter `migrated-from:` array (the original relative path(s)), so the new
slug is unconstrained by the old name and reversal/search still works.

Assemble a **migration plan** (batch — one table for the whole tree, no per-file
prompts):

```
migration plan — <N> workitems · <M> references · <K> out-of-scope

WORKITEMS
  old path                     → new slug              status      dates (created/updated)
  manual-pipeline/PRD.md       → pdf-archive-pipeline   done        2025-11-03 / 2026-01-12
  idea-recipe-role-property.md → recipe-role-property   idea        2025-09-01 / 2025-09-01
  ...
REFERENCES
  old path            → owner slug          as
  spec/auth-v2.md     → auth-refactor        references/original-spec.md
OUT-OF-SCOPE (left in place, reported)
  prompt-summarize.md   subagent-review.md
```

### Step 3.5 — Audit / triage (DL #5)

The migration is the moment to look at every task, because the pre-crystal era
had no discipline and drift is guaranteed. Surface, as a triage report:

- **drift / completeness** — work stuck `in-progress` with no recent touch (use
  the scan's `updated` date), implicitly abandoned items.
- **orphans** — references with no owner workitem; dangling artifacts.
- **status audit** — any `tier == non-canonical` value → warn + propose a remap
  to the canonical taxonomy (or a `status-alias`). Never migrate a broken status
  silently.
- **singleton triage** — legacy drift often holds several "active" items at once.
  The singleton invariant allows one `in-progress` per root (or globally). The
  **`migration` crystal itself holds that single active slot during setup**, so
  migrated workitems that were "active" come in **paused/pre-work** by default;
  after `crystal-cut migration`, the user re-activates the one real current
  workitem. Flag the collision, don't resolve it silently.

The output of migration is not "everything ✅" — it's a **triage report**:
cleanly migrated vs. requires-human-decision. Each requires-decision item becomes
a `- [ ]` in the `migration` crystal so its completion gate blocks closing until
resolved.

### Step 3.6 — Link-integrity scope (Sidetrack #2)

Migration is not a pure file-move: moving/renaming a workitem can strand
references to it elsewhere — code, docs, cross-vault wikilinks, frontmatter
`relates-to:` / `reference-for:`. The blast radius is **project-specific** and
can dwarf the md-files themselves. In the plan, add a link-integrity line per
renamed slug: grep the project for the old path/slug and list inbound
references the human must rewrite. Deep automated rewrite is deferred (v1 surfaces
the scope; it does not silently rewrite code). Record what was found as a triage
`- [ ]` so it isn't lost.

### Step 4 — One HITL review pass (DL #8)

Present the full plan (Step 3) + triage report (Step 3.5/3.6) **once**. The user
edits slugs, reclassifies buckets, resolves status remaps. This is a single
batch review — **not** per-file interruptions. Apply only after the user signs
off.

### Step 5 — Apply

For each file, in dependency order (workitems before the references that point at
them):

1. **Read dates from the source file *before* moving** (DL #8) — the scan already
   did this; stamp `created:` / `last-updated:` from the scan row into the new
   frontmatter. `${CLAUDE_PLUGIN_ROOT}/scripts/crystal-dates.sh <file>` re-derives
   them on demand (git first-commit / last-touch, with a birthtime/mtime fallback
   for non-git projects — Sidetrack #3).
2. **Move with history continuity.** In a git repo: `git mv <old> <new>` so blame
   follows the file. In a non-git project: plain `mv`. (`git mv` is best-effort
   future-continuity; a heavy frontmatter rewrite may still show as delete+add in
   blame — cosmetic, not a correctness issue.)
3. **Write the new frontmatter** — `status:` (audited/remapped), `created:` /
   `last-updated:` from source, `migrated-from: [<old relative path>]`. If the
   doc is already complete, write it at `status: done` with **zero** `- [ ]` —
   the completion-guard fires on the creating Write too, so convert leftover
   unchecked boxes first.
4. **References** → `<owner>/references/<name>.md` with a `reference-for:
   [[<owner>/workitem|<owner>]]` back-link (disambig wikilink form — bare
   `[[<slug>]]` fails Obsidian's shortest-path resolver once every workitem shares
   the basename `workitem.md`).
5. **Out-of-scope** → do nothing but list it in the report.

### Step 6 — Create the `migration` crystal

Read `${CLAUDE_PLUGIN_ROOT}/templates/migration-crystal-template.md`, substitute
`{{TODAY}}`, write to `<root>/migration/workitem.md` (`status: in-progress`).
Populate:
- `## Buckets` — the counts.
- `## Decision Log` — the slug decisions, status remaps, reference attachments.
- `## Triage findings` + `## Next actions` — one `- [ ]` per requires-decision
  item (Step 3.5/3.6) and per migrated batch.

Then `TaskCreate` for each unchecked item so the user sees progress mirrored in
the Tasks UI (file stays source of truth; UI ticks don't propagate back).

### Step 7 — Report + feed lessons upstream

Emit the triage report (cleanly migrated vs. requires-decision). Then, if
anything surfaced that improves the skill for future migrations (a legacy shape
the buckets didn't cleanly handle, a new audit heuristic), note it for the
design-home crystal in `cc-vdm-plugins` — that's the whole point of the two-level
model.

## Quality gates

A successful migrate ends in this state:

- [ ] `<root>/migration/workitem.md` exists, `status: in-progress`, with a
      `- [ ]` for every requires-decision item
- [ ] Each migrated workitem: valid frontmatter, `created`/`last-updated` from
      source (not today), `migrated-from:` set
- [ ] References sit under their owner with `reference-for:` back-links
- [ ] Out-of-scope files untouched and listed in the report
- [ ] Singleton respected — exactly one `in-progress` per root (the `migration`
      crystal during setup)
- [ ] Non-canonical statuses either remapped or recorded as a triage `- [ ]`
- [ ] Tasks UI populated from the `migration` crystal

## Examples

### Example 1 — Virgin vault, flat-prefix layout

User: `/vdm:crystal-migrate` in a project whose task notes are flat files under
`docs/tasks/` (`idea-*.md`, `PRD.md`, `prompt-*.md`, mixed frontmatter).

1. Scanner finds the `docs/tasks/` root, emits ~20 rows.
2. Classify: `idea-*` → workitems (pre-work); `PRD.md` → reference under the
   pipeline workitem it specs; `prompt-*` → out-of-scope.
3. Propose clean slugs (`idea-recipe-role-property` → `recipe-role-property`),
   `migrated-from` each.
4. Triage: 3 files sit `in-progress` untouched for months → propose `dormant`;
   one non-canonical `status: wip` → remap to `in-progress`.
5. One review pass; user tweaks two slugs.
6. Apply with `git mv`, create `docs/tasks/migration/workitem.md`, report.

### Example 2 — Monorepo, multiple roots

`/vdm:crystal-migrate packages/*/docs/tasks` — scanner enumerates every root;
slugs are qualified `<parent>/<slug>` (multi-root naming); one `migration`
crystal per root, singleton derived per-root.

### Example 3 — Non-git project

No `.git`. Dates fall back to filesystem birthtime/mtime (Sidetrack #3), moves
are plain `mv`. Everything else identical.

## Integration with other skills

| Other skill      | Interaction                                                        |
|------------------|--------------------------------------------------------------------|
| `crystal-grow`   | migrate composes grow's layout/date rules; grow refuses on collision, migrate is the batch path |
| `crystal-cut`    | closes the `migration` crystal once triage `- [ ]` are resolved    |
| `crystal-cave`   | verify the migrated tree — tiers, singleton, non-canonical drift    |
| `crystal-bud`    | capture a mid-migration observation as a побег on the `migration` crystal |
| `/vdm:changelog` | record the onboarding outcome after the migration crystal is cut   |

## Configuration

Shares the `crystal` config section with the other crystal-* skills (roots,
singleton mode, status-aliases). See `/vdm:crystal-grow` for the sub-command
surface. Migration honors configured `status-aliases` when auditing — an aliased
legacy status resolves to its canonical target rather than flagging as drift.
