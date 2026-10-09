#!/bin/bash
# docs-sync reminder — the documents this change may leave behind, as pairs.
#
# Speaks only when there is a pair: a document outside the change that names an
# identifier the uncommitted code removed or rewrote, or that the changed code
# points at with `@see`. Silent otherwise — on a clean tree, on a change of
# documents and crystals alone, on code that no document names. The pairs come
# from lib/docs-pairs.py, the same function git-guard-prepare calls at the
# moment a commit is prepared (docs/tasks/docs-sync-signal, DL #2, #3).
#
# What it replaced: a list built from the path components of every dirty file.
# In a project whose code sits in `<project>/`, the project's name was one of
# them, every document named it, and the list was the first ten documents by
# path on every turn — 94 reminders, the same head, one skill run.
#
# Behavior governed by .claude/vdm-plugins.json:
#   enabled=false           → never fires (git-guard-prepare honours it too)
#   mode=silent             → never fires
#   mode=conditional|quiet  → looks on every prompt while the tree is dirty
#   mode=smart              → looks when the tree is dirty AND the throttle window elapsed (default)
#   mode=proactive          → as conditional; it used to speak on a clean tree too,
#                             with nothing to say but the list of all documents
#
# Throttle window: docs-sync.throttle (seconds), default 600 (10 min), or
# docs-sync.throttle-turns prompts. Per-session state under
# ${TMPDIR:-/tmp}/vdm-reminder-throttle/docs-sync-<session_id>.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true
# Loaded up front, not at the output step: the paths below are DATA that goes
# into a JSON string, and they are escaped as they are placed.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-emit.sh" 2>/dev/null || {
  _vdm_json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  _vdm_reminder_emit() { printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$4"; }
}

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
[ "$in_git" = 1 ] || exit 0

# 1. A clean tree has no change to pair with. One byte of `git status` answers
# that; which files changed is docs-pairs.py's business.
if [ -z "$(git status --porcelain -z 2>/dev/null | head -c 1)" ]; then
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

# 2. The pairs. Paths in them may be Cyrillic: Python is told its output is
# UTF-8 rather than left to guess from a locale.
command -v python3 >/dev/null 2>&1 || exit 0
pairs=$(PYTHONIOENCODING=utf-8 python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/docs-pairs.py" \
          --worktree 2>/dev/null) || exit 0
[ -n "$pairs" ] || exit 0

# --- Output Phase ---

# The count is every document that qualified, not the three listed: the lib
# ends the list with `+N more`, and that N is part of the total.
n_docs=$(printf '%s\n' "$pairs" | grep -vc '^+')
case "$pairs" in
  *$'\n+'*' more')
    n_more=${pairs##*$'\n+'}; n_more=${n_more% more}
    case "$n_more" in ''|*[!0-9]*) ;; *) n_docs=$((n_docs + n_more)) ;; esac ;;
esac
list=$(_vdm_json_escape "$(printf '%s\n' "$pairs" | sed -e '/^+/!s/^/  - /' -e '/^+/s/^/    /')")
context="[docs-sync] 📋 ${n_docs} document(s) name what the uncommitted code removed or rewrote, and did not change with it:\n${list}"
context="${context}\nRead each before the commit: a line that is now wrong goes into the same commit."
context="${context}\nThis finds pairs, not contradictions inside one document — for those, a full pass: /vdm:docs-sync"

_vdm_reminder_emit docs-sync 1 \
  "docs-sync: ${n_docs} document(s) name code this change rewrote (/vdm:docs-sync)" "$context"
