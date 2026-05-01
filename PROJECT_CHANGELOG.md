# Project Changelog

This file tracks significant changes: features, bugs, architecture decisions, and tooling updates.

**Format**: Compact entries with links to detailed documentation.

**Entry types**: ✨ FEATURE | 🐛 BUG | 🔧 TOOLING | 🏗️ ARCH | 📝 DOCS | ⚡ PERF | 🔒 SEC

---

## 2026-05-01

### 📝 DOCS: agent-agnostic skill text standard
Replaced hardcoded "Claude" agent-name references in `plugins/vdm-git/skills/guard/SKILL.md`, `plugins/vdm/skills/learn/SKILL.md`, and `plugins/vdm/scripts/learn-reminder.sh` with generic "the assistant" terminology. The plugins run under multiple AI harnesses (Claude Code primary, Qwen Code supported), so naming any one model implicitly tells the others "this isn't for you." Standard captured in `CLAUDE.md` → "Authoring standard: agent-agnostic skill text".
**Ref**: CLAUDE.md, plugins/vdm-git/skills/guard/SKILL.md, plugins/vdm/skills/learn/SKILL.md, plugins/vdm/scripts/learn-reminder.sh

### ✨ FEATURE: project-aware commit suggestions in git-guard (vdm-git v2.2.0)
When `git-guard` intercepts a `git commit`, it now detects the project's commit message convention (priority: `git config commit.template` → `.gitmessage*` → `commitlint*` → Commit section in `CLAUDE.md` / `CONTRIBUTING.md` / `README.md` → pattern detection from `git log -30`) and emits instructions for the assistant to compose a ready-to-paste command using session context. Output includes the staged file list and an explicit hint to present the command as inline code (single backticks) so copy-paste preserves no leading whitespace. `git push` continues to block without suggestions.
**Ref**: plugins/vdm-git/scripts/git-guard-hook.py, docs/tasks/phase-3-hook-extensions.md (deferred work)

### 📝 DOCS: phase-3 deferred work captured as PRD
Adds `docs/tasks/phase-3-hook-extensions.md` describing the deferred extensions (`prompt_keywords`, `ignore_paths`, real `quiet` thresholds, optional cooldown) with explicit decision criteria — what real-session feedback would justify reopening, and what would close the task entirely.
**Ref**: docs/tasks/phase-3-hook-extensions.md

### 🔧 TOOLING: dev-time lib-sync guard
Adds `scripts/check-lib-sync.sh` plus `.githooks/pre-commit` that detect drift between `plugins/vdm/lib/` and `plugins/vdm-git/lib/` (must stay byte-identical modulo cross-reference comments). Activate locally via `git config core.hooksPath .githooks`. A SessionStart hook in `.claude/settings.json` warns (warn-only — never auto-modifies `.git/config`) when the dev hooks aren't wired up after a fresh clone, plus a top-level `CLAUDE.md` documents the dev setup. A matching GitHub Actions workflow is documented in README but not committed (blocked by local security hook).
**Ref**: scripts/check-lib-sync.sh, scripts/ensure-githooks.sh, .githooks/pre-commit, .claude/settings.json, CLAUDE.md, README.md (Development section)

### ✨ FEATURE: per-project hook config + skill self-config (vdm v2.2.0, vdm-git v2.1.0)
Adds `.claude/vdm-plugins.json` (or `.qwen/vdm-plugins.json`) for granular per-project control of every reminder hook. Each skill (`/vdm:changelog`, `/vdm:learn`, `/vdm:docs-sync`, `/vdm-git:guard`) now accepts subcommands `off` / `on` / `proactive` / `conditional` / `quiet` / `silent` / `config` / `reset` to edit its own section without manual JSON editing. Modes: `proactive` (always fires), `conditional` (fires only when working tree has changes — now sees untracked files via `git status --porcelain`), `quiet` (alias for conditional in this release; tightened in fase 3), `silent` (never fires). Note: `git-guard`'s PreToolUse blocking hook is intentionally not configurable — only the reminder text is.
**Ref**: plugins/vdm/lib/, plugins/vdm-git/lib/, README.md (Configuration section)

### 🔧 TOOLING: hooks silent on clean tree (vdm v2.1.1)
`changelog` and `docs-sync` reminders now exit silently when the working tree has no uncommitted changes. Reduces ambient noise — feedback from real sessions showed agents starting to ignore reminders that fired regardless of relevance (habituation). `learn` and `git-guard` remain proactive by design.
**Ref**: plugins/vdm/scripts/changelog-reminder.sh, plugins/vdm/scripts/docs-sync-reminder.sh

## 2026-03-09

### 🏗️ ARCH: Rename to ai-dev-plugins, move to GitHub
Repository renamed from `cc-vdm-plugins` to `ai-dev-plugins`. `dev` chosen over `code` to cover full SDLC (QA, docs, DevOps). Remote moved from own git server to `github.com/VoDmAl/ai-dev-plugins`. Marketplace source switched to GitHub shorthand.
**Ref**: README.md (Naming Convention & Scope)

### 🏗️ ARCH: Split into modular plugins (v2.0.0)
Monolithic `vdm` plugin split into two independently installable plugins via `git-subdir`: `vdm` (core: docs-sync, learn, changelog) and `vdm-git` (optional: guard). git-guard skill renamed to `guard` under `vdm-git` namespace (`/vdm-git:guard`).
**Ref**: README.md (Installation, Namespaces)

### ✨ FEATURE: learn skill — improved routing & Serena optional (v2.1.0)
Learn skill routing updated: CLAUDE.md now accepts concise behavioral rules (not only safety-critical), `docs/llm/` is auto-created when missing instead of falling back to memory. Serena Memory marked as optional enhancement with graceful degradation.
**Ref**: plugins/vdm/skills/learn/SKILL.md

## 2026-03-04

### ✨ FEATURE: docs-sync v2.0 — smart discovery (hook + skill)
Hook upgraded from static reminder to dynamic discovery: git diff detection, .md mapping, @see extraction, keyword matching. SKILL.md enhanced with Deep Discovery Protocol (Phase 1-3: Discovery → Relevance Scoring → Concrete Output), adaptive project structure support, and actionable checklists.
**Ref**: scripts/docs-sync-reminder.sh, skills/docs-sync/SKILL.md

## 2026-03-03

### ✨ FEATURE: learn skill — interactive clarification phase (v1.6.0)
Added Phase 1.5: Interactive Clarification between scenario detection and routing. Analyzes conversation context, proposes 2-4 concrete knowledge formulations via AskUserQuestion (multiSelect), lets user select/edit before integration. Auto-skips when input is already precise or `--no-ask` flag is set.
**Ref**: skills/learn/SKILL.md (Phase 1.5, Manual Override Flags)

## 2026-01-23

### 📝 DOCS: learn skill routing clarification
Clarified permanent vs transient knowledge routing: version conflicts and API constraints → docs/llm/ (permanent), environment config → Serena Memory (transient).
**Ref**: skills/learn/SKILL.md (Example 4, Decision Tree)

## 2026-01-22

### ✨ FEATURE: changelog skill (v1.4.0)
Project change tracking in `PROJECT_CHANGELOG.md`. Compact format with refs to detailed docs.
**Ref**: skills/changelog/SKILL.md

### ✨ FEATURE: learn skill (v1.3.0)
Intelligent knowledge integration with scenario detection (problem/discovery/standard).
**Ref**: skills/learn/SKILL.md

## 2026-01-15

### ✨ FEATURE: docs-sync skill (v1.0.0)
Automatic documentation synchronization for `docs/features/`. Part of Definition of Done.
**Ref**: skills/docs-sync/SKILL.md
