# ai-dev-plugins — Dmitry Vorobyev

AI-powered plugins and extensions for development tools.

## Naming Convention & Scope

**`ai-dev-plugins`** — the umbrella repository for plugins across AI-assisted development tools (Claude Code, Qwen Code, and others).

`dev` was chosen over `code` intentionally: it covers the full development lifecycle — coding, QA, tech writing, DevOps, and beyond.

**Specialization path** (when this repo grows too broad):

| Repository | Scope |
|------------|-------|
| `ai-dev-plugins` | Cross-tool, general-purpose (this repo) |
| `ai-code-plugins` | Code-specific: linters, refactoring, code generation |
| `ai-qa-plugins` | QA: test generation, coverage, bug detection |
| `ai-docs-plugins` | Documentation: tech writing, API docs, changelogs |
| `ai-ops-plugins` | DevOps: CI/CD, deployment, monitoring |

Until specialization is needed, everything lives here.

## Available Plugins

### `vdm` — Core SDLC Workflow

| Skill | Command | Description |
|-------|---------|-------------|
| docs-sync | `/vdm:docs-sync` | Smart documentation discovery & sync (adapts to any project structure) |
| learn | `/vdm:learn` | Intelligent knowledge integration with scenario detection |
| changelog | `/vdm:changelog` | Project change tracking in `PROJECT_CHANGELOG.md` |
| crystal-grow | `/vdm:crystal-grow` | Start (or promote) a workitem under `docs/tasks/<slug>/workitem.md` |
| crystal-bud | `/vdm:crystal-bud` | Capture a sidetrack into the active (or routed dormant) workitem |
| crystal-cut | `/vdm:crystal-cut` | Close a workitem — sweeps unchecked items, blocks done-transition if any remain |
| crystal-cave | `/vdm:crystal-cave` | View all crystals + sidetracks + decision-log summaries (read-only) |
| intercom | `/vdm:intercom` | Central cross-agent/cross-session message store (send / check / pickup) outside all repos |

### `vdm-git` — Git Safety (optional)

| Skill | Command | Description |
|-------|---------|-------------|
| guard | `/vdm-git:guard` | Blocks commit/push until user confirms, enforces commit message format |

## What It Does

### docs-sync
Ensures project documentation always reflects current product state. Adapts to any documentation structure — not limited to `docs/features/`.

**Hook (automatic)**: On every prompt, performs lightweight discovery — detects changed files, maps all `.md` docs, extracts `@see` references, finds potentially affected docs via keyword matching.

**Skill (manual `/vdm:docs-sync`)**: Deep analysis with relevance scoring, cross-reference chains, and concrete "file X, section Y needs change Z" recommendations.

### learn
Systematically captures and preserves project knowledge. Auto-detects scenario type (problem/discovery/standard) and routes through appropriate analysis:
- **Problems** → `/sc:troubleshoot` → root cause analysis → knowledge integration
- **Discoveries** → Technical documentation → `docs/llm/` patterns
- **Standards** → Systematic documentation across CLAUDE.md, Serena Memory, and `docs/llm/`

**Auto-activation**: Claude will proactively invoke this skill when:
- Finding solutions after struggling with issues
- Discovering effective patterns worth preserving
- Making mistakes that should never repeat

### changelog
Maintains `PROJECT_CHANGELOG.md` as a concise record of significant project changes. Focus on **what changed and why**, with links to detailed documentation instead of inline descriptions.

**Key principle**: Keep entries SHORT. Link to details, don't duplicate them.

**Entry format**:
```markdown
### ✨ FEATURE: Feature Name
Brief description (1-2 sentences max).
**Ref**: docs/features/feature-name.md
```

**Entry types**: ✨ FEATURE | 🐛 BUG | 🔧 TOOLING | 🏗️ ARCH | 📝 DOCS | ⚡ PERF | 🔒 SEC

### crystal-* suite
Adds workitem discipline to long-running sessions. A *crystal* is an in-repo workitem at `<root>/<slug>/workitem.md` (canonical folder-stem layout) carrying frontmatter (4-tier `status:` taxonomy — Pre-work / Active / Paused / Terminal), main content, a `## Sidetracks` section for побеги, and an optional `## Decision Log` for brainstorm/PRD sessions. The completion gate is the core invariant: the workitem cannot transition to `status: done` while any `- [ ]` checkbox remains anywhere in the file.

**Multi-root (v2.5.0).** Roots auto-discover from the project tree — any `tasks/` directory under project root counts, skipping hidden segments (`.git/`, `.stversions/`, etc.) and `node_modules/`/`vendor/`. Classic single-root repos see `docs/tasks/` discovered automatically; monorepo/vault layouts get `packages/*/tasks/` or `projects/*/tasks/` for free. Override via `crystal.paths` (array of globs) or pin via `crystal.path` (legacy single root). Singleton invariant derives from the number of resolved roots: 1 root → repo-wide singleton (DL #11), ≥2 roots → per-root singleton.

**Three-layer gate** (defense in depth):
- **Primary** — `PreToolUse` hook `crystal-completion-guard` intercepts Write/Edit/MultiEdit on workitems and blocks done-transitions with the five resolution paths (resolve / migrate / cancel / defer / promote-to-stem). Also enforces `superseded-by:` frontmatter for `status: superseded` transitions.
- **Visibility** — `Stop` hook `crystal-stop-reminder` surfaces active workitems with open items at end-of-turn.
- **Backup (git only)** — pre-commit check in the `vdm-git` plugin (and an in-repo equivalent for this dev clone) catches IDE-direct edits that bypass the assistant.

A `SessionStart` hook (`crystal-hydrate`) lists active workitems so the assistant Reads them before continuing. Non-canonical statuses (anything outside the 4-tier taxonomy after `status-aliases` resolution) surface as audit warnings in `list-open-crystals`, `crystal-hydrate`, and `crystal-cave` for triage. The design document for the suite is itself the first crystal in this repo — `docs/tasks/crystal-design/workitem.md` — serving as a worked example of the format.

### intercom
Central **cross-agent / cross-session message store**. Leave a task brief or note for another repo's agent — or for a future clean session of your own (the common "note to future me" case) — with `/vdm:intercom send <target> <slug>`; list and consume your inbox with `check` / `pickup`. Messages live in a **single machine-level store outside all repos** (`$VDM_INTERCOM_ROOT` → `~/.claude/vdm-plugins.json` `intercom.root` → default `~/.claude/vdm/intercom`), so no repo's history or `.gitignore` is touched. Routing is by **canonical identity from the git remote slug**, not the directory basename — a self-registering registry keeps dir-name / `owner/repo` aliases so any of a project's names resolve to the same inbox. Every message carries an explicit `from`/`to` envelope; `pickup --grow` promotes a brief into a workitem via `crystal-grow`. A receiver-side `UserPromptSubmit` reminder surfaces waiting messages (silent when the inbox is empty). Supersedes the older per-repo `_outbox/` handoff pattern.

### guard (vdm-git plugin)
Prevents Claude from running `git commit` and `git push` without explicit user permission. All other git operations (merge, rebase, status, diff, etc.) are allowed freely.

**Hook (automatic)**: On every prompt, displays a reminder that commit/push are blocked. When Claude attempts a blocked command, it acknowledges the block, suggests a commit message, and waits for confirmation.

**Skill (manual `/vdm-git:guard`)**: Pre-commit review — checks branch, staged files, recent history, and runs safety checks (no secrets, intentional changes) before asking user to confirm or abort.

**Commit message format**: `[+]` new feature, `[-]` bugfix, `[*]` other change. Max 50 chars.

## Installation

### Claude Code

```bash
# Add marketplace
claude plugin marketplace add VoDmAl/ai-dev-plugins

# Install core workflow (docs-sync, learn, changelog)
claude plugin install vdm@vodmal --scope user

# Install git safety (optional)
claude plugin install vdm-git@vodmal --scope user
```

### Qwen Code

```bash
qwen extensions install VoDmAl/ai-dev-plugins
# Select "vdm" when prompted
```

**Limitations**:
- Qwen Code treats the entire repo as one extension — only one plugin can be installed at a time
- `git-subdir` source type is not supported, so the marketplace selection of `vdm-git` will fail
- `qwen-extension.json` at repo root exposes core skills (`vdm`) directly
- `vdm-git` (guard) is **not available** in Qwen Code

<!-- TODO: Remove qwen-extension.json workaround when Qwen Code adds git-subdir + multi-plugin support -->

## How the Skills Work Together

**`vdm` plugin:**

| Aspect | docs-sync | learn | changelog |
|--------|-----------|-------|-----------|
| Focus | All project `.md` docs | `docs/llm/` + Serena Memory | `PROJECT_CHANGELOG.md` |
| Audience | Users, stakeholders | LLMs, developers | Project history |
| Trigger | Code changes | Knowledge capture | Significant changes |
| Content | Product capabilities | Technical patterns | Change summaries + refs |

**`vdm-git` plugin:**

| Aspect | guard |
|--------|-------|
| Focus | `git commit` / `git push` |
| Audience | Developer safety |
| Trigger | Every git commit/push |
| Content | Pre-commit review |

**Typical workflow:**
```bash
# After implementing a feature
/vdm:docs-sync              # Update user-facing docs in docs/features/
/vdm:learn "Pattern I used" # Capture technical knowledge in docs/llm/
/vdm:changelog              # Add compact entry to PROJECT_CHANGELOG.md
```

## Project Structure Requirements

This plugin expects projects to have:

```
your-project/
├── docs/
│   ├── features/     # Product documentation (user-facing)
│   │   ├── feature-a.md
│   │   └── feature-b.md
│   └── llm/          # Technical documentation (dev-facing)
│       ├── patterns.md
│       └── architecture.md
└── ...
```

**If this structure doesn't exist**, Claude will propose creating it when starting feature work.

## How It Works

### Automatic Hooks

Each plugin installs its own hooks that run on **every prompt**.

Since v2.1.1, `changelog` and `docs-sync` reminders **stay silent on a clean working tree** — no uncommitted changes means nothing to remind about. `learn` and `git-guard` remain proactive by design (capture moments / safety gate).

Since v2.2.0, every hook is **configurable per project** — see [Configuration](#configuration) below.

**docs-sync discovery:**
```
[docs-sync] 📋 Documentation sync context:
Changed files (3): src/auth.ts, src/config.ts, .env.example
Project docs (5): README.md, docs/setup.md, docs/api.md, ...
Potentially affected docs: docs/setup.md, docs/api.md
For deep analysis with relevance scoring → run /vdm:docs-sync
```

**learn reminder:**
```
[learn] 💡 After resolving issues or discovering patterns...
```

**changelog reminder:**
```
[changelog] 📋 After completing significant work...
```

These hooks remind Claude about documentation, knowledge capture, and change tracking without requiring manual invocation.

### Skill Protocol (`/vdm:docs-sync`)

When invoked, the skill performs deep discovery:

1. **Discovery** — Detect changed files, map all `.md` docs, extract `@see` references, keyword matching
2. **Relevance scoring** — Rank docs by priority (direct references → keyword matches → thematic → general)
3. **Concrete output** — Actionable checklist: "in file X, section Y doesn't reflect change Z"

### Feature Detection

When working on code, Claude announces the detected feature:

```
📋 Feature: /remind → docs/features/reminder.md
   Key files: Commands/ReminderCommand.php, ReminderTrait.php
```

### Completion Flow

Before declaring work complete, Claude will:

```
✅ Implementation complete
✅ Tests passing
📝 Next step: Update docs/features/reminder.md

Proposed documentation changes:
- Usage section: Added --priority parameter
- Changelog: 2026-01-15: Added priority flag

Proceed with documentation update?
```

### Code-to-Docs Linking

The plugin encourages bidirectional links using `@see` annotations:

**In code:**
```php
/** @see docs/features/reminder.md */
class ReminderCommand extends UserCommand
```

**In documentation:**
```markdown
## Implementation
- `Commands/ReminderCommand.php` — Main command logic
```

## Templates

The plugin includes templates for consistent documentation:

- `templates/feature-template.md` — For `docs/features/` files
- `templates/llm-template.md` — For `docs/llm/` files
- `templates/changelog-template.md` — For initializing `PROJECT_CHANGELOG.md`

## Behavior Summary

| Scenario | Claude's Action |
|----------|-----------------|
| Product capability change | Update `docs/features/`, require before completion |
| Refactoring (tests pass) | Add changelog entry only |
| New feature | Create `docs/features/{feature}.md` from template |
| No docs structure | Propose creating `docs/features/` and `docs/llm/` |

## Configuration

Since v2.2.0 every reminder hook is configurable per project via `.claude/vdm-plugins.json` (or `.qwen/vdm-plugins.json` for Qwen Code).

### Quick disable / enable via skill subcommands

Each skill accepts subcommands as the first argument — no manual JSON editing required:

```bash
/vdm:learn off          # disable learn reminder in this project
/vdm:changelog quiet    # changelog: fire only on strong signals
/vdm-git:guard silent   # silence the git-guard reminder text
/vdm:docs-sync proactive  # always fire, even on clean tree
/vdm:learn config       # show current config for this section
/vdm:learn reset        # restore defaults for this section
```

Recognized subcommands: `off` / `disable`, `on` / `enable`, `proactive`, `conditional`, `quiet`, `silent`, `config` / `status`, `reset`.

### Config file shape

```json
{
  "learn":      { "enabled": true,  "mode": "proactive" },
  "changelog":  { "enabled": true,  "mode": "conditional" },
  "docs-sync":  { "enabled": true,  "mode": "conditional" },
  "git-guard":  { "enabled": true,  "mode": "proactive" }
}
```

Sections may be partial — missing keys fall back to defaults. Missing sections fall back to defaults entirely.

### Modes

| Mode | When the reminder fires |
|------|-------------------------|
| `proactive` | Every prompt, unconditionally |
| `conditional` | Only when working tree has changes (modified, staged, or untracked) |
| `quiet` | Same as `conditional` today; fase 3 will tighten further |
| `silent` | Never (synonym for `enabled: false`) |

### Defaults

| Plugin | Default mode | Reasoning |
|--------|--------------|-----------|
| `learn` | `proactive` | Knowledge-capture moments are easy to miss |
| `changelog` | `conditional` | Nothing to changelog when tree is clean |
| `docs-sync` | `conditional` | No diff → no docs to flag |
| `git-guard` | `proactive` | Safety reminder, should always be visible |

### Important note about `git-guard`

The config controls only the **UserPromptSubmit reminder** (the visible text). The **PreToolUse blocking hook** that intercepts `git commit` / `git push` is intentionally not configurable — it remains active even with `git-guard.enabled = false`. To fully disable the safety guard, uninstall the `vdm-git` plugin.

## Project CLAUDE.md Integration

For maximum reliability, add this rule to your project's `CLAUDE.md`:

```markdown
## Documentation Sync

**ALWAYS update docs/features/** when changing user-facing behavior:
1. Before declaring any task complete, identify affected `docs/features/{feature}.md`
2. Update documentation to reflect current product state
3. Add changelog entry with date

Invoke `/vdm:docs-sync` for full documentation protocol.
```

This ensures Claude treats documentation as part of Definition of Done even if the hook reminder is missed.

### Recommended CLAUDE.md Rules

Add to your critical rules section:

```markdown
- **Documentation is Definition of Done** — Never complete user-facing changes without updating `docs/features/`
- **Invoke /vdm:docs-sync** — Run before completing feature work for full protocol
```

## Namespaces

Two plugin namespaces:

**`vdm`** (core):
- `vdm:docs-sync` — documentation synchronization
- `vdm:learn` — knowledge integration
- `vdm:changelog` — project change tracking

**`vdm-git`** (optional):
- `vdm-git:guard` — git safety guard (commit/push protection)

## changelog Skill Quick Reference

```bash
# Auto-invoke after completing work
/vdm:changelog   # Claude will detect change type and create entry

# Entry types with emoji:
# ✨ FEATURE - new user-facing functionality
# 🐛 BUG     - bug fixes
# 🔧 TOOLING - infrastructure, CI/CD
# 🏗️ ARCH    - architectural decisions
# 📝 DOCS    - documentation restructuring
# ⚡ PERF    - performance improvements
# 🔒 SEC     - security fixes
```

See `plugins/vdm/skills/changelog/SKILL.md` for full documentation.

## learn Skill Quick Reference

```bash
# Auto-detection (most common usage)
/vdm:learn "Database migration deleted prod tables"   # Problem → troubleshoot
/vdm:learn "Found caching pattern for API calls"      # Discovery → document
/vdm:learn "All errors must use RFC 7807 format"      # Standard → systematic

# Manual override when needed
/vdm:learn "Complex issue" --force-problem
/vdm:learn "New pattern" --force-discovery
/vdm:learn "New rule" --force-standard
```

See `plugins/vdm/skills/learn/SKILL.md` for full documentation.

## Development

This repo carries deterministic gates that enforce structural invariants the project has chosen to hold. Each gate is a pure-shell script with a remediation message; CLAUDE.md describes the rule, the gate enforces it. See `docs/llm/soft-guidance-vs-deterministic-gates.md` for why we layer rules and gates rather than relying on either alone.

### Activate the dev hooks

After cloning, run once:

```bash
git config core.hooksPath .githooks
```

If you forget, a SessionStart hook in `.claude/settings.json` prints a one-line `[vdm-dev]` reminder at the top of each Claude Code session in this repo. The warner is **idempotent and warn-only** — it never modifies your `.git/config`. To opt out, point `core.hooksPath` somewhere else (e.g. `git config core.hooksPath .git/hooks`); the warner only stays quiet when it's exactly `.githooks`.

### Pre-commit gates

`.githooks/pre-commit` runs the relevant gate for whatever you've staged:

| Gate | Script | Triggers when |
|------|--------|---------------|
| lib-sync | `scripts/check-lib-sync.sh` | any file under `plugins/{vdm,vdm-git}/lib/**` is staged |
| version-bump | `scripts/check-version-bump.sh` | any file under `plugins/X/**` is staged (bump check) **and** unconditionally (marketplace ↔ plugin.json parity) |
| skill-paths | `scripts/check-skill-paths.sh` | unconditionally — user-time files must not reference `plugins/X/<subdir>/` (use `${CLAUDE_PLUGIN_ROOT}/...` instead) |
| crystal | `scripts/check-crystal-completion.sh` | any `docs/tasks/**/workitem.md` (or flat `docs/tasks/*.md`) is staged with frontmatter `status: done` and unchecked `- [ ]` items remain |

All three can be run manually:

```bash
bash scripts/check-lib-sync.sh             # 0 = clean, 1 = drift report
bash scripts/check-version-bump.sh         # 0 = bumped + in parity, 1 = drift
bash scripts/check-skill-paths.sh          # 0 = clean, 1 = dev-path leak found
bash scripts/check-crystal-completion.sh   # 0 = clean, 1 = workitem done with open items
```

**lib-sync.** The two plugins ship duplicated copies of `lib/config-path.sh` and `lib/config-read.sh` (each plugin must be self-contained for independent installation). The check normalizes the cross-reference comments that name the opposite plugin (`plugins/vdm/lib` ↔ `plugins/vdm-git/lib`); everything else must match byte-for-byte. A GitHub Actions workflow running the same check on PRs is planned but not yet wired up (the file `.github/workflows/lib-sync.yml` was blocked by a local security hook during a prior commit).

**version-bump.** Two independent checks:

1. *Bump check (conditional).* Any change inside `plugins/X/**` requires a new version in `plugins/X/.claude-plugin/plugin.json` (compared via `git show :path` vs `git show HEAD:path`). The check accepts any version difference — choose semver level appropriate to the change (PATCH for fixes, MINOR for new behavior, MAJOR for breaking).
2. *Marketplace parity (unconditional).* For each plugin, the `plugins[].version` field in `.claude-plugin/marketplace.json` must equal the `version` in `plugins/X/.claude-plugin/plugin.json`. Catches the case where one is bumped without the other — the marketplace catalog must always advertise what plugin.json actually ships.

Always pair the bump with a `PROJECT_CHANGELOG.md` entry.

**skill-paths.** Lints `plugins/*/skills/**/SKILL.md` and `plugins/*/templates/*.md` for direct references to `plugins/(vdm|vdm-git)/(scripts|lib|hooks|templates|skills)/...`. Those paths only resolve inside this dev clone — at user time the plugin lives under `${CLAUDE_PLUGIN_ROOT}` (resolved by Claude Code). Use `${CLAUDE_PLUGIN_ROOT}/<subdir>/...` everywhere in user-time files. Bare plugin names (e.g. "the vdm plugin") are not flagged — only concrete subpaths.

**crystal.** Backup to the `crystal-completion-guard` runtime hook (which catches the assistant flipping `status: done` mid-edit). The pre-commit variant catches IDE-direct edits that bypass the assistant — by the time it fires, the runtime hook already missed it, which is exactly when a deterministic check earns its keep. Reads the STAGED version of each workitem (`git show :path`) so the gate sees what's about to commit, not whatever sits on disk. Hardcoded to `docs/tasks/` (this repo doesn't override the default crystal root). The downstream-shipped equivalent — `vdm-git/scripts/crystal-precommit-check.sh` — reads `.claude/vdm-plugins.json:crystal.path` and is universally configurable.

### Runtime hooks (ship with the plugin)

`plugins/vdm/hooks/hooks.json` wires five hook scripts. The orphan-guard one fires after writes to `docs/llm/*.md`; the four crystal ones implement the workitem discipline gate described above:

| Hook event | Script | What it does |
|------------|--------|--------------|
| SessionStart | `crystal-hydrate.sh` | Lists active in-progress workitems so the assistant Reads them before continuing |
| UserPromptSubmit | `docs-sync-reminder.sh`, `learn-reminder.sh`, `changelog-reminder.sh` | Per-prompt nudges (see Configuration section above) |
| PreToolUse (Write/Edit/MultiEdit) | `crystal-completion-guard.sh` | Blocks status:in-progress → status:done while `- [ ]` items remain |
| PostToolUse (Write/Edit/MultiEdit) | `orphan-guard-hook.sh` | Catches new `docs/llm/*.md` without a discovery hook |
| Stop | `crystal-stop-reminder.sh` | End-of-turn visibility for active workitems with open items |

Orphan-guard detail: without a discovery hook (CLAUDE.md ref / source-code @see / `docs/features/` ref / sibling `docs/llm/` ref) it exits 2 with a remediation message — surfacing as actionable feedback the assistant must address before the turn ends.

The audit script can also be invoked manually against any project that has `docs/llm/`:

```bash
bash plugins/vdm/scripts/check-llm-orphans.sh                 # audit all
bash plugins/vdm/scripts/check-llm-orphans.sh --file PATH     # one file
```

The same script is what `/vdm:docs-sync` Phase 1.5 calls — single source of truth.

## License

MIT

## Author

Dmitry Vorobyev — [vorobyev.org](https://vorobyev.org)
