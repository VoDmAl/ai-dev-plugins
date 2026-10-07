#!/bin/bash
# memory-scope-check.sh — SessionStart: one line naming this project's memory
# records marked `hq` or `conduct` that are not lifted yet (no `shared:`).
#
# Session start, because a lesson waiting to go up waits across sessions and
# no write marks the moment. Silent when there is nothing to say, when the
# learn reminders are off, or without python3.
#
# @see plugins/vdm/scripts/memory-scope.py
# @see docs/tasks/hq-lessons-up/workitem.md — DL #3, DL #4

set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat >/dev/null 2>&1 || true   # drain the hook payload; nothing in it is needed
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "learn" || exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0
root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
python3 "$SELF_DIR/memory-scope.py" check "$root" 2>/dev/null
exit 0
