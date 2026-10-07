#!/bin/bash
# memory-scope-hook.sh — PostToolUse (Write|Edit|MultiEdit): a memory record
# written without a valid `scope:` gets one reminder, as additionalContext.
#
# A reminder, not a gate: it never blocks, and it fails open — without python3
# it says nothing (a missed nudge costs one nudge). Old records are not touched:
# only the record just written is read. The logic and its reasons live in
# memory-scope.py.
#
# @see plugins/vdm/scripts/memory-scope.py
# @see docs/tasks/hq-lessons-up/workitem.md — DL #3, DL #4

set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "learn" || { cat >/dev/null 2>&1; exit 0; }
fi
command -v python3 >/dev/null 2>&1 || { cat >/dev/null 2>&1; exit 0; }
python3 "$SELF_DIR/memory-scope.py" hook 2>/dev/null
exit 0
