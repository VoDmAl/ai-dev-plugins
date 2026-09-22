#!/bin/bash
# comms-lint.sh — the meeting contract linter, as a PostToolUse hook and as a CLI.
#
#   comms-lint.sh --hook          read a hook payload on stdin (PostToolUse)
#   comms-lint.sh <file>...       lint the named files
#   comms-lint.sh --all           lint the whole meetings tree
#   comms-lint.sh --print-contract  print the floor this linter enforces
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

LINTER="$SELF_DIR/comms-lint.py"

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

if [ "${1:-}" != "--hook" ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "comms-lint: needs python3 (the linter is a python script, stdlib only)" >&2
    exit 1
  }
  exec python3 "$LINTER" "$@"
fi

payload=$(cat)
[ -z "$payload" ] && exit 0

# Dependency-free scope prefilter. `meetings` is the default directory name and
# the one all three field repositories use; a project that renames it via
# `comms.meetings-dir` and also has no python3 gets no feedback rather than a
# wrong one — the rename cannot be read without a parser.
lint_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE '/meetings/' 2>/dev/null || return 1
  return 0
}

lint_unverified() {
  lint_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-lint" "$1" \
      "a file under the meetings tree was just written — whether it meets the contract was never checked" \
      "install python3 (stdlib is enough — the plugin brings no dependencies), then re-run: \${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh <file>" \
      "or check it against \${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --print-contract by hand"
  else
    printf '\n[comms-lint] NOT CHECKED — %s\n  A meetings file was written and the contract check could not run.\n\n' "$1" >&2
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
[ -z "$tool_name" ] && lint_unverified "could not read \`tool_name\` from the hook payload"

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

command -v python3 >/dev/null 2>&1 || lint_unverified "python3 is not on PATH"
[ -f "$LINTER" ] || lint_unverified "linter not found at $LINTER"

out=$(python3 "$LINTER" --quiet "$file_path" 2>&1)
rc=$?

case "$rc" in
  0|1) ;;
  *)   lint_unverified "the linter exited $rc without reaching a verdict" ;;
esac

# Warnings without errors are printed but do not block: they name a divergence
# (a `type` the shared contract does not use, a series file that does not exist
# yet) whose resolution is a judgement call, not a defect.
if [ "$rc" -eq 1 ]; then
  {
    printf '🚫 comms-lint: this file does not meet the meetings contract:\n'
    printf '%s\n' "$out"
    printf '\n'
    printf 'The contract is a FLOOR — extra keys and extra sections are never\n'
    printf 'violations. Print it with:\n'
    printf '  ${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --print-contract\n'
  } >&2
  exit 2
fi

if [ -n "$out" ]; then
  printf '%s\n' "$out" >&2
fi
exit 0
