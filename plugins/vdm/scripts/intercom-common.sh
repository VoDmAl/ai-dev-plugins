#!/bin/bash
# intercom-common.sh — sourced resolvers for the /vdm:intercom skill.
#
# The intercom store is a SINGLE machine-level mailbox that lives OUTSIDE all
# repositories (Decision Log #1 in docs/tasks/intercom-skill/workitem.md), so
# there is no per-repo .gitignore and nothing to commit. Messages are routed by
# a project's CANONICAL IDENTITY derived from its git remote slug — never the
# directory basename, which is unstable across clones (DL #4).
#
# NOT a hook and NOT mirrored to vdm-git — intercom ships in the vdm plugin only.
# Sourced by scripts/intercom.sh (CLI) and scripts/intercom-reminder.sh (hook).
#
# Every function FAILS OPEN: absence of git or jq must never break the caller.
# Worst case a resolver returns a basename fallback or skips registry upkeep.

_INTERCOM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vdm_config_read (per-project .claude/vdm-plugins.json) — used for the optional
# intercom.identity override. Sourced best-effort; guarded at every call site.
# shellcheck disable=SC1091
. "$_INTERCOM_LIB_DIR/../lib/config-read.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Store root resolution (DL #3): env → global config → namespaced default.
# ---------------------------------------------------------------------------

intercom_store_root() {
  local root=""
  if [ -n "${VDM_INTERCOM_ROOT:-}" ]; then
    root="$VDM_INTERCOM_ROOT"
  else
    local gcfg="$HOME/.claude/vdm-plugins.json"
    if command -v jq >/dev/null 2>&1 && [ -f "$gcfg" ]; then
      local r
      r="$(jq -r '.intercom.root // empty' "$gcfg" 2>/dev/null)"
      [ -n "$r" ] && root="$r"
    fi
  fi
  [ -n "$root" ] || root="$HOME/.claude/vdm/intercom"
  # Expand a leading ~ (env/config values may be written with a tilde).
  case "$root" in
    "~")   root="$HOME" ;;
    "~/"*) root="$HOME/${root#\~/}" ;;
  esac
  printf '%s' "$root"
}

intercom_registry_dir() { printf '%s/_registry' "$(intercom_store_root)"; }

# ---------------------------------------------------------------------------
# Identity resolution (DL #4): config override → git remote slug → basename.
# Canonical granularity = repo-slug (last path segment, lowercased) — DL #7.
# ---------------------------------------------------------------------------

intercom_remote_url() { git remote get-url origin 2>/dev/null || true; }

# Normalize a git remote URL to a lowercase repo slug (last path segment, no .git).
# Handles both scp-style (git@host:owner/repo.git) and url-style (https://…/repo.git).
_intercom_slug_from_url() {
  local url="$1" slug
  [ -n "$url" ] || return 1
  slug="${url%.git}"   # strip trailing .git
  slug="${slug%/}"     # strip a trailing slash
  slug="${slug##*/}"   # take the segment after the last slash
  slug="${slug##*:}"   # scp-style with no slash after host: git@host:name
  [ -n "$slug" ] || return 1
  printf '%s' "$slug" | tr '[:upper:]' '[:lower:]'
}

# Extract a lowercase owner/repo pair from a remote URL, or fail (return 1) when
# the URL carries no owner segment. Used only for registry aliases.
_intercom_owner_repo_from_url() {
  local url="$1" path
  [ -n "$url" ] || return 1
  url="${url%.git}"
  case "$url" in
    *://*)  path="${url#*://}"; path="${path#*/}" ;;   # scheme://host/owner/repo
    *@*:*)  path="${url##*:}" ;;                        # scp: git@host:owner/repo
    *)      path="$url" ;;
  esac
  case "$path" in
    */*) printf '%s' "$path" | tr '[:upper:]' '[:lower:]' ;;
    *)   return 1 ;;
  esac
}

intercom_identity() {
  local ov=""
  if command -v vdm_config_read >/dev/null 2>&1; then
    ov="$(vdm_config_read intercom identity "" 2>/dev/null)"
  fi
  if [ -n "$ov" ]; then
    printf '%s' "$ov" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  local url slug
  url="$(intercom_remote_url)"
  if [ -n "$url" ]; then
    slug="$(_intercom_slug_from_url "$url" 2>/dev/null)"
    if [ -n "$slug" ]; then
      printf '%s' "$slug"
      return 0
    fi
  fi
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then
    basename "$top" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  basename "$PWD" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# Inbox enumeration. Pending = *.md directly in the inbox dir (non-recursive,
# so _done/ is naturally excluded); README.md is skipped.
# ---------------------------------------------------------------------------

intercom_inbox_dir() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(intercom_identity)"
  printf '%s/%s' "$(intercom_store_root)" "$id"
}

intercom_inbox_list() {
  local dir
  dir="$(intercom_inbox_dir "${1:-}")"
  [ -d "$dir" ] || return 0
  local f base
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue          # literal glob when no match
    base="$(basename "$f")"
    if [ "$base" != "README.md" ]; then
      printf '%s\n' "$f"
    fi
  done
}

intercom_inbox_count() {
  intercom_inbox_list "${1:-}" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Frontmatter scalar extraction (for `check` listings).
# ---------------------------------------------------------------------------

intercom_fm_field() {
  local file="$1" field="$2"
  [ -f "$file" ] || return 0
  awk -v want="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      idx=index($0, ":")
      if (idx>0) {
        k=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",k)
        if (k==want) {
          v=substr($0,idx+1); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/^"|"$/,"",v)
          print v; exit
        }
      }
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Registry (DL #6): self-maintained who-is-who so a sender can address a
# project by any alias. Needs jq; fails open (routing by canonical still works).
# ---------------------------------------------------------------------------

intercom_register() {
  command -v jq >/dev/null 2>&1 || return 0
  local id
  id="$(intercom_identity)"
  [ -n "$id" ] || return 0
  local regdir regfile url top basename_alias ownerrepo now tmp base aliasjson
  regdir="$(intercom_registry_dir)"
  mkdir -p "$regdir" 2>/dev/null || return 0
  regfile="$regdir/$id.json"
  url="$(intercom_remote_url)"
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] || top="$PWD"
  basename_alias="$(basename "$top" | tr '[:upper:]' '[:lower:]')"
  ownerrepo="$(_intercom_owner_repo_from_url "$url" 2>/dev/null || true)"

  local aliases=()
  if [ -n "$basename_alias" ] && [ "$basename_alias" != "$id" ]; then
    aliases+=("$basename_alias")
  fi
  if [ -n "$ownerrepo" ] && [ "$ownerrepo" != "$id" ]; then
    aliases+=("$ownerrepo")
  fi
  aliasjson='[]'
  if [ "${#aliases[@]}" -gt 0 ]; then
    aliasjson="$(printf '%s\n' "${aliases[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  tmp="$(mktemp 2>/dev/null)" || return 0
  base='{}'
  [ -f "$regfile" ] && base="$(cat "$regfile" 2>/dev/null || echo '{}')"
  if printf '%s' "$base" | jq \
      --arg id "$id" \
      --arg remote "$url" \
      --arg path "$top" \
      --arg now "$now" \
      --argjson newaliases "$aliasjson" '
      .identity = $id
      | .remote  = (if $remote == "" then (.remote // null) else $remote end)
      | .aliases = (((.aliases // []) + $newaliases) | unique)
      | .paths   = (((.paths // []) + [$path]) | unique)
      | .updated = $now
    ' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$regfile" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# Resolve an input target to a canonical identity via the registry.
# Prints the canonical id. Return codes:
#   0 = resolved to a known project (direct match or alias)
#   2 = unknown target, echoed back lowercased as-is (first contact — caller warns)
intercom_resolve_target() {
  local target canon regdir rf
  target="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  regdir="$(intercom_registry_dir)"

  if [ -f "$regdir/$target.json" ]; then
    printf '%s' "$target"
    return 0
  fi
  if command -v jq >/dev/null 2>&1 && [ -d "$regdir" ]; then
    for rf in "$regdir"/*.json; do
      [ -e "$rf" ] || continue
      canon="$(jq -r --arg t "$target" '
        if (.identity == $t) or (((.aliases // []) | index($t)) != null)
        then .identity else empty end
      ' "$rf" 2>/dev/null)"
      if [ -n "$canon" ]; then
        printf '%s' "$canon"
        return 0
      fi
    done
  fi
  printf '%s' "$target"
  return 2
}
