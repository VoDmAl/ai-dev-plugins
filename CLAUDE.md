# cc-vdm-plugins — Project Notes

Two plugins (`vdm`, `vdm-git`) live under `plugins/`. They run under multiple AI coding harnesses — Claude Code (primary) and Qwen Code (via `qwen-extension.json`).

## Scope of this CLAUDE.md

**This file applies only when developing this repo** — i.e. when working on the plugins themselves. The plugins ship to user projects via the marketplace; in those projects, only the plugins' SKILL.md files (`plugins/*/skills/**/SKILL.md`) and registered hooks (`plugins/*/hooks/hooks.json`) govern assistant behavior. *This* `CLAUDE.md` is **not** loaded there.

Practical consequence:
- Rules below describe how to work safely **inside this repo**.
- The plugins' contracts with downstream user projects live in `plugins/*/skills/**/SKILL.md` and the registered hook scripts. If a behavior needs to apply at user-time, it must be declared there, not added here.

## Read first: how the suite is put together

`docs/model/suite.md` — **the synthesis layer for this repo.** Answers what the suite *is as a
system*: why every mechanism (crystal, docs-distill, the pre-commit gates) turned out to have the
same shape — soft until named / binding once named, every signal a comparison of two artifacts on
disk, no state anywhere. Read it **before adding a new mechanism**: the usual outcome is that you
don't need a new gate at all, only a new way to *name* the obligation in a form an existing gate
already understands.

Kept honest by the drift signal — `bash plugins/vdm/scripts/distill-scan.sh --drift`. It is rebuilt,
not appended to.

Its neighbour `docs/llm/soft-guidance-vs-deterministic-gates.md` answers a different question — *when*
a soft rule has earned promotion to a gate. That one is about the decision; `suite.md` is about the
structure.

## Critical Rules (this repo only)

Each rule is paired with a deterministic gate — see `docs/llm/soft-guidance-vs-deterministic-gates.md` for why we layer rules and gates rather than relying on either alone.

1. **Bump the plugin version on any change inside `plugins/X/`.** Editing anything under `plugins/vdm/**` or `plugins/vdm-git/**` requires:
   - a bump in `plugins/X/.claude-plugin/plugin.json` (semver: PATCH for fixes, MINOR for new behavior, MAJOR for breaking changes);
   - a matching bump of the `plugins[].version` entry in `.claude-plugin/marketplace.json` so the catalog advertises the new version;
   - a `PROJECT_CHANGELOG.md` entry.

   Enforced at commit time by `scripts/check-version-bump.sh` via `.githooks/pre-commit`. The gate runs two passes: (a) conditional — staged plugin file changes require a plugin.json bump; (b) unconditional — `plugin.json` ↔ `marketplace.json` parity is asserted regardless of staging.

2. **Every `docs/llm/*.md` must have a discovery hook** (CLAUDE.md ref, source-code @see comment, `docs/features/` ref, or sibling `docs/llm/` ref; `PROJECT_CHANGELOG.md` mentions don't count). Without a hook the doc is invisible to future sessions because only `CLAUDE.md` is auto-loaded. Enforced inside this repo by the `orphan-guard` `PostToolUse` hook (`plugins/vdm/scripts/orphan-guard-hook.sh`) — i.e. by the plugin's own user-time hook, which we benefit from while developing here. Periodic audit via `plugins/vdm/scripts/check-llm-orphans.sh` (also called by `/vdm:docs-sync` Phase 1.5).

3. **Keep `plugins/{vdm,vdm-git}/lib/` byte-identical.** Mirror invariant; any divergence beyond the cross-reference comment must be resolved before commit. Enforced by `scripts/check-lib-sync.sh` via `.githooks/pre-commit`.

4. **No dev-tree paths in user-time files.** Inside `plugins/*/skills/**/SKILL.md` and `plugins/*/templates/*.md`, references to scripts/lib/hooks/templates must use `${CLAUDE_PLUGIN_ROOT}/...`, not `plugins/X/...` — the latter only resolves inside this dev clone, not in a user project. Enforced by `scripts/check-skill-paths.sh` via `.githooks/pre-commit` (runs on every commit).

5. **Workitem completion discipline (crystal gate).** Any file under `docs/tasks/<slug>/workitem.md` (or flat `docs/tasks/<slug>.md`) with frontmatter `status: in-progress` must have zero `- [ ]` checkboxes before transitioning to `status: done`. This generalizes "completion discipline" — every unchecked checkbox is an open obligation, not only items inside `## Sidetracks`. Five resolution paths (resolve / migrate / cancel / defer / promote-to-stem) per Decision Log #9 in `docs/tasks/crystal-design/workitem.md`. Enforced in three layers (Decision Log #7): (a) PreToolUse hook `crystal-completion-guard` in the `vdm` plugin (primary, fires on Write/Edit/MultiEdit of any workitem); (b) Stop hook `crystal-stop-reminder` (visibility); (c) `.githooks/pre-commit` Gate 4 — `scripts/check-crystal-completion.sh` — for IDE-direct edits that bypass the assistant. Same backup ships in `vdm-git` for downstream projects.

## Authoring standard: agent-agnostic skill text

When writing prompts, hook output, or instructions inside `plugins/**/skills/**/SKILL.md` and `plugins/**/scripts/**`:

- **Don't hardcode the assistant's name** ("Claude", "Qwen", "GPT", etc.). The same files load under multiple harnesses, and naming one model implicitly tells the others "this isn't for you."
- **Use generic terms** instead: "the assistant", "the AI assistant", "you (the assistant)", or `Assistant:` as a label prefix.
- **OK to mention by name:** product-level harness names (`Claude Code`, `Qwen Code`) when describing where files live or which install path is used — e.g. `.claude/` vs `.qwen/`. That's harness, not agent identity.

**Why:** plugins ship through multiple marketplaces; agent-agnostic text means a single source of truth and no per-harness forks. Caught during the v2.2.0 work — fix touched 5 files (guard SKILL.md, learn SKILL.md, learn-reminder.sh, hook output) where "Claude" had crept in.

## Commit Message Format

Subject-only, single line. **No body** — the detail belongs in `PROJECT_CHANGELOG.md` (one entry per change), not duplicated in the commit. The git-guard hook detects this section automatically when intercepting `git commit` and emits these rules to the assistant.

Prefix + short imperative. Aim ≤ 80 chars (mild ceiling — recent commits run 50–80).

| Prefix | Meaning |
|--------|---------|
| `[+]` | New feature |
| `[-]` | Bugfix |
| `[*]` | Improvement / refactor / docs |
| `[!]` | Structural / multi-faceted (feature + tooling + docs together) |

Recent examples — match this terseness:

```
[!] Add orphan-guard hook, discovery-hook enforcement, and new pre-commit gates
[+] git-guard: project-aware commit suggestions (v2.2.0)
[!] Add dev-time lib-sync enforcement via pre-commit hook and SessionStart warning
[*] Update README to clarify Qwen Code limitations and plugin behavior
[+] Add qwen-extension.json and document limitations of Qwen Code
```

## Dev setup (one-time per clone)

Activate `.githooks/` so the lib-sync pre-commit check runs locally:

```bash
git config core.hooksPath .githooks
```

A SessionStart hook in `.claude/settings.json` warns if this isn't set, but does **not** auto-fix `.git/config` — the activation gesture is left to the user.

If you see `[vdm-dev] Dev hooks not active in this clone…`, run the command above.

## Where things live

- `plugins/vdm/` — core plugin (docs-sync, docs-distill, learn, changelog, crystal-*, intercom skills)
- `plugins/vdm-git/` — optional git safety plugin (guard skill)
- `plugins/{vdm,vdm-git}/lib/` — **mirrored** config helpers (drift-checked by `scripts/check-lib-sync.sh`)
- `scripts/check-lib-sync.sh` — manual run of the drift check
- `.githooks/pre-commit` — runs the drift check before any commit that stages `plugins/{vdm,vdm-git}/lib/**`
- `scripts/ensure-githooks.sh` — SessionStart warner (warn-only check that `core.hooksPath=.githooks`)

See `README.md` → Development for the full developer protocol.
