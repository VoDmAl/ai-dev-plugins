#!/bin/bash
# changelog reminder. Behavior governed by .claude/vdm-plugins.json:
#   enabled=false           → never fires
#   mode=silent             → never fires
#   mode=conditional|quiet  → fires only when working tree has changes (no throttle)
#   mode=smart              → fires when tree dirty AND throttle window elapsed (default)
#   mode=proactive          → fires every prompt, even on clean tree (no throttle)
# Default (no config): enabled=true, mode=smart.
#
# Throttle window: changelog.throttle (seconds), default 600 (10 min). Per-session
# state file under ${TMPDIR:-/tmp}/vdm-reminder-throttle/changelog-<session_id>.
#
# Pre-v2.8.0 default was `conditional` — fired every prompt while the tree was
# dirty. With long dirty-tree sessions that meant per-turn chatter. Smart
# default adds the throttle ceiling on top.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true

vdm_is_enabled "changelog" || exit 0
mode=$(vdm_get_mode "changelog" "smart")

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
    if git rev-parse --is-inside-work-tree &>/dev/null; then
      if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        exit 0
      fi
    fi
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
    throttle=$(vdm_config_read "changelog" "throttle" "600")
    if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
      if _vdm_reminder_throttle_check "changelog" "$throttle" "$sid"; then
        exit 0
      fi
      _vdm_reminder_throttle_touch "changelog" "$sid"
    fi
    ;;
  proactive|*)
    ;;
esac

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[changelog] 📋 After completing significant work:\n- Feature/bug/arch change? → Update PROJECT_CHANGELOG.md\n- Keep entries compact: title + 1-2 sentences + refs\n- Link to docs/tasks/, docs/llm/, .serena/memories/ for details\n\nNo PROJECT_CHANGELOG.md? Run /vdm:changelog to create."
  }
}
EOF
