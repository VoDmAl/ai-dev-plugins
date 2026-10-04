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

# A session run from $HOME (or /) is not a project, and its basename is not an
# identity — on this machine `basename $HOME` is literally `vdm`, a registered
# NAME of ai-dev-plugins, so one send from the home directory would have created
# a second entry claiming that name and made `resolve vdm` ambiguous. What such
# a session actually is, is *this machine*, and the OS already knows its name in
# slug form. `LocalHostName` is machine-local BY CONSTRUCTION — it lives in the
# system, not in ~/.claude, which here is a symlink into Dropbox shared by every
# machine the user owns, so the documented `intercom.identity` override cannot
# express "this computer" even in principle.
_intercom_machine_name() {
  local m=""
  command -v scutil >/dev/null 2>&1 && m="$(scutil --get LocalHostName 2>/dev/null || true)"
  [ -n "$m" ] || m="$(hostname -s 2>/dev/null || true)"
  [ -n "$m" ] || m="localhost"
  printf '%s' "$m" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | sed -e 's|[^a-z0-9._-]|-|g' -e 's|-\{2,\}|-|g' -e 's|^-||' -e 's|-$||'
}

# True when $PWD is a directory that cannot be a project — the same predicate
# the SessionStart check has always applied (intercom-identity-check.sh), lifted
# here so every caller gets it rather than only the hook.
_intercom_pwd_is_not_a_project() {
  case "$PWD" in
    "$HOME"|"/") return 0 ;;
    *)           return 1 ;;
  esac
}

# Where the identity came from — for `whoami` / the session-start line.
# Prints one of: config | remote | git-toplevel | machine | cwd
#
# `machine` and `cwd` are the two weak sources and they are NOT equivalent:
# `machine` is stable and cannot collide with a project slug by accident, while
# `cwd` is whatever directory the shell happens to sit in. Only the latter is
# refused for implicit registration (see intercom_register --implicit).
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
  if _intercom_pwd_is_not_a_project; then printf 'machine'; return 0; fi
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
  if _intercom_pwd_is_not_a_project; then
    _intercom_machine_name
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
# Letter references — the relay form.
#
# A relay (agent A → B → C) used to travel by each hop pasting the previous
# letter inside its own. Measured on the whole store 2026-09-22: one such relay
# in 318 letters, and it cost 64 KB with two levels of `>` quoting, 288 of 550
# lines being re-transmitted text the last recipient had to read past.
#
# Nothing forced that. The store is ONE machine-level directory and every inbox
# is a sibling, so the previous letter was readable by path the whole time —
# what was missing was a form for naming it. That is all `reply-to:` is: an
# address, not a copy.
#
# A reference is `<identity>/<slug>`, or a bare `<slug>` when it is unambiguous.
# Both the inbox and its `_done/` archive are searched, because a relay's
# previous hop is routinely picked up before the next hop is written.
# ---------------------------------------------------------------------------

intercom_find_letter() {
  local ref="${1:-}" root id slug d f
  [ -n "$ref" ] || return 0
  root="$(intercom_store_root)"
  [ -d "$root" ] || return 0
  case "$ref" in
    */*) id="${ref%%/*}"; slug="${ref##*/}" ;;
    *)   id=""; slug="$ref" ;;
  esac
  slug="${slug%.md}"
  [ -n "$slug" ] || return 0

  if [ -n "$id" ]; then
    for f in "$root/$id/$slug.md" "$root/$id/_done/$slug.md"; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
  fi
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "_registry" ] && continue
    for f in "${d}${slug}.md" "${d}_done/${slug}.md"; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  done
}

# Path → `<identity>/<slug>`, the form written into an envelope. A path would
# go stale the moment the letter is picked up (inbox → `_done/`); the reference
# does not, because it is resolved on every read.
intercom_letter_ref() {
  local f="${1:-}" root rel id
  [ -n "$f" ] || return 0
  root="$(intercom_store_root)"
  rel="${f#"$root"/}"
  id="${rel%%/*}"
  [ -n "$id" ] && [ "$id" != "$rel" ] || return 0
  printf '%s/%s\n' "$id" "$(basename "$f" .md)"
}

# Walk back along `reply-to:`, one hop per line: `<ref>\t<path>\t<title>`.
# The chain is DERIVED, never stored: each letter names only its immediate
# predecessor, so there is no list to keep in sync and no way for a stored
# chain to disagree with the letters. A missing link and a cycle are both
# reported rather than silently ending the walk — a chain that stops early
# looks exactly like a chain that was complete.
intercom_chain() {
  local ref="${1:-}" depth=0 seen="" path title
  while [ -n "$ref" ] && [ "$depth" -lt 12 ]; do
    case "|$seen|" in
      *"|$ref|"*) printf '%s\t\t(cycle — this letter is already in the chain)\n' "$ref"; return 0 ;;
    esac
    seen="$seen|$ref"
    path="$(intercom_find_letter "$ref" | head -1)"
    if [ -z "$path" ]; then
      printf '%s\t\t(missing — no letter with that reference is in the store)\n' "$ref"
      return 0
    fi
    title="$(grep -m1 '^# ' "$path" 2>/dev/null | sed 's/^# //')"
    printf '%s\t%s\t%s\n' "$ref" "$path" "${title:-$ref}"
    ref="$(intercom_fm_field "$path" reply-to)"
    depth=$((depth + 1))
  done
}

# ---------------------------------------------------------------------------
# Name folding. A human says "VDM plugins", "vdm_plugins" or "vdm-plugins" and
# means the same agent; every comparison in the registry goes through this
# fold on BOTH sides. Lowercase (ASCII); runs of whitespace/underscore → "-";
# trim "-". Dots and slashes survive (www.example.org, owner/repo are real names).
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

# Every entry file of the registry, one path per line — never a sync conflict
# copy. The store is synced between the user's machines, and when two of them
# edit one entry at once Syncthing keeps the losing side beside it as
# `<id>.sync-conflict-<date>-<time>-<device>.json`. Read as an entry, such a
# copy claims every name of the original, and each of those names turns
# ambiguous: on 2026-10-03 ten copies made `resolve vdm` exit 3 and put ten
# phantom agents into `directory`. The copy holds no fact the entry lacks — the
# ten differed from theirs only in `.updated`. Every reader that enumerates the
# registry goes through here; reading one entry by identity needs no filter.
_intercom_registry_files() {
  local regdir rf
  regdir="$(intercom_registry_dir)"
  [ -d "$regdir" ] || return 0
  for rf in "$regdir"/*.json; do
    [ -e "$rf" ] || continue
    case "${rf##*/}" in *.sync-conflict-*) continue ;; esac
    printf '%s\n' "$rf"
  done
}

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
#   intercom_register [--explicit] [--name N]... [--describe D] [--role R]... [--same-project]
#
# Implicit by default: an identity resting on nothing but the directory's name
# is not registered. `--explicit` — the `register` subcommand, the one gesture
# that asserts "this is a project" — lifts that. The default is the guarded side
# on purpose: the guard was once opt-in, and the one caller that forgot the flag
# (the session-start hook) turned scratch directories and a plugin's cache folder
# into agents (vdx, 2026-09-28). A new caller is now safe without knowing.
#
# Mechanical part (always): identity, remote(s), auto-aliases, paths, timestamps.
# Human part (only when asked): names + description — the part the session-start
# check nags about until it is present. Returns 1 without writing when a
# requested name already routes to a DIFFERENT project (ambiguity is the one
# thing a directory must never contain).
# ---------------------------------------------------------------------------

# _intercom_need_value <flag> <args-left> — a value flag must have a value.
#
# Every option parser here used to read `--x) v="${2:-}"; shift 2`. With the
# flag as the LAST argument, `shift 2` has one argument to shift, shifts none,
# returns non-zero — and the loop sees the same flag again, forever. Measured
# 2026-09-24: `send <to> <slug> --title` hung until killed. A typo must not
# freeze the caller's shell; it gets a refusal naming the flag.
_intercom_need_value() {
  [ "$2" -ge 2 ] && return 0
  printf 'intercom: %s needs a value.\n' "$1" >&2
  return 1
}

intercom_register() {
  command -v jq >/dev/null 2>&1 || return 0
  local same_project=0 implicit=1 desc="" names=() roles=() n
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)          _intercom_need_value "$1" $# || return 2
                       _intercom_role_check "$2" || return 2; roles+=("$2"); shift 2 ;;
      --role=*)        _intercom_role_check "${1#--role=}" || return 2; roles+=("${1#--role=}"); shift ;;
      --name)          _intercom_need_value "$1" $# || return 2
                       n="$(_intercom_norm_name "$2")"; [ -n "$n" ] && names+=("$n"); shift 2 ;;
      --name=*)        n="$(_intercom_norm_name "${1#--name=}")"; [ -n "$n" ] && names+=("$n"); shift ;;
      --describe)      _intercom_need_value "$1" $# || return 2; desc="$2"; shift 2 ;;
      --describe=*)    desc="${1#--describe=}"; shift ;;
      --same-project)  same_project=1; shift ;;
      --implicit)      implicit=1; shift ;;   # the default; kept so old callers read the same
      --explicit)      implicit=0; shift ;;
      # Refused before the registry is touched: `--nmae X` used to register
      # without the name and report success.
      *)               printf 'intercom: register: unknown option %s — nothing written. Usage: intercom register [--name N]... [--describe D] [--role R]... [--same-project]\n' "$1" >&2
                       return 2 ;;
    esac
  done

  # Registration rides along on `check` / `send` / `claim` — the natural "I
  # exist" moments — and those run from whatever directory the shell is in, not
  # from a project the user chose. When the identity rests on nothing sturdier
  # than that basename, riding along is how the directory acquires agents named
  # after a version folder or a browser profile. Explicit `register` stays the
  # way to say "this really is a project"; it is the only gesture that carries
  # the assertion.
  if [ "$implicit" -eq 1 ] && [ "$(intercom_identity_source)" = "cwd" ]; then
    return 0
  fi

  local id
  id="$(intercom_identity)"
  [ -n "$id" ] || return 0

  # The identity itself can collide with a human NAME another agent already
  # owns, and that direction is worse than a name clash: `intercom_resolve_target`
  # answers from `<registry>/<input>.json` before it ever looks at names, so the
  # new entry does not merely tie — it WINS, and silently takes over routing
  # that used to work. Refuse before writing anything.
  local id_owner id_rc=0
  id_owner="$(intercom_resolve_target "$id" 2>/dev/null)"; id_rc=$?
  if [ "$id_rc" -eq 0 ] && [ -n "$id_owner" ] && [ "$id_owner" != "$id" ]; then
    printf 'intercom: ✗ identity "%s" is already a NAME of `%s` — refusing to register.\n' "$id" "$id_owner" >&2
    printf '          Registering it would hijack `intercom send %s ...`, which today reaches `%s`.\n' "$id" "$id_owner" >&2
    printf '          Set a distinct intercom.identity in .claude/vdm-plugins.json, or work from the project directory.\n' >&2
    return 1
  fi

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
  # …and a role to one agent (see the Roles block below).
  for n in "${roles[@]+"${roles[@]}"}"; do
    _intercom_role_free "$n" "$id" || return 1
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
  if [ -n "$top" ]; then
    basename_alias="$(basename "$top" | tr '[:upper:]' '[:lower:]')"
  elif _intercom_pwd_is_not_a_project; then
    # $HOME has a basename like any directory, and here it is `vdm`. Guarding
    # only the identity moved the collision into `aliases`, which resolve just
    # as well — the first version of this fix passed four acceptance criteria
    # and broke the fifth exactly this way.
    basename_alias=""
  else
    basename_alias="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
  fi
  ownerrepo="$(_intercom_owner_repo_from_url "$url" 2>/dev/null || true)"

  # An alias is machine-derived guesswork, not something the user asked for, so
  # one that already routes elsewhere is dropped rather than refused: a clone
  # sitting in a directory that happens to share another agent's name is the
  # user's filesystem, not their intent. Names get the opposite treatment above
  # (hard refusal) because a name IS the intent.
  _intercom_alias_is_free() {
    local a="$1" owner rc=0
    owner="$(intercom_resolve_target "$a" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] && [ -n "$owner" ] && [ "$owner" != "$id" ] && return 1
    [ "$rc" -eq 3 ] && return 1
    return 0
  }

  local aliases=()
  if [ -n "$basename_alias" ] && [ "$basename_alias" != "$id" ] \
     && _intercom_alias_is_free "$basename_alias"; then
    aliases+=("$basename_alias")
  fi
  if [ -n "$ownerrepo" ] && [ "$ownerrepo" != "$id" ] \
     && _intercom_alias_is_free "$ownerrepo"; then
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
  local rolesjson='[]'
  if [ "${#roles[@]}" -gt 0 ]; then
    rolesjson="$(printf '%s\n' "${roles[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  tmp="$(mktemp 2>/dev/null)" || return 0
  base='{}'
  [ -f "$regfile" ] && base="$(cat "$regfile" 2>/dev/null || echo '{}')"
  # An entry that would change in nothing but its stamp is left alone: the jq
  # program prints nothing, and an empty result is not written. This runs at
  # every session start, check and send, on every machine the store is synced
  # to, and rewriting an unchanged entry was how two machines came to edit one
  # file at once (see _intercom_registry_files). `.updated` is therefore the
  # time of the last change, which is all its name ever claimed.
  if printf '%s' "$base" | jq \
      --arg id "$id" \
      --arg remote "$url" \
      --arg path "$top" \
      --arg now "$now" \
      --arg desc "$desc" \
      --argjson newaliases "$aliasjson" \
      --argjson newnames "$namesjson" \
      --argjson newroles "$rolesjson" \
      --argjson addremote "$add_remote" "$_INTERCOM_JQ_UNIQ"'
      . as $old
      | .identity    = $id
      | .registered  = (.registered // $now)
      | .remote      = (if ((.remote // "") == "") then (if $remote == "" then null else $remote end) else .remote end)
      | .remotes     = (((.remotes // []) + (if .remote then [.remote] else [] end) + $addremote) | uniq_ord)
      | .aliases     = (((.aliases // []) + $newaliases) | uniq_ord)
      | .names       = (((.names // []) + $newnames) | uniq_ord)
      | .description = (if $desc == "" then (.description // "") else $desc end)
      | .paths       = (((.paths // []) + [$path]) | uniq_ord)
      | (if ($newroles | length) > 0 then .roles = (((.roles // []) + $newroles) | uniq_ord) else . end)
      | if del(.updated) == ($old | del(.updated)) then empty else .updated = $now end
    ' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
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
      --for)   _intercom_need_value "$1" $# || return 2; id="$(_intercom_fold "$2")"; shift 2 ;;
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

# intercom_filed_but_pending
#
# Prints, one slug per line, every message still sitting in this repo's inbox
# whose brief has ALREADY been filed into a crystal — i.e. a copy of it exists
# under `<crystal-root>/<slug>/references/` carrying the same envelope `slug:`.
#
# The gap this closes. Archiving a consumed brief (`pickup`) is a separate
# gesture with nothing comparing it against anything, so a brief can be worked
# to completion — code shipped, reply sent — and still read as pending to the
# next session. Observed here 2026-09-11 on `intercom-home-guard-missing`: fully
# closed, answered, and found in the inbox only by a manual sweep at the end.
#
# Why the envelope `slug:` and not the filename: a brief is routinely RENAMED on
# the way into `references/` (this repo holds `intercom-brief-executor.md`
# twice, for two different briefs). The frontmatter survives the rename, so it
# is the only join key that actually joins. Files without an `intercom:` header
# are other kinds of reference and are skipped.
#
# Cost, and the order below is that cost. The EMPTY INBOX is checked first and
# costs one glob on one directory — which is the common case, and it exits before
# resolving crystal roots at all. That matters because root resolution scans for
# `tasks/` directories, `crystal-hydrate.sh` already pays for it at the same
# SessionStart, and the two hooks are separate processes so the memo is not
# shared. Only when something is actually pending does this walk
# `<root>/*/references/*.md` — bounded by the number of crystals, never by the
# size of the tree. A tree walk here would repeat a mistake this repo has already
# paid for (docs/tasks/crystal-capture-hook-timeout).
#
# Fails open: no crystal resolver, no roots, no inbox — print nothing.
intercom_filed_but_pending() {
  command -v resolve_crystal_roots >/dev/null 2>&1 || return 0
  local id="${1:-}"
  [ -n "$id" ] || id="$(intercom_identity 2>/dev/null)"
  [ -n "$id" ] || return 0

  local pending
  pending="$(intercom_inbox_list "$id" 2>/dev/null)" || return 0
  [ -n "$pending" ] || return 0

  local roots ref filed="" s
  roots="$(resolve_crystal_roots 2>/dev/null)" || return 0
  [ -n "$roots" ] || return 0

  # One pass over the reference files; collect "<slug>\t<path>" for each.
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for ref in "$root"/*/references/*.md; do
      [ -f "$ref" ] || continue
      grep -q '^intercom: ' "$ref" 2>/dev/null || continue
      s="$(sed -n 's/^slug:[[:space:]]*//p' "$ref" 2>/dev/null | head -1)"
      [ -n "$s" ] && filed="${filed}${s}	${ref}
"
    done
  done <<<"$roots"
  [ -n "$filed" ] || return 0

  # Output is "<slug>\t<where it is filed>" so the caller can name the file
  # without searching for it a second time.
  local p base hit
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    base="$(basename "$p" .md)"
    hit="$(printf '%s' "$filed" | awk -F'\t' -v s="$base" '$1 == s { print $2; exit }')"
    [ -n "$hit" ] && printf '%s\t%s\n' "$base" "$hit"
  done <<<"$pending"
  return 0
}

# intercom_describe_edit [--for <identity>] <text>
#
# Symmetric with intercom_names_edit. Descriptions are normally written by the
# agent about itself (`register --describe`), and that stays the preferred path:
# the one line that says what a repo is, is a thing the repo knows. `--for`
# exists because the alternative does not scale — a directory of a dozen agents
# cannot be completed without opening a session in each of a dozen repositories,
# and until it is completed the listing cannot tell an unfinished onboarding
# from an accidental entry.
intercom_describe_edit() {
  command -v jq >/dev/null 2>&1 || { printf 'intercom: describe needs jq.\n' >&2; return 1; }
  local id="" desc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --for)   _intercom_need_value "$1" $# || return 2; id="$(_intercom_fold "$2")"; shift 2 ;;
      --for=*) id="$(_intercom_fold "${1#--for=}")"; shift ;;
      *)       [ -z "$desc" ] && desc="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || id="$(intercom_identity)"
  local rf
  rf="$(intercom_registry_file "$id")"
  if [ ! -f "$rf" ]; then
    printf 'intercom: ✗ no registered agent `%s` (intercom directory lists them).\n' "$id" >&2
    return 1
  fi
  [ -n "${desc//[[:space:]]/}" ] || { printf 'intercom: describe: no text given.\n' >&2; return 1; }

  local tmp now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  tmp="$(mktemp 2>/dev/null)" || return 1
  if jq --arg d "$desc" --arg now "$now" '.description = $d | .updated = $now' "$rf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$rf" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
}

# ---------------------------------------------------------------------------
# Roles (docs/tasks/intercom-agent-roles, DL #2).
#
# The directory keeps ONE role: `access-layer` — the agent through which the
# user's projects reach external systems, and whose `hq <project root>` command
# says which project is whose HQ. The plugin finds that agent BY ROLE, so that
# neither its name nor the path of one machine is written into code that ships.
#
# Why its own entry declares it: nothing else on disk says who the access layer
# is, and the access layer cannot be asked before it is found. No prohibition
# rests on this role — only where a question is sent. HQ and hand are NOT roles
# here: the access layer keeps them and answers for them, and a copy in the
# directory would be the same fact in a second place, guarded against the first
# — `comms.hq` was removed for exactly that on 2026-10-02. Descriptive roles
# (product, executor) are not kept either: no line of code reads them.
#
# A role has one holder, as a name routes to one agent: every consumer needs
# exactly one place to ask, so a second claim is refused when it is made rather
# than discovered as an ambiguity when someone asks.
# ---------------------------------------------------------------------------

INTERCOM_ROLES="access-layer"

# _intercom_role_check <role> — 0 when the directory keeps <role>; otherwise
# says what it keeps and who answers for HQ and hand, and returns 1.
_intercom_role_check() {
  case " $INTERCOM_ROLES " in *" $1 "*) return 0 ;; esac
  printf 'intercom: ✗ "%s" is not a role the directory keeps — it keeps one: %s.\n' "$1" "$INTERCOM_ROLES" >&2
  printf '          HQ and hand are answered by the access layer: "<its checkout>/bin/<its identity>" hq <project root>.\n' >&2
  return 1
}

# intercom_role_holders <role> — the identities whose entry declares <role>,
# one per line, sync conflict copies excluded.
intercom_role_holders() {
  command -v jq >/dev/null 2>&1 || return 0
  local files=() rf
  while IFS= read -r rf; do
    files+=("$rf")
  done < <(_intercom_registry_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -r --arg r "$1" 'select((.roles // []) | any(.[]; . == $r)) | .identity // empty' "${files[@]}" 2>/dev/null
}

# intercom_role_resolve <role> — prints the holder(s); returns
#   0 = exactly one holder, 2 = none, 3 = several (all printed).
intercom_role_resolve() {
  local holders n=0
  holders="$(intercom_role_holders "$1")"
  [ -n "$holders" ] && n="$(printf '%s\n' "$holders" | grep -c '.')"
  [ "$n" -gt 0 ] || return 2
  printf '%s\n' "$holders"
  [ "$n" -eq 1 ] && return 0
  return 3
}

# _intercom_role_free <role> <identity> — 0 when nobody but <identity> holds it;
# otherwise names the holder and returns 1.
_intercom_role_free() {
  local h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ "$h" = "$2" ] && continue
    printf 'intercom: ✗ role "%s" is already held by `%s` — a role has one holder.\n' "$1" "$h" >&2
    printf '          Drop it there first (intercom roles rm --for %s %s).\n' "$h" "$1" >&2
    return 1
  done <<<"$(intercom_role_holders "$1")"
  return 0
}

# intercom_roles_edit add|rm [--for <identity>] <role>...
# Symmetric with intercom_names_edit: an agent declares its own role, and
# `--for` lets the directory be completed without a session in that repository.
intercom_roles_edit() {
  command -v jq >/dev/null 2>&1 || { printf 'intercom: roles editing needs jq.\n' >&2; return 1; }
  local op="${1:-}"; [ $# -gt 0 ] && shift
  local id="" roles=() r
  while [ $# -gt 0 ]; do
    case "$1" in
      --for)   _intercom_need_value "$1" $# || return 2; id="$(_intercom_fold "$2")"; shift 2 ;;
      --for=*) id="$(_intercom_fold "${1#--for=}")"; shift ;;
      *)       roles+=("$1"); shift ;;
    esac
  done
  case "$op" in add|rm) ;; *) printf 'intercom: roles: unknown op "%s" (add|rm).\n' "$op" >&2; return 1 ;; esac
  [ "${#roles[@]}" -gt 0 ] || { printf 'intercom: roles %s: no role given.\n' "$op" >&2; return 1; }
  [ -n "$id" ] || id="$(intercom_identity)"
  local rf
  rf="$(intercom_registry_file "$id")"
  if [ ! -f "$rf" ]; then
    printf 'intercom: ✗ no registered agent `%s` (intercom directory lists them).\n' "$id" >&2
    return 1
  fi
  for r in "${roles[@]}"; do
    _intercom_role_check "$r" || return 1
    if [ "$op" = "add" ]; then
      _intercom_role_free "$r" "$id" || return 1
    fi
  done
  local rolesjson tmp now prog
  rolesjson="$(printf '%s\n' "${roles[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  case "$op" in
    add) prog="$_INTERCOM_JQ_UNIQ"'.roles = (((.roles // []) + $r) | uniq_ord)' ;;
    rm)  prog='.roles = ((.roles // []) | map(select(. as $x | ($r | index($x)) == null)))
               | if (.roles | length) == 0 then del(.roles) else . end' ;;
  esac
  tmp="$(mktemp 2>/dev/null)" || return 1
  # Same rule as intercom_register: an entry that would not change is not written.
  if jq --argjson r "$rolesjson" --arg now "$now" '. as $old | '"$prog"' | if . == $old then empty else .updated = $now end' "$rf" > "$tmp" 2>/dev/null; then
    if [ -s "$tmp" ]; then
      mv "$tmp" "$rf" 2>/dev/null || { rm -f "$tmp"; return 1; }
    else
      rm -f "$tmp"
    fi
  else
    rm -f "$tmp"; return 1
  fi
}

# intercom_unregister <identity> [--force]
#
# Removes ONE registry entry. Never a sweep: an entry that turns out to be real
# is not recoverable from the listing it disappeared from, and the sender who
# addressed it gets "no agent is registered as …" — which reads as a typo, not
# as a deletion. So removal is per-item and refuses anything that looks alive.
#
# A human NAME is the strong signal of alive: names exist only because someone
# said them. `--force` is there for the case where the user is removing an entry
# they themselves just named by mistake.
#
# The inbox is left alone. Messages are data, and an inbox without an agent is
# already a recognised state — `directory` lists it and `claim` recovers it.
intercom_unregister() {
  command -v jq >/dev/null 2>&1 || { printf 'intercom: unregister needs jq.\n' >&2; return 1; }
  local id="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *)       [ -z "$id" ] && id="$(_intercom_fold "$1")"; shift ;;
    esac
  done
  [ -n "$id" ] || { printf 'intercom: unregister: which agent? (intercom directory lists them)\n' >&2; return 1; }

  local rf
  rf="$(intercom_registry_file "$id")"
  if [ ! -f "$rf" ]; then
    printf 'intercom: ✗ no registered agent `%s` — nothing to remove.\n' "$id" >&2
    return 1
  fi

  local nm
  nm="$(jq -r '(.names // []) | join(", ")' "$rf" 2>/dev/null || echo "")"
  if [ -n "$nm" ] && [ "$force" -eq 0 ]; then
    printf 'intercom: ✗ `%s` is addressed by name: %s\n' "$id" "$nm" >&2
    printf '          Someone reaches this agent that way; removing the entry breaks it silently.\n' >&2
    printf '          Drop the names first (intercom names rm --for %s "<name>"), or pass --force.\n' "$id" >&2
    return 1
  fi

  local pending
  pending="$(intercom_inbox_count "$id" 2>/dev/null || echo 0)"
  rm -f "$rf" 2>/dev/null || { printf 'intercom: ✗ could not remove %s\n' "$rf" >&2; return 1; }
  printf 'intercom: ✓ removed `%s` from the directory.\n' "$id"
  if [ "${pending:-0}" -gt 0 ] 2>/dev/null; then
    printf '           Its inbox still holds %s message(s) and now lists as an unclaimed inbox.\n' "$pending"
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
  local t="$1"
  command -v jq >/dev/null 2>&1 || return 0
  local files=() rf
  while IFS= read -r rf; do
    files+=("$rf")
  done < <(_intercom_registry_files)
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
                   # `. as $k` is load-bearing: inside `$t | contains(.)` the pipe
                   # rebinds `.` to $t, so that form asks whether $t contains
                   # ITSELF — always true. The whole clause then degraded to "has
                   # a key of 3+ chars", which every agent does, and every lookup
                   # that missed returned the entire directory under the heading
                   # "Did you mean:". Invisible for as long as the tests only
                   # asserted that the RIGHT agent appears in the list.
                   or (.keys | any(. as $k | ($k | length) >= 3 and ($t | contains($k))))
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
# `intercom_directory_line <identity>` — marks ⚠ unnamed when NO human name.
#
# The flag tracks names ONLY, matching the legend the listing prints under
# itself ("⚠ unnamed = that repo has not yet registered how the user calls it").
# It used to fire on a missing description as well, and the two drifted apart
# without anyone noticing — because while both fields were empty together the
# wrong condition gave the right answer. Naming eleven agents in one pass
# separated them and the label started lying about every row it marked.
#
# A missing description needs no flag of its own: this same line already prints
# `(no description)` a few characters to the left. `intercom_registration_missing`
# still requires both — the SessionStart nag is a different consumer with a
# different question ("is my registration finished?"), and there the answer is no.
intercom_directory_line() {
  local id="$1" rf
  rf="$(intercom_registry_file "$id")"
  [ -f "$rf" ] || { printf '  • %s\n' "$id"; return 0; }
  jq -r --arg id "$id" '
    def joinlist: if length == 0 then "" else join(", ") end;
    ((.names // []) + (.aliases // [])) as $aka
    | "  • " + $id
      + (if ((.roles // []) | length) > 0 then "   role: " + (.roles | joinlist) else "" end)
      + (if ($aka | length) > 0 then "   aka: " + ($aka | joinlist) else "" end)
      + "   — " + (if ((.description // "") | length) > 0 then .description else "(no description)" end)
      + (if ((.names // []) | length) == 0 then "   ⚠ unnamed" else "" end)
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
  local rf
  _intercom_registry_files | while IFS= read -r rf; do
    basename "$rf" .json
  done | sort
}

# ---------------------------------------------------------------------------
# Delivery is not receipt.
#
# `send` writes a file and the sender's side is done; whether the recipient ever
# reads it is invisible to both. Field case (hq → product, 2026-09-14):
# a reply lay unread while the recipient's session was alive and working next
# to it, and a brief beside it lay for three days. Measured on the whole store
# 2026-09-24: about 110 letters unpicked, 20 of them ours, the oldest 19 days —
# and `check` shows only what came IN, so no sender saw any of it.
#
# Two halves, both read from files that already exist — nothing new is stored:
#   - the live sessions of an agent on this machine (so the assistant can wake
#     one with its cross-session message tool; the inbox stays the truth);
#   - the letters an agent wrote that are still in someone's inbox.
# @see docs/tasks/intercom-live-delivery/workitem.md
# ---------------------------------------------------------------------------

# _intercom_realpath <dir> — the physical path, or the input when it is gone.
# The registry records `git rev-parse --show-toplevel` (physical); a session's
# cwd is whatever the user started in (logical). Compared raw, /var and
# /private/var would never match.
_intercom_realpath() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# _intercom_owners — every agent's checkouts as physical paths, one
# "<path><TAB><identity>" per line. Read once by each caller that maps a
# working directory to the agent it belongs to.
_intercom_owners() {
  command -v jq >/dev/null 2>&1 || return 0
  local entries=() rf
  while IFS= read -r rf; do
    entries+=("$rf")
  done < <(_intercom_registry_files)
  [ "${#entries[@]}" -gt 0 ] || return 0
  jq -r '.identity as $i | (.paths // [])[] | [., $i] | @tsv' "${entries[@]}" 2>/dev/null \
    | while IFS=$'\t' read -r p who; do
        [ -n "$p" ] && printf '%s\t%s\n' "$(_intercom_realpath "$p")" "$who"
      done
}

# _intercom_owner_of <physical cwd> <owners> — the agent whose registered
# checkout is the LONGEST one containing that directory. By path, not by
# session name: the name is derived and two clones can share it. Longest,
# because a session in a sub-directory belongs to the repo around it (measured:
# a live session sat in hq/tracks/<track>), while a separate repo nested inside
# another is its own agent.
_intercom_owner_of() {
  local rcwd="$1" best="" best_len=0 p who
  while IFS=$'\t' read -r p who; do
    [ -n "$p" ] || continue
    case "$rcwd/" in
      "$p/"*) [ "${#p}" -gt "$best_len" ] && { best="$who"; best_len="${#p}"; } ;;
    esac
  done <<<"$2"
  printf '%s' "$best"
}

# intercom_live_sessions <identity> — "name<TAB>status<TAB>sessionId<TAB>updated"
# for every LIVE session of that agent on this machine, other than the caller's
# own. `updated` is the session file's statusUpdatedAt (ms), empty when absent.
#
# Live means all of: the file is not a sync conflict (settings synced from
# another machine carry sessions whose pids mean nothing here), its socket
# exists (/tmp is never synced), and its pid answers `kill -0`. A session file
# alone proves nothing — on the machine this was written on, 4 of the files in
# sessions/ were conflict copies from other devices. Since 2026-09-26 the
# owner's machines no longer sync sessions/ at all; the checks stay, because a
# harness directory synced elsewhere would bring the same copies back.
# Belongs to the agent `_intercom_owner_of` names. Silent, and harmless,
# wherever the harness keeps no such files.
intercom_live_sessions() {
  local id="$1" dir regdir
  command -v jq >/dev/null 2>&1 || return 0
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  regdir="$(intercom_registry_dir)"
  [ -d "$dir" ] && [ -d "$regdir" ] || return 0

  local owners
  owners="$(_intercom_owners)"
  [ -n "$owners" ] || return 0

  local f pid cwd name status sock sid upd
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *.sync-conflict-*) continue ;; esac
    # Unit separator, not TAB: TAB is whitespace to `read`, so an empty field
    # (a session with no status yet) would collapse and shift every column after it.
    IFS=$'\037' read -r pid cwd name status sock sid upd < <(
      jq -r '[(.pid // "" | tostring), (.cwd // ""), (.name // ""), (.status // ""),
              (.messagingSocketPath // ""), (.sessionId // ""),
              ((.statusUpdatedAt // .updatedAt // "") | tostring)] | join("\u001f")' "$f" 2>/dev/null
    ) || continue
    [ -n "$pid" ] && [ -n "$name" ] && [ -n "$cwd" ] || continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ -n "$sock" ] && [ -S "$sock" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$sid" = "$CLAUDE_CODE_SESSION_ID" ]; then
      continue
    fi
    [ "$(_intercom_owner_of "$(_intercom_realpath "$cwd")" "$owners")" = "$id" ] \
      && printf '%s\t%s\t%s\t%s\n' "$name" "${status:-?}" "$sid" "$upd"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Which ONE session to wake (docs/tasks/intercom-wake-one-machine, DL #3).
#
# A project may live in sessions on two machines, and a cross-session message
# reaches only this one — so waking every live session here sent the work
# wherever the SENDER happened to sit. Where the owner is, the harness already
# writes down: every turn the owner typed carries `"turnOrigin":"human"` in the
# session's transcript (`peer` is a turn another session started), and the
# transcripts under projects/ travel between the machines. Keyboard idle time
# was the other candidate and it fails exactly here: the owner often drives a
# session on one machine through a terminal opened on the other.
#
# The rule, chosen by the owner (DL #3):
#   - the owner's last turn in the recipient's sessions is in a session live on
#     this machine → wake that one;
#   - it is in a session that is not live here → wake nobody: the letter waits
#     for that session;
#   - no turn of the owner's within the window → one session here, the most
#     recently active (a message cannot reach the other machine anyway).
# A turn older than the window is not presence: the session may be closed, and
# the owner gone since. Nothing is stored — both operands are on disk.
# ---------------------------------------------------------------------------

INTERCOM_PRESENCE_WINDOW_H=12

# _intercom_now — seconds since the epoch; VDM_INTERCOM_NOW pins it for tests.
_intercom_now() {
  if [ -n "${VDM_INTERCOM_NOW:-}" ]; then printf '%s' "$VDM_INTERCOM_NOW"; return; fi
  date -u +%s
}

# _intercom_iso_utc <epoch> — YYYY-MM-DDTHH:MM:SSZ, comparable as a string with
# the transcripts' timestamps. BSD date first, then GNU.
_intercom_iso_utc() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _intercom_epoch_utc <YYYY-MM-DDTHH:MM:SSZ> — seconds since the epoch, or
# nothing. BSD date first, then GNU.
_intercom_epoch_utc() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# intercom_owner_turns <identity> — "<timestamp><TAB><sessionId>" for every
# transcript of that agent whose last owner-typed turn is inside the window,
# newest first. A transcript belongs to the agent `_intercom_owner_of` names
# for its `cwd` — read from the transcript, because the directory name the
# harness derives from a path is lossy (`a-b` and `a/b` look the same).
intercom_owner_turns() {
  local id="$1" projects owners cutoff f cwd ts
  projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [ -d "$projects" ] || return 0
  owners="$(_intercom_owners)"
  [ -n "$owners" ] || return 0
  cutoff="$(_intercom_iso_utc "$(( $(_intercom_now) - INTERCOM_PRESENCE_WINDOW_H * 3600 ))")"
  # A transcript with a turn inside the window was written inside it: the
  # modification time narrows the scan to the sessions of the last hours.
  find "$projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin "-$((INTERCOM_PRESENCE_WINDOW_H * 60 + 60))" 2>/dev/null \
    | while IFS= read -r f; do
        # A conversation written from two machines leaves Syncthing's copy of
        # the losing side beside it — not a session, and its turns are not
        # where the owner is now.
        case "${f##*/}" in *.sync-conflict-*) continue ;; esac
        cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/^"cwd":"//; s/"$//')"
        [ -n "$cwd" ] || continue
        [ "$(_intercom_owner_of "$(_intercom_realpath "$cwd")" "$owners")" = "$id" ] || continue
        ts="$(grep -F '"turnOrigin":"human"' "$f" 2>/dev/null | tail -1 \
              | grep -o '"timestamp":"[^"]*"' | tail -1 | sed 's/^"timestamp":"//; s/"$//')"
        [ -n "$ts" ] || continue
        ts="${ts%%.*}"; ts="${ts%Z}Z"          # 2026-10-04T09:00:00.123Z → …:00Z
        [ "$ts" \< "$cutoff" ] && continue
        f="${f##*/}"; printf '%s\t%s\n' "$ts" "${f%.jsonl}"
      done | sort -r
}

# intercom_wake_choice <identity> [<live>] — one line, or nothing when no
# session of that agent is live here. <live> is the caller's own
# `intercom_live_sessions` output when it already has it: every caller prints
# the live list first, and reading the session files twice doubled the cost of
# a send (counted 2026-10-04: +786 jq launches in the intercom suite). Fields are joined by the unit separator (\037), not
# TAB: TAB is whitespace to `read`, and the empty fields of "wait" would collapse.
#   "wake<US><name><US><status><US><why>"   wake this one session
#   "wait<US><US><US><why>"                 wake nobody here
intercom_wake_choice() {
  local id="$1" live="${2-}" turns top_ts top_sid name status sid upd
  [ $# -ge 2 ] || live="$(intercom_live_sessions "$id")"
  [ -n "$live" ] || return 0
  turns="$(intercom_owner_turns "$id")"
  if [ -n "$turns" ]; then
    IFS=$'\t' read -r top_ts top_sid <<<"$(printf '%s\n' "$turns" | head -1)"
    # One conversation can be open on both machines (measured 2026-10-04: one
    # agent's two sessions shared a sessionId and a transcript written from
    # both sides), and then its transcript cannot say where the turn was
    # typed. The session file can: it is each machine's own, and a turn typed
    # here moves this session's status. A status that last moved before the
    # turn means the turn went into the same conversation elsewhere. No stamp
    # in the file — no verdict from it.
    local top_epoch
    top_epoch="$(_intercom_epoch_utc "$top_ts")"
    while IFS=$'\t' read -r name status sid upd; do
      if [ -n "$sid" ] && [ "$sid" = "$top_sid" ]; then
        case "$upd" in
          ''|*[!0-9]*) ;;
          *) if [ -n "$top_epoch" ] && [ $((upd / 1000)) -lt $((top_epoch - 5)) ]; then
               printf 'wait\037\037\037your last turn in `%s` (%s) went into the same conversation on another machine — %s here has not moved since; the letter waits for that one\n' \
                 "$id" "$top_ts" "$name"
               return 0
             fi ;;
        esac
        printf 'wake\037%s\037%s\037your last turn in `%s` was there (%s)\n' "$name" "$status" "$id" "$top_ts"
        return 0
      fi
    done <<<"$live"
    printf 'wait\037\037\037your last turn in `%s` (%s) was in a session that is not on this machine — the letter waits for it\n' \
      "$id" "$top_ts"
    return 0
  fi
  # No presence: the most recently active live session (its file's status
  # stamp), the first listed on a tie or when the harness writes none.
  local best="" best_upd=-1 best_status=""
  while IFS=$'\t' read -r name status sid upd; do
    case "$upd" in ''|*[!0-9]*) upd=0 ;; esac
    if [ "$upd" -gt "$best_upd" ]; then best="$name"; best_status="$status"; best_upd="$upd"; fi
  done <<<"$live"
  printf 'wake\037%s\037%s\037no turn of yours in `%s` in the last %s h — one session here, the most recently active\n' \
    "$best" "$best_status" "$id" "$INTERCOM_PRESENCE_WINDOW_H"
}

# ---------------------------------------------------------------------------
# Taken (docs/tasks/intercom-wake-one-machine, DL #3). Two sessions that each
# find the same letter by themselves both start on it — the wake picks one, but
# `check` and session start are not the wake. A session that takes a letter
# writes `taken: <machine>/<session> <time>` into its envelope; the store
# carries it to the other machine within about a minute, and pickup, reply and
# the wake respect it. Two takes inside that minute leave a sync conflict copy
# of the letter — visible, and the race the mark narrows rather than closes.
# ---------------------------------------------------------------------------

# _intercom_taker — who this session is, as the mark records it:
# `<machine>/<session name>`, or `<machine>` where the harness names no session.
_intercom_taker() {
  local m name="" f
  m="$(_intercom_machine_name)"
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
    for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"/*.json; do
      [ -f "$f" ] || continue
      case "${f##*/}" in *.sync-conflict-*) continue ;; esac
      name="$(jq -r --arg s "$CLAUDE_CODE_SESSION_ID" 'select(.sessionId == $s) | .name // empty' "$f" 2>/dev/null)"
      [ -n "$name" ] && break
    done
  fi
  if [ -n "$name" ]; then printf '%s/%s' "$m" "$name"; else printf '%s' "$m"; fi
}

# intercom_taken_elsewhere <letter> — prints the mark ("<who> <time>") when the
# letter is taken by someone other than this session; silent otherwise.
intercom_taken_elsewhere() {
  local mark who
  mark="$(intercom_fm_field "$1" taken)"
  [ -n "$mark" ] || return 0
  who="${mark%% *}"
  [ "$who" = "$(_intercom_taker)" ] && return 0
  printf '%s' "$mark"
}

# intercom_take <letter> — write this session's mark into the envelope, in
# place of any earlier one. The caller has already decided it may.
intercom_take() {
  local f="$1" tmp mark
  [ -f "$f" ] || return 1
  mark="$(_intercom_taker) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp 2>/dev/null)" || return 1
  awk -v mark="$mark" '
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---"    { print "taken: " mark; infm = 0; print; next }
    infm && /^taken:/      { next }
    { print }
  ' "$f" > "$tmp" 2>/dev/null && grep -q '^taken: ' "$tmp" \
    && cat "$tmp" > "$f" && rm -f "$tmp" && return 0
  rm -f "$tmp"
  return 1
}

# _intercom_today — today's date, YYYY-MM-DD (UTC). VDM_INTERCOM_TODAY pins it
# for tests, the same way the comms tools pin theirs.
_intercom_today() {
  if [ -n "${VDM_INTERCOM_TODAY:-}" ]; then printf '%s' "$VDM_INTERCOM_TODAY"; return; fi
  date -u +%Y-%m-%d
}

# intercom_sent_list <identity> — every letter that identity wrote which is
# still in someone else's inbox, oldest first:
#   "<age-days><TAB><inbox><TAB><slug><TAB><title><TAB><file>"
#
# "Unpicked" is where the file lies, not what its `status:` says: `pickup` is the
# only thing that moves a letter into `_done/`, while the status value is
# written by different versions and different hands (`pending` and `new` both
# occur). The sender's own inbox is skipped — a note to self is already counted
# by `check`. Age is in whole calendar days, from the envelope's `created:`.
#
# One awk pass over every inbox: this runs at session start, and a field-per-
# process version took 0.9 s on a store of ~110 letters.
intercom_sent_list() {
  local me="$1" root d f
  root="$(intercom_store_root)"
  [ -d "$root" ] || return 0
  local files=()
  for d in "$root"/*/; do
    d="${d%/}"
    case "$(basename "$d")" in _*|"$me") continue ;; esac
    for f in "$d"/*.md; do
      [ -f "$f" ] && files+=("$f")
    done
  done
  [ ${#files[@]} -gt 0 ] || return 0
  awk -v me="$me" -v today="$(_intercom_today)" '
    function days(s,   y, m, d, era, yoe, doy) {
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return -1
      y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
      y -= (m <= 2)
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    }
    function strip(v) { gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v); return v }
    function flush(   n, parts, inbox, slug, c, t, age) {
      if (file == "" || from != me) return
      n = split(file, parts, "/"); inbox = parts[n - 1]; slug = parts[n]; sub(/\.md$/, "", slug)
      c = days(created); t = days(today)
      age = (c < 0 || t < 0) ? 0 : t - c
      if (age < 0) age = 0
      if (title == "") title = slug     # never empty: an empty field collapses under read
      printf "%d\t%s\t%s\t%s\t%s\n", age, inbox, slug, title, file
    }
    FNR == 1 { flush(); file = FILENAME; from = ""; created = ""; title = ""; infm = ($0 == "---"); next }
    infm && $0 == "---" { infm = 0; next }
    infm && /^from:/    { from = strip(substr($0, 6)); next }
    infm && /^created:/ { created = strip(substr($0, 9)); next }
    !infm && title == "" && /^# / { title = substr($0, 3) }
    END { flush() }
  ' "${files[@]}" | sort -t "$(printf '\t')" -k1,1nr
}
