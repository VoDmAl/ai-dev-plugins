#!/bin/bash
# learn reminder. Behavior governed by .claude/vdm-plugins.json:
#   enabled=false           → never fires
#   mode=silent             → never fires
#   mode=conditional|quiet  → fires only when working tree has changes (no throttle)
#   mode=smart              → fires when tree dirty AND throttle window elapsed (default)
#   mode=proactive          → fires every prompt, even on clean tree (no throttle)
# Default (no config): enabled=true, mode=smart.
#
# Throttle window: learn.throttle (seconds), default 600 (10 min). Per-session
# state file under ${TMPDIR:-/tmp}/vdm-reminder-throttle/learn-<session_id>.
#
# Pre-v2.8.0 default was `proactive` — fired every UserPromptSubmit. That cost
# ~400 chars × N turns of context for zero marginal value once the user
# internalised the discipline. The smart default keeps the safety net without
# the constant chatter; users who want the old behavior can set
# `learn.mode=proactive` explicitly.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true

vdm_is_enabled "learn" || exit 0
mode=$(vdm_get_mode "learn" "smart")

case "$mode" in
  silent)
    exit 0
    ;;
  conditional|quiet)
    if git rev-parse --is-inside-work-tree &>/dev/null; then
      if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        exit 0
      fi
    fi
    ;;
  smart)
    # Smart trigger: only fire when work is happening (tree dirty) AND we
    # haven't fired recently for this session.
    if git rev-parse --is-inside-work-tree &>/dev/null; then
      if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        exit 0
      fi
    else
      # No git → can't detect work signal → fall through to throttle-only.
      :
    fi
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
    throttle=$(vdm_config_read "learn" "throttle" "600")
    if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
      if _vdm_reminder_throttle_check "learn" "$throttle" "$sid"; then
        exit 0
      fi
      _vdm_reminder_throttle_touch "learn" "$sid"
    fi
    ;;
  proactive|*)
    ;;
esac

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[learn] 💡 After resolving issues or discovering patterns:\n- Found solution after struggling? → /vdm:learn to capture the journey\n- Discovered effective pattern? → /vdm:learn to preserve it\n- Made a mistake worth preventing? → /vdm:learn for safety rules\n\nAssistant: PROACTIVELY invoke /vdm:learn when these situations occur."
  }
}
EOF
