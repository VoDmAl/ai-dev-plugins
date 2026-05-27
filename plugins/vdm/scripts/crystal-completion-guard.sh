#!/bin/bash
# crystal-completion-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Implements the primary gate from docs/tasks/crystal-design Decision Log #4
# and #7: any workitem under the crystal root cannot transition to
# `status: done` while it still has unchecked `- [ ]` items.
#
# Hook protocol (Claude Code):
#   stdin   JSON {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
#   exit 0  no-op (transition is safe, or this edit doesn't touch a workitem)
#   exit 2  stderr surfaces as feedback to the assistant — used to block the
#           done-transition with the five-path diagnostic from Decision Log #9
#
# Fail-open by design: parse errors, missing config, exotic edits — all exit 0.
# Better to miss one edit than to block the assistant on a hook bug.
#
# The actual simulator lives in the sibling crystal-completion-guard.py; this
# wrapper just resolves the crystal root via the shared lib and delegates.
# Keeping the Python in its own file avoids quoting hell inside a $(...)
# heredoc.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

if ! command -v resolve_crystal_root >/dev/null 2>&1; then
  exit 0
fi
crystal_root=$(resolve_crystal_root 2>/dev/null || true)
[ -z "$crystal_root" ] && exit 0

simulator="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crystal-completion-guard.py"
[ -f "$simulator" ] || exit 0

CRYSTAL_ROOT="$crystal_root" python3 "$simulator"
exit $?
