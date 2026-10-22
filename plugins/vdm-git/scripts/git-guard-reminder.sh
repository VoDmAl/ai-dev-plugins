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
# (executor, 2026-09-10): 1324 bytes of additionalContext on EVERY prompt
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
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || true

# Every git call here is a read, and a read must not rewrite .git/index:
# `git status` refreshes stat data and writes the index back, and on a repo
# that Syncthing carries between two machines that write is a conflict copy
# (vdx, 2026-09-30). Does NOT cover `git diff` without a revision — see
# tests/hook-index-writes.test.sh.
export GIT_OPTIONAL_LOCKS=0

vdm_is_enabled "git-guard" || exit 0

# No git work tree → no commits possible → reminder is pure noise.
# Without this guard, proactive mode pushes the assistant toward defensive
# `[ -d .git ]` probing in every non-git working directory.
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

mode=$(vdm_get_mode "git-guard" "smart")

# notes_only — true when every change in the work tree is one of the
# assistant's notes: a file under a crystal root (the lib's answer, configured
# or auto-scanned) or its memory in .claude/memory/. A note rides with the next
# work commit or the session's last (/vdm:wrap), never alone. Field case (a
# project, 2026-10-22): a crystal in the branch of a merge request under review
# took three of its four commits, each with a push — a pipeline run and an
# "added 1 commit" for the reviewer every time. Not docs/llm/: a long-lived doc
# is part of the work it documents. Without the lib, memory is the only note.
notes_only() {
  local top roots
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  roots=""
  command -v resolve_crystal_roots >/dev/null 2>&1 && roots=$(resolve_crystal_roots 2>/dev/null)
  printf '%s\n' "$changes" | ROOTS="$roots" TOP="$top/" LC_ALL=C awk '
    BEGIN { n = split(ENVIRON["ROOTS"], r, "\n") }
    /./ {
      path = substr($0, 4)
      note = (index(path, ".claude/memory/") == 1)
      for (i = 1; i <= n && !note; i++)
        if (r[i] != "" && index(ENVIRON["TOP"] path, r[i] "/") == 1) note = 1
      if (!note) { work = 1; exit }
    }
    END { exit work }'
}

# One status for every mode that reads the tree: -z so a name outside ASCII is
# not quoted, renames as an add and a delete so each line names one path.
changes=""
case "$mode" in
  conditional|quiet|smart)
    changes=$(git status --porcelain -z --no-renames 2>/dev/null | LC_ALL=C tr '\0' '\n')
    ;;
esac

case "$mode" in
  silent)
    exit 0
    ;;
  conditional|quiet)
    if [ -z "$changes" ]; then
      exit 0
    fi
    notes_only && exit 0
    ;;
  smart)
    if [ -z "$changes" ]; then
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
    # After the window, not before: the roots cost a git ls-files, paid once a
    # window rather than on every prompt of a session spent writing notes.
    notes_only && exit 0
    ;;
  proactive|*)
    ;;
esac

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[git-guard] When work warrants a commit, you (the assistant) run `git add <files>` and `git-guard-prepare \"<subject>\"` yourself via Bash. Both live on your PATH only (plugin `bin/` mounted by the harness), never the user's shell.\n\n  • ONE COMMIT PER TURN. Stage → run the helper → hand off the printed line → wait for the user. Never bundle several commits into one shell recipe, and never list `git add` or `git-guard-prepare` as steps for the user: their shell answers `command not found`.\n  • HAND OFF THE PRINTED LINE VERBATIM, as inline code — `git commit -F <path> -- <paths>`. The explicit pathspec is what keeps a parallel session's staged files out of the commit, and the `[ -f … ] ||` check in front stops a dead line before any hook runs — never trim either.\n  • AMEND NEEDS ITS OWN PATHSPEC. `git commit --amend` without `-- <paths>` takes the WHOLE index and sweeps in whatever a neighbouring session staged. Name the paths explicitly, every time.\n  • NOTES ALONE ARE NO COMMIT. A crystal's files and the assistant's memory ride with the next work commit or the session's last (/vdm:wrap); a line of notes alone only when the user asks, and never with a push to a branch whose merge request is under review.\n  • ONE LINE PER FINISHED BLOCK. Don't prepare while the user is still discussing the work or busy with a step of their own (a letter to send, a reply to wait for). A line handed off stands: edits to its paths ride with it, new files with the next commit. If the helper refuses because a line is STILL WAITING, hand off nothing new; `--supersede` only when the user reported that line failed or the block changed in substance — then say the earlier line is void.\n  • If the helper prints SWEPT IN / NOT COMMITTED, the PREVIOUS commit is not what was prepared. Stop and inspect it with `git show --stat` before handing off anything new.\n  • The helper exits 1 if nothing is staged, or if the working tree differs from the index on those paths — reconcile with `git add` / `git checkout --` and re-run rather than working around it. To commit a subset of what is staged: `git-guard-prepare \"<subject>\" -- <path>...`.\n\nDo not run `git commit` / `git push` yourself, and do not announce that git-guard is blocking — the user knows."
  }
}
EOF
