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

## Working inside an active crystal (in-flight discipline)

`crystal-grow` is the *creation* skill, but the file it produces only earns
its keep if the assistant *uses* it during work. Field experience shows the
common failure mode: a session works on an active crystal for hours, makes
several architectural decisions, finds several побеги — and never opens
`workitem.md`. At the next context compaction the decisions collapse to
"discussed alternatives", the побеги collapse to "noted some follow-ups",
and the work that justified having a crystal at all dies in chat.

The four crystal-* skills are not just commands — they're a discipline. The
discipline runs *continuously* while a crystal is active, not only at
grow/cut moments. Two complementary hooks remind the assistant:

- `crystal-hydrate.sh` at **SessionStart** — surfaces the active workitem(s)
  with the source-of-truth reminder.
- `crystal-capture-reminder.sh` at **UserPromptSubmit** — fires when source
  edits accumulate without workitem.md being touched (smart mode default;
  per-session throttle).
- `crystal-stop-reminder.sh` at **Stop** — emits the work-without-capture
  nudge at end-of-turn when source files are newer than workitem.md.

Below is the explicit checklist the hooks are pointing at. Read it once
when working inside an active crystal — the discipline is small and
mechanical, but it has to *happen* every turn.

### What goes into `## Decision Log` (DL entry)

Anything chosen-over-alternative-with-rationale. Specifically:

| Trigger                                                | Why a DL entry matters                                            |
|--------------------------------------------------------|-------------------------------------------------------------------|
| Chose X over Y after weighing alternatives             | Future reader sees *why* X, not just that X happened             |
| Raised/lowered a threshold or tolerance                | Future reader otherwise sees a magic number with no context       |
| Deviated from an earlier plan in this same workitem    | Without it, the Next-actions list silently lies                   |
| User confirmed a non-obvious choice (validated, not corrected) | The validation is signal — preserves judgment, not just code |
| Single-instance exception to a documented rule         | Without it, the exception looks like inconsistency                |
| Dropped/cut work that was earlier listed as in scope   | Scope shrinkage needs to be explicit, not a silent disappearance  |

Format (mirrors existing entries in `docs/tasks/crystal-design/workitem.md`):

```markdown
### #N / YYYY-MM-DD / <short title>

**Source:** user | assistant | both
**Basis:** observed | user-stated | inferred | assumed
**Basis-detail:** <what was actually seen — or what this was derived from;
                  if inferred/assumed, what was NOT checked>
**Context:** <one paragraph — what was on the table>
**Why:** <one paragraph — the reasoning that selected this option>
**Implication:** <what changes downstream because of this choice>
**Cross:** см. Sidetrack #N (optional)
**Supersedes:** #N, #M (only when this entry overturns earlier ones)
**Superseded-by:** #N (added to an entry when a later one overturns it)
```

Do not write DL entries for: routine implementation steps, obvious choices,
mechanical refactors. The bar is "future reader, six months from now,
opening this file cold, would need this to understand the work."

### `Basis:` — what the decision *stands on* (not who made it)

`Source` records **who** decided. `Basis` records **what the decision rests
on** — and it is the field that makes an epistemic hole visible at the moment
of writing rather than after it has cost something.

| Value | Meaning | Trust |
|-------|---------|-------|
| `observed` | Seen with your own eyes in the **target system** — the report, the log, the dump, the actual response, the rendered page. | Load-bearing |
| `user-stated` | The user said so. Not independently verified. | Usually fine — but it is *their* claim, not your observation |
| `inferred` | Derived from an **adjacent** source: a config file, the code, the documentation, a schema. | **Suspect** |
| `assumed` | A default expectation. Nobody said it and nothing showed it. | **Suspect** |

The distinction that matters is `observed` vs. `inferred`, and it is subtle
precisely because `inferred` *feels* like knowledge. **A config describes what
a system was told to do. It does not tell you what the system actually does,
what else writes to the same place, or what was already there.** Reading a
config and concluding what exists in the live system is inference, not
observation — even when the config is authoritative, even when you are right.
The same trap holds for code (what it does when it runs ≠ what it looks like),
schemas (declared shape ≠ stored data), and docs (intent ≠ reality).

Rules:

1. **`Basis` is mandatory.** An entry without it is not a Decision Log entry.
2. **`inferred` and `assumed` must say what was NOT checked** in `Basis-detail`.
   "Derived from the config; not verified against the live system" is a complete
   and honest answer. The unverified part is the *point* of the field — hiding
   it defeats the purpose.
3. **Do not upgrade `inferred` to `observed` because it feels solid.** Confidence
   is not observation. If you did not look at the target system, the value is
   `inferred`, however obvious the conclusion.
4. **When an `inferred` entry is later verified**, do not silently edit it.
   Write a new entry (`Basis: observed`) that supersedes it — the history of
   having been unsure is itself signal.

#### Where `Basis` bites — and where it doesn't

`Basis` is not a quality score, and `observed` is not the goal. The field
constrains **claims about how some existing system actually behaves** — the
kind of claim that can be false without anyone noticing. It is nearly inert on
**preference decisions** (*what shall we build, what shall we call it, which
trade-off do we accept*), because there is nothing to observe: the basis of a
design choice genuinely **is** somebody's judgment.

A design or brainstorm crystal whose entries are honestly all `user-stated` is
not a crystal that failed the discipline — that is simply what the log of a
design conversation looks like. Do not manufacture `observed` where there was
nothing to look at; a fabricated `observed` is strictly worse than an honest
`user-stated`, because it spends the credibility the field exists to carry.

The field earns its keep the moment an entry asserts something *factual about a
live system* — what exists, what is already wired to what, what will happen if
this changes. That is the claim that gets acted on, and the claim that is
cheapest to be quietly wrong about.

For `user-stated`, a **verbatim quote is the ideal `Basis-detail`** (several
entries in `docs/tasks/crystal-design/workitem.md` already do this with an
ad-hoc `**Quote:**` line). It preserves what was actually said, rather than your
paraphrase of it — and your paraphrase is where their claim quietly becomes
your inference.

### Superseding a decision

The Decision Log is **append-only**. When a later decision overturns an earlier
one, do not delete or rewrite the earlier entry — it is the record of what was
believed and why. Instead:

1. Add the new entry with `**Supersedes:** #N` naming every entry it overturns.
2. Add `**Superseded-by:** #<new>` to each overturned entry — one line, in place.
   This is the *only* edit permitted to a past entry.
3. **Update `## Текущая модель`.** This is not optional. A supersede that leaves
   the live section stale has done half the job: the log now records the
   correction, but the file still *reads* as the old truth to anyone who does
   not replay the whole history.

An entry with no `Superseded-by:` is in force. Absence means active — which is
why existing entries written before this field existed remain valid as-is; no
backfill is needed.

> **Do not rename this to `**Status:**`.** It reads like the obvious name, and
> it is taken: sidetrack cards use `**Status:** open|deferred|…`, and the
> open-sidetrack parser (`audit_sidetracks_without_markers` in
> `${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh`) discriminates DL entries from
> sidetrack cards on the documented invariant that **DL entries never carry
> `**Status:**`**. Reusing the token would also give one file two different
> `Status` taxonomies, which no reader should have to disambiguate by enclosing
> section.

Why the append-only log needs a live section: a crystal that runs for weeks
accumulates entries where #11 kills #6, #9 and #10. A reader opening the file
cold hits the **overturned** decisions first, in chronological order, and only
finds the corrections if they read to the end. `## Текущая модель` is the
answer to "if I read one section, which one tells me where things actually
stand?"

### What goes into `## Sidetracks` (побег)

Anything that surfaces during work and isn't the current main goal. See
`/vdm:crystal-bud` for the card format. Concrete triggers:

| Trigger                                                | Capture as побег because                                          |
|--------------------------------------------------------|-------------------------------------------------------------------|
| Adjacent code observation (TODO, smell, stale comment) | Loss would forfeit a found-while-here fix                         |
| Ecosystem block (lib X requires Y v8, breaks A)        | Future migration attempts will hit the same wall                  |
| "We should also..." / "later we'll need..."            | The "later" never comes back unless captured                      |
| Implicit dependency noticed mid-work                   | Documents the actual coupling, not the assumed one                |
| Failed attempt with useful diagnosis                   | Saves the next attempter from re-deriving why X didn't work       |
| Bug in tooling/dep with a workaround applied here      | Workaround needs context for future "is this still needed" review |

If unsure — capture. Bud is cheap; a missed бег is the whole reason this
suite exists.

### Per-turn cadence

The mechanical question to ask yourself at the end of each significant
work segment (not every turn — but anytime a real chunk landed):

> Что из того, что мы сейчас сделали или обсудили, нужно перенести в
> workitem.md? Decisions → DL. Observations → побеги. Closed Next-actions
> → flip `- [ ]` → `[x]`.

The capture-reminder hook will ask you this when source files are newer
than workitem.md. Treat its appearance as a contract reminder, not noise.

### Configuration

The hooks honor `crystal.capture-mode` in `.claude/vdm-plugins.json`:

| Mode        | Behavior                                                              |
|-------------|-----------------------------------------------------------------------|
| `smart`     | Default. Fires only when source edits accumulate without workitem touch, throttled per session (default 600s, override via `crystal.capture-throttle`). |
| `proactive` | Fires every UserPromptSubmit while an active workitem exists. Use during onboarding or when discipline isn't yet internalised. |
| `silent`    | Never fires. Use only after the discipline is fully internalised — the cost of a missed капчер is the cost of the suite. |

## Pre-action gate — before anything irreversible

> **Кристалл защищает не только своё закрытие, но и прод.** Нельзя совершать
> необратимое действие, опираясь на решение, которое никто не наблюдал.

Everything else in this suite guards the *workitem*: the completion-guard hook
refuses `status: done` while `- [ ]` items remain. Nothing guards what happens
*outside* the workitem. That asymmetry is the expensive one — the crystal will
faithfully record a decision, carry it across three compactions, and hand it to
you intact, without ever asking whether the decision was ever true.

This gate is the missing step. It is a **protocol, not a hook** — see *Why this
isn't a hook* below.

### When it applies

Before any **irreversible external action**. The test is not the tool you use,
it is the effect:

> Could I undo this in the next minute, by myself, with nobody else affected?

If **no**, the gate applies. Typical categories — not an exhaustive list, and
the list is not the point, the test is:

- **publish / deploy** — pushing config or code to a live environment
- **delete / overwrite** — data, history, backups, branches (`push --force`)
- **send** — mail, messages, webhooks, notifications to real recipients
- **migrate** — schema changes, data transformations, backfills
- **external side effects** — any API call that charges, provisions, orders,
  grants access, or mutates third-party state
- anything touching **money, people, or someone else's system**

### The checklist

1. **Re-read `workitem.md`.** The file, not your memory of it. After a
   compaction your memory of it is a summary, and a summary is exactly where
   the `Basis` field goes missing.
2. **Name the Decision Log entries this action rests on.** Explicitly, by
   number. If you cannot name any — the action rests on nothing that was ever
   written down. Stop and write the entry first; the act of writing it is what
   surfaces the gap.
3. **Read the `Basis` of each one.** If **any** is `inferred` or `assumed` —
   **stop.** Do not proceed on an unobserved model.

### What "verify" means

Look at the **target system**. Not the config that configures it. Not the code
that writes to it. Not the documentation that describes it. Not a second
inference from a third artifact.

If a decision is `inferred` from a configuration file, the verification is to
observe the live behaviour or the actual stored state — because the thing
inference cannot tell you is **what else is going on that the config never
mentions**. A config says what one component was told to do. It is silent about
every other component writing to the same place, and about what was already
there before any of this existed. That silence is not evidence of absence, and
it is the exact shape of the hole this gate exists to catch.

Verification typically costs seconds. The action you are about to take does not
cost seconds to undo — that is the whole reason it is on this list. The
asymmetry is not close, and it is worth being boring about.

### When verification is impossible

Escalate to the user, and **name the hole explicitly** — do not soften it into
a generic "shall I proceed?", which invites a reflexive yes:

> Это действие опирается на DL #7 (`Basis: inferred` — выведено из
> `<источник>`, в `<целевой системе>` не проверялось). Действие необратимо:
> `<что именно произойдёт>`. Проверить не могу, потому что `<причина>`.
> Проверяем иначе, или принимаем риск явно?

If the user accepts the risk, that acceptance is itself a Decision Log entry
(`Source: user`, `Basis: user-stated`) — written **before** the action, not after.

### Why this isn't a hook

The rest of this suite prefers deterministic gates over soft guidance — the
completion-guard is a hook precisely because "does this file contain `- [ ]`"
is mechanically decidable. This gate is soft on purpose, and the reason is
worth stating so nobody "fixes" it later without knowing:

**"Irreversible external action" is not decidable from a tool call.** A shell
command gives no reliable signal — `curl -X POST` is a health check as often as
it is a payment. Worse, the truly expensive actions frequently do not pass
through an interceptable tool at all: they happen in an external UI, through a
third-party integration, or in the user's own hands after you hand them a
recommendation. A gate that fires on the wrong things and stays silent on the
right ones is worse than none: it trains everyone to click through it.

So the enforcement here is the assistant reading this and *doing it*. That is a
weaker guarantee than a hook, and it is stated plainly rather than dressed up.

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

### `references/` — the provenance rule («чат не хранилище»)

**An artifact a Decision Log entry rests on lands in `references/` *before*
that entry is written — not afterwards, and not "if it turns out to matter."**

Screenshots, exported configs, ticket text, API response dumps, log excerpts,
query results: if a conclusion stands on it, it is saved at the moment it is
received. `<root>/<slug>/references/<name>.<ext>`, and the DL entry's
`Basis-detail` points at it.

Chat scrollback is **not** storage. It is truncated by compaction, and pasted
images are typically the first thing to go — so the artifact that a decision
depends on evaporates while the decision itself survives, leaving an entry that
claims `Basis: observed` with nothing left to show for it. An observation whose
evidence is gone has quietly decayed into an assertion, and nobody gets told.

This is what makes `Basis: observed` verifiable by someone other than the person
who wrote it. Without the artifact, `observed` is just a stronger-sounding word.

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
  real touch. Don't hand-run the git plumbing — call the shared helper, which
  derives both in one shot and **falls back to filesystem birthtime/mtime in
  non-git projects** (crystal-migrate Sidetrack #3 — projects without git must
  still get honest dates):

  ```
  ${CLAUDE_PLUGIN_ROOT}/scripts/crystal-dates.sh <file>   # → "<created>\t<last-updated>"
  ```

  (Under the hood: `git log --diff-filter=A --format=%as -- <file>` for created,
  `git log -1 --format=%as -- <file>` for last-updated, then `stat` birthtime/mtime
  when git can't answer.) The cave's recency view is only honest if it shows when
  work actually happened, not when you ran the migration. `/vdm:crystal-migrate`
  is the batch counterpart for a whole tree of legacy docs at once.
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