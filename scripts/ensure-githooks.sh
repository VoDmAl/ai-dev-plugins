#!/bin/bash
# SessionStart check: warn if `.githooks/` isn't wired up via core.hooksPath.
# Idempotent and warn-only by design — this script never modifies .git/config.
# The user activates manually with: git config core.hooksPath .githooks

set -eu

# Bail silently outside git repos or when .githooks/ is absent.
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
repo_root=$(git rev-parse --show-toplevel)
[ -d "$repo_root/.githooks" ] || exit 0

current=$(git config --get core.hooksPath 2>/dev/null || echo "")
expected=".githooks"

# Already correct — silent.
[ "$current" = "$expected" ] && exit 0

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[vdm-dev] Dev hooks not active in this clone. To enable the lib-sync pre-commit guard, run once:\n    git config core.hooksPath .githooks\nThis prevents drift between plugins/vdm/lib/ and plugins/vdm-git/lib/. See README → Development."
  }
}
EOF
