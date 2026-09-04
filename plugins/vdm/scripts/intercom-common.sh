#!/bin/bash
# intercom-common.sh — sourced resolvers for the /vdm:intercom skill.
#
# The intercom store is a SINGLE machine-level mailbox that lives OUTSIDE all
# repositories (Decision Log #1 in docs/tasks/intercom-skill/workitem.md), so
# there is no per-repo .gitignore and nothing to commit. Messages are routed by
# a project's CANONICAL IDENTITY derived from its git remote slug — never the
# directory basename, which is unstable across clones (DL #4).
#
# The registry (<store>/_registry/<identity>.json) doubles as the AGENT
# DIRECTORY: one entry per project, carrying the canonical identity, the
# machine-derived aliases (directory basename, owner/repo), the HUMAN names the
# user actually says ("vdm", "the intercom agent"), a one-line description, and
# every remote the project has been seen under. A sender resolves ANY of those
# to the canonical inbox, so a brief lands on the first try (v2.21.0).
#
# NOT a hook and NOT mirrored to vdm-git — intercom ships in the vdm plugin only.
# Sourced by scripts/intercom.sh (CLI), scripts/intercom-reminder.sh (hook) and
# scripts/intercom-identity-check.sh (SessionStart hook).
#
# Every function FAILS OPEN: absence of git or jq must never break the caller.
# Worst case a resolver returns a basename fallback or skips registry upkeep.
# Target: bash 3.2 (macOS default) — no ${var,,}, no mapfile, no declare -A.

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

# Where the identity came from — for `whoami` / the session-start line.
# Prints one of: config | remote | git-toplevel | cwd
intercom_identity_source() {
  local ov=""
  if command -v vdm_config_read >/dev/null 2>&1; then
    ov="$(vdm_config_read intercom identity "" 2>/dev/null)"
  fi
  if [ -n "$ov" ]; then printf 'config'; return 0; fi
  local url
  url="$(intercom_remote_url)"
  if [ -n "$url" ] && _intercom_slug_from_url "$url" >/dev/null 2>&1; then
    printf 'remote'; return 0
  fi
  if git rev-parse --show-toplevel >/dev/null 2>&1; then printf 'git-toplevel'; return 0; fi
  printf 'cwd'
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
# Name folding. A human says "VDM plugins", "vdm_plugins" or "vdm-plugins" and
# means the same agent; every comparison in the registry goes through this
# fold on BOTH sides. Lowercase (ASCII); runs of whitespace/underscore → "-";
# trim "-". Dots and slashes survive (www.t23b.org, owner/repo are real names).
#
# ONE implementation, in jq — the bash side calls it rather than restating it.
# A second formulation of the same rule is a second copy of the rule, and a
# copy has nothing to be compared against (docs/model/suite.md, cases 6 and 8).
# Non-ASCII names (Cyrillic etc.) therefore match case-exactly — store them
# lowercase. Without jq there is no directory at all (the registry is JSON), so
# the fallback is the pre-2.21 behaviour: plain lowercase, canonical routing.
# ---------------------------------------------------------------------------

_INTERCOM_JQ_FOLD='def fold: (tostring | ascii_downcase | gsub("[ \t_]+"; "-") | sub("^-+"; "") | sub("-+$"; ""));'
# Order-preserving dedupe (jq's `unique` sorts, and the FIRST name the user
# gave is the primary one).
_INTERCOM_JQ_UNIQ='def uniq_ord: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);'

_intercom_fold() {
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" "$_INTERCOM_JQ_FOLD"' $s | fold' 2>/dev/null
  else
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  fi
}

# Human names are STORED lowercased (ASCII) + trimmed, inner whitespace
# collapsed to one space so they read well in listings; matching still goes
# through the fold above.
_intercom_norm_name() {
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" '$s | ascii_downcase | gsub("^[ \t]+|[ \t]+$"; "") | gsub("[ \t]+"; " ")' 2>/dev/null
  else
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  fi
}

# ---------------------------------------------------------------------------
# Registry read helpers. All fail open (empty output) without jq or entry.
# ---------------------------------------------------------------------------

intercom_registry_file() { printf '%s/%s.json' "$(intercom_registry_dir)" "$1"; }

# intercom_registry_get <identity> <jq-filter>  → raw output of the filter
intercom_registry_get() {
  local rf
  rf="$(intercom_registry_file "$1")"
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$rf" ] || return 0
  jq -r "$2" "$rf" 2>/dev/null
}

# Comma-joined list of the parts a registration still lacks. Empty = complete.
# "Complete" = at least one human name AND a description: the canonical id and
# the auto-aliases are always there, but they are the names a MACHINE derives —
# the user says "vdm", and nothing derived from a remote URL will ever say that.
intercom_registration_missing() {
  local id="${1:-}" rf
  [ -n "$id" ] || id="$(intercom_identity)"
  rf="$(intercom_registry_file "$id")"
  if ! command -v jq >/dev/null 2>&1; then printf ''; return 0; fi
  if [ ! -f "$rf" ]; then printf 'registration'; return 0; fi
  jq -r '
    [ (if ((.names // []) | length) == 0 then "names" else empty end),
      (if ((.description // "") | length) == 0 then "description" else empty end) ]
    | join(", ")
  ' "$rf" 2>/dev/null
}

# Remote mismatch = this clone's origin is neither the registered primary remote
# nor one of the confirmed `remotes`. Prints the registered primary and returns
# 0 when there IS a mismatch; returns 1 (prints nothing) when all is well.
# A mismatch is either a real inbox collision (two different projects share a
# slug — set a distinct intercom.identity in one) or the same project under a
# second remote (working clone vs marketplace clone — confirm with
# `register --same-project`). The registry cannot tell which; the user can.
intercom_remote_mismatch() {
  local id="${1:-}" url rf
  [ -n "$id" ] || id="$(intercom_identity)"
  url="$(intercom_remote_url)"
  [ -n "$url" ] || return 1
  rf="$(intercom_registry_file "$id")"
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$rf" ] || return 1
  local primary
  primary="$(jq -r --arg u "$url" '
    if ((.remote // "") == "") then ""
    elif (.remote == $u) then ""
    elif ((.remotes // []) | any(. == $u)) then ""
    else .remote end
  ' "$rf" 2>/dev/null)"
  [ -n "$primary" ] || return 1
  printf '%s' "$primary"
  return 0
}

# ---------------------------------------------------------------------------
# Registry (DL #6): self-maintained who-is-who so a sender can address a
# project by any alias. Needs jq; fails open (routing by canonical still works).
#
#   intercom_register [--name N]... [--describe D] [--same-project]
#
# Mechanical part (always): identity, remote(s), auto-aliases, paths, timestamps.
# Human part (only when asked): names + description — the part the session-start
# check nags about until it is present. Returns 1 without writing when a
# requested name already routes to a DIFFERENT project (ambiguity is the one
# thing a directory must never contain).
# ---------------------------------------------------------------------------

intercom_register() {
  command -v jq >/dev/null 2>&1 || return 0
  local same_project=0 desc="" names=() n
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)          n="$(_intercom_norm_name "${2:-}")"; [ -n "$n" ] && names+=("$n"); shift 2 ;;
      --name=*)        n="$(_intercom_norm_name "${1#--name=}")"; [ -n "$n" ] && names+=("$n"); shift ;;
      --describe)      desc="${2:-}"; shift 2 ;;
      --describe=*)    desc="${1#--describe=}"; shift ;;
      --same-project)  same_project=1; shift ;;
      *)               shift ;;
    esac
  done

  local id
  id="$(intercom_identity)"
  [ -n "$id" ] || return 0
  local regdir regfile url top basename_alias ownerrepo now tmp base aliasjson namesjson
  regdir="$(intercom_registry_dir)"
  mkdir -p "$regdir" 2>/dev/null || return 0
  regfile="$regdir/$id.json"
  url="$(intercom_remote_url)"

  # A human name must route to exactly one project. Refuse (before writing
  # anything) if any requested name is already an exact match elsewhere.
  local other rc=0
  for n in "${names[@]+"${names[@]}"}"; do
    other="$(intercom_resolve_target "$n" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$other" ] && [ "$other" != "$id" ]; then
      printf 'intercom: ✗ name "%s" already routes to `%s` — a name must point to exactly one agent.\n' "$n" "$other" >&2
      printf '          Remove it there first (intercom names rm --for %s "%s") or pick another name.\n' "$other" "$n" >&2
      return 1
    elif [ "$rc" -eq 3 ]; then
      printf 'intercom: ✗ name "%s" is already ambiguous in the directory (intercom resolve "%s").\n' "$n" "$n" >&2
      return 1
    fi
  done

  # Collision / second-remote detection (Sidetrack #4, refined in v2.21.0):
  # warn while this clone's remote is unconfirmed; `--same-project` confirms it.
  local add_remote='[]' mismatch=""
  if [ -n "$url" ]; then
    mismatch="$(intercom_remote_mismatch "$id" 2>/dev/null || true)"
    if [ -z "$mismatch" ] || [ "$same_project" -eq 1 ]; then
      add_remote="$(printf '%s' "$url" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
    else
      printf 'intercom: ⚠️  identity "%s" is registered under a different remote:\n' "$id" >&2
      printf '            registered: %s\n            this clone: %s\n' "$mismatch" "$url" >&2
      printf '            Same project (mirror / marketplace clone)? → intercom register --same-project\n' >&2
      printf '            Different project sharing the slug?        → set a distinct intercom.identity\n' >&2
      printf '            (.claude/vdm-plugins.json) in one of them so they stop sharing inbox `%s`.\n' "$id" >&2
    fi
  fi

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
  namesjson='[]'
  if [ "${#names[@]}" -gt 0 ]; then
    namesjson="$(printf '%s\n' "${names[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
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
      --arg desc "$desc" \
      --argjson newaliases "$aliasjson" \
      --argjson newnames "$namesjson" \
      --argjson addremote "$add_remote" "$_INTERCOM_JQ_UNIQ"'
      .identity    = $id
      | .registered  = (.registered // $now)
      | .remote      = (if ((.remote // "") == "") then (if $remote == "" then null else $remote end) else .remote end)
      | .remotes     = (((.remotes // []) + (if .remote then [.remote] else [] end) + $addremote) | uniq_ord)
      | .aliases     = (((.aliases // []) + $newaliases) | uniq_ord)
      | .names       = (((.names // []) + $newnames) | uniq_ord)
      | .description = (if $desc == "" then (.description // "") else $desc end)
      | .paths       = (((.paths // []) + [$path]) | uniq_ord)
      | .updated     = $now
    ' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$regfile" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# Edit the human names of a registration (own by default, or --for <identity>).
#   intercom_names_edit add|rm [--for <id>] <name>...
# Returns 1 on an unknown --for target or a name that routes elsewhere.
intercom_names_edit() {
  command -v jq >/dev/null 2>&1 || { printf 'intercom: names editing needs jq.\n' >&2; return 1; }
  local op="${1:-}"; [ $# -gt 0 ] && shift
  local id="" names=() n
  while [ $# -gt 0 ]; do
    case "$1" in
      --for)   id="$(_intercom_fold "${2:-}")"; shift 2 ;;
      --for=*) id="$(_intercom_fold "${1#--for=}")"; shift ;;
      *)       n="$(_intercom_norm_name "$1")"; [ -n "$n" ] && names+=("$n"); shift ;;
    esac
  done
  [ -n "$id" ] || id="$(intercom_identity)"
  local rf
  rf="$(intercom_registry_file "$id")"
  if [ ! -f "$rf" ]; then
    printf 'intercom: ✗ no registered agent `%s` (intercom directory lists them).\n' "$id" >&2
    return 1
  fi
  [ "${#names[@]}" -gt 0 ] || { printf 'intercom: names %s: no names given.\n' "$op" >&2; return 1; }

  if [ "$op" = "add" ]; then
    local other rc
    for n in "${names[@]}"; do
      other="$(intercom_resolve_target "$n" 2>/dev/null)"; rc=$?
      if [ "$rc" -eq 0 ] && [ -n "$other" ] && [ "$other" != "$id" ]; then
        printf 'intercom: ✗ name "%s" already routes to `%s` — remove it there first (intercom names rm --for %s "%s").\n' "$n" "$other" "$other" "$n" >&2
        return 1
      elif [ "$rc" -eq 3 ]; then
        printf 'intercom: ✗ name "%s" is already ambiguous in the directory.\n' "$n" >&2
        return 1
      fi
    done
  fi

  local namesjson tmp now
  namesjson="$(printf '%s\n' "${names[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  tmp="$(mktemp 2>/dev/null)" || return 1
  local prog
  case "$op" in
    add) prog="$_INTERCOM_JQ_UNIQ"'.names = (((.names // []) + $n) | uniq_ord) | .updated = $now' ;;
    rm)  prog="$_INTERCOM_JQ_FOLD"' ($n | map(fold)) as $drop | .names = ((.names // []) | map(select((fold) as $f | ($drop | index($f)) == null))) | .updated = $now' ;;
    *)   rm -f "$tmp"; printf 'intercom: names: unknown op "%s" (add|rm).\n' "$op" >&2; return 1 ;;
  esac
  if jq --argjson n "$namesjson" --arg now "$now" "$prog" "$rf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$rf" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
}

# ---------------------------------------------------------------------------
# Target resolution. One jq pass over the whole registry classifies every
# agent against the folded input:
#   exact   — input equals identity / alias / name (after fold)
#   partial — input is a substring of one of those (or of the description),
#             or a name ≥3 chars is a substring of the input
# Lines: "<kind>\t<identity>", registry order.
# ---------------------------------------------------------------------------

_intercom_match() {
  local t="$1" regdir
  regdir="$(intercom_registry_dir)"
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$regdir" ] || return 0
  local files=() rf
  for rf in "$regdir"/*.json; do
    [ -e "$rf" ] || continue
    files+=("$rf")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -r -s --arg t "$t" "$_INTERCOM_JQ_FOLD"'
    [ .[] | select(((.identity // "") | tostring) != "") ]
    | map({
        id: .identity,
        keys: (([.identity] + (.aliases // []) + (.names // [])) | map(fold)),
        desc: ((.description // "") | fold)
      })
    | map(
        if (.keys | any(. == $t)) then "exact\t" + .id
        elif ($t | length) >= 2
             and ( (.keys | any(contains($t)))
                   or (.keys | any((length >= 3) and ($t | contains(.))))
                   or (.desc | contains($t)) )
        then "partial\t" + .id
        else empty end
      )
    | .[]
  ' "${files[@]}" 2>/dev/null
}

# Resolve an input target to a canonical identity via the registry.
# stdout + return code:
#   0 = resolved (prints the canonical identity)
#   2 = unknown target (prints the folded input, for --first-contact use)
#   3 = ambiguous — several agents claim that name (prints nothing)
intercom_resolve_target() {
  local t regdir
  t="$(_intercom_fold "$1")"
  [ -n "$t" ] || return 2
  regdir="$(intercom_registry_dir)"
  if [ -f "$regdir/$t.json" ]; then
    printf '%s' "$t"
    return 0
  fi
  local exact n
  exact="$(_intercom_match "$t" | awk -F'\t' '$1=="exact" { print $2 }')"
  n=0
  [ -n "$exact" ] && n="$(printf '%s\n' "$exact" | grep -c '.' 2>/dev/null || echo 0)"
  if [ "$n" -eq 1 ]; then
    printf '%s' "$exact"
    return 0
  elif [ "$n" -gt 1 ]; then
    return 3
  fi
  printf '%s' "$t"
  return 2
}

# One directory line per agent. Format:
#   • <identity>   aka: <names, aliases>   — <description|(no description)>
# `intercom_directory_line <identity> [mark]` — mark ⚠ when incomplete.
intercom_directory_line() {
  local id="$1" rf
  rf="$(intercom_registry_file "$id")"
  [ -f "$rf" ] || { printf '  • %s\n' "$id"; return 0; }
  jq -r --arg id "$id" '
    def joinlist: if length == 0 then "" else join(", ") end;
    ((.names // []) + (.aliases // [])) as $aka
    | "  • " + $id
      + (if ($aka | length) > 0 then "   aka: " + ($aka | joinlist) else "" end)
      + "   — " + (if ((.description // "") | length) > 0 then .description else "(no description)" end)
      + (if (((.names // []) | length) == 0) or (((.description // "") | length) == 0) then "   ⚠ unnamed" else "" end)
  ' "$rf" 2>/dev/null
}

# Candidate list for an input that did not resolve (exact + partial matches).
intercom_suggest() {
  local t id
  t="$(_intercom_fold "$1")"
  [ -n "$t" ] || return 0
  _intercom_match "$t" | awk -F'\t' '{ print $2 }' | while IFS= read -r id; do
    [ -n "$id" ] || continue
    intercom_directory_line "$id"
  done
}

# Inbox directories that exist in the store but have NO registry entry — the
# footprint of a --first-contact send whose recipient never registered under
# that name (or registered under another). One per line, sorted.
intercom_orphan_inboxes() {
  local root d id
  root="$(intercom_store_root)"
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    case "$id" in _*) continue ;; esac
    if [ ! -f "$(intercom_registry_file "$id")" ]; then
      printf '%s\n' "$id"
    fi
  done | sort
}

# Orphan inboxes whose name folds to one of THIS agent's names or aliases:
# a --first-contact send that was addressed to you under a name you go by,
# but which is not your canonical inbox. Surfaced at session start and by
# `check`/`whoami`; moved home with `intercom claim <inbox>`.
intercom_orphans_matching() {
  local id="${1:-}" rf keys o
  [ -n "$id" ] || id="$(intercom_identity)"
  rf="$(intercom_registry_file "$id")"
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$rf" ] || return 0
  keys="$(jq -r "$_INTERCOM_JQ_FOLD"' ((.names // []) + (.aliases // [])) | map(fold) | .[]' "$rf" 2>/dev/null)"
  [ -n "$keys" ] || return 0
  intercom_orphan_inboxes | while IFS= read -r o; do
    [ -n "$o" ] || continue
    if printf '%s\n' "$keys" | grep -qxF "$(_intercom_fold "$o")"; then
      printf '%s\n' "$o"
    fi
  done
}

# All registered identities, one per line, sorted.
intercom_registry_ids() {
  local regdir rf
  regdir="$(intercom_registry_dir)"
  [ -d "$regdir" ] || return 0
  for rf in "$regdir"/*.json; do
    [ -e "$rf" ] || continue
    basename "$rf" .json
  done | sort
}
