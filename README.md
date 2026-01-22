# vdm — Claude Code Plugins

A collection of Claude Code plugins by Dmitry Vorobyev.

## Available Skills

| Skill | Command | Description |
|-------|---------|-------------|
| docs-sync | `/vdm:docs-sync` | Automatic documentation synchronization for `docs/features/` |
| learn | `/vdm:learn` | Intelligent knowledge integration with scenario detection |

## What It Does

### docs-sync
Ensures `docs/features/` always reflects current product state. Documentation is part of Definition of Done — code changes are not complete without corresponding documentation updates.

### learn
Systematically captures and preserves project knowledge. Auto-detects scenario type (problem/discovery/standard) and routes through appropriate analysis:
- **Problems** → `/sc:troubleshoot` → root cause analysis → knowledge integration
- **Discoveries** → Technical documentation → `docs/llm/` patterns
- **Standards** → Systematic documentation across CLAUDE.md, Serena Memory, and `docs/llm/`

**Auto-activation**: Claude will proactively invoke this skill when:
- Finding solutions after struggling with issues
- Discovering effective patterns worth preserving
- Making mistakes that should never repeat

## Installation

```bash
claude plugin marketplace add git@git.vorobyev.name:claude-code-marketplace.git
claude plugin install vdm@vodmal-claude-code-marketplace --scope user
```

## How docs-sync and learn Work Together

| Aspect | docs-sync | learn |
|--------|-----------|-------|
| Focus | `docs/features/` | `docs/llm/` + CLAUDE.md + Serena Memory |
| Audience | Users, stakeholders | LLMs, developers |
| Trigger | Code changes | Knowledge capture |
| Content | Product capabilities | Technical patterns, lessons |

**Typical workflow:**
```bash
# After implementing a feature
/vdm:docs-sync              # Update user-facing docs in docs/features/
/vdm:learn "Pattern I used" # Capture technical knowledge in docs/llm/
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

### Automatic Hooks (v1.2.0+)

The plugin installs `UserPromptSubmit` hooks that run on **every prompt**:

**docs-sync reminder:**
```
[docs-sync] ⚠️ BEFORE completing user-facing changes...
```

**learn reminder:**
```
[learn] 💡 After resolving issues or discovering patterns...
```

These hooks remind Claude about documentation and knowledge capture without requiring manual invocation.

### Skill Protocol (`/vdm:docs-sync`)

When invoked, the skill instructs Claude to:

1. **Detect features** — Identify which feature is being modified
2. **Track changes** — Monitor what product capabilities are affected
3. **Sync documentation** — Update `docs/features/` before completing tasks

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
