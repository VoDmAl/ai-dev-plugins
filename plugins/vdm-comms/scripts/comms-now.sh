#!/bin/bash
# comms-now.sh — build the live signals/now.md from the project's homes.
#
#   comms-now.sh [--project-root DIR] [--stdout]
#
# A command, never a hook (workitem vdm-comms-live-now, DL #1): echelon runs it
# after a pass (`after_pass` of the project), a session runs it when the hook
# says now.md is behind. The plugin's hooks write no project files.
#
# Exit: 0 built / 2 not configured or config unreadable — nothing written.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "comms-now: needs python3 (the builder is a python script, stdlib only) — nothing built" >&2
  exit 1
}
exec python3 "$SELF_DIR/comms-now.py" "$@"
