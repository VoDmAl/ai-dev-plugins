#!/bin/bash
# intercom reminder — receiver-side "you have pending messages" nudge.
# Behavior governed by .claude/vdm-plugins.json → intercom:
#   enabled=false           → never fires
#   mode=silent             → never fires
#   mode=conditional|quiet  → fires whenever the inbox is non-empty (no throttle)
#   mode=smart              → fires when inbox non-empty AND throttle window elapsed (default)
#   mode=proactive          → fires every prompt while inbox non-empty (no throttle)
# Default (no config): enabled=true, mode=smart.
#
# The store is a machine-level mailbox OUTSIDE all repos; "inbox" = this repo's
# canonical-identity dir under the store (DL #1, #4). The reminder is inherently
# low-noise: it stays silent whenever the inbox is empty, regardless of mode.
#
# Throttle window: intercom.throttle (seconds), default 600 (10 min). Per-session
# state under ${TMPDIR:-/tmp}/vdm-reminder-throttle/intercom-<session_id>.
# Not mirrored to vdm-git — intercom ships in the vdm plugin only.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/intercom-common.sh" 2>/dev/null || true

vdm_is_enabled "intercom" || exit 0
mode=$(vdm_get_mode "intercom" "smart")
[ "$mode" = "silent" ] && exit 0

# intercom-common must be present to know the inbox; fail open (silent) if not.
command -v intercom_inbox_count >/dev/null 2>&1 || exit 0

id="$(intercom_identity 2>/dev/null)"
count="$(intercom_inbox_count "$id" 2>/dev/null)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# Receiver-side condition: only ever fire when the inbox is non-empty.
[ "$count" -gt 0 ] || exit 0

case "$mode" in
  conditional|quiet) ;;   # fire, no throttle
  proactive)         ;;   # fire, no throttle
  smart|*)
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
    throttle=$(vdm_config_read "intercom" "throttle" "600")
    if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
      if _vdm_reminder_throttle_check "intercom" "$throttle" "$sid"; then
        exit 0
      fi
      _vdm_reminder_throttle_touch "intercom" "$sid"
    fi
    ;;
esac

# JSON-escape the identity (backslash + double-quote) for safe embedding.
id_esc=$(printf '%s' "$id" | sed 's/\\/\\\\/g; s/"/\\"/g')

msg="[intercom] 📬 ${count} pending message(s) for \`${id_esc}\`.\n- Review: /vdm:intercom check\n- Pick up: /vdm:intercom pickup <slug>  (add --grow to promote into a workitem)"

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$msg"
