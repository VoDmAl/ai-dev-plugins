# Project Changelog

This file tracks significant changes: features, bugs, architecture decisions, and tooling updates.

**Format**: Compact entries with links to detailed documentation.

**Entry types**: ✨ FEATURE | 🐛 BUG | 🔧 TOOLING | 🏗️ ARCH | 📝 DOCS | ⚡ PERF | 🔒 SEC

---

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
