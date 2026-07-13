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

# ---------------------------------------------------------------------------
# Gate 2: citations of THIS repo's own docs/ files.
#
# The plugin ships as a git-subdir of `plugins/vdm` — the repo's `docs/` tree
# is NOT part of the package. So a user-time reference to `docs/tasks/<slug>/`
# or `docs/llm/<file>` resolves to nothing: not in the user's project, and not
# under ${CLAUDE_PLUGIN_ROOT} either. Worst case a SKILL.md instructs the
# assistant to *Read* a file that cannot exist.
#
# The check is against the filesystem, not a heuristic — that's what makes it
# precise enough to be a gate rather than a nag:
#
#   FLAG a docs/tasks/<slug>/ or docs/llm/<file> reference  ⟺  that slug/file
#   ACTUALLY EXISTS in this repo  AND  the line does not name the repo.
#
# Consequences of that rule, all intended:
#   - `docs/llm/{topic}.md`, `docs/features/{feature}.md` — placeholders for the
#     USER's tree (learn / docs-sync write there). No such file here → never flagged.
#     This is the plugin's whole job; flagging it would be backwards.
#   - `docs/tasks/auth-refactor/workitem.md` — invented example slug. Doesn't
#     exist here → never flagged.
#   - `docs/tasks/crystal-design/workitem.md` — a real crystal of ours. Flagged,
#     unless written as a citation naming the repo:
#         `cc-vdm-plugins → docs/tasks/crystal-design/workitem.md`
#     which turns a broken local path into an honest pointer at another repo.
#
# Repo name must be on the SAME line as the path (this check is line-based).
# ---------------------------------------------------------------------------

repo_name='cc-vdm-plugins'

# Enumerate what actually exists here, so "does this resolve?" is a fact.
own_docs=()
while IFS= read -r d; do
  [ -n "$d" ] && own_docs+=("$d")
done < <(
  { [ -d docs/tasks ] && find docs/tasks -mindepth 1 -maxdepth 1 -type d -exec basename {} \; ;
    [ -d docs/llm ]   && find docs/llm   -mindepth 1 -maxdepth 1 -type f -name '*.md' -exec basename {} \; ;
  } 2>/dev/null | sort -u
)

for f in "${targets[@]}"; do
  for name in "${own_docs[@]}"; do
    # Match `docs/tasks/<name>/` or `docs/llm/<name>` (name already carries .md
    # for llm files). Skip lines that name the repo — those are citations.
    hits=$(grep -nE "docs/(tasks/${name}/|llm/${name})" "$f" 2>/dev/null \
           | grep -v "$repo_name" || true)
    [ -n "$hits" ] || continue
    drift=1
    {
      printf '\n'
      printf 'skill-paths: 🚨 dangling repo-doc reference in user-time file: %s\n' "$f"
      printf '\n'
      printf '%s\n' "$hits" | sed 's/^/  /'
      printf '\n'
      printf '  `%s` exists in THIS repo but is not shipped: the plugin package is\n' "$name"
      printf '  plugins/vdm only, so docs/ is absent both from the user project and\n'
      printf '  from ${CLAUDE_PLUGIN_ROOT}. As written, that path resolves to nothing.\n'
      printf '\n'
      printf '  Either drop the reference, or make it an explicit cross-repo citation\n'
      printf '  by naming the repo on the same line:\n'
      printf '      `%s → docs/tasks/<slug>/workitem.md`\n' "$repo_name"
    } >&2
  done
done

if [ "$drift" -eq 0 ]; then
  echo "skill-paths: ✓ user-time files use \${CLAUDE_PLUGIN_ROOT}; no dangling repo-doc refs"
fi

exit "$drift"
