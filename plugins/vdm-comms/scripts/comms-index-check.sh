#!/bin/bash
# comms-index-check.sh — SessionStart drift signal for the generated layer.
#
# Says one line when the registry, the series lists or the per-track pointers
# are behind the meetings, and nothing at all otherwise. It never writes and
# never blocks: this is a REMINDER, and a reminder may fail open — the cost of
# a missed nudge is one nudge. (The gates in this plugin do the opposite; see
# lib/gate-guard.sh for why the two differ.)
#
# It fires at session start only, on purpose. Every write to a meeting file
# makes the registry stale by definition, so a PostToolUse variant would fire
# on essentially every such write — a reminder that is always on is one nobody
# reads.
#
# Silent when: no meetings directory, the plugin is disabled, python3 is
# missing, or nothing is behind.

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

INDEXER="$SELF_DIR/comms-index.py"
[ -f "$INDEXER" ] || exit 0

out=$(python3 "$INDEXER" --check --project-root "$root" 2>/dev/null)
rc=$?
[ "$rc" -eq 1 ] || exit 0

behind=$(printf '%s\n' "$out" | grep -cE '^  (update|remove) ' 2>/dev/null || true)
[ -z "$behind" ] && behind=0
[ "$behind" -gt 0 ] || exit 0

printf '[comms] %s generated artefact(s) are behind the meetings — registry, series lists or track pointers:\n' "$behind"
# The first few by name. A count alone arrived every session and said nothing
# about WHAT was behind — reported from the field, where "21 artefacts" stood
# unchanged for days because nobody could tell from it whether it mattered.
printf '%s\n' "$out" | grep -E '^  (update|remove) ' | head -3 | sed 's/^  /        /'
[ "$behind" -gt 3 ] && printf '        … and %s more\n' "$((behind - 3))"
printf '        Rebuild with /vdm-comms:index (it prints what it changed), or inspect first:\n'
printf '        ${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --check\n'
exit 0
