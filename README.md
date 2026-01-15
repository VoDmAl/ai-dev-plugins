# docs-sync

A Claude Code plugin for automatic synchronization between code changes and product documentation.

## What It Does

This plugin establishes a behavioral pattern where Claude automatically:

1. **Detects features** — At the start of work, identifies which feature is being modified
2. **Tracks changes** — Monitors what product capabilities are affected
3. **Syncs documentation** — Ensures `docs/features/` reflects the current product state before completing tasks

**Key principle**: Documentation is part of Definition of Done. Code changes affecting user-facing behavior are not complete without corresponding documentation updates.

## Installation

```bash
claude plugin marketplace add git@git.vorobyev.name:claude-code-marketplace.git
claude plugin install docs-sync@vodmal-claude-code-marketplace --scope user
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

### Automatic Hook (v1.1.0+)

The plugin installs a `UserPromptSubmit` hook that:
1. Checks if your project has `docs/features/` directory
2. If yes — automatically injects the documentation protocol into Claude's context
3. No keyword matching — purely project structure based

This means Claude will **always** remember to follow the documentation protocol in projects with the proper structure.

### Feature Detection

When you start working on code, Claude announces the detected feature:

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

## License

MIT

## Author

Dmitry Vorobyev — [vorobyev.org](https://vorobyev.org)
