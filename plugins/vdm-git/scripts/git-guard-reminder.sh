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
    "additionalContext": "[git-guard] When work warrants a commit, you (the assistant) run `git add <files>` and `git-guard-prepare \"<subject>\"` yourself via Bash — both live on your PATH only (plugin `bin/` mounted by the harness), not the user's shell. `git-guard-prepare` prints a single `git commit -F <path>` line; that one line is what you hand off to the user as inline code. Never list `git-guard-prepare` as a step for the user — their shell will say `command not found`. For multiple commits in one task, repeat the cycle sequentially (stage → helper → hand off → wait), one commit per turn — do not bundle the steps into a shell recipe. Do not announce that git-guard is blocking; the user knows. Do not run `git commit` / `git push` yourself."
  }
}
EOF
