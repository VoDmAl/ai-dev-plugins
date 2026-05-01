#!/bin/bash
# git-guard reminder. Behavior governed by .claude/vdm-plugins.json:
#   enabled=false       → never fires (note: PreToolUse blocking still applies)
#   mode=silent         → never fires
#   mode=conditional|quiet → fires only when tree has changes (commit could be near)
#   mode=proactive      → fires every prompt (default — safety reminder)
# Default (no config): enabled=true, mode=proactive.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

vdm_is_enabled "git-guard" || exit 0
mode=$(vdm_get_mode "git-guard" "proactive")

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
    "additionalContext": "[git-guard] Git safety active. git commit and git push are blocked until user confirms.\n- Need to commit/push? Ask user first or invoke /vdm-git:guard for pre-commit review."
  }
}
EOF
