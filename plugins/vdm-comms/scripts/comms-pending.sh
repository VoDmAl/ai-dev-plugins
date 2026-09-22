#!/bin/bash
# comms-pending.sh — the pending-item contract linter, as a PostToolUse hook
# and as a CLI.
#
#   comms-pending.sh --hook          read a hook payload on stdin (PostToolUse)
#   comms-pending.sh                 the summary
#   comms-pending.sh --owner|--all|--json|--brief
#   comms-pending.sh --lint [files]  violations
#   comms-pending.sh --print-contract
#
# Exit: 0 clean / 1 violations (CLI) / 2 violations or NOT CHECKED (hook — the
# harness returns stderr to the assistant as feedback on 2, and on nothing else).
#
# Fail-closed: when the linter cannot run, this hook says so and blocks instead
# of exiting 0. "The check failed" and "the check did not run" are different
# events, and only the first is what exit 0 means — see lib/gate-guard.sh.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

LINTER="$SELF_DIR/comms-pending.py"

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

if [ "${1:-}" != "--hook" ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "comms-pending: needs python3 (the linter is a python script, stdlib only)" >&2
    exit 1
  }
  exec python3 "$LINTER" "$@"
fi

payload=$(cat)
[ -z "$payload" ] && exit 0

# Dependency-free scope prefilter, and the one place this hook differs from its
# sibling. `comms-lint` can prefilter on a literal (`/meetings/`); here the
# scope is `comms.pending-paths`, which is JSON and therefore unreadable in the
# very situation the prefilter exists for — no parser. So the fallback question
# is not "is this file in scope" but "could this write have touched an
# obligation at all": a markdown write whose payload carries a checkbox or a due
# marker. It over-triggers, and only in a broken environment, which is exactly
# where a loud failure is the correct one.
pending_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -q '\.md' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE '⏰|\(due:|- \[ \]' 2>/dev/null || return 1
  return 0
}

pending_unverified() {
  pending_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-pending" "$1" \
      "a markdown file carrying open items was just written — whether its new items name an owner and a date was never checked" \
      "install python3 (stdlib is enough — the plugin brings no dependencies), then re-run: \${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --lint <file>" \
      "or check it against \${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --print-contract by hand"
  else
    printf '\n[comms-pending] NOT CHECKED — %s\n  A file with open items was written and the contract check could not run.\n\n' "$1" >&2
  fi
  exit 2
}

read_field() {
  if command -v vdm_json_field >/dev/null 2>&1; then
    vdm_json_field "$payload" "$1"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  FIELD_PATH="$1" python3 -c '
import json, os, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
cur = data
for part in os.environ.get("FIELD_PATH", "").split("."):
    cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None:
        break
if cur is not None:
    print(cur)
' <<<"$payload" 2>/dev/null
}

tool_name=$(read_field "tool_name")
# `tool_name` is always present in a hook payload, so empty means the payload
# was not read — no parser, or one that is present and broken.
[ -z "$tool_name" ] && pending_unverified "could not read \`tool_name\` from the hook payload"

case "$tool_name" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(read_field "tool_input.file_path")
[ -z "$file_path" ] && exit 0
case "$file_path" in
  *.md) ;;
  *) exit 0 ;;
esac
[ -f "$file_path" ] || exit 0

command -v python3 >/dev/null 2>&1 || pending_unverified "python3 is not on PATH"
[ -f "$LINTER" ] || pending_unverified "linter not found at $LINTER"

# Only NEW lines. Every repository that keeps open items has a tail of old ones
# written before the contract existed; re-reporting them on every edit is how a
# linter becomes background noise, and the tail is a migration, not a hook's job.
out=$(python3 "$LINTER" --lint --changed --cap 20 "$file_path" 2>&1)
rc=$?

case "$rc" in
  0|1) ;;
  *)   pending_unverified "the linter exited $rc without reaching a verdict" ;;
esac

if [ "$rc" -eq 1 ]; then
  {
    printf '🚫 comms-pending: new open items outside the contract:\n'
    printf '%s\n' "$out"
    printf '\n'
    printf 'An item needs an owner and a date to be a signal rather than a note.\n'
    printf 'Print the contract with:\n'
    printf '  ${CLAUDE_PLUGIN_ROOT}/scripts/comms-pending.sh --print-contract\n'
  } >&2
  exit 2
fi

exit 0
