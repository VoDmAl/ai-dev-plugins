#!/bin/bash
# comms-draft-guard.sh — PreToolUse (Write) guard for outgoing correspondence.
#
# Refuses to CREATE a `comms/*-out.md` that already claims `sent: <date>`.
# A letter is sent by a person, not by the assistant: until that happened the
# file is a draft (`draft: true`), and `sent:` is added afterwards. Writing it
# up front records a send that never took place, in the one place the project
# treats as the record of what went out.
#
# Scope is the PATH SHAPE — `*/comms/*-out.md` — and deliberately not a list of
# track prefixes. The field version of this guard matched `/gaps/` only, and by
# the time it was measured its own repository had grown `org/` and `incidents/`:
# nineteen outgoing letters sat outside the guard, and nothing said so, because
# a narrowed guard looks exactly like a quiet one.
#
# Editing an EXISTING file is allowed: fixing a typo in a letter that really
# was sent is legitimate, and the guard has nothing to say about it.
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
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Write"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE '/comms/[^"]*-out\.md' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE 'sent:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' 2>/dev/null || return 1
  return 0
}

guard_unverified() {
  guard_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-draft-guard" "$1" \
      "a new outgoing letter carrying \`sent:\` — whether it is a draft claiming to have been sent was never checked" \
      "install python3 or jq so the hook can read its payload, then write again, or" \
      "check by hand: a letter that has not left yet carries \`draft: true\`, never \`sent:\`"
  else
    printf '\n[comms-draft-guard] NOT CHECKED — %s\n  A new outgoing letter with `sent:` arrived and the guard could not run.\n\n' "$1" >&2
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
[ "$tool_name" = "Write" ] || exit 0

file_path=$(read_field "tool_input.file_path")
[ -z "$file_path" ] && exit 0

case "$file_path" in
  */comms/*-out.md) ;;
  *) exit 0 ;;
esac

# Only the CREATION of a letter is guarded.
[ -e "$file_path" ] && exit 0

content=$(read_field "tool_input.content")
if [ -z "$content" ]; then
  # A Write with no readable content on a path we do guard: we cannot tell
  # whether it claims to be sent.
  guard_unverified "could not read \`tool_input.content\` from the hook payload"
fi

if printf '%s' "$content" | head -n 20 \
   | grep -qE '^sent:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' 2>/dev/null; then
  cat >&2 <<'EOF'
🚫 comms-draft-guard: a NEW outgoing letter must not claim `sent:`.

  A draft carries `draft: true` and no `sent:` field. `sent: <date>` is added
  only after a person has actually sent the letter — it is the record of what
  went out, and writing it in advance records a send that did not happen.

  Fix: replace `sent: YYYY-MM-DD` with `draft: true`, then write again.
EOF
  exit 2
fi

exit 0
