#!/bin/bash
# crystal-path.sh — resolver + workitem helpers for the crystal-* suite.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/crystal-path.sh.
# Drift is caught by scripts/check-lib-sync.sh in .githooks/pre-commit; any change
# here MUST be applied to the vdm-git copy in the same commit.
#
# Strategy:
#   - Storage root resolves through vdm_config_read "crystal" "path"; default
#     "docs/tasks" matches the existing repo convention.
#   - Read-only: never creates the directory. Writers (crystal-grow skill) own
#     `mkdir -p`. Hooks must survive a missing root silently.
#   - Workitem layout: folder-style (<root>/<slug>/workitem.md) is canonical;
#     flat-style (<root>/<slug>.md) is also recognized for legacy compat.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-read.sh"

resolve_crystal_root() {
  local project_root rel
  project_root=$(git rev-parse --show-toplevel 2>/dev/null) || project_root=$(pwd)

  rel=$(vdm_config_read "crystal" "path" "docs/tasks")
  rel="${rel%/}"

  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s/%s\n' "$project_root" "$rel" ;;
  esac
}

find_workitems() {
  # Outputs all candidate workitem file paths under the crystal root.
  # Folder-style first (<root>/<slug>/workitem.md), then flat-style
  # (<root>/<slug>.md). Sorted, deduped.
  local root
  root=$(resolve_crystal_root)
  [ -d "$root" ] || return 0
  {
    find "$root" -mindepth 2 -maxdepth 2 -type f -name 'workitem.md' 2>/dev/null
    find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null
  } | sort -u
}

extract_frontmatter_field() {
  # extract_frontmatter_field <file> <field>
  # Reads the YAML frontmatter (between leading `---` markers) and prints the
  # value for the given top-level key, or nothing if absent. No quoting fixups —
  # we only consume simple scalar values (status, slug, session-type).
  local file="$1" field="$2"
  [ -f "$file" ] || return 0
  awk -v key="$field" '
    BEGIN { count = 0 }
    /^---[[:space:]]*$/ {
      count++
      if (count == 2) exit
      next
    }
    count == 1 {
      if (match($0, "^"key"[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", val)
        gsub(/^["\047]|["\047]$/, "", val)
        print val
        exit
      }
    }
  ' "$file" 2>/dev/null
}

filter_status() {
  # filter_status <expected-status>
  # Reads file paths on stdin, prints only those whose frontmatter `status`
  # equals the argument. Files without frontmatter are dropped.
  local expected="$1"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(extract_frontmatter_field "$f" status)" = "$expected" ] && printf '%s\n' "$f"
  done
}

count_unchecked() {
  # Counts unchecked markdown checkboxes (`- [ ]`) in the file. The crystal-cut
  # gate (Decision Log #4) generalizes "completion discipline" to any unchecked
  # checkbox in the workitem, not only items inside `## Sidetracks`.
  local file="$1"
  [ -f "$file" ] || { printf '0\n'; return; }
  local n
  n=$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$file" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

extract_slug() {
  # extract_slug <workitem-path>
  # Returns the slug for either folder-style or flat-style workitems, relative
  # to the resolved crystal root. Falls back to basename when the path isn't
  # rooted under the crystal root (defensive — shouldn't happen in practice).
  local file="$1" root rel
  root=$(resolve_crystal_root)
  rel="${file#"$root"/}"
  case "$rel" in
    */workitem.md) printf '%s\n' "${rel%/workitem.md}" ;;
    *.md)          printf '%s\n' "${rel%.md}" ;;
    *)
      local base
      base=$(basename "$file" .md)
      printf '%s\n' "${base%/workitem}"
      ;;
  esac
}
