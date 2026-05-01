#!/bin/bash
# learn reminder. Behavior is governed by .claude/vdm-plugins.json:
#   enabled=false → never fires
#   mode=proactive → always fires (default — captures discovery moments)
#   mode=conditional|quiet → fires only when working tree has changes
#   mode=silent → never fires
# Default (no config): enabled=true, mode=proactive.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

vdm_is_enabled "learn" || exit 0
mode=$(vdm_get_mode "learn" "proactive")

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
    "additionalContext": "[learn] 💡 After resolving issues or discovering patterns:\n- Found solution after struggling? → /vdm:learn to capture the journey\n- Discovered effective pattern? → /vdm:learn to preserve it\n- Made a mistake worth preventing? → /vdm:learn for safety rules\n\nAssistant: PROACTIVELY invoke /vdm:learn when these situations occur."
  }
}
EOF
