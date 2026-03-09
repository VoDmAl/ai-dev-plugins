---
name: docs-sync
description: "INVOKE BEFORE COMPLETING any task that changes user-facing behavior. Required step in Definition of Done: sync documentation with code changes. Never declare task complete without documentation update."
license: MIT
---

# docs-sync - Automatic Documentation Synchronization

## Purpose

Ensures project documentation always reflects the current state of product capabilities. Documentation is treated as part of Definition of Done — code changes are not complete without corresponding documentation updates.

Adapts to any project documentation structure — not limited to `docs/features/`.

## Automatic Activation

**Via Hook (v2.0.0+):** A `UserPromptSubmit` hook performs lightweight discovery on every prompt:
- Detects changed files via `git diff`
- Maps all `.md` files in the project
- Extracts `@see` references from changed files
- Finds potentially affected docs via keyword matching
- Suggests running `/vdm:docs-sync` for deep analysis

**Via Skill:** Invoke `/vdm:docs-sync` explicitly for full deep discovery with relevance scoring.

This skill activates when:
- Working on code that affects user-facing product behavior
- Adding, modifying, or removing product features
- Changing commands, UI, API endpoints, or user workflows

## Deep Discovery Protocol (Manual Invocation)

When invoked via `/vdm:docs-sync`, perform the full discovery pipeline:

### Phase 1: Discovery

**Step 1 — Change detection:**
- `git diff --name-only HEAD` → list of changed files
- If clean: use conversation context to identify affected files/areas

**Step 2 — Documentation map:**
- Glob `**/*.md` across the project (exclude `.git/`, `node_modules/`, `vendor/`)
- Categorize found docs: README, CLAUDE.md, feature docs, API docs, guides, changelogs, etc.
- Note the project's documentation structure (flat, nested, by-feature, by-type)

**Step 3 — Direct references:**
- Grep changed files for `@see` annotations pointing to `.md` files
- Grep changed files for markdown links (`[text](path.md)`)
- These are highest-priority matches

**Step 4 — Keyword extraction:**
- Extract meaningful identifiers from changed files: function names, class names, config keys, endpoint paths, service names, env variables
- Search documentation files for these identifiers
- Focus on specific terms (e.g., `STRIPE_API_KEY`, `UserService`, `/api/webhooks`) over generic ones

**Step 5 — Cross-reference chains:**
- Check found docs for links to other docs → follow one level deep
- If doc A references doc B, and A is affected, B may need review too

### Phase 2: Relevance Scoring

Rank discovered documents by relevance:

| Priority | Criteria | Example |
|----------|----------|---------|
| 🔴 HIGH | Direct `@see` reference from changed file | `@see docs/stripe-setup.md` in changed code |
| 🔴 HIGH | Doc mentions changed function/class/endpoint by name | `docs/api.md` mentions `createWebhook()` |
| 🟡 MEDIUM | Thematic match (same domain/feature area) | Stripe docs + Stripe code changes |
| 🟡 MEDIUM | Cross-reference from a HIGH-priority doc | Doc linked from an affected doc |
| 🟢 LOW | General project docs (README, CLAUDE.md) | Check if they reference affected areas |
| ⚪ SKIP | No connection to current changes | Unrelated feature docs |

**Filter aggressively**: better to miss a non-obvious doc than to flood with false positives.

### Phase 3: Concrete Output

Present results as an actionable checklist:

```
📋 Documentation sync — deep analysis results:

🔴 Must update:
  - docs/stripe-setup.md — contains Stripe env vars setup, you added STRIPE_WEBHOOK_SECRET
  - .env.example — missing new STRIPE_WEBHOOK_SECRET variable

🟡 Review and update if needed:
  - CLAUDE.md — Environment Variables section, may need new var reference
  - docs/api.md — Webhooks section describes old flow, verify still accurate

🟢 Probably fine, quick check:
  - README.md — mentions Stripe integration in overview, verify still accurate

Changes to sync:
  - [specific section] in [specific file]: [what needs to change]
```

**Key principle**: not "update docs" but "in file X, section Y doesn't reflect change Z".

## Behavioral Protocol

### Feature Detection (Start of Work)

At the beginning of any task, identify the related documentation and announce:

```
📋 Feature: {feature_name} → {doc_path}
   Key files: {list of main implementation files}
```

**How to detect the feature:**
1. Check for `@see` annotations in touched files → direct doc links
2. Look at directory structure (e.g., `Service/Evernote/` → Evernote feature)
3. Analyze the task context and affected functionality
4. If unclear, ask the user to confirm

### Change Tracking (During Work)

While working, mentally track:
- What product capabilities are changing (added/modified/removed)
- What user-facing behavior is affected
- Which documentation sections will need updates

### Documentation Sync (Before Completion)

**CRITICAL**: Never declare a task "complete" or "done" without addressing documentation.

**For product changes** (affects user-facing behavior):
1. Update relevant documentation to reflect current state
2. Add changelog entry with date and brief description
3. Verify bidirectional links (code ↔ docs)

**For refactoring only** (tests confirm no behavior change):
1. Add brief changelog entry: `YYYY-MM-DD: Internal refactoring, no behavior changes`
2. No need to update main documentation sections

**Completion pattern:**
```
✅ Implementation complete
✅ Tests passing
📝 Next step: Update {doc_path}

Proposed documentation changes:
- [Section]: [What changed]
- Changelog: [Brief entry]

Proceed with documentation update?
```

## Documentation Structure

### Recommended structure (propose if absent):
```
docs/
├── features/           # Product documentation (user-facing)
│   ├── {feature}.md    # One file per feature
│   └── ...
└── llm/                # Technical documentation (LLM/dev-facing)
    └── {topic}.md      # Patterns, architecture, conventions
```

### Adaptive behavior:
- If project uses `docs/features/` — follow that convention
- If project uses flat `docs/` — work with it, don't force restructuring
- If project has only `README.md` — suggest when docs would add value, don't insist
- If project has custom structure — map it and work within it

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

**Location:** `${CLAUDE_PLUGIN_ROOT}/templates/`

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
⏳ 📝 Update {relevant_doc_path}
```

## Quality Gates

**Task is NOT complete until:**
- [ ] Code changes implemented and working
- [ ] Tests pass (confirm behavior change or preservation)
- [ ] Relevant documentation reflects current product state
- [ ] Bidirectional links verified (code @see → docs, docs → code)

## Priority Levels

| Documentation Type | Priority | When to Update |
|-------------------|----------|----------------|
| Feature/product docs | 🔴 HIGH | Any product capability change |
| Technical/LLM docs | 🟡 MEDIUM | Technical pattern changes, architectural decisions |
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

### Example 2: Project with flat docs structure

```
📋 Deep discovery results:

Changed: src/stripe/webhook.ts, src/stripe/config.ts
@see found: src/stripe/webhook.ts → docs/stripe-setup.md

🔴 Must update:
  - docs/stripe-setup.md — references old webhook URL format, you changed endpoint path
  - .env.example — add STRIPE_WEBHOOK_SECRET

🟡 Review:
  - README.md — "Stripe Integration" section, verify setup steps still accurate
```

### Example 3: Refactoring without behavior change

```
📋 Feature: /pocket → docs/features/pocket.md
   Key files: Service/Pocket/PocketService.php

Working on: Extracting authentication logic to separate class

✅ Refactoring complete
✅ All tests passing (behavior unchanged)
📝 Updating docs/features/pocket.md:
   - Changelog only: 2026-01-15: Internal refactoring, no behavior changes
```
