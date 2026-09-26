#!/bin/bash
# Resolves where vdm-plugins.json lives for the current project.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm/lib/config-path.sh.
# An automated dev-time guard against drift is tracked as a separate task; until
# then any change here MUST be applied to the vdm copy in the same commit.
#
# Strategy: follow existing harness convention — .claude/ for Claude Code,
# .qwen/ for Qwen Code. When neither exists, default to .claude/.
# Read-only: never creates directories. Writers (skills) handle mkdir -p.

# The project root is asked of git once per shell and place, not once per read.
# Every `vdm_config_read` resolves this path, and a hook reads its config a dozen
# times and more: one crystal-capture run made 41 `git rev-parse` calls, and an
# ordinary prompt spent 27 of its 98 launches on them (Sidetrack #8,
# cc-vdm-plugins → docs/tasks/crystal-wake/workitem.md). The answer is filled in
# at the bottom of this file, while it is being sourced, in the sourcing shell
# itself: callers ask from inside `$(...)`, and a value first computed in a
# subshell would be thrown away with it. It is keyed by the working directory
# and git's own location variables, so a caller that moves, or points git
# elsewhere, is answered afresh rather than from the memo.
_vdm_project_root() {
  # The project root: git's toplevel, or the working directory outside git.
  if [ "${_VDM_ROOT_KEY-}" = "$PWD|${GIT_DIR-}|${GIT_WORK_TREE-}" ]; then
    printf '%s\n' "$_VDM_ROOT"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_config_path() {
  local project_root
  project_root=$(_vdm_project_root)

  if [ -d "$project_root/.claude" ]; then
    printf '%s/.claude/vdm-plugins.json\n' "$project_root"
  elif [ -d "$project_root/.qwen" ]; then
    printf '%s/.qwen/vdm-plugins.json\n' "$project_root"
  else
    printf '%s/.claude/vdm-plugins.json\n' "$project_root"
  fi
}

if [ "${_VDM_ROOT_KEY-}" != "$PWD|${GIT_DIR-}|${GIT_WORK_TREE-}" ]; then
  _VDM_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  _VDM_ROOT_KEY="$PWD|${GIT_DIR-}|${GIT_WORK_TREE-}"
fi
