# docs-sync

A Claude Code plugin for automatic synchronization between code changes and product documentation.

## What It Does

This plugin establishes a behavioral pattern where Claude automatically:

1. **Detects features** — At the start of work, identifies which feature is being modified
2. **Tracks changes** — Monitors what product capabilities are affected
3. **Syncs documentation** — Ensures `docs/features/` reflects the current product state before completing tasks

**Key principle**: Documentation is part of Definition of Done. Code changes affecting user-facing behavior are not complete without corresponding documentation updates.

## Installation

### Option 1: Install from Git Repository

```bash
# Add as a marketplace (if you host multiple plugins)
claude /plugin marketplace add git.vorobyev.name/vdm/docs-sync-plugin

# Or install directly
claude plugin install docs-sync@git.vorobyev.name/vdm/docs-sync-plugin
```

### Option 2: Local Installation

```bash
# Clone the repository
git clone https://git.vorobyev.name/vdm/docs-sync-plugin.git ~/.claude/plugins/docs-sync-plugin

# Install from local path
claude --plugin-dir ~/.claude/plugins/docs-sync-plugin
```

### Option 3: Add to Project

For project-specific installation, add to your project's `.claude/settings.json`:

```json
{
  "enabledPlugins": [
    "docs-sync@your-marketplace"
  ]
}
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

### Automatic Feature Detection

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
- Changelog: 2025-01-15: Added priority flag

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

Copy these to your project when creating new documentation files.

## Behavior Summary

| Scenario | Claude's Action |
|----------|-----------------|
| Product capability change | Update `docs/features/`, require before completion |
| Refactoring (tests pass) | Add changelog entry only |
| New feature | Create `docs/features/{feature}.md` from template |
| No docs structure | Propose creating `docs/features/` and `docs/llm/` |

## Configuration

No configuration required. The plugin activates automatically for any project with code changes.

## Compatibility

- **Claude Code**: 1.0+
- **Works with**: Any programming language/framework
- **Integrates with**: SuperClaude Framework, standard Claude Code workflows

## License

MIT

## Author

Dmitry Vorobyev — [vorobyev.org](https://vorobyev.org)
