#!/bin/bash
# Resolves where vdm-plugins.json lives for the current project.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/config-path.sh.
# An automated dev-time guard against drift is tracked as a separate task; until
# then any change here MUST be applied to the vdm-git copy in the same commit.
#
# Strategy: follow existing harness convention — .claude/ for Claude Code,
# .qwen/ for Qwen Code. When neither exists, default to .claude/.
# Read-only: never creates directories. Writers (skills) handle mkdir -p.

resolve_config_path() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null) || project_root=$(pwd)

  if [ -d "$project_root/.claude" ]; then
    printf '%s/.claude/vdm-plugins.json\n' "$project_root"
  elif [ -d "$project_root/.qwen" ]; then
    printf '%s/.qwen/vdm-plugins.json\n' "$project_root"
  else
    printf '%s/.claude/vdm-plugins.json\n' "$project_root"
  fi
}
