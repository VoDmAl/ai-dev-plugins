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
# A second line names sent letters edited since their commit (comms-pending.py
# → edited_records): an editor's write passes every hook, and a record of what
# went out then drifts unseen. That one does not need `pending-paths`.
#
# Silent when: the plugin is disabled, python3 is missing, or nothing is due
# and no sent letter differs from HEAD.

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

# Both scripts below read the same comms.pending-paths. Side by side the hook
# takes the longer of the two rather than their sum, and both stop at a deadline
# under the harness's timeout (hooks.json: 30 s) and say so, instead of being
# killed by it in silence — which reads exactly like a check that found nothing
# (vault agent, 2026-10-24: 29.7 s of the 30 over a 22k-note tree).
COMMS_DEADLINE_AT=$(( $(date +%s) + ${COMMS_HOOK_BUDGET:-25} ))
export COMMS_DEADLINE_AT
work=$(mktemp -d "${TMPDIR:-/tmp}/comms-pending-check.XXXXXX") || exit 0
trap 'rm -rf "$work"' EXIT

python3 "$LINTER" --brief --project-root "$root" > "$work/pending" 2>/dev/null &
pending_pid=$!

# The live now.md falls behind outside any session too — a box ticked in
# Obsidian, a pass that could not build. Session start is where that is said.
now_pid=""
if [ -f "$SELF_DIR/comms-now.py" ]; then
  python3 "$SELF_DIR/comms-now.py" --check --project-root "$root" > "$work/now" 2>/dev/null &
  now_pid=$!
fi

wait "$pending_pid"
rc=$?
[ -z "$now_pid" ] || wait "$now_pid"
out=$(cat "$work/pending" 2>/dev/null)
nowline=$(cat "$work/now" 2>/dev/null)

if [ "$rc" -eq 1 ] && [ -n "$out" ]; then
  printf '%s\n' "$out"
  case "$out" in
    *"NOT CHECKED"*) ;;
    *"[comms] pending:"*)
      printf '        Who owes what: /vdm-comms:pending — or by owner:\n'
      printf '        "${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh" --owner\n' ;;
  esac
fi
[ -n "$nowline" ] && printf '%s\n' "$nowline"
exit 0
