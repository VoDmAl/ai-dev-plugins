#!/bin/bash
# comms-versions.sh — keep an outgoing letter as a version (comms_versions.py):
#   PostToolUse (Write, Edit, MultiEdit) — the letter just written;
#   PreToolUse (Bash) — each letter the command names, as it lies before it,
#   so an edit made in an editor just before does not merge into the version
#   the command leaves.
#
# A recorder, not a gate: it never blocks, and without python3 it is quiet —
# comms-lint already says NOT CHECKED for the same letter and the same cause.
# The two other moments a version is kept, before a write and after a shell
# command, ride the processes comms_sent_proof.py already starts there.

set -u

payload=$(cat)

# Dependency-free fast path, before the config is read and without a process:
# a call that names no outgoing letter is not ours. That is nearly every call —
# and on Bash this hook runs for every command.
case "$payload" in
  *-out.md*) ;;
  *) exit 0 ;;
esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$payload" | python3 "$SELF_DIR/comms_versions.py" 2>/dev/null
exit 0
