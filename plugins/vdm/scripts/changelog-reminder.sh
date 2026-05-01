#!/bin/bash
# changelog reminder. Behavior is governed by .claude/vdm-plugins.json:
#   enabled=false → never fires
#   mode=proactive → always fires
#   mode=conditional|quiet → fires only when working tree has changes
#   mode=silent → never fires
# Default (no config): enabled=true, mode=conditional.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

vdm_is_enabled "changelog" || exit 0
mode=$(vdm_get_mode "changelog" "conditional")

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
