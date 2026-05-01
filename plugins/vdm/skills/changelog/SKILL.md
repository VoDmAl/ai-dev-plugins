---
name: changelog
description: "Track significant project changes in PROJECT_CHANGELOG.md. Auto-invoke after completing features, fixing bugs, or making architectural decisions. Complements docs-sync (user-facing) with project-level change tracking."
license: MIT
---

# changelog - Project Change Tracking

## Purpose

Maintains `PROJECT_CHANGELOG.md` as a concise record of significant project changes. Focus on **what changed and why**, with links to detailed documentation instead of inline descriptions.

**Relationship with docs-sync**:
- `docs-sync` → `docs/features/{feature}.md` (user-facing, per-feature)
- `changelog` → `PROJECT_CHANGELOG.md` (project-level, architectural)

## Configuration Sub-commands

`/vdm:changelog [subcommand]` recognizes these as the first word of arguments. When no subcommand matches, behave as the regular changelog skill described below.

| Subcommand | Effect on `.claude/vdm-plugins.json` → `changelog` section |
|------------|------------------------------------------------------------|
| `off` / `disable` | Set `enabled = false` (hook stays silent) |
| `on` / `enable` | Set `enabled = true` |
| `proactive` | Set `mode = "proactive"` (fires every prompt) |
| `conditional` | Set `mode = "conditional"` (fires only when tree has changes) |
| `quiet` | Set `mode = "quiet"` (same as conditional today; tightened in fase 3) |
| `silent` | Set `mode = "silent"` (never fires) |
| `config` / `status` | Read and display the current section |
| `reset` | Remove the `changelog` key (revert to defaults) |

**Defaults when the section is missing:** `enabled: true`, `mode: "conditional"`.

### Config file path detection

1. `project_root` = `git rev-parse --show-toplevel` (fallback: `pwd`)
2. If `<project_root>/.claude/` exists → `<project_root>/.claude/vdm-plugins.json`
3. Else if `<project_root>/.qwen/` exists → `<project_root>/.qwen/vdm-plugins.json`
4. Else create `<project_root>/.claude/` and write to `<project_root>/.claude/vdm-plugins.json`

### Patching rules

1. Read the file (if missing, start with `{}`).
2. Modify only the `changelog` key — preserve `learn`, `docs-sync`, `git-guard` verbatim.
3. For `reset`, delete the `changelog` key (do not leave `"changelog": {}`).
4. Use the Edit/Write tool — **do not** invoke `jq`; users may not have it.
5. Final file must be valid JSON, 2-space indent, trailing newline.

## Automatic Activation

**Via Hook:** A `UserPromptSubmit` hook reminds about changelog updates when working on significant changes.

**Auto-invoke when:**
- Completing a feature implementation
- Fixing bugs (especially production issues)
- Making architectural decisions
- Changing tooling or infrastructure
- Completing refactoring with behavioral changes

## Entry Format (Compact)

```markdown
## YYYY-MM-DD

### 🔧 TOOLING: Short Title
Brief description (1-2 sentences max).
**Ref**: docs/tasks/detailed-prd.md, .serena/memories/related_memory.md

### ✨ FEATURE: Feature Name
What was added and why.
**Ref**: docs/features/feature-name.md

### 🐛 BUG: Issue Description
Root cause and fix summary.
**Ref**: docs/tasks/bugfix-workflow.md

### 🏗️ ARCH: Architecture Change
Decision and rationale.
**Ref**: docs/llm/architecture-pattern.md
```

## Entry Types

| Emoji | Type | When to Use |
|-------|------|-------------|
| ✨ | FEATURE | New user-facing functionality |
| 🐛 | BUG | Bug fixes, especially production issues |
| 🔧 | TOOLING | Infrastructure, CI/CD, dev environment |
| 🏗️ | ARCH | Architectural decisions, patterns |
| 📝 | DOCS | Documentation restructuring |
| ⚡ | PERF | Performance improvements |
| 🔒 | SEC | Security fixes or enhancements |

## Behavioral Protocol

### Phase 1: Detection
At task completion, check if change is changelog-worthy:

```
📋 Changelog check:
   Type: {FEATURE|BUG|TOOLING|ARCH|...}
   Summary: {one-line description}
   References: {existing docs/PRDs/memories}
```

### Phase 2: Entry Creation
If PROJECT_CHANGELOG.md doesn't exist, create with template.

Add entry at TOP of file (newest first), under today's date header.

**Key principle**: Keep entries SHORT. Link to details, don't duplicate them.

### Phase 3: Verification
```
✅ PROJECT_CHANGELOG.md updated
   Entry: {type}: {title}
   Date: {YYYY-MM-DD}
   Refs: {linked documents}
```

## What Requires Entry

| Change Type | Entry? | Rationale |
|-------------|--------|-----------|
| New feature | ✅ YES | User-visible capability |
| Bug fix | ✅ YES | Especially production bugs |
| Tooling change | ✅ YES | Affects development workflow |
| Architecture decision | ✅ YES | Future reference |
| Refactoring (behavior unchanged) | ⚠️ Maybe | Only if significant |
| Typo fixes | ❌ NO | Too minor |
| Config tweaks | ❌ NO | Unless affects workflow |

## Project Initialization

If `PROJECT_CHANGELOG.md` doesn't exist:

```markdown
# Project Changelog

This file tracks significant changes: features, bugs, architecture decisions, and tooling updates.

**Format**: Compact entries with links to detailed documentation.

---

## YYYY-MM-DD

### ✨ FEATURE: Initial Setup
Project initialized with changelog tracking.
```

## Integration with Other Skills

**With docs-sync:**
```bash
# After feature work
/vdm:docs-sync      # Update docs/features/
/vdm:changelog      # Add PROJECT_CHANGELOG entry
```

**With learn:**
```bash
# After discovering pattern
/vdm:learn "pattern"  # Capture to docs/llm/ or memory
/vdm:changelog        # Reference in changelog if significant
```

## Examples

### Good Entry (Compact)
```markdown
### 🐛 BUG: Swiss Tournament Round Tracking
Fixed race saturation bug where participants competed 9 times in 16 races.
**Ref**: docs/tasks/swiss-tournament-critical-bugs-fix.md
```

### Bad Entry (Too Verbose)
```markdown
### 🐛 BUG: Swiss Tournament Round Tracking Bug Fix

**What Changed:**
- Fixed catastrophic production bug in Swiss tournament round tracking
- Refactored `UnitRaceService::createRun()` to properly compute round numbers
- Added 4 new private methods for robust round determination logic

**Root Cause:**
- Manual race creation bypassed round tracking logic...
[50+ more lines of detail]
```

## Quality Gates

**Entry is complete when:**
- [ ] Type emoji and category correct
- [ ] Title is concise (5-10 words)
- [ ] Description is 1-2 sentences max
- [ ] References link to detailed docs (if they exist)
- [ ] Entry is under today's date header
- [ ] Entry is at TOP of that day's section
