#!/bin/bash
# check-skill-paths.sh — lint user-time files for dev-tree path leaks.
#
# Files in plugins/*/skills/**/SKILL.md and plugins/*/templates/*.md are
# the plugin's contract with user projects. Their paths must resolve at user
# time — i.e. through `${CLAUDE_PLUGIN_ROOT}` or via abstract reference.
# Direct strings like `plugins/vdm/scripts/foo.sh` only resolve in this dev
# clone; in a user project that path doesn't exist (the plugin is installed
# wherever Claude Code put it).
#
# Pattern flagged: plugins/(vdm|vdm-git)/(scripts|lib|hooks|templates|skills)/...
# Bare plugin names (e.g. "the vdm plugin") are NOT flagged — only concrete
# subpaths that the dev tree resolves but a user project doesn't.
#
# Used by .githooks/pre-commit alongside check-lib-sync.sh and
# check-version-bump.sh. Scope: dev-time only — the plugins do not see
# this script at user time.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# Build the target list. Single find with combined predicate; works in bash
# 3.2 (macOS) without `mapfile` / `readarray`.
targets=()
while IFS= read -r f; do
  [ -n "$f" ] && targets+=("$f")
done < <(
  find plugins -type f \( \
       -name 'SKILL.md' \
    -o \( -path '*/templates/*' -name '*.md' \) \
  \) 2>/dev/null
)

if [ ${#targets[@]} -eq 0 ]; then
  echo "skill-paths: no SKILL.md or templates/*.md found — nothing to lint"
  exit 0
fi

# Pattern: concrete dev-tree subpath that doesn't resolve at user time.
pattern='plugins/(vdm|vdm-git)/(scripts|lib|hooks|templates|skills)/'

drift=0
for f in "${targets[@]}"; do
  hits=$(grep -nE "$pattern" "$f" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    drift=1
    {
      printf '\n'
      printf 'skill-paths: 🚨 dev-tree path leak in user-time file: %s\n' "$f"
      printf '\n'
      printf '%s\n' "$hits" | sed 's/^/  /'
      printf '\n'
      printf '  These paths only resolve inside this dev clone. At user time the\n'
      printf '  plugin lives at ${CLAUDE_PLUGIN_ROOT} (resolved by Claude Code).\n'
      printf '  Replace plugins/X/<subdir>/ with ${CLAUDE_PLUGIN_ROOT}/<subdir>/.\n'
    } >&2
  fi
done

if [ "$drift" -eq 0 ]; then
  echo "skill-paths: ✓ user-time files use \${CLAUDE_PLUGIN_ROOT} consistently"
fi

exit "$drift"
