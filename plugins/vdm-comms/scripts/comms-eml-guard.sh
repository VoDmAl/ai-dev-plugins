#!/bin/bash
# comms-eml-guard.sh — PreToolUse (Write|Bash) guard: the raw `.eml` stays out
# of comms/ and the meetings tree.
#
# The decision lives in comms-eml-guard.py (why, what territory, which Bash verbs
# are read). This wrapper does the two things a hook needs before python:
#
#   1. A dependency-free fast path — a call that does not mention `.eml` is not
#      ours, and costs one grep. That is nearly every call.
#   2. Fail-closed (lib/gate-guard.sh): when the decision cannot be made and the
#      raw payload looks like an `.eml` headed for comms/ or meetings/, block and
#      say NOT CHECKED rather than let it through as if checked.
#
# Exit: 0 allow / 2 block (stderr returns to the assistant as feedback).

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

payload=$(cat)
[ -z "$payload" ] && exit 0

printf '%s' "$payload" | grep -qiE '\.eml([^a-z0-9]|$)' 2>/dev/null || exit 0

guard_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit|Bash)"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE '(^|[/"[:space:]])(comms|meetings)(/|[[:space:]"]|$)' 2>/dev/null || return 1
  return 0
}

guard_unverified() {
  guard_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-eml-guard" "$1" \
      "a call that mentions an \`.eml\` next to comms/ or meetings/ — whether it puts the raw mail file into the repository was never checked" \
      "install python3 (stdlib is enough) and try again, or" \
      "write only the letter's text to comms/*-in.md and the extracted attachments to comms/attachments/ — never the .eml itself"
  else
    printf '\n[comms-eml-guard] NOT CHECKED — %s\n  An .eml near comms/ or meetings/ arrived and the guard could not run.\n\n' "$1" >&2
  fi
  exit 2
}

command -v python3 >/dev/null 2>&1 || guard_unverified "python3 is not on PATH"
[ -f "$SELF_DIR/comms-eml-guard.py" ] || guard_unverified "guard not found at $SELF_DIR/comms-eml-guard.py"

out=$(printf '%s' "$payload" | python3 "$SELF_DIR/comms-eml-guard.py" 2>&1)
rc=$?
case "$rc" in
  0) exit 0 ;;
  2) printf '%s\n' "$out" >&2; exit 2 ;;
  *) guard_unverified "the guard exited $rc without a verdict" ;;
esac
