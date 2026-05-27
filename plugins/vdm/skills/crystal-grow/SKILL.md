---
name: crystal-grow
description: "Start (or promote) a crystal — an in-repo workitem under docs/tasks/<slug>/workitem.md that anchors long-running sessions and prevents loss of sidetracks, decisions, and deferred promises. Invoke when a session is widening into research, brainstorm, PRD work, or any flow likely to spawn 3+ branches."
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

## Storage layout (DL #2, #18, #20)

- **Root** resolves through `vdm_config_read "crystal" "path"` (in
  `${CLAUDE_PLUGIN_ROOT}/lib/crystal-path.sh`). Default: `docs/tasks`.
- **Folder-style** (canonical for multi-file workitems):
  `<root>/<slug>/workitem.md` plus optional `<root>/<slug>/references/`,
  `<root>/<slug>/attachments/`, etc.
- **Flat-style** (single-file): `<root>/<slug>.md` — supported for legacy
  and trivial workitems; the gate still applies.

On first `crystal-grow` in a project without the root, create it silently
(`mkdir -p` — no confirmation prompt, per DL #20).

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

## Behavioral protocol

When `/vdm:crystal-grow [slug]` is invoked (or auto-promotion is accepted):

### Step 1: Classify session

If `session-type` isn't supplied, infer from the conversation so far. Use
the assistant's best judgment from the first few messages; default to
`other` when unclear.

### Step 2: Resolve root and check collisions

Run the resolver, then run the collision check above. Abort with the
appropriate message on conflict.

### Step 3: Create the workitem

Read the template at `${CLAUDE_PLUGIN_ROOT}/templates/workitem-template.md`,
substitute placeholders, write to `<root>/<slug>/workitem.md`. Frontmatter:

```yaml
---
title: "<human title>"
slug: <kebab>
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
described above.

| Subcommand               | Effect on `.claude/vdm-plugins.json` → `crystal` |
|--------------------------|----------------------------------------------------|
| `off` / `disable`        | Set `enabled = false` (hooks stay silent)          |
| `on` / `enable`          | Set `enabled = true`                               |
| `path <value>`           | Set `path = "<value>"` (relative to project root)  |
| `config` / `status`      | Read and display the current section               |
| `reset`                  | Remove the `crystal` key (revert to defaults)      |

**Defaults when the section is missing:** `enabled: true`, `path: "docs/tasks"`.

The same `crystal` config section is shared by all four crystal-* skills
and by the hook scripts (completion-guard, stop-reminder, hydrate). One
section, one source of truth.

### Config file path detection

1. `project_root` = `git rev-parse --show-toplevel` (fallback: `pwd`)
2. If `<project_root>/.claude/` exists → `<project_root>/.claude/vdm-plugins.json`
3. Else if `<project_root>/.qwen/` exists → `<project_root>/.qwen/vdm-plugins.json`
4. Else create `<project_root>/.claude/` and write there.

### Patching rules

1. Read the file (if missing, start with `{}`).
2. Modify only the `crystal` key — preserve `learn`, `docs-sync`, `changelog`,
   `git-guard` verbatim.
3. For `reset`, delete the `crystal` key (do not leave `"crystal": {}`).
4. Use the Edit/Write tool — **do not** invoke `jq`; users may not have it.
5. Final file must be valid JSON, 2-space indent, trailing newline.

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