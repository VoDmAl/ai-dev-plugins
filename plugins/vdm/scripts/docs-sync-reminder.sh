#!/bin/bash
# docs-sync smart discovery hook.
# Behavior governed by .claude/vdm-plugins.json:
#   enabled=false       → never fires
#   mode=silent         → never fires
#   mode=conditional|quiet → fires only when working tree has changes (default)
#   mode=proactive      → fires every prompt, even on a clean tree (skinny payload)
# Budget: must complete within 5s timeout.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

vdm_is_enabled "docs-sync" || exit 0
mode=$(vdm_get_mode "docs-sync" "conditional")
[ "$mode" = "silent" ] && exit 0

# --- Discovery Phase ---

# 1. Changed files — modified, staged, and untracked. We use porcelain status
# so newly created files (which `git diff` ignores) also surface in reminders.
# Strip the 2-char status code and any rename arrow ("old -> new" → "new").
changed_files=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
  changed_files=$(git status --porcelain 2>/dev/null | sed -E 's/^.{2} //;s/^.* -> //')
fi

# Conditional firing: nothing to report when the tree is clean.
# Proactive mode falls through and emits a skinny payload (project docs map only).
if [ -z "$changed_files" ] && [ "$mode" != "proactive" ]; then
  exit 0
fi

# 2. Find all .md files in project (exclude node_modules, vendor, .git)
md_files=$(find . -name "*.md" \
  -not -path "./.git/*" \
  -not -path "./node_modules/*" \
  -not -path "./vendor/*" \
  -not -path "./.claude/*" \
  -not -path "./.serena/*" \
  2>/dev/null | head -30 | sed 's|^\./||' | sort)

# 3. Extract @see references from changed files
see_refs=""
if [ -n "$changed_files" ]; then
  while IFS= read -r f; do
    if [ -f "$f" ]; then
      refs=$(grep -oP '@see\s+\K\S+' "$f" 2>/dev/null | grep -i '\.md' | head -5)
      if [ -n "$refs" ]; then
        see_refs="${see_refs}${f}: ${refs}\n"
      fi
    fi
  done <<< "$changed_files"
fi

# 4. Extract keywords from changed file paths (directory names, file basenames without extension)
keywords=""
if [ -n "$changed_files" ]; then
  keywords=$(echo "$changed_files" | while IFS= read -r f; do
    # Get meaningful path segments (skip common dirs like src, lib, app)
    echo "$f" | tr '/' '\n' | sed 's/\.[^.]*$//' | grep -viE '^(src|lib|app|index|main|test|spec|__tests__|scripts|hooks|config|utils|helpers|common|shared|types|models|services|controllers|templates|docs|features|public|assets|styles|dist|build|vendor|node_modules)$' | grep -E '.{4,}'
  done | sort -u | head -10 | tr '\n' ', ' | sed 's/,$//')
fi

# 5. Find .md files that mention keywords from changed files
relevant_docs=""
if [ -n "$keywords" ] && [ -n "$md_files" ]; then
  # Build grep pattern from top keywords (max 5 to stay fast)
  pattern=$(echo "$keywords" | tr ',' '\n' | head -5 | sed 's/^ *//' | tr '\n' '|' | sed 's/|$//')
  if [ -n "$pattern" ]; then
    relevant_docs=$(echo "$md_files" | while IFS= read -r md; do
      if [ -f "$md" ] && grep -qilE "$pattern" "$md" 2>/dev/null; then
        echo "$md"
      fi
    done | head -10)
  fi
fi

# --- Output Phase ---

context="[docs-sync] 📋 Documentation sync context:"

# Changed files summary. In proactive mode this block may be skipped when the
# tree is clean — the rest of the payload (project docs map, footer) still emits.
if [ -n "$changed_files" ]; then
  file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
  file_list=$(echo "$changed_files" | head -10 | tr '\n' ', ' | sed 's/,$//')
  context="${context}\n\nChanged files (${file_count}): ${file_list}"
fi

# @see references
if [ -n "$see_refs" ]; then
  context="${context}\n\n@see references found:\n${see_refs}"
fi

# Project documentation map
if [ -n "$md_files" ]; then
  md_count=$(echo "$md_files" | wc -l | tr -d ' ')
  md_list=$(echo "$md_files" | tr '\n' ', ' | sed 's/,$//')
  context="${context}\n\nProject docs (${md_count}): ${md_list}"
else
  context="${context}\n\nNo .md documentation found in project."
fi

# Relevant docs (keyword matches)
if [ -n "$relevant_docs" ]; then
  rel_list=$(echo "$relevant_docs" | tr '\n' ', ' | sed 's/,$//')
  context="${context}\n\nPotentially affected docs: ${rel_list}"
fi

# Action guidance
context="${context}\n\nBEFORE completing user-facing changes: verify listed docs reflect current behavior."
context="${context}\nFor deep analysis with relevance scoring → run /vdm:docs-sync"

# Output JSON
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
