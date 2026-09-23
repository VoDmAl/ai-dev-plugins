#!/bin/bash
# git-guard reminder. Behavior governed by .claude/vdm-plugins.json:
#   enabled=false       → never fires (note: PreToolUse blocking still applies)
#   mode=silent         → never fires
#   mode=conditional|quiet → fires only when tree has changes (commit could be near)
#   mode=smart          → fires when the tree has changes AND both throttle
#                         windows have elapsed (default)
#   mode=proactive      → fires every prompt, no throttle
# Default (no config): enabled=true, mode=smart.
#
# Windows: git-guard.throttle (seconds, default 600) and
# git-guard.throttle-turns (prompts, default 5). An emit needs BOTH elapsed —
# see lib/reminder-throttle.sh for why there are two axes.
#
# Until 2.14.0 the default was `proactive` with no throttle at all, and this
# was the ONLY reminder in the suite built that way. Measured in the field
# (t23b-content, 2026-09-10): 1324 bytes of additionalContext on EVERY prompt
# in any git repository, while its five siblings were spending 0 on a repeat
# prompt. The asymmetry was never decided by anyone — it is what you get when a
# hook is written before the shared pattern exists and nobody goes back. The
# blocking PreToolUse guard is untouched: that is the part that actually stops
# a bad commit, and it does not depend on this text having been read.
#
# Always exits silently outside a git work tree — non-git folders cannot
# produce commits, so the reminder would only push the assistant toward
# defensive probing.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true

vdm_is_enabled "git-guard" || exit 0

# No git work tree → no commits possible → reminder is pure noise.
# Without this guard, proactive mode pushes the assistant toward defensive
# `[ -d .git ]` probing in every non-git working directory.
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

mode=$(vdm_get_mode "git-guard" "smart")

case "$mode" in
  silent)
    exit 0
    ;;
  conditional|quiet)
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
      exit 0
    fi
    ;;
  smart)
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
      exit 0
    fi
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
    throttle=$(vdm_config_read "git-guard" "throttle" "600")
    turns=$(vdm_config_read "git-guard" "throttle-turns" "5")
    if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
      if _vdm_reminder_throttle_check "git-guard" "$throttle" "$sid" "$turns"; then
        exit 0
      fi
      _vdm_reminder_throttle_touch "git-guard" "$sid"
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
