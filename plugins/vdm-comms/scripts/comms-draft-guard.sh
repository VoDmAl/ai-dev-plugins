#!/bin/bash
# comms-draft-guard.sh — PreToolUse (Write, Edit, MultiEdit) guard for outgoing
# correspondence.
#
# Refuses a write that makes a `comms/*-out.md` SENT without proof: not sent
# before (or no file yet), `sent:` after, and no `sent-proof:` beside it. Until
# the letter has left, the file is a draft (`draft: true`); `sent:` is the record
# of what went out, and the proof is what shows it left — an id or link from
# the sending tool's answer, or `owner` when the owner said they sent it
# themselves. The comparison lives in comms_sent_proof.py.
#
# Edits are guarded too (vdm-comms 0.25.0). Before that only the creation of a
# letter was, while the skill told the assistant to set `sent:` by an edit — the
# one path it prescribed was the one path nobody watched (crystal
# `outgoing-ladder`, DL #3).
#
# Scope is the PATH SHAPE — `*/comms/*-out.md` — and deliberately not a list of
# track prefixes. The field version of this guard matched ONE prefix, and by the
# time anyone measured it that repository had grown two more: nineteen outgoing
# letters sat outside the guard, and nothing said so, because a narrowed guard
# looks exactly like a quiet one.
#
# A letter that was ALREADY sent is history: fixing a typo in it is legitimate,
# and it is never asked for a proof it was written without.
#
# A new draft that passes gets the checklist of /vdm-comms:letters as context
# (comms_checklist.py) — the skill's short form, at the moment of writing.
#
# Exit: 0 allow / 2 block (stderr returns to the assistant as feedback).
# Fail-closed when the payload cannot be read — see lib/gate-guard.sh.

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

guard_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE '/comms/[^"]*-out\.md' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -q 'sent' 2>/dev/null || return 1
  return 0
}

guard_unverified() {
  guard_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-draft-guard" "$1" \
      "a write to an outgoing letter that mentions \`sent\` — whether it marks the letter sent without proof was never checked" \
      "install python3 so the hook can compare the letter before and after the write, then write again, or" \
      "check by hand: a letter that has not left carries \`draft: true\`; \`sent:\` comes only with \`sent-proof:\` beside it"
  else
    printf '\n[comms-draft-guard] NOT CHECKED — %s\n  A write to an outgoing letter mentioning `sent` arrived and the guard could not run.\n\n' "$1" >&2
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
[ -z "$tool_name" ] && guard_unverified "could not read \`tool_name\` from the hook payload"
case "$tool_name" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(read_field "tool_input.file_path")
[ -z "$file_path" ] && exit 0

case "$file_path" in
  */comms/*-out.md) ;;
  *) exit 0 ;;
esac

creating=0
[ -e "$file_path" ] || creating=1

# Sent before → sent after needs nothing; not sent → sent needs `sent-proof:`.
# Working that out for an Edit means applying it to the file on disk, which is
# python's job; without python3 the guard says so instead of passing quietly.
SENT_PROOF="$SELF_DIR/comms_sent_proof.py"
command -v python3 >/dev/null 2>&1 \
  || guard_unverified "python3 is needed to see whether this write marks the letter sent"
[ -f "$SENT_PROOF" ] || guard_unverified "comms_sent_proof.py is missing next to the guard"
note=$(printf '%s' "$payload" | python3 "$SENT_PROOF")
rc=$?
case "$rc" in
  0) ;;
  2) exit 2 ;;
  *) guard_unverified "could not work out the letter as this write would leave it" ;;
esac
# A letter the owner sent by hand: the reconciliation note is the context, and
# the draft checklist is not — the letter is no longer a draft.
if [ -n "$note" ]; then
  printf '%s\n' "$note"
  exit 0
fi

# A new draft passed: hand over the checklist of /vdm-comms:letters, at the one
# moment it is worth reading — as additionalContext, never a block. A reminder,
# so it fails open: no checklist, the write goes through.
[ "$tool_name" = "Write" ] && [ "$creating" -eq 1 ] || exit 0
content=$(read_field "tool_input.content")
CHECKLIST="$SELF_DIR/comms_checklist.py"
if [ -n "$content" ] && [ -f "$CHECKLIST" ]; then
  printf '%s' "$content" | python3 "$CHECKLIST" --hook --file "$file_path" 2>/dev/null || true
fi

exit 0
