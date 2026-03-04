# vdm — Claude Code Plugins

A collection of Claude Code plugins by Dmitry Vorobyev.

## Available Skills

| Skill | Command | Description |
|-------|---------|-------------|
| docs-sync | `/vdm:docs-sync` | Smart documentation discovery & sync (adapts to any project structure) |
| learn | `/vdm:learn` | Intelligent knowledge integration with scenario detection |
| changelog | `/vdm:changelog` | Project change tracking in `PROJECT_CHANGELOG.md` |

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

## Installation

```bash
claude plugin marketplace add git@git.vorobyev.name:claude-code-marketplace.git
claude plugin install vdm@vodmal-claude-code-marketplace --scope user
```

## How the Skills Work Together

| Aspect | docs-sync | learn | changelog |
|--------|-----------|-------|-----------|
| Focus | All project `.md` docs | `docs/llm/` + Serena Memory | `PROJECT_CHANGELOG.md` |
| Audience | Users, stakeholders | LLMs, developers | Project history |
| Trigger | Code changes | Knowledge capture | Significant changes |
| Content | Product capabilities | Technical patterns | Change summaries + refs |

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

### Automatic Hooks (v1.7.0+)

The plugin installs `UserPromptSubmit` hooks that run on **every prompt**:

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

## Namespace

This plugin uses `vdm` as namespace. All skills appear as `vdm:{skill-name}`:
- `vdm:docs-sync` — documentation synchronization
- `vdm:learn` — knowledge integration
- `vdm:changelog` — project change tracking

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

See `skills/changelog/SKILL.md` for full documentation.

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

See `skills/learn/SKILL.md` for full documentation.

## License

MIT

## Author

Dmitry Vorobyev — [vorobyev.org](https://vorobyev.org)
