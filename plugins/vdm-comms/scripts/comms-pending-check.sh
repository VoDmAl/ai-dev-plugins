#!/bin/bash
# comms-pending-check.sh — SessionStart reminder: what is overdue right now.
#
# One line when something is overdue, falls due within a week, or was written
# and never sent; nothing at all otherwise. It never writes and never blocks:
# this is a REMINDER, and a reminder may fail open — the cost of a missed nudge
# is one nudge. (The gates in this plugin do the opposite; see lib/gate-guard.sh
# for why the two differ.)
#
# Session start is the right moment and the only one. A dated item becomes
# overdue by the calendar turning, not by anyone writing a file, so there is no
# tool call to hang this on; and the first question of a session is exactly
# "what is waiting".
#
# Silent when: `comms.pending-paths` is unset, the plugin is disabled, python3
# is missing, or nothing is due.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

# Drain stdin when invoked as a hook so the harness never blocks on the pipe.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

command -v python3 >/dev/null 2>&1 || exit 0

root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)
fi
[ -d "$root" ] || exit 0

LINTER="$SELF_DIR/comms-pending.py"
[ -f "$LINTER" ] || exit 0

out=$(python3 "$LINTER" --brief --project-root "$root" 2>/dev/null)
rc=$?
[ "$rc" -eq 1 ] || exit 0
[ -n "$out" ] || exit 0

printf '%s\n' "$out"
printf '        Who owes what: /vdm-comms:pending — or by owner:\n'
printf '        ${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --owner\n'
exit 0
