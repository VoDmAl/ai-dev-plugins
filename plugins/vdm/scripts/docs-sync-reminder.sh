#!/bin/bash
# docs-sync smart discovery hook.
# Behavior governed by .claude/vdm-plugins.json:
#   enabled=false           → never fires
#   mode=silent             → never fires
#   mode=conditional|quiet  → fires only when working tree has changes (no throttle)
#   mode=smart              → fires when tree dirty AND throttle window elapsed (default)
#   mode=proactive          → fires every prompt, even on a clean tree (skinny payload, no throttle)
# Budget: runs under scripts/reminders.sh, whose deadline (25 s) replaced the
# 5 s per-hook timeout in vdm 2.32.0. Still meant to take well under a second.
#
# Throttle window: docs-sync.throttle (seconds), default 600 (10 min). Per-session
# state under ${TMPDIR:-/tmp}/vdm-reminder-throttle/docs-sync-<session_id>.
#
# The discovery phase (find + grep across project .md files) is heavy enough
# that throttling matters: pre-v2.8.0 default `conditional` re-ran it on every
# prompt while the tree was dirty.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true

vdm_is_enabled "docs-sync" || exit 0
mode=$(vdm_get_mode "docs-sync" "smart")
[ "$mode" = "silent" ] && exit 0

# Capture payload up-front so the stdin buffer is drained before we shell out
# to git/find/grep below. session_id extraction needs the payload too.
payload=$(cat 2>/dev/null || true)

# --- Discovery Phase ---

# Every git call below is a read. None of them may take the OPTIONAL index lock
# that `git status` grabs to refresh stat info: on a machine where several
# sessions work in one repository, a reminder that contends for `index.lock`
# with a real commit is a reminder that can make that commit fail.
export GIT_OPTIONAL_LOCKS=0
in_git=0
git rev-parse --is-inside-work-tree &>/dev/null && in_git=1

# 1. Changed files — modified, staged, and untracked. We use porcelain status
# so newly created files (which `git diff` ignores) also surface in reminders.
# Strip the 2-char status code and any rename arrow ("old -> new" → "new").
changed_files=""
if [ "$in_git" = 1 ]; then
  changed_files=$(git status --porcelain 2>/dev/null | sed -E 's/^.{2} //;s/^.* -> //')
fi

# Smart/conditional firing: nothing to report when the tree is clean.
# Proactive mode falls through and emits a skinny payload (project docs map only).
if [ -z "$changed_files" ] && [ "$mode" != "proactive" ]; then
  exit 0
fi

# Throttle gate (smart only) — short-circuits before the heavy discovery step.
if [ "$mode" = "smart" ]; then
  sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
  throttle=$(vdm_config_read "docs-sync" "throttle" "600")
  turns=$(vdm_config_read "docs-sync" "throttle-turns" "5")
  if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
    if _vdm_reminder_throttle_check "docs-sync" "$throttle" "$sid" "$turns"; then
      exit 0
    fi
    _vdm_reminder_throttle_touch "docs-sync" "$sid"
  fi
fi

# 2. The project's .md files. In a git work tree, git already knows them —
# tracked plus untracked-but-not-ignored — without walking the tree and while
# honouring .gitignore. The old `find . | head -30` did neither: it walked every
# ignored .venv / target / Pods, and it capped the list at the first thirty in
# directory order, so "Project docs (30)" was a ceiling rather than a count and
# which thirty depended on the filesystem. Measured on a 60k-file fixture: the
# count said 30 for 640 files, and four of the project's own guides were missing.
# Outside git, `find` with the heavy directories pruned — never descended into.
if [ "$in_git" = 1 ]; then
  md_files=$(git ls-files -co --exclude-standard -- '*.md' 2>/dev/null \
             | grep -vE '^(\.claude|\.serena)/' | sort)
else
  md_files=$(find . \( -name .git -o -name node_modules -o -name vendor -o -name .claude \
               -o -name .serena -o -name .venv -o -name venv -o -name target -o -name dist \
               -o -name build -o -name Pods -o -name __pycache__ \) -prune \
             -o -type f -name '*.md' -print 2>/dev/null | head -2000 | sed 's|^\./||' | sort)
fi

# 3. Extract @see references from changed files
see_refs=""
if [ -n "$changed_files" ]; then
  while IFS= read -r f; do
    if [ -f "$f" ]; then
      # `grep -P` is not portable: the stock macOS grep has no -P, and with
      # 2>/dev/null the refusal read as "no @see found" — this section never
      # appeared on a Mac. sed -E is in every base system.
      refs=$(sed -nE 's/.*@see[[:space:]]+([^[:space:]]+).*/\1/p' "$f" 2>/dev/null \
             | grep -i '\.md' | head -5 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
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
  if [ -n "$pattern" ] && [ "$in_git" = 1 ]; then
    # One process over every doc, instead of one grep per file over the first
    # thirty the filesystem happened to return.
    relevant_docs=$(git grep --untracked -l -i -E -e "$pattern" -- '*.md' \
                      ':(exclude).claude' ':(exclude).serena' 2>/dev/null | head -10)
  elif [ -n "$pattern" ]; then
    relevant_docs=$(echo "$md_files" | head -500 | while IFS= read -r md; do
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
  context="${context}\n\n@see references found:\n${see_refs%\\n}"
fi

# Project documentation map. Truncated like `changed_files` above — the
# truncation was written for that block and never applied to this one, which is
# the larger by far: measured 2026-09-10 in the field, the full list was 1018
# of this hook's 1835 bytes (55%), while the section that actually answers the
# question — `Potentially affected docs` — was 98 bytes (5%). The hook was
# spending its budget printing its INPUT.
#
# It is also a property of the repository, not of the turn: identical on every
# prompt of the session. A sample plus the count says the same thing.
if [ -n "$md_files" ]; then
  md_count=$(echo "$md_files" | wc -l | tr -d ' ')
  md_list=$(echo "$md_files" | head -10 | tr '\n' ', ' | sed 's/,$//')
  if [ "$md_count" -gt 10 ]; then
    md_list="${md_list}, … (+$((md_count - 10)))"
  fi
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

# Output
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-emit.sh" 2>/dev/null \
  || _vdm_reminder_emit() { printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$4"; }
_vdm_reminder_emit docs-sync 1 \
  "docs-sync: user-facing change → verify affected docs (/vdm:docs-sync)" "$context"
