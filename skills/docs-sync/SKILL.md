---
name: docs-sync
description: "INVOKE BEFORE COMPLETING any task that changes user-facing behavior. Required step in Definition of Done: sync docs/features/ with code changes. Never declare task complete without documentation update."
license: MIT
---

# docs-sync - Automatic Documentation Synchronization

## Purpose

Ensures `docs/features/` always reflects the current state of product capabilities. Documentation is treated as part of Definition of Done — code changes are not complete without corresponding documentation updates.

## Automatic Activation

**Via Hook (v1.1.0+):** A `UserPromptSubmit` hook automatically injects this protocol when the project has `docs/features/` directory. No manual invocation needed.

**Via Skill:** Invoke `/docs-sync` explicitly for full protocol details.

This skill activates when:
- Working on code that affects user-facing product behavior
- Adding, modifying, or removing product features
- Changing commands, UI, API endpoints, or user workflows

## Behavioral Protocol

### Phase 1: Feature Detection (Start of Work)

At the beginning of any task, identify the related feature and announce:

```
📋 Feature: {feature_name} → docs/features/{file}.md
   Key files: {list of main implementation files}
```

**How to detect the feature:**
1. Check for `@see docs/features/...` annotations in touched files
2. Look at directory structure (e.g., `Service/Evernote/` → Evernote feature)
3. Analyze the task context and affected functionality
4. If unclear, ask the user to confirm

### Phase 2: Change Tracking (During Work)

While working, mentally track:
- What product capabilities are changing (added/modified/removed)
- What user-facing behavior is affected
- Which documentation sections will need updates

### Phase 3: Documentation Sync (Before Completion)

**CRITICAL**: Never declare a task "complete" or "done" without addressing documentation.

**For product changes** (affects user-facing behavior):
1. Update `docs/features/{feature}.md` to reflect current state
2. Add changelog entry with date and brief description
3. Verify bidirectional links (code ↔ docs)

**For refactoring only** (tests confirm no behavior change):
1. Add brief changelog entry: `YYYY-MM-DD: Internal refactoring, no behavior changes`
2. No need to update main documentation sections

**Completion pattern:**
```
✅ Implementation complete
✅ Tests passing
📝 Next step: Update docs/features/{feature}.md

Proposed documentation changes:
- [Section]: [What changed]
- Changelog: [Brief entry]

Proceed with documentation update?
```

## Documentation Structure Convention

All projects should have:
```
docs/
├── features/           # Product documentation (user-facing)
│   ├── {feature}.md    # One file per feature
│   └── ...
└── llm/                # Technical documentation (LLM/dev-facing)
    └── {topic}.md      # Patterns, architecture, conventions
```

**If structure doesn't exist**: Propose creating it before proceeding with feature work.

## Cross-Language @see Convention

Link code to documentation using language-appropriate annotations:

| Technology | Format |
|------------|--------|
| PHP | `/** @see docs/features/reminder.md */` |
| JavaScript/TypeScript | `/** @see docs/features/auth.md */` |
| Python | `# @see docs/features/analytics.md` |
| Twig/Jinja | `{# @see docs/features/templates.md #}` |
| HTML | `<!-- @see docs/features/ui.md -->` |
| YAML/Config | `# @see docs/features/config.md` |
| Go | `// @see docs/features/api.md` |
| Rust | `//! @see docs/features/core.md` |
| Shell | `# @see docs/features/cli.md` |

## Feature Documentation Templates

When creating new documentation, use the templates from this plugin:

**Location:** `~/.claude/plugins/cache/vodmal-claude-code-marketplace/docs-sync/*/templates/`

| Template | Purpose | Target |
|----------|---------|--------|
| `feature-template.md` | User-facing feature docs | `docs/features/{feature}.md` |
| `llm-template.md` | Technical/LLM guidance | `docs/llm/{topic}.md` |

Copy the appropriate template and fill in the placeholders.

## Integration with TodoWrite

When creating task lists for feature work, always include documentation:

```
⏳ Implement {feature change}
⏳ Add/update tests
⏳ 📝 Update docs/features/{feature}.md
```

## Quality Gates

**Task is NOT complete until:**
- [ ] Code changes implemented and working
- [ ] Tests pass (confirm behavior change or preservation)
- [ ] `docs/features/` reflects current product state
- [ ] Bidirectional links verified (code @see → docs, docs → code)

## Priority Levels

| Documentation Type | Priority | When to Update |
|-------------------|----------|----------------|
| `docs/features/` | 🔴 HIGH | Any product capability change |
| `docs/llm/` | 🟡 MEDIUM | Technical pattern changes, architectural decisions |
| Code `@see` links | 🟢 NORMAL | When creating new files or major refactoring |

## Examples

### Example 1: Adding a new command parameter

```
📋 Feature: /remind → docs/features/reminder.md
   Key files: Commands/ReminderCommand.php, ReminderTrait.php

Working on: Adding --priority flag to /remind command

✅ Implementation complete
✅ Tests passing
📝 Updating docs/features/reminder.md:
   - Usage section: Added --priority parameter documentation
   - Changelog: 2026-01-15: Added priority flag for reminder urgency levels
```

### Example 2: Refactoring without behavior change

```
📋 Feature: /pocket → docs/features/pocket.md
   Key files: Service/Pocket/PocketService.php

Working on: Extracting authentication logic to separate class

✅ Refactoring complete
✅ All tests passing (behavior unchanged)
📝 Updating docs/features/pocket.md:
   - Changelog only: 2026-01-15: Internal refactoring, no behavior changes
```

### Example 3: Project without docs structure

```
⚠️ Documentation structure not found.

This project doesn't have the standard docs/ structure.
Recommend creating:

docs/
├── features/    # Product documentation
└── llm/         # Technical documentation

Create this structure now? This enables automatic documentation sync for all future work.
```
