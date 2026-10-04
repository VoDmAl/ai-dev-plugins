#!/bin/bash
# intercom.sh — CLI dispatcher for the /vdm:intercom skill.
#
#   intercom identity                     print this repo's canonical identity
#   intercom whoami                       identity + names + aliases + registration status
#   intercom store                        print the resolved store root
#   intercom register [--name N]... [--describe D] [--role R]... [--same-project]
#                                         register this repo in the agent directory
#   intercom names [add|rm] [--for ID] <name>...
#                                         list / edit the human names of an agent
#   intercom roles [add|rm] [--for ID] <role>...
#                                         list / edit an agent's role (the one kept: access-layer)
#   intercom role <role> [--path]         which agent holds <role> — or its checkout on this machine
#   intercom directory [-v]               list every registered agent (aka: who, list, agents)
#   intercom resolve <name>               which agent does <name> address?
#   intercom check [--count]              list (or count) pending messages
#   intercom chain <slug>                 the relay chain behind a letter, and where each link lives
#   intercom send <to> <slug> [--title T] [--from-agent A] [--reply-to REF] [--body FILE] [--to ID] [--first-contact]
#   intercom claim <inbox> [--force]      move an unclaimed inbox addressed to one of your names home
#   intercom pickup <slug> [--grow]       archive a message (or promote with --grow)
#   intercom reply <letter> (--done T [--link U]... --ball T | --body F)
#                                         close a letter you received with its outcome, to its sender
#   intercom sent                         your letters still unpicked in other inboxes (aka: outbox)
#
# Routing is by CANONICAL IDENTITY (git remote slug), never directory basename
# (DL #4). The store lives outside all repos (DL #1). See skills/intercom/SKILL.md.
# Not mirrored to vdm-git — intercom ships in the vdm plugin only.

_INTERCOM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_INTERCOM_SCRIPT_DIR/intercom-common.sh"

_INTERCOM_TEMPLATE="$_INTERCOM_SCRIPT_DIR/../templates/intercom-brief-template.md"

_ic_die() { printf 'intercom: %s\n' "$1" >&2; exit "${2:-1}"; }

# Sanitize a user-supplied slug into a safe filename: lowercase, spaces→dash,
# keep [a-z0-9._-], collapse repeats, trim leading/trailing dashes.
_ic_sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | tr -cd 'a-z0-9._-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//'
}

# Comma-join a jq array field of this identity's registry entry.
_ic_reg_list() { intercom_registry_get "$1" "($2 // []) | join(\", \")"; }

cmd_identity() { intercom_identity; printf '\n'; }

cmd_store() { intercom_store_root; printf '\n'; }

cmd_whoami() {
  local id src names aliases desc remotes roles missing n mismatch
  id="$(intercom_identity)"
  src="$(intercom_identity_source)"
  printf '🪪 intercom whoami\n'
  printf '   identity:     %s   (from: %s)\n' "$id" "$src"
  if ! command -v jq >/dev/null 2>&1; then
    printf '   registry:     unavailable (jq not installed) — routing by canonical identity only\n'
    return 0
  fi
  if [ ! -f "$(intercom_registry_file "$id")" ]; then
    printf '   registration: ✗ NOT REGISTERED — run: intercom register --name "<how the user calls this project>" --describe "<one-liner>"\n'
    return 0
  fi
  names="$(_ic_reg_list "$id" .names)"
  aliases="$(_ic_reg_list "$id" .aliases)"
  desc="$(intercom_registry_get "$id" '.description // ""')"
  remotes="$(_ic_reg_list "$id" .remotes)"
  roles="$(_ic_reg_list "$id" .roles)"
  printf '   names:        %s\n' "${names:-(none)}"
  printf '   aliases:      %s\n' "${aliases:-(none)}"
  printf '   description:  %s\n' "${desc:-(none)}"
  [ -n "$roles" ] && printf '   roles:        %s\n' "$roles"
  printf '   remotes:      %s\n' "${remotes:-(none)}"
  n="$(intercom_inbox_count "$id")"; [ -n "$n" ] || n=0
  printf '   inbox:        %s   (%s pending)\n' "$(intercom_inbox_dir "$id")" "$n"
  missing="$(intercom_registration_missing "$id")"
  if [ -z "$missing" ]; then
    # Deduplicated: `names` and `aliases` routinely contain an entry that folds
    # to the identity itself (a repo whose directory basename IS its slug), and
    # printing it three times in the one line that answers "what am I called?"
    # is the opposite of what the line is for. Fold via the shared helper — the
    # comparison rule has one home (_intercom_fold), and restating it here would
    # be a second copy of it.
    printf '   registration: ✓ complete — other agents can address you as: %s' "$id"
    _seen="$(_intercom_fold "$id")"
    _print_unique() {
      local raw folded
      raw="$1"
      [ -n "$raw" ] || return 0
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        folded="$(_intercom_fold "$n")"
        case "
$_seen
" in *"
$folded
"*) continue ;; esac
        _seen="$_seen
$folded"
        printf ', %s' "$n"
      done <<<"$(printf '%s' "$raw" | tr ',' '\n' | sed 's/^ *//; s/ *$//')"
    }
    _print_unique "$names"
    _print_unique "$aliases"
    printf '\n'
  else
    printf '   registration: ⚠ INCOMPLETE — missing: %s\n' "$missing"
    printf '                 fix: intercom register --name "<name>" [--name "<another>"] --describe "<one-liner>"\n'
  fi
  mismatch="$(intercom_remote_mismatch "$id" 2>/dev/null || true)"
  if [ -n "$mismatch" ]; then
    printf '   remote:       ⚠ this clone (%s) is not confirmed for `%s` (registered: %s)\n' "$(intercom_remote_url)" "$id" "$mismatch"
    printf '                 same project → intercom register --same-project · different project → intercom identity <distinct-name>\n'
  fi
  _ic_print_unclaimed "$id" "   "
}

# Unclaimed inboxes addressed to one of this agent's names (see intercom_orphans_matching).
_ic_print_unclaimed() {
  local id="$1" indent="${2:-}" o n
  intercom_orphans_matching "$id" | while IFS= read -r o; do
    [ -n "$o" ] || continue
    n="$(intercom_inbox_count "$o")"; [ -n "$n" ] || n=0
    printf '%s📥 unclaimed inbox `%s` (%s message(s)) matches one of your names — claim it: intercom claim %s\n' "$indent" "$o" "$n" "$o"
  done
}

cmd_register() {
  intercom_register --explicit "$@" || exit 1
  local id missing
  id="$(intercom_identity)"
  printf 'registered: %s → %s\n' "$id" "$(intercom_inbox_dir "$id")"
  if command -v jq >/dev/null 2>&1; then
    printf '   names:       %s\n' "$(_ic_reg_list "$id" .names)"
    printf '   aliases:     %s\n' "$(_ic_reg_list "$id" .aliases)"
    printf '   description: %s\n' "$(intercom_registry_get "$id" '.description // ""')"
    missing="$(intercom_registration_missing "$id")"
    if [ -n "$missing" ]; then
      printf '   ⚠ still missing: %s — add with: intercom register --name "<name>" --describe "<one-liner>"\n' "$missing"
    fi
  fi
}

cmd_names() {
  local op="${1:-}"
  case "$op" in
    add|rm)
      shift
      intercom_names_edit "$op" "$@" || exit 1
      local id="" a
      for a in "$@"; do
        case "$a" in --for=*) id="${a#--for=}" ;; esac
      done
      # --for <id> as two args
      local prev=""
      for a in "$@"; do
        [ "$prev" = "--for" ] && id="$a"
        prev="$a"
      done
      [ -n "$id" ] || id="$(intercom_identity)"
      id="$(_intercom_fold "$id")"
      printf 'names of %s: %s\n' "$id" "$(_ic_reg_list "$id" .names)"
      ;;
    ""|list)
      local id
      id="$(intercom_identity)"
      printf 'names of %s: %s\n' "$id" "$(_ic_reg_list "$id" .names)"
      ;;
    *)
      _ic_die "names: unknown op '$op'. Usage: intercom names [add|rm] [--for <identity>] <name>..."
      ;;
  esac
}

cmd_roles() {
  local op="${1:-}" id=""
  case "$op" in
    add|rm)
      shift
      intercom_roles_edit "$op" "$@" || exit 1
      local a prev=""
      for a in "$@"; do
        case "$a" in --for=*) id="${a#--for=}" ;; esac
        [ "$prev" = "--for" ] && id="$a"
        prev="$a"
      done
      ;;
    ""|list) ;;
    *) _ic_die "roles: unknown op '$op'. Usage: intercom roles [add|rm] [--for <identity>] <role>..." ;;
  esac
  [ -n "$id" ] || id="$(intercom_identity)"
  id="$(_intercom_fold "$id")"
  local roles
  roles="$(_ic_reg_list "$id" .roles)"
  printf 'roles of %s: %s\n' "$id" "${roles:-(none)}"
}

# `role <role> [--path]` — the one agent holding <role>, or with --path its
# checkout on this machine. The question a consumer asks before calling the
# access layer: a name or a path written into the caller instead would be a
# second copy of this answer, true on one machine.
cmd_role() {
  local role="" want_path=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) want_path=1; shift ;;
      -*)     _ic_die "role: unknown option '$1'. Usage: intercom role <role> [--path]" ;;
      *)      [ -z "$role" ] && role="$1"; shift ;;
    esac
  done
  [ -n "$role" ] || _ic_die "role: which role? Usage: intercom role <role> [--path]"
  command -v jq >/dev/null 2>&1 || _ic_die "role needs jq (registry is JSON)."
  _intercom_role_check "$role" || exit 1
  local holder rc
  holder="$(intercom_role_resolve "$role")"; rc=$?
  case "$rc" in
    2) printf 'intercom: ✗ no agent in the directory declares the role %s.\n' "$role" >&2
       printf '   The agent that holds it declares it: intercom register --role %s — or, from any session: intercom roles add --for <identity> %s\n' "$role" "$role" >&2
       exit 2 ;;
    3) printf 'intercom: ✗ several agents declare the role %s: %s — a role has one holder.\n' "$role" "$(printf '%s' "$holder" | paste -sd ',' - | sed 's/,/, /g')" >&2
       printf '   Drop it from all but one: intercom roles rm --for <identity> %s\n' "$role" >&2
       exit 3 ;;
  esac
  if [ "$want_path" -eq 0 ]; then
    printf '%s\n' "$holder"
    return 0
  fi
  local p found=""
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && { found="$p"; break; }
  done <<<"$(intercom_registry_get "$holder" '(.paths // [])[]')"
  if [ -z "$found" ]; then
    printf 'intercom: ✗ `%s` holds the role %s, but none of its checkouts is on this machine: %s\n' \
      "$holder" "$role" "$(_ic_reg_list "$holder" .paths)" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}

cmd_describe() {
  case "${1:-}" in
    ""|list)
      local id
      id="$(intercom_identity)"
      printf 'description of %s: %s\n' "$id" "$(intercom_registry_get "$id" '.description // ""')"
      ;;
    *)
      intercom_describe_edit "$@" || exit 1
      local id="" a prev=""
      for a in "$@"; do
        case "$a" in --for=*) id="${a#--for=}" ;; esac
        [ "$prev" = "--for" ] && id="$a"
        prev="$a"
      done
      [ -n "$id" ] || id="$(intercom_identity)"
      id="$(_intercom_fold "$id")"
      printf 'description of %s: %s\n' "$id" "$(intercom_registry_get "$id" '.description // ""')"
      ;;
  esac
}

cmd_unregister() {
  intercom_unregister "$@" || exit 1
}

cmd_directory() {
  local verbose=0
  case "${1:-}" in -v|--verbose) verbose=1 ;; esac
  command -v jq >/dev/null 2>&1 || _ic_die "directory needs jq (registry is JSON)."
  local ids n total=0 id count line
  ids="$(intercom_registry_ids)"
  [ -n "$ids" ] && total="$(printf '%s\n' "$ids" | grep -c '.' 2>/dev/null || echo 0)"
  printf '📇 intercom directory — %s agent(s)   store: %s\n' "$total" "$(intercom_store_root)"
  [ "$total" -gt 0 ] || { printf '   (empty — every repo registers itself at session start or on `intercom check`)\n'; return 0; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="$(intercom_directory_line "$id")"
    count="$(intercom_inbox_count "$id")"; [ -n "$count" ] || count=0
    if [ "$count" -gt 0 ]; then
      printf '%s   [📬 %s pending]\n' "$line" "$count"
    else
      printf '%s\n' "$line"
    fi
    if [ "$verbose" -eq 1 ]; then
      printf '      remotes: %s\n' "$(_ic_reg_list "$id" .remotes)"
      printf '      paths:   %s\n' "$(_ic_reg_list "$id" .paths)"
    fi
  done <<<"$ids"
  local orphans
  orphans="$(intercom_orphan_inboxes)"
  if [ -n "$orphans" ]; then
    printf '\n⚠ inboxes with NO registered agent (first-contact sends nobody has claimed — the recipient may live under another name):\n'
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      count="$(intercom_inbox_count "$id")"; [ -n "$count" ] || count=0
      printf '  • %s   [%s pending]   → in that repo: intercom identity (if it differs, set intercom.identity or resend)\n' "$id" "$count"
    done <<<"$orphans"
  fi
  printf '\nAddress any agent by identity, alias or name: intercom send <name> <slug>. ⚠ unnamed = that repo has not yet registered how the user calls it.\n'
}

cmd_resolve() {
  local input="${1:-}"
  [ -n "$input" ] || _ic_die "resolve: missing <name>. Usage: intercom resolve <name>"
  local canon rc
  canon="$(intercom_resolve_target "$input")"; rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$canon"
      ;;
    3)
      printf 'intercom: ✗ "%s" is ambiguous — several agents claim it:\n' "$input" >&2
      intercom_suggest "$input" >&2
      printf '   Address one by its identity, or fix the directory (intercom names rm --for <identity> "%s").\n' "$input" >&2
      exit 3
      ;;
    *)
      printf 'intercom: ✗ no agent is registered as "%s".\n' "$input" >&2
      local sugg
      sugg="$(intercom_suggest "$input")"
      if [ -n "$sugg" ]; then
        printf '   Did you mean:\n%s\n' "$sugg" >&2
      else
        printf '   Nothing similar in the directory — see: intercom directory\n' >&2
      fi
      exit 2
      ;;
  esac
}

cmd_check() {
  local count_only=0
  [ "${1:-}" = "--count" ] && count_only=1
  intercom_register --implicit 2>/dev/null   # checking your inbox is the natural "I exist" moment
  local id n
  id="$(intercom_identity)"
  n="$(intercom_inbox_count "$id")"; [ -n "$n" ] || n=0
  if [ "$count_only" -eq 1 ]; then
    printf '%s\n' "$n"
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    printf '📭 intercom: no pending messages for `%s`.\n' "$id"
    _ic_print_unclaimed "$id" "   "
    return 0
  fi
  _ic_print_unclaimed "$id" "   "
  printf '📬 intercom: %s pending message(s) for `%s`\n   inbox: %s\n\n' "$n" "$id" "$(intercom_inbox_dir "$id")"
  local f from created slug title prev
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    from="$(intercom_fm_field "$f" from)"
    created="$(intercom_fm_field "$f" created)"
    slug="$(intercom_fm_field "$f" slug)"
    [ -n "$slug" ] || slug="$(basename "$f" .md)"
    title="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')"
    [ -n "$title" ] || title="$slug"
    printf '  • %s\n    from: %s   created: %s\n    file: %s\n' \
      "$title" "${from:-?}" "${created:-?}" "$f"
    # A relay letter is only half a message without what it continues, and the
    # chain is derived here rather than written into the letter so that picking
    # a link up (inbox → _done/) cannot make a stored path lie.
    prev="$(intercom_fm_field "$f" reply-to)"
    if [ -n "$prev" ]; then
      printf '    continues:\n'
      _ic_print_chain "$prev" "      "
    fi
    printf '    pickup: /vdm:intercom pickup %s\n\n' "$slug"
  done < <(intercom_inbox_list "$id")
}

_ic_print_chain() {
  # <ref> <indent> — one line per hop, oldest last. Nothing is printed for a
  # letter that starts no chain.
  local ref="${1:-}" pad="${2:-}" n=0 r path title
  [ -n "$ref" ] || return 0
  while IFS="$(printf '\t')" read -r r path title; do
    [ -n "$r" ] || continue
    n=$((n + 1))
    if [ -n "$path" ]; then
      printf '%s↩ %s — %s\n%s   %s\n' "$pad" "$r" "$title" "$pad" "$path"
    else
      printf '%s↩ %s %s\n' "$pad" "$r" "$title"
    fi
  done < <(intercom_chain "$ref")
  [ "$n" -gt 0 ]
}

cmd_chain() {
  local input="${1:-}"
  [ -n "$input" ] || _ic_die "chain: missing <slug>. Usage: intercom chain <slug | identity/slug>"
  local n path ref prev
  n="$(intercom_find_letter "$input" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    printf 'intercom: ✗ no letter matches "%s".\n' "$input" >&2
    printf '   A reference is `<identity>/<slug>`, or a bare `<slug>` when it is unique.\n' >&2
    exit 2
  fi
  if [ "$n" -gt 1 ]; then
    printf 'intercom: ✗ "%s" is ambiguous — %s letters carry that slug:\n' "$input" "$n" >&2
    intercom_find_letter "$input" | while IFS= read -r p; do
      printf '     %s\n' "$(intercom_letter_ref "$p")"
    done >&2
    exit 3
  fi
  path="$(intercom_find_letter "$input" | head -1)"
  ref="$(intercom_letter_ref "$path")"
  printf '%s — %s\n   %s\n' "$ref" "$(grep -m1 '^# ' "$path" 2>/dev/null | sed 's/^# //')" "$path"
  prev="$(intercom_fm_field "$path" reply-to)"
  if [ -z "$prev" ]; then
    printf '   (starts the chain — no reply-to)\n'
    return 0
  fi
  _ic_print_chain "$prev" "   "
}

# The first line of the template's placeholder comment. The one place that
# knows it — a sender using --body never has to.
_IC_PLACEHOLDER_MARK='<!-- Write the brief below.'

# _ic_splice_body <rendered> <body-file> — replace the placeholder comment in
# <rendered> with the file's bytes, then prove it: the slice of the result where
# the body went must compare equal to the file. The body never passes through
# the token substitution above, so `{{TITLE}}`, `&` or `\` in it stay as written.
_ic_splice_body() {
  local rendered="$1" body="$2" start end offset len out="$1.body"
  start="$(grep -n -m1 -F "$_IC_PLACEHOLDER_MARK" "$rendered" | cut -d: -f1)"
  if [ -z "$start" ]; then
    printf 'intercom: send: the letter template has no placeholder to put the body in — not sending.\n' >&2
    return 1
  fi
  end="$(awk -v s="$start" 'NR >= s && /-->/ { print NR; exit }' "$rendered")"
  if [ -z "$end" ]; then
    printf 'intercom: send: the template placeholder is never closed — not sending.\n' >&2
    return 1
  fi
  head -n $((start - 1)) "$rendered" > "$out"
  offset="$(wc -c < "$out" | tr -d ' ')"
  cat "$body" >> "$out"
  tail -n +$((end + 1)) "$rendered" >> "$out"
  len="$(wc -c < "$body" | tr -d ' ')"
  if ! tail -c +$((offset + 1)) "$out" | head -c "$len" | cmp -s - "$body"; then
    rm -f "$out"
    printf 'intercom: send: the written body differs from %s — not sending.\n' "$body" >&2
    return 1
  fi
  mv -f "$out" "$rendered"
}

cmd_send() {
  local to="" slug="" title="" title_given=0 from_agent="" first_contact=0 deliver_to="" reply_to=""
  local body_file="" body_set=0
  to="${1:-}"; [ $# -gt 0 ] && shift
  slug="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title|--from-agent|--to|--reply-to|--body)
                        _intercom_need_value "$1" $# || exit 2 ;;
    esac
    case "$1" in
      --title)          title="$2"; title_given=1; shift 2 ;;
      --title=*)        title="${1#--title=}"; title_given=1; shift ;;
      --from-agent)     from_agent="$2"; shift 2 ;;
      --from-agent=*)   from_agent="${1#--from-agent=}"; shift ;;
      --to)             deliver_to="$2"; shift 2 ;;
      --to=*)           deliver_to="${1#--to=}"; shift ;;
      --reply-to)       reply_to="$2"; shift 2 ;;
      --reply-to=*)     reply_to="${1#--reply-to=}"; shift ;;
      --body)           body_file="$2"; body_set=1; shift 2 ;;
      --body=*)         body_file="${1#--body=}"; body_set=1; shift ;;
      --first-contact)  first_contact=1; shift ;;
      # An unknown flag used to be shifted past in silence, so a typo
      # (`--reply-too`) produced a letter with no chain and no complaint —
      # the same shape as every other defect this suite hunts: silence that
      # reads as success. Caught on the first real use of `--reply-to`, against
      # an installed version that predated the flag.
      -*)               _ic_die "send: unknown option '$1'. Usage: intercom send <target> <slug> [--title T] [--from-agent A] [--reply-to <ref>] [--body <file>] [--to <identity>] [--first-contact]" ;;
      # A stray word after <slug> is almost always a value whose flag was
      # forgotten — a title without --title — and dropping it sends a letter
      # that is not the one the sender wrote.
      *)                _ic_die "send: unexpected argument '$1' — after <target> <slug> every value takes a flag. Usage: intercom send <target> <slug> [--title T] [--from-agent A] [--reply-to <ref>] [--body <file>] [--to <identity>] [--first-contact]" ;;
    esac
  done
  [ -n "$to" ]   || _ic_die "send: missing <target>. Usage: intercom send <target> <slug> [--title T] [--from-agent A] [--reply-to <ref>] [--body <file>] [--to <identity>] [--first-contact]"
  [ -n "$slug" ] || _ic_die "send: missing <slug>."
  slug="$(_ic_sanitize_slug "$slug")"
  [ -n "$slug" ] || _ic_die "send: slug is empty after sanitization."

  # The sender side of the envelope gets the same law as the recipient side: a
  # letter nobody can answer is as broken as a letter to nobody. Outside a
  # project the identity falls back to the directory's name, and unless that
  # directory was registered on purpose no agent answers to it. Field case
  # (echelon, 2026-09-29/30): two letters signed `from: letters`, run from a
  # directory of that name outside the checkout; `reply` had nowhere to go.
  local sender_id
  sender_id="$(intercom_identity)"
  if [ "$(intercom_identity_source)" = "cwd" ] && [ ! -f "$(intercom_registry_file "$sender_id")" ]; then
    printf 'intercom: ✗ send: %s is not a project — the letter would be signed `%s`, a name no agent answers to, so no reply could come back. Not sending.\n' "$PWD" "$sender_id" >&2
    printf '   Send from the project'"'"'s checkout, or make this directory a project: intercom register --name "<how the user calls it>" --describe "<one-liner>"\n' >&2
    exit 2
  fi

  # record_hint: 0 = nothing to learn, 1 = record <to> as a name of the
  # recipient after delivery, 2 = <to> routes to a DIFFERENT agent (deliver as
  # told, warn, do not touch the directory).
  local canon rc from created inbox outfile record_hint=0 hint_canon hint_rc
  if [ -n "$deliver_to" ]; then
    # The negative scenario, closed: the user has just said which agent they
    # meant. <to> stays the hint (to_input in the envelope); --to is where it
    # goes; and the hint becomes that agent's name so next time it resolves
    # directly. This is the one command that records a name at send time.
    canon="$(intercom_resolve_target "$deliver_to")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      _ic_die "send: --to \"$deliver_to\" does not resolve to exactly one registered agent — --to takes an identity, alias or name from the directory (intercom directory)."
    fi
    hint_canon="$(intercom_resolve_target "$to")"; hint_rc=$?
    if [ "$hint_rc" -eq 0 ] && [ "$hint_canon" = "$canon" ]; then
      record_hint=0
    elif [ "$hint_rc" -eq 0 ]; then
      record_hint=2
    else
      record_hint=1
    fi
  else
    canon="$(intercom_resolve_target "$to")"; rc=$?

    # A message that lands in the wrong inbox is indistinguishable from one that
    # was never sent. So an unresolved target is a hard stop, not a fresh inbox —
    # unless the sender says explicitly that this is first contact.
    if [ "$rc" -eq 3 ]; then
      printf 'intercom: ✗ "%s" is ambiguous — several agents claim that name:\n' "$to" >&2
      intercom_suggest "$to" >&2
      printf '   Next step: ask the user which one they mean, then\n' >&2
      printf '     intercom send "%s" %s --to <identity>     (delivers there; the name stays ambiguous until fixed)\n' "$to" "$slug" >&2
      printf '   Fix the directory so it stops being ambiguous: intercom names rm --for <other-identity> "%s"\n' "$to" >&2
      exit 3
    fi
    if [ "$rc" -ne 0 ] && [ "$first_contact" -eq 0 ]; then
      printf 'intercom: ✗ no agent is registered as "%s" — not sending.\n' "$to" >&2
      local sugg
      sugg="$(intercom_suggest "$to")"
      if [ -n "$sugg" ]; then
        printf '   Did you mean one of these?\n%s\n' "$sugg" >&2
        printf '   Next step: if one of them is clearly the one the user means, resend as\n' >&2
      else
        printf '   Nothing similar in the directory. Show it (intercom directory), ask the user which agent they mean, then resend as\n' >&2
      fi
      printf '     intercom send "%s" %s --to <identity>\n' "$to" "$slug" >&2
      printf '   → delivers there AND records "%s" as that agent'"'"'s name, so next time it resolves directly.\n' "$to" >&2
      printf '   Not sure which agent? Ask the user — never guess a recipient. Hint too circumstantial to be a name\n' >&2
      printf '   ("the one from yesterday")? Resend with the identity alone: intercom send <identity> %s\n' "$slug" >&2
      printf '   Recipient has genuinely never registered (brand-new repo)? → add --first-contact to create inbox `%s`;\n' "$canon" >&2
      printf '   they see it once their canonical identity equals "%s" (intercom identity, run there).\n' "$canon" >&2
      exit 2
    fi
  fi

  # A chain link that points at nothing reads exactly like a chain that was
  # never broken, so an unresolvable --reply-to is a hard stop, the same law
  # that governs an unresolvable recipient. Resolved BEFORE the file is written:
  # a letter on disk naming a letter that is not is worse than no letter.
  local reply_ref="" reply_path="" reply_title="" n_hits
  if [ -n "$reply_to" ]; then
    n_hits="$(intercom_find_letter "$reply_to" | wc -l | tr -d " ")"
    if [ "$n_hits" -eq 0 ]; then
      printf 'intercom: ✗ --reply-to "%s" matches no letter in the store — not sending.\n' "$reply_to" >&2
      printf '   A reference is `<identity>/<slug>`, or a bare `<slug>` when it is unique.\n' >&2
      printf '   Both the inbox and its _done/ archive are searched, so a picked-up letter still resolves.\n' >&2
      printf '   Store: %s\n' "$(intercom_store_root)" >&2
      exit 2
    fi
    if [ "$n_hits" -gt 1 ]; then
      printf 'intercom: ✗ --reply-to "%s" is ambiguous — %s letters carry that slug:\n' "$reply_to" "$n_hits" >&2
      intercom_find_letter "$reply_to" | while IFS= read -r _p; do
        printf '     %s\n' "$(intercom_letter_ref "$_p")"
      done >&2
      printf '   Qualify it: --reply-to <identity>/<slug>\n' >&2
      exit 3
    fi
    reply_path="$(intercom_find_letter "$reply_to" | head -1)"
    reply_ref="$(intercom_letter_ref "$reply_path")"
    reply_title="$(grep -m1 "^# " "$reply_path" 2>/dev/null | sed "s/^# //")"
  fi

  # --body: the letter's body IS this file, byte for byte. Field request
  # (executor, 2026-09-24): a sender keeps a copy of every letter
  # in its repo and audits against it, and splicing the copy in by hand meant
  # knowing where this template's placeholder begins and ends. Everything that
  # would produce a letter that only LOOKS sent is refused before a byte is
  # written — an empty body, an unreadable one, or one that is itself an
  # unfilled scaffold.
  if [ "$body_set" -eq 1 ]; then
    [ -n "$body_file" ] || _ic_die "send: --body needs a file path." 2
    if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
      _ic_die "send: cannot read body file '$body_file' — not sending." 2
    fi
    grep -q '[^[:space:]]' "$body_file" 2>/dev/null \
      || _ic_die "send: body file '$body_file' is empty — not sending (a letter without a body looks sent)." 2
    if grep -qF "$_IC_PLACEHOLDER_MARK" "$body_file" 2>/dev/null; then
      _ic_die "send: body file '$body_file' still holds the template placeholder — it is an unfilled scaffold, not a body. Not sending." 2
    fi
  fi

  # A body that opens with its own `# heading` is the letter's heading: the
  # template's `# {{TITLE}}` is not written above it. A sender's kept copy
  # usually starts with one, and measured 2026-09-30, 142 of the 344 letters
  # sent since --body appeared carried two headings in a row. The body itself is
  # untouched — the byte-for-byte promise is about the body, and the line that
  # goes is the template's.
  local body_h1=""
  if [ "$body_set" -eq 1 ]; then
    body_h1="$(awk 'NF { if (/^# /) { sub(/^# /, ""); print } exit }' "$body_file" 2>/dev/null)"
  fi

  from="$(intercom_identity)"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%d)"
  [ -n "$title" ] || title="$slug"

  inbox="$(intercom_inbox_dir "$canon")"
  mkdir -p "$inbox" 2>/dev/null || _ic_die "send: cannot create inbox dir $inbox"
  outfile="$inbox/$slug.md"
  if [ -e "$outfile" ]; then
    _ic_die "send: a pending message '$slug' already exists at $outfile (use a different slug, or have the recipient pick up the existing one first)."
  fi
  [ -f "$_INTERCOM_TEMPLATE" ] || _ic_die "send: template not found at $_INTERCOM_TEMPLATE"
  # Rendered beside the letter and moved into place only when complete, so the
  # recipient can never read a letter whose body is still the placeholder.
  local render="$inbox/.$slug.md.render.$$"

  local from_agent_suffix=""
  [ -n "$from_agent" ] && from_agent_suffix=" ($from_agent)"

  # Both tokens expand to nothing for an ordinary letter, and the line they sit
  # on is then dropped entirely: an envelope field claiming an empty chain is a
  # claim, and the envelope is the machine-readable truth.
  local reply_line="" reply_banner=""
  if [ -n "$reply_ref" ]; then
    reply_line="reply-to: $reply_ref"
    reply_banner="> ↩ **CONTINUES:** \`$reply_ref\`"
    [ -n "$reply_title" ] && reply_banner="$reply_banner — $reply_title"
    reply_banner="$reply_banner
>    Whole chain, and where each link lives now: \`/vdm:intercom chain $slug\`"
  fi

  # Literal token substitution (bash ${//}, not sed/awk) so free-text values
  # containing & \ / cannot corrupt the output.
  local line raw skip_blank=0
  while IFS= read -r line || [ -n "$line" ]; do
    raw="$line"
    if [ -n "$body_h1" ]; then
      # The template's heading goes, and the blank line under it with it —
      # otherwise the body's heading sits under two blank lines.
      if [ "$raw" = '# {{TITLE}}' ]; then skip_blank=1; continue; fi
      if [ "$skip_blank" -eq 1 ]; then
        skip_blank=0
        [ -z "$raw" ] && continue
      fi
    fi
    line="${line//'{{REPLY_TO_LINE}}'/$reply_line}"
    line="${line//'{{REPLY_TO_BANNER}}'/$reply_banner}"
    # A token line that expanded to nothing leaves no blank line behind.
    case "$raw" in
      *'{{REPLY_TO_'*) [ -z "$line" ] && continue ;;
    esac
    line="${line//'{{FROM}}'/$from}"
    line="${line//'{{FROM_AGENT}}'/$from_agent}"
    line="${line//'{{FROM_AGENT_SUFFIX}}'/$from_agent_suffix}"
    line="${line//'{{TO}}'/$canon}"
    line="${line//'{{TO_INPUT}}'/$to}"
    line="${line//'{{CREATED}}'/$created}"
    line="${line//'{{SLUG}}'/$slug}"
    line="${line//'{{TITLE}}'/$title}"
    printf '%s\n' "$line"
  done < "$_INTERCOM_TEMPLATE" > "$render"

  if [ "$body_set" -eq 1 ]; then
    _ic_splice_body "$render" "$body_file" || { rm -f "$render"; exit 1; }
  fi
  mv -f "$render" "$outfile" || { rm -f "$render"; _ic_die "send: cannot write $outfile"; }

  intercom_register --implicit 2>/dev/null   # so the recipient (or a reply) can resolve us by alias

  printf '✉️  intercom: staged message → %s\n' "$outfile"
  if [ "$to" != "$canon" ]; then
    printf '    from: %s   to: %s (resolved from "%s")\n' "$from" "$canon" "$to"
  else
    printf '    from: %s   to: %s\n' "$from" "$canon"
  fi
  case "$record_hint" in
    1)
      if intercom_names_edit add --for "$canon" "$to" 2>/dev/null; then
        printf '    📇 recorded "%s" as a name of `%s` — next time it resolves directly.\n' "$to" "$canon"
      else
        printf '    ⚠️  could not record "%s" as a name of `%s` (try: intercom names add --for %s "%s").\n' "$to" "$canon" "$canon" "$to"
      fi
      ;;
    2)
      printf '    ⚠️  "%s" currently routes to `%s`, not `%s` — delivered as told, name NOT recorded.\n' "$to" "$hint_canon" "$canon"
      printf '        If the directory is wrong, move the name: intercom names rm --for %s "%s" && intercom names add --for %s "%s"\n' "$hint_canon" "$to" "$canon" "$to"
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    printf '    ⚠️  first contact: no project is registered as "%s" — created a fresh inbox `%s`.\n' "$to" "$canon"
    printf '        The recipient sees it only if their canonical identity == "%s"\n' "$canon"
    printf '        (verify there with: intercom identity). If it differs, set intercom.identity\n'
    printf '        in their .claude/vdm-plugins.json, or resend to the correct slug. Once they register\n'
    printf '        a name that matches "%s", their session-start check offers `intercom claim %s`.\n' "$canon" "$canon"
  fi
  if [ "$body_set" -eq 1 ] && [ -n "${_IC_BODY_LABEL:-}" ]; then
    # A body `reply` rendered from its flags: the temporary file's path would
    # name a file that is gone by the time anyone reads this line.
    printf '    body: %s — %s bytes, compared after writing.\n' \
      "$_IC_BODY_LABEL" "$(wc -c < "$body_file" | tr -d ' ')"
  elif [ "$body_set" -eq 1 ]; then
    printf '    body: %s — %s bytes, identical to the file (compared after writing).\n' \
      "$body_file" "$(wc -c < "$body_file" | tr -d ' ')"
  else
    printf '    → now write the brief body into that file (replace the placeholder comment).\n'
  fi
  if [ -n "$body_h1" ] && [ "$title_given" -eq 1 ] && [ "$body_h1" != "$title" ]; then
    printf '    heading: the body'"'"'s own — "%s"; the title "%s" is not written above it.\n' "$body_h1" "$title"
  fi

  # Delivery is not receipt: a letter in an inbox is read only when somebody
  # runs `check`. If the recipient has a session alive on this machine right
  # now, say so and hand over the pointer — the assistant sends it; nothing here
  # writes to another session. With a scaffold the pointer must wait for the
  # body, or the recipient reads a placeholder.
  local live
  live="$(intercom_live_sessions "$canon")"
  if [ -n "$live" ]; then
    printf '    📣 live session(s) of `%s` on this machine: %s\n' "$canon" \
      "$(printf '%s\n' "$live" | awk -F '\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2 }')"
    if [ "$body_set" -eq 1 ]; then
      printf '       → wake each now with your cross-session message tool (Claude Code: SendMessage).\n'
    else
      printf '       → once the body is written — not before, or they read a placeholder — wake each\n'
      printf '         with your cross-session message tool (Claude Code: SendMessage).\n'
    fi
    printf '         It is a pointer; the inbox stays the truth. Text, first line self-contained:\n'
    printf '         📬 intercom: `%s` from `%s` — %s. Read: /vdm:intercom check — not urgent: the user'"'"'s pending steps come first\n' "$slug" "$from" "$title"
  fi
}

# `sent` — the sender's half of "delivery is not receipt": every letter this
# agent wrote that is still lying in somebody's inbox, oldest first, and
# whether its recipient has a session alive to be woken right now.
cmd_sent() {
  local id list n
  id="$(intercom_identity)"
  list="$(intercom_sent_list "$id")"
  if [ -z "$list" ]; then
    printf '📤 intercom: nothing from `%s` is waiting — every letter it sent has been picked up.\n' "$id"
    return 0
  fi
  n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  printf '📤 intercom: %s letter(s) from `%s` not picked up yet (oldest first):\n\n' "$n" "$id"
  local age inbox slug title file live seen="" cache=""
  while IFS=$'\t' read -r age inbox slug title file; do
    [ -n "$inbox" ] || continue
    # One lookup per recipient, not per letter — bash 3.2 has no maps, so a
    # plain "<inbox>=<live>" list stands in for one.
    case "$seen" in
      *"|$inbox|"*) live="$(printf '%s\n' "$cache" | awk -F '=' -v k="$inbox" '$1 == k { sub(/^[^=]*=/, ""); print; exit }')" ;;
      *) live="$(intercom_live_sessions "$inbox" | cut -f1 | paste -sd ',' - | sed 's/,/, /g')"
         seen="${seen}|$inbox|"; cache="${cache}${inbox}=${live}
" ;;
    esac
    printf '  • %sd  %s/%s — %s\n' "$age" "$inbox" "$slug" "$title"
    if [ -n "$live" ]; then
      printf '      live now: %s → wake with SendMessage: 📬 intercom: `%s` from `%s` — %s. Read: /vdm:intercom check — not urgent: the user'"'"'s pending steps come first\n' \
        "$live" "$slug" "$id" "$title"
    else
      printf '      no live session — it waits for their next `check`\n'
    fi
  done <<<"$list"
}

cmd_claim() {
  local inbox="" force=0
  inbox="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *)       _ic_die "claim: unknown argument '$1'. Usage: intercom claim <inbox> [--force]" ;;
    esac
  done
  [ -n "$inbox" ] || _ic_die "claim: missing <inbox>. Usage: intercom claim <inbox> [--force]"
  inbox="$(_intercom_fold "$inbox")"
  local id src dst
  id="$(intercom_identity)"
  [ "$inbox" != "$id" ] || _ic_die "claim: \`$inbox\` is already your own inbox."
  src="$(intercom_store_root)/$inbox"
  if [ -f "$(intercom_registry_file "$inbox")" ]; then
    _ic_die "claim: \`$inbox\` belongs to a registered agent — not an unclaimed inbox. Send them a message instead."
  fi
  [ -d "$src" ] || _ic_die "claim: no inbox \`$inbox\` in the store ($(intercom_store_root))."
  if [ "$force" -eq 0 ]; then
    if ! intercom_orphans_matching "$id" | grep -qxF "$inbox"; then
      _ic_die "claim: \`$inbox\` matches none of your names/aliases (intercom whoami). If it really is yours: intercom claim $inbox --force"
    fi
  fi
  intercom_register --implicit >/dev/null 2>&1
  dst="$(intercom_inbox_dir "$id")"
  mkdir -p "$dst/_done" 2>/dev/null || _ic_die "claim: cannot create $dst"

  # Move every message home, rewriting the envelope's `to:` to the canonical
  # identity (to_input keeps the name it was addressed under — that is the trace).
  local moved=0 f base dest tmp
  for f in "$src"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    dest="$dst/$base"
    [ -e "$dest" ] && dest="$dst/${base%.md}.$(date +%s).md"
    tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$tmp" ] && awk -v old="to: $inbox" -v new="to: $id" 'NR<=20 && $0==old { print new; next } { print }' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$dest" 2>/dev/null && rm -f "$f" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
      mv "$f" "$dest" 2>/dev/null
    fi
    moved=$((moved+1))
  done
  for f in "$src"/_done/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    dest="$dst/_done/$base"
    [ -e "$dest" ] && dest="$dst/_done/${base%.md}.$(date +%s).md"
    mv "$f" "$dest" 2>/dev/null
  done
  rmdir "$src/_done" 2>/dev/null || true
  rmdir "$src" 2>/dev/null || true

  local learned=""
  if intercom_names_edit add "$inbox" >/dev/null 2>&1; then
    learned="; \"$inbox\" recorded as your name"
  fi
  printf '📥 intercom: claimed inbox `%s` → `%s` (%s message(s) moved%s)\n' "$inbox" "$id" "$moved" "$learned"
  [ -d "$src" ] && printf '    ⚠️  %s could not be removed (non-message files left inside).\n' "$src"
  printf '    → intercom check\n'
}

# Move a pending letter to `_done/`, flipping `status: pending` → `done`.
# Prints the archived path. Shared by `pickup` and by `reply`, which archives a
# brief still lying in the inbox when its outcome goes out.
_ic_archive() {
  local msg="$1" inbox donedir dest tmp slug
  inbox="$(dirname "$msg")"
  slug="$(basename "$msg" .md)"
  donedir="$inbox/_done"
  mkdir -p "$donedir" 2>/dev/null || _ic_die "cannot create $donedir"
  tmp="$(mktemp 2>/dev/null || true)"
  if [ -n "$tmp" ]; then
    if sed 's/^status: pending$/status: done/' "$msg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$msg" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  dest="$donedir/$slug.md"
  if [ -e "$dest" ]; then
    dest="$donedir/$slug.$(date +%s).md"
  fi
  mv "$msg" "$dest" 2>/dev/null || _ic_die "failed to archive $msg"
  printf '%s\n' "$dest"
}

# Has an outcome of brief <slug> gone back to <sender>? Yes when any letter
# from <me> in the sender's inbox or archive names the slug — in `reply-to:` or
# in its text. Text counts because an answer often closes several briefs and
# `reply-to:` holds one: measured 2026-09-29, 22 of the 60 briefs no `reply-to:`
# pointed at had been answered that way. The slug must stand alone, so
# `ask-one` is not found inside `ask-one-extra`.
_ic_outcome_sent() {
  local me="$1" sender="$2" slug="$3" dir re f
  dir="$(intercom_inbox_dir "$sender")"
  [ -d "$dir" ] || return 1
  re="$(printf '%s' "$slug" | sed 's/\./\\./g')"
  re="(^|[^A-Za-z0-9._-])${re}([^A-Za-z0-9._-]|\$)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(intercom_fm_field "$f" from)" = "$me" ] && return 0
  done < <(grep -lE "$re" "$dir"/*.md "$dir"/_done/*.md 2>/dev/null)
  return 1
}

# The command that closes a brief, printed wherever intercom sees a brief being
# taken without it.
_ic_reply_hint() {
  printf 'intercom reply %s --done "<what was done>" --link <url> --ball "<who holds the ball — what ⏰ date>"' "$1"
}

cmd_pickup() {
  local slug="" grow=0
  slug="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --grow) grow=1; shift ;;
      # Refused before anything moves: an unknown flag here used to archive the
      # letter and drop whatever the flag carried (field case: `pickup <slug>
      # --done "…"`, product, 2026-09-29). The outcome has its own verb.
      *)      _ic_die "pickup: unknown argument '$1' — nothing archived. Usage: intercom pickup <slug> [--grow]. An outcome goes back with: intercom reply <slug> --done … --ball …" ;;
    esac
  done
  [ -n "$slug" ] || _ic_die "pickup: missing <slug>. Usage: intercom pickup <slug> [--grow]"
  slug="$(_ic_sanitize_slug "$slug")"
  local id inbox msg sender
  id="$(intercom_identity)"
  inbox="$(intercom_inbox_dir "$id")"
  msg="$inbox/$slug.md"
  [ -f "$msg" ] || _ic_die "pickup: no pending message '$slug' in your inbox ($inbox)."
  sender="$(intercom_fm_field "$msg" from)"

  if [ "$grow" -eq 1 ]; then
    printf '🌱 intercom: promote message → workitem\n'
    printf '    message: %s\n' "$msg"
    printf '    next: run /vdm:crystal-grow %s, seed the workitem from the body above,\n' "$slug"
    # The outcome is owed after the work, and the brief is archived before it
    # starts. Named as a Next action, the promise is held by the crystal-cut
    # gate instead of by anyone's memory.
    if [ -n "$sender" ] && [ "$sender" != "$id" ]; then
      printf '          add the outcome you owe the sender to its Next actions:\n'
      printf '            - [ ] Outcome to `%s`: %s\n' "$sender" "$(_ic_reply_hint "$slug")"
    fi
    printf '          then archive with: /vdm:intercom pickup %s\n' "$slug"
    return 0
  fi

  local dest
  dest="$(_ic_archive "$msg")" || exit 1
  printf '✅ intercom: archived → %s\n' "$dest"

  # The receipt: the sender otherwise learns "received" only by auditing the
  # store by hand. Offered only while the sender has a live session to tell.
  local live
  if [ -n "$sender" ] && [ "$sender" != "$id" ]; then
    live="$(intercom_live_sessions "$sender")"
    if [ -n "$live" ]; then
      printf '    📣 the sender `%s` has a live session on this machine: %s\n' "$sender" \
        "$(printf '%s\n' "$live" | awk -F '\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2 }')"
      printf '       → send a receipt with your cross-session message tool (Claude Code: SendMessage):\n'
      printf '         ✅ intercom: `%s` picked up by `%s`.\n' "$slug" "$id"
    fi
  fi

  # "Received" is not "done". A brief — a letter from someone else that is not
  # itself an answer — owes its sender an outcome, and until a letter back names
  # it, every pickup says so with the command that closes it.
  if [ -n "$sender" ] && [ "$sender" != "$id" ] \
     && [ -z "$(intercom_fm_field "$dest" reply-to)" ] \
     && ! _ic_outcome_sent "$id" "$sender" "$slug"; then
    printf '    ↩ no outcome has gone back to `%s` yet. Once this brief'"'"'s items are closed — even if it asks for nothing back:\n' "$sender"
    printf '         %s\n' "$(_ic_reply_hint "$slug")"
  fi
}

# `reply` — close a letter you received with its outcome: what was done, where,
# and whose ball it is now. The recipient and the chain link come from the
# letter's own envelope, so there is nothing to remember and nothing to mistype;
# the letter may still be in the inbox (archived here, in the same step) or
# already in `_done/` (the crystal path: picked up when the work started).
cmd_reply() {
  local ref="" title="" from_agent="" slug_out="" body_file="" body_set=0
  local dones=() links=() balls=()
  local usage='Usage: intercom reply <letter> (--done "<what>" [--link <url>]... --ball "<who — what ⏰ date>" | --body <file>) [--title T] [--slug S] [--from-agent A]'
  ref="${1:-}"; [ $# -gt 0 ] && shift
  case "$ref" in -*) _ic_die "reply: the first argument is the letter you answer. $usage" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --done|--link|--ball|--body|--title|--slug|--from-agent)
                      _intercom_need_value "$1" $# || exit 2 ;;
    esac
    case "$1" in
      --done)         dones+=("$2"); shift 2 ;;
      --done=*)       dones+=("${1#--done=}"); shift ;;
      --link)         links+=("$2"); shift 2 ;;
      --link=*)       links+=("${1#--link=}"); shift ;;
      --ball)         balls+=("$2"); shift 2 ;;
      --ball=*)       balls+=("${1#--ball=}"); shift ;;
      --body)         body_file="$2"; body_set=1; shift 2 ;;
      --body=*)       body_file="${1#--body=}"; body_set=1; shift ;;
      --title)        title="$2"; shift 2 ;;
      --title=*)      title="${1#--title=}"; shift ;;
      --slug)         slug_out="$2"; shift 2 ;;
      --slug=*)       slug_out="${1#--slug=}"; shift ;;
      --from-agent)   from_agent="$2"; shift 2 ;;
      --from-agent=*) from_agent="${1#--from-agent=}"; shift ;;
      *)              _ic_die "reply: unknown argument '$1' — nothing sent. $usage" ;;
    esac
  done
  [ -n "$ref" ] || _ic_die "reply: missing <letter>. $usage"

  # What goes back is decided before anything is looked up: an outcome is
  # either written (--body) or stated (--done + --ball), and "whose ball" is the
  # half that is forgotten — so it is required, even when the answer is "nobody".
  if [ "$body_set" -eq 1 ] && [ ${#dones[@]} -gt 0 -o ${#links[@]} -gt 0 -o ${#balls[@]} -gt 0 ]; then
    _ic_die "reply: --body, or --done/--link/--ball — not both. $usage"
  fi
  if [ "$body_set" -eq 0 ]; then
    [ ${#dones[@]} -gt 0 ] || _ic_die "reply: say what was done — --done \"<what>\" (and --ball), or --body <file>. $usage"
    [ ${#balls[@]} -gt 0 ] || _ic_die "reply: whose ball is it now? --ball \"<who — what ⏰ date>\"; when nothing is left: --ball \"nobody — closed\". $usage"
  fi

  # The letter answered is one YOU received: its sender is who gets the reply.
  # Continuing someone else's letter is a relay, and that is `send --reply-to`.
  local id inbox slug msg
  id="$(intercom_identity)"
  case "$ref" in
    */*) [ "${ref%%/*}" = "$id" ] \
           || _ic_die "reply: \`$ref\` is not a letter you received — reply answers your own inbox. To continue someone else's letter: intercom send <to> <slug> --reply-to $ref"
         slug="${ref##*/}" ;;
    *)   slug="$ref" ;;
  esac
  slug="$(_ic_sanitize_slug "${slug%.md}")"
  inbox="$(intercom_inbox_dir "$id")"
  msg=""
  if [ -f "$inbox/$slug.md" ]; then
    msg="$inbox/$slug.md"
  elif [ -f "$inbox/_done/$slug.md" ]; then
    msg="$inbox/_done/$slug.md"
  fi
  [ -n "$msg" ] || _ic_die "reply: no letter '$slug' in your inbox or its archive ($inbox)."
  local sender
  sender="$(intercom_fm_field "$msg" from)"
  [ -n "$sender" ] || _ic_die "reply: '$slug' names no sender in its envelope — nothing to reply to."
  [ "$sender" != "$id" ] || _ic_die "reply: '$slug' is a note from yourself — there is nobody to send an outcome to."
  # Checked here, not left to send: send's refusal is written for a recipient
  # the sender typed, and its advice (--to, --first-contact) does not fit an
  # answer to a letter whose envelope is wrong.
  if ! intercom_resolve_target "$sender" >/dev/null 2>&1; then
    _ic_die "reply: '$slug' names \`$sender\` as its sender, and no agent answers to that name — nothing sent, nothing archived. Such a letter was sent from outside its project, so the envelope carries a directory's name. Once you know who wrote it: intercom send <identity> $slug-outcome --reply-to $id/$slug --body <file>" 2
  fi

  # A slug that is free in the recipient's inbox AND archive: a second outcome
  # of the same brief is normal (items close at different times), and a slug
  # taken in `_done/` would make the reference to it ambiguous later.
  local rinbox base n
  rinbox="$(intercom_inbox_dir "$sender")"
  if [ -z "$slug_out" ]; then
    base="$slug-outcome"; slug_out="$base"; n=2
    while [ -e "$rinbox/$slug_out.md" ] || [ -e "$rinbox/_done/$slug_out.md" ]; do
      slug_out="$base-$n"; n=$((n + 1))
    done
  fi
  if [ -z "$title" ]; then
    title="$(grep -m1 '^# ' "$msg" 2>/dev/null | sed 's/^# //')"
    title="Outcome: ${title:-$slug}"
  fi

  # Global, not local: the EXIT trap runs after this function has returned —
  # or from inside `cmd_send`, which exits on a refusal — and a local would be
  # gone by then, leaving the file behind.
  if [ "$body_set" -eq 0 ]; then
    # An explicit template: a bare `mktemp` on macOS ignores $TMPDIR.
    local tmpdir="${TMPDIR:-/tmp}"
    _IC_REPLY_BODY="$(mktemp "${tmpdir%/}/intercom-reply.XXXXXX" 2>/dev/null)" \
      || _ic_die "reply: cannot create a temporary body."
    _IC_BODY_LABEL="rendered from --done/--link/--ball"
    trap 'rm -f "$_IC_REPLY_BODY"' EXIT
    {
      printf '## Done\n\n'
      local x
      for x in "${dones[@]}"; do printf -- '- %s\n' "$x"; done
      for x in "${links[@]+"${links[@]}"}"; do printf -- '- %s\n' "$x"; done
      printf '\n## Ball\n\n'
      for x in "${balls[@]}"; do printf -- '- [ ] %s\n' "$x"; done
    } > "$_IC_REPLY_BODY"
    body_file="$_IC_REPLY_BODY"
  fi

  local args=("$sender" "$slug_out" --title "$title" --reply-to "$id/$slug" --body "$body_file")
  [ -n "$from_agent" ] && args+=(--from-agent "$from_agent")
  cmd_send "${args[@]}"

  if [ "$msg" = "$inbox/$slug.md" ]; then
    local dest
    dest="$(_ic_archive "$msg")" || exit 1
    printf '✅ intercom: the brief is archived → %s\n' "$dest"
  fi
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  identity)                   cmd_identity "$@" ;;
  whoami)                     cmd_whoami "$@" ;;
  store)                      cmd_store "$@" ;;
  register)                   cmd_register "$@" ;;
  names)                      cmd_names "$@" ;;
  roles)                      cmd_roles "$@" ;;
  role)                       cmd_role "$@" ;;
  describe)                   cmd_describe "$@" ;;
  unregister)                 cmd_unregister "$@" ;;
  directory|who|list|agents)  cmd_directory "$@" ;;
  resolve)                    cmd_resolve "$@" ;;
  check|inbox)                cmd_check "$@" ;;
  send)                       cmd_send "$@" ;;
  claim)                      cmd_claim "$@" ;;
  pickup)                     cmd_pickup "$@" ;;
  reply)                      cmd_reply "$@" ;;
  sent|outbox)                cmd_sent "$@" ;;
  chain)                      cmd_chain "$@" ;;
  ""|-h|--help|help)
    cat <<'HELP'
intercom — central cross-agent/cross-session mailbox (/vdm:intercom)

  intercom identity                     print this repo's canonical identity
  intercom whoami                       identity + names + aliases + registration status
  intercom store                        print the resolved store root
  intercom register [--name N]... [--describe D] [--role R]... [--same-project]
                                        register this repo in the agent directory
                                        (--name: how the user calls it; --role: the role it
                                        holds; --same-project: confirm this clone's remote
                                        as the same project)
  intercom names [add|rm] [--for ID] <name>...
                                        list / edit an agent's human names
  intercom roles [add|rm] [--for ID] <role>...
                                        list / edit an agent's role. The directory keeps one,
                                        access-layer, with one holder; HQ and hand are answered
                                        by the access layer's own `hq <project root>`
  intercom role <role> [--path]         the agent holding <role>; --path: its checkout here
  intercom describe [--for ID] "<one-liner>"
                                        set an agent's description (own entry without --for)
  intercom unregister <identity> [--force]
                                        remove ONE directory entry; refuses while the agent
                                        is addressed by a human name. Never a sweep.
  intercom directory [-v]               every registered agent (aka: who, list, agents)
  intercom resolve <name>               which agent does <name> address?
  intercom check [--count]              list (or count) pending messages for this repo
  intercom chain <slug>                 the relay chain behind a letter, and where each link lives
  intercom send <to> <slug> [--title T] [--from-agent A] [--reply-to REF] [--body FILE] [--to ID] [--first-contact]
                                        stage a message addressed to <to> (identity, alias
                                        or name); unknown target = hard stop with next steps.
                                        --to <identity>: deliver there and record <to> as
                                        that agent's name (after the user said whom they meant)
  intercom claim <inbox> [--force]      move an unclaimed inbox that was addressed to one of
                                        your names into your own inbox
  intercom pickup <slug> [--grow]       archive a message (or promote with --grow)
  intercom reply <letter> (--done "<what>" [--link <url>]... --ball "<who — what ⏰ date>" | --body FILE)
                                        close a letter you received with its outcome: it goes
                                        to the letter's sender as a reply-to link; a letter
                                        still in the inbox is archived in the same step
  intercom sent                         your letters still unpicked in other inboxes, with age
                                        and the recipient's live sessions (aka: outbox)
HELP
    ;;
  *) _ic_die "unknown subcommand '$sub' (try: identity|whoami|store|register|names|describe|unregister|directory|resolve|check|send|claim|pickup|reply|sent|chain)" ;;
esac
