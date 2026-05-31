#!/bin/bash
# crystal-completion-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Implements the primary gate from docs/tasks/crystal-design Decision Log #4
# and #7 (done-transition completion discipline) plus the superseded-by
# requirement from crystal-multi-root DL #10.
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
# The wrapper resolves all crystal roots and the active status-alias sets
# (canonical "done"/"superseded" plus any aliases that map to them), passing
# them via env to the Python simulator. Keeping Python pure-stdlib and
# env-driven avoids quoting hell inside a $(...) heredoc.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

if ! command -v resolve_crystal_roots >/dev/null 2>&1; then
  exit 0
fi

# Collect roots as colon-separated. Empty = nothing to guard.
roots_colon=$(resolve_crystal_roots | tr '\n' ':' | sed 's/:$//')
[ -z "$roots_colon" ] && exit 0

# Build gate value sets — canonical terminal status + any status-aliases that
# resolve to it. Status-aliases let projects use their own vocab while still
# tripping the gate. Default to bare canonical when jq/config unavailable.
gate_values_for() {
  local target="$1"
  printf '%s' "$target"
  command -v jq >/dev/null 2>&1 || return 0
  local cfg
  cfg=$(resolve_config_path 2>/dev/null) || return 0
  [ -f "$cfg" ] || return 0
  local aliases
  aliases=$(jq -r --arg t "$target" '
    .crystal["status-aliases"] // {} | to_entries[] | select(.value == $t) | .key
  ' "$cfg" 2>/dev/null)
  if [ -n "$aliases" ]; then
    printf ',%s' $(printf '%s' "$aliases" | tr '\n' ' ')
  fi
}

done_csv=$(gate_values_for "done")
superseded_csv=$(gate_values_for "superseded")

simulator="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crystal-completion-guard.py"
[ -f "$simulator" ] || exit 0

CRYSTAL_ROOTS="$roots_colon" \
CRYSTAL_GATE_DONE="$done_csv" \
CRYSTAL_GATE_SUPERSEDED="$superseded_csv" \
  python3 "$simulator"
exit $?
