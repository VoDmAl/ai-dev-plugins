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

The two plugins ship duplicated copies of `lib/config-path.sh` and `lib/config-read.sh` (each plugin must be self-contained for independent installation). To prevent drift, this repo includes a pre-commit hook that diff-checks the two `lib/` directories.

### Activate the dev hook

After cloning, run once:

```bash
git config core.hooksPath .githooks
```

The hook fires only when files under `plugins/{vdm,vdm-git}/lib/` are staged.

If you forget, a SessionStart hook in `.claude/settings.json` will print a one-line `[vdm-dev]` reminder at the top of each Claude Code session in this repo. The warner is **idempotent and warn-only** — it never modifies your `.git/config`. To opt out, point `core.hooksPath` somewhere else (e.g. `git config core.hooksPath .git/hooks`); the warner only stays quiet when it's exactly `.githooks`.

### Run the check manually

```bash
bash scripts/check-lib-sync.sh
```

Exits 0 when in sync, 1 with a unified diff and `DRIFT` / `ORPHAN` / `MISSING` markers otherwise. The check normalizes the cross-reference comments that name the opposite plugin (`plugins/vdm/lib` ↔ `plugins/vdm-git/lib`); everything else must match byte-for-byte.

A GitHub Actions workflow that runs the same check on PRs is planned but not yet wired up (the file `.github/workflows/lib-sync.yml` was blocked by a local security hook during this commit).

## License

MIT

## Author

Dmitry Vorobyev — [vorobyev.org](https://vorobyev.org)
