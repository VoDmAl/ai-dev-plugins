#!/bin/bash
# crystal-path.sh — resolver + workitem helpers for the crystal-* suite.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/crystal-path.sh.
# Drift is caught by scripts/check-lib-sync.sh in .githooks/pre-commit; any change
# here MUST be applied to the vdm-git copy in the same commit.
#
# Strategy:
#   - Storage root(s) resolve through three branches, in order:
#       1. crystal.paths (array, plural) — explicit globs, expanded.
#       2. crystal.path  (string, legacy single root) — back-compat shim.
#       3. Auto-scan: find <project_root> -type d -name tasks, pruning hidden
#          segments and node_modules/vendor. Safe default in vault/monorepo
#          trees. See DL #2, #12 in docs/tasks/crystal-multi-root/workitem.md.
#   - Read-only: never creates directories. Writers (crystal-grow skill) own
#     `mkdir -p`. Hooks must survive missing roots silently.
#   - Workitem layout: folder-style (<root>/<slug>/workitem.md) is canonical
#     (DL #12); flat-style (<root>/<slug>.md) recognized for legacy compat.
#   - Status taxonomy: 4 tiers (pre-work / active / paused / terminal) — see
#     derive_status_tier(). Singleton invariant applies to the active tier
#     only (DL #5). Non-canonical statuses surfaced via audit_non_canonical().

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-read.sh"

# ----------------------------------------------------------------------------
# Status taxonomy (DL #10)
# ----------------------------------------------------------------------------

crystal_tier() {
  # crystal_tier <tier-name> — prints statuses belonging to tier, one per line.
  case "$1" in
    pre-work) printf '%s\n' idea draft ready ;;
    active)   printf '%s\n' in-progress ;;
    paused)   printf '%s\n' blocked dormant ;;
    terminal) printf '%s\n' done cancelled superseded ;;
    *)        return 1 ;;
  esac
}

crystal_canonical_statuses() {
  # Outputs all canonical statuses, one per line. Used by audit and validation.
  local tier
  for tier in pre-work active paused terminal; do
    crystal_tier "$tier"
  done
}

_load_status_aliases() {
  # Loads status-aliases from config once per shell process; stores as a flat
  # newline-separated `key=value` blob in _VDM_STATUS_ALIASES_DATA. Bash 3.2
  # compat (no associative arrays).
  [ -n "${_VDM_STATUS_ALIASES_LOADED:-}" ] && return 0
  _VDM_STATUS_ALIASES_LOADED=1
  _VDM_STATUS_ALIASES_DATA=""
  command -v jq >/dev/null 2>&1 || return 0
  local cfg
  cfg=$(resolve_config_path 2>/dev/null) || return 0
  [ -f "$cfg" ] || return 0
  _VDM_STATUS_ALIASES_DATA=$(jq -r '
    .crystal["status-aliases"] // {} | to_entries[] | "\(.key)=\(.value)"
  ' "$cfg" 2>/dev/null)
}

_apply_status_alias() {
  # _apply_status_alias <raw-status> — returns alias target if mapped, else raw.
  local raw="$1"
  _load_status_aliases
  [ -z "$_VDM_STATUS_ALIASES_DATA" ] && { printf '%s\n' "$raw"; return; }
  local line
  while IFS= read -r line; do
    case "$line" in
      "$raw="*) printf '%s\n' "${line#*=}"; return ;;
    esac
  done <<<"$_VDM_STATUS_ALIASES_DATA"
  printf '%s\n' "$raw"
}

derive_status_tier() {
  # derive_status_tier <status> — prints tier name ("pre-work"/"active"/
  # "paused"/"terminal") or "non-canonical". Aliases applied transparently.
  local status="$1"
  local resolved tier candidate
  resolved=$(_apply_status_alias "$status")
  for tier in pre-work active paused terminal; do
    while IFS= read -r candidate; do
      [ "$candidate" = "$resolved" ] && { printf '%s\n' "$tier"; return 0; }
    done < <(crystal_tier "$tier")
  done
  printf 'non-canonical\n'
}

# ----------------------------------------------------------------------------
# Root resolution (DL #3, #9, #12)
# ----------------------------------------------------------------------------

_expand_globs_under_root() {
  # _expand_globs_under_root <project-root> <newline-separated-globs>
  # Each glob expands via bash nullglob/globstar inside a subshell so settings
  # don't leak. Absolute globs respected; relative resolved against project root.
  local project_root="$1" globs="$2"
  (
    # shellcheck disable=SC3044
    shopt -s nullglob globstar
    local glob expanded e
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      glob="${glob%/}"
      case "$glob" in
        /*) expanded=( $glob ) ;;
        *)  expanded=( "$project_root"/$glob ) ;;
      esac
      for e in "${expanded[@]}"; do
        [ -d "$e" ] && printf '%s\n' "$e"
      done
    done <<<"$globs"
  ) | sort -u
}

_extract_tasks_dirs_from_git_files() {
  # stdin: tracked file paths (one per line, relative); stdout: distinct
  # `<prefix>/tasks` directories (each printed once, with no trailing slash).
  awk -F/ '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "tasks") {
          p = $1
          for (j = 2; j < i; j++) p = p "/" $j
          p = (i == 1) ? "tasks" : p "/tasks"
          if (!(p in seen)) { seen[p] = 1; print p }
          break
        }
      }
    }
  '
}

_auto_scan_tasks_dirs() {
  # _auto_scan_tasks_dirs <project-root>
  # Default discovery: any `tasks/` directory under root. Hidden segments
  # (cs:s2-605) and common dependency dirs (node_modules, vendor) excluded.
  #
  # Two implementations, picked at runtime:
  #   - git ls-files (fast — ~50ms on vault) when inside a git work tree
  #   - find fallback (~4s on large trees) for non-git repos (cs:p2-85f4 —
  #     projects without git must still work)
  local root="$1"
  [ -d "$root" ] || return 0

  if command -v git >/dev/null 2>&1 && \
     ( cd "$root" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    ( cd "$root" 2>/dev/null && git ls-files 2>/dev/null ) \
      | _extract_tasks_dirs_from_git_files \
      | awk -v r="$root/" '/./{ print r $0 }' \
      | grep -vE '/(node_modules|vendor)/' \
      | sort -u
    return 0
  fi

  # Non-git fallback. cd-ing into root makes the `*/.*` path test see only
  # post-root segments, so a repo placed under a hidden path still scans.
  (
    cd "$root" 2>/dev/null && \
    find . \
      \( -path '*/.*' -o -name 'node_modules' -o -name 'vendor' \) -prune -o \
      -type d -name tasks -prune -print 2>/dev/null
  ) | awk -v r="$root/" '/./{ sub(/^\.\//, r); print }' | sort -u
}

_resolve_crystal_roots_uncached() {
  # Inner resolver — does the actual work. Cached wrapper below.
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null) || project_root=$(pwd)

  # 1. crystal.paths — explicit array of globs
  local paths_out
  paths_out=$(vdm_config_read_array "crystal" "paths" 2>/dev/null)
  if [ -n "$paths_out" ]; then
    _expand_globs_under_root "$project_root" "$paths_out"
    return 0
  fi

  # 2. crystal.path — legacy single root (back-compat)
  local singular
  singular=$(vdm_config_read "crystal" "path" "__VDM_UNSET__")
  if [ "$singular" != "__VDM_UNSET__" ] && [ -n "$singular" ]; then
    singular="${singular%/}"
    case "$singular" in
      /*) printf '%s\n' "$singular" ;;
      *)  printf '%s/%s\n' "$project_root" "$singular" ;;
    esac
    return 0
  fi

  # 3. Auto-scan
  _auto_scan_tasks_dirs "$project_root"
}

resolve_crystal_roots() {
  # Outputs zero or more absolute root paths, one per line.
  # Memoized at shell-process scope — hooks call this from many places per
  # invocation (extract_slug per file, format_active_summary, derive_singleton_mode);
  # auto-scan on a large tree (e.g. vault's `attachments/` with 7000+ files)
  # is multi-second. The cache makes a single hook call O(1) instead of O(N²).
  # Cache lifetime: the lib-sourcing process. Re-source the lib to invalidate.
  if [ -n "${_VDM_CRYSTAL_ROOTS_LOADED:-}" ]; then
    [ -n "$_VDM_CRYSTAL_ROOTS_CACHE" ] && printf '%s\n' "$_VDM_CRYSTAL_ROOTS_CACHE"
    return 0
  fi
  _VDM_CRYSTAL_ROOTS_CACHE=$(_resolve_crystal_roots_uncached)
  _VDM_CRYSTAL_ROOTS_LOADED=1
  [ -n "$_VDM_CRYSTAL_ROOTS_CACHE" ] && printf '%s\n' "$_VDM_CRYSTAL_ROOTS_CACHE"
  return 0
}

resolve_crystal_root() {
  # Backward-compat wrapper — returns first root or empty. Callers that need
  # full multi-root awareness must use resolve_crystal_roots directly.
  resolve_crystal_roots | head -n 1
}

# ----------------------------------------------------------------------------
# Singleton mode (DL #5)
# ----------------------------------------------------------------------------

derive_singleton_mode() {
  # Prints "global" / "per-root" / "off".
  # Explicit override wins; otherwise derives from number of resolved roots.
  local override
  override=$(vdm_config_read "crystal" "singleton" "__VDM_UNSET__")
  case "$override" in
    global|per-root|off) printf '%s\n' "$override"; return 0 ;;
    auto|__VDM_UNSET__|"") : ;;
    *) ;;
  esac
  local count
  count=$(resolve_crystal_roots | grep -c '.' 2>/dev/null || true)
  if [ "${count:-0}" -le 1 ]; then
    printf 'global\n'
  else
    printf 'per-root\n'
  fi
}

# ----------------------------------------------------------------------------
# Workitem discovery
# ----------------------------------------------------------------------------

find_workitems() {
  # Outputs all candidate workitem file paths across ALL resolved roots.
  # Folder-style (<root>/<slug>/workitem.md), then flat-style (<root>/<slug>.md).
  # Sorted, deduped. Empty output when no roots resolved or no roots exist.
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    find "$root" -mindepth 2 -maxdepth 2 -type f -name 'workitem.md' 2>/dev/null
    find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null
  done < <(resolve_crystal_roots) | sort -u
}

extract_frontmatter_field() {
  # extract_frontmatter_field <file> <field>
  # Reads the YAML frontmatter (between leading `---` markers) and prints the
  # value for the given top-level key, or nothing if absent. No quoting fixups —
  # we only consume simple scalar values (status, slug, session-type, etc.).
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
  # filter_status <expected-status>|tier:<tier-name>
  # Reads file paths on stdin; prints only those whose frontmatter `status`
  # matches the argument (after status-alias resolution). When called with
  # `tier:active` etc, prints all files in that tier. Files without `status:`
  # are dropped — those are artifacts, not workitems (DL #12 collateral).
  local expected="$1"
  local match_tier=""
  case "$expected" in
    tier:*) match_tier="${expected#tier:}" ;;
  esac
  local f raw resolved tier
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    raw=$(extract_frontmatter_field "$f" status)
    [ -z "$raw" ] && continue
    resolved=$(_apply_status_alias "$raw")
    if [ -n "$match_tier" ]; then
      tier=$(derive_status_tier "$resolved")
      if [ "$tier" = "$match_tier" ]; then
        printf '%s\n' "$f"
      fi
    else
      if [ "$resolved" = "$expected" ]; then
        printf '%s\n' "$f"
      fi
    fi
  done
  # Explicit return — guard against the while-loop exit code being non-zero
  # when the final iteration takes the no-match branch (bash returns the
  # last command's status, and `[ ... ] = ... ]` returns 1 on no match).
  return 0
}

audit_non_canonical() {
  # Reads file paths on stdin; outputs only paths whose `status:` is
  # non-canonical (after alias resolution). Files without `status:` are
  # skipped — they're artifacts, not workitems with broken metadata.
  local f raw resolved
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    raw=$(extract_frontmatter_field "$f" status)
    [ -z "$raw" ] && continue
    resolved=$(_apply_status_alias "$raw")
    if [ "$(derive_status_tier "$resolved")" = "non-canonical" ]; then
      printf '%s\n' "$f"
    fi
  done
  return 0
}

count_unchecked() {
  # Counts unchecked markdown checkboxes (`- [ ]`) in the file. The crystal-cut
  # gate (Decision Log #4 in crystal-design) generalizes "completion discipline"
  # to any unchecked checkbox in the workitem, not only items inside
  # `## Sidetracks`.
  local file="$1"
  [ -f "$file" ] || { printf '0\n'; return; }
  local n
  n=$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$file" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

audit_sidetracks_without_markers() {
  # Returns "#N. <title>" lines for every sidetrack card with `**Status:** open`
  # that lacks a matching inline `- [ ] ... Sidetrack #N` marker in the workitem
  # body (DL #14 in crystal-multi-root). Empty output = no orphans.
  #
  # Sidetrack cards: `### #N. <title>` followed at some point by
  # `**Status:** open[ ...]`. Decision-Log entries use `### #N / date / title`
  # (slash separator, no period) and never carry `**Status:**` — so they don't
  # collide with this parser.
  #
  # Marker recognition: matches `- [ ] ... Sidetrack #N` anywhere in body
  # (typically inside `## Pending sidetracks` block, but free placement is OK).
  # Word-boundary on N uses `[^0-9]|$` instead of `\b` for grep -E portability.
  local file="$1"
  [ -f "$file" ] || return 0

  local current_n=""
  local current_title=""
  local missing=""
  local line rest n_part status_text trimmed
  while IFS= read -r line; do
    case "$line" in
      "### #"*)
        # Strip the literal "### #" prefix — quote needed so bash doesn't read
        # the `#`s as parameter-expansion operators.
        rest="${line#"### #"}"
        # Sidetrack heading shape is "<digits>. <title>" — DL entries use
        # "<digits> / date / title" instead, so the literal period after N
        # disambiguates.
        case "$rest" in
          *.*) : ;;
          *)   current_n=""; current_title=""; continue ;;
        esac
        n_part="${rest%%.*}"
        case "$n_part" in
          ''|*[!0-9]*) current_n=""; current_title=""; continue ;;
          *) current_n="$n_part" ;;
        esac
        # Title is everything after the first period; trim leading whitespace.
        trimmed="${rest#*.}"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        current_title="$trimmed"
        ;;
      "**Status:**"*)
        if [ -n "$current_n" ]; then
          status_text="${line#"**Status:**"}"
          status_text="${status_text#"${status_text%%[![:space:]]*}"}"
          case "$status_text" in
            open*)
              if ! grep -qE "^[[:space:]]*-[[:space:]]*\[[[:space:]]\].*Sidetrack #${current_n}([^0-9]|$)" "$file" 2>/dev/null; then
                missing="${missing}#${current_n}. ${current_title}
"
              fi
              ;;
          esac
          current_n=""
          current_title=""
        fi
        ;;
    esac
  done < "$file"

  printf '%s' "$missing"
}

extract_slug() {
  # extract_slug <workitem-path>
  # In single-root mode: slug is relative to root (e.g. "auth-refactor").
  # In multi-root mode: slug is `<parent>/<file-slug>` where <parent> is the
  # path segment immediately above the tasks/ root (e.g. "auth/refactor-jwt").
  # Defensive fallback to basename when path isn't rooted under any known root.
  local file="$1"
  local roots root rel root_count
  roots=$(resolve_crystal_roots)
  root_count=$(printf '%s\n' "$roots" | grep -c '.' 2>/dev/null || echo 0)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$file" in
      "$r"/*) root="$r"; rel="${file#"$r"/}"; break ;;
    esac
  done <<<"$roots"

  if [ -z "${root:-}" ]; then
    local base
    base=$(basename "$file" .md)
    printf '%s\n' "${base%/workitem}"
    return 0
  fi

  local slug
  case "$rel" in
    */workitem.md) slug="${rel%/workitem.md}" ;;
    *.md)          slug="${rel%.md}" ;;
    *)             slug="$rel" ;;
  esac

  if [ "${root_count:-1}" -gt 1 ]; then
    local parent
    parent=$(basename "$(dirname "$root")")
    printf '%s/%s\n' "$parent" "$slug"
  else
    printf '%s\n' "$slug"
  fi
}

# ----------------------------------------------------------------------------
# Output formatting (DL #13)
# ----------------------------------------------------------------------------

format_active_summary() {
  # Reads workitem paths (sorted, slug order) on stdin; outputs human-readable
  # summary. Single-root → flat one-liner. Multi-root → multi-line, grouped by
  # the leading `<parent>` component of the slug, alphabetical within group.
  # Caller decides whether to wrap this in a hook envelope or print directly.
  local roots_count
  roots_count=$(resolve_crystal_roots | grep -c '.' 2>/dev/null || echo 0)
  if [ "${roots_count:-1}" -le 1 ]; then
    local first=1 line="" f slug n
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      slug=$(extract_slug "$f")
      n=$(count_unchecked "$f")
      if [ $first -eq 1 ]; then
        line="${slug} (${n} open)"
        first=0
      else
        line="${line}, ${slug} (${n} open)"
      fi
    done
    [ -n "$line" ] && printf '%s\n' "$line"
  else
    local current_group="" group_items="" f slug n group item
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      slug=$(extract_slug "$f")
      n=$(count_unchecked "$f")
      case "$slug" in
        */*) group="${slug%%/*}"; item="${slug#*/} (${n})" ;;
        *)   group="(root)"; item="${slug} (${n})" ;;
      esac
      if [ "$group" != "$current_group" ]; then
        [ -n "$current_group" ] && printf '  - %s: %s\n' "$current_group" "$group_items"
        current_group="$group"
        group_items="$item"
      else
        group_items="${group_items}, ${item}"
      fi
    done
    [ -n "$current_group" ] && printf '  - %s: %s\n' "$current_group" "$group_items"
  fi
}
