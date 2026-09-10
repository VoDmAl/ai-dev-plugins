#!/bin/bash
# git-guard reminder. Behavior governed by .claude/vdm-plugins.json:
#   enabled=false       → never fires (note: PreToolUse blocking still applies)
#   mode=silent         → never fires
#   mode=conditional|quiet → fires only when tree has changes (commit could be near)
#   mode=proactive      → fires every prompt (default — safety reminder)
# Default (no config): enabled=true, mode=proactive.
#
# Always exits silently outside a git work tree — non-git folders cannot
# produce commits, so the reminder would only push the assistant toward
# defensive probing.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

vdm_is_enabled "git-guard" || exit 0

# No git work tree → no commits possible → reminder is pure noise.
# Without this guard, proactive mode pushes the assistant toward defensive
# `[ -d .git ]` probing in every non-git working directory.
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

mode=$(vdm_get_mode "git-guard" "proactive")

case "$mode" in
  silent)
    exit 0
    ;;
  conditional|quiet)
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
      exit 0
    fi
    ;;
  proactive|*)
    ;;
esac

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[git-guard] When work warrants a commit, you (the assistant) run `git add <files>` and `git-guard-prepare \"<subject>\"` yourself via Bash. Both live on your PATH only (plugin `bin/` mounted by the harness), never the user's shell.\n\n  • ONE COMMIT PER TURN. Stage → run the helper → hand off the printed line → wait for the user. Never bundle several commits into one shell recipe, and never list `git add` or `git-guard-prepare` as steps for the user: their shell answers `command not found`.\n  • HAND OFF THE PRINTED LINE VERBATIM, as inline code — `git commit -F <path> -- <paths>`. The explicit pathspec is what keeps a parallel session's staged files out of the commit, so never trim it off.\n  • AMEND NEEDS ITS OWN PATHSPEC. `git commit --amend` without `-- <paths>` takes the WHOLE index and sweeps in whatever a neighbouring session staged. Name the paths explicitly, every time.\n  • If the helper says a prepared command was NEVER RUN, the earlier line in the user's scrollback is now dead — say so when you hand off the new one.\n  • If the helper prints SWEPT IN / NOT COMMITTED, the PREVIOUS commit is not what was prepared. Stop and inspect it with `git show --stat` before handing off anything new.\n  • The helper exits 1 if nothing is staged, or if the working tree differs from the index on those paths — reconcile with `git add` / `git checkout --` and re-run rather than working around it. To commit a subset of what is staged: `git-guard-prepare \"<subject>\" -- <path>...`.\n\nDo not run `git commit` / `git push` yourself, and do not announce that git-guard is blocking — the user knows."
  }
}
EOF
