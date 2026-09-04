#!/bin/bash
# intercom.sh — CLI dispatcher for the /vdm:intercom skill.
#
#   intercom identity                     print this repo's canonical identity
#   intercom whoami                       identity + names + aliases + registration status
#   intercom store                        print the resolved store root
#   intercom register [--name N]... [--describe D] [--same-project]
#                                         register this repo in the agent directory
#   intercom names [add|rm] [--for ID] <name>...
#                                         list / edit the human names of an agent
#   intercom directory [-v]               list every registered agent (aka: who, list, agents)
#   intercom resolve <name>               which agent does <name> address?
#   intercom check [--count]              list (or count) pending messages
#   intercom send <to> <slug> [--title T] [--from-agent A] [--to ID] [--first-contact]
#   intercom claim <inbox> [--force]      move an unclaimed inbox addressed to one of your names home
#   intercom pickup <slug> [--grow]       archive a message (or promote with --grow)
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
  local id src names aliases desc remotes missing n mismatch
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
  printf '   names:        %s\n' "${names:-(none)}"
  printf '   aliases:      %s\n' "${aliases:-(none)}"
  printf '   description:  %s\n' "${desc:-(none)}"
  printf '   remotes:      %s\n' "${remotes:-(none)}"
  n="$(intercom_inbox_count "$id")"; [ -n "$n" ] || n=0
  printf '   inbox:        %s   (%s pending)\n' "$(intercom_inbox_dir "$id")" "$n"
  missing="$(intercom_registration_missing "$id")"
  if [ -z "$missing" ]; then
    printf '   registration: ✓ complete — other agents can address you as: %s' "$id"
    [ -n "$names" ] && printf ', %s' "$names"
    [ -n "$aliases" ] && printf ', %s' "$aliases"
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
  intercom_register "$@" || exit 1
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
  intercom_register 2>/dev/null   # checking your inbox is the natural "I exist" moment
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
  local f from created slug title
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    from="$(intercom_fm_field "$f" from)"
    created="$(intercom_fm_field "$f" created)"
    slug="$(intercom_fm_field "$f" slug)"
    [ -n "$slug" ] || slug="$(basename "$f" .md)"
    title="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')"
    [ -n "$title" ] || title="$slug"
    printf '  • %s\n    from: %s   created: %s\n    file: %s\n    pickup: /vdm:intercom pickup %s\n\n' \
      "$title" "${from:-?}" "${created:-?}" "$f" "$slug"
  done < <(intercom_inbox_list "$id")
}

cmd_send() {
  local to="" slug="" title="" from_agent="" first_contact=0 deliver_to=""
  to="${1:-}"; [ $# -gt 0 ] && shift
  slug="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)          title="${2:-}"; shift 2 ;;
      --title=*)        title="${1#--title=}"; shift ;;
      --from-agent)     from_agent="${2:-}"; shift 2 ;;
      --from-agent=*)   from_agent="${1#--from-agent=}"; shift ;;
      --to)             deliver_to="${2:-}"; shift 2 ;;
      --to=*)           deliver_to="${1#--to=}"; shift ;;
      --first-contact)  first_contact=1; shift ;;
      *)                shift ;;
    esac
  done
  [ -n "$to" ]   || _ic_die "send: missing <target>. Usage: intercom send <target> <slug> [--title T] [--from-agent A] [--to <identity>] [--first-contact]"
  [ -n "$slug" ] || _ic_die "send: missing <slug>."
  slug="$(_ic_sanitize_slug "$slug")"
  [ -n "$slug" ] || _ic_die "send: slug is empty after sanitization."

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

  local from_agent_suffix=""
  [ -n "$from_agent" ] && from_agent_suffix=" ($from_agent)"

  # Literal token substitution (bash ${//}, not sed/awk) so free-text values
  # containing & \ / cannot corrupt the output.
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//'{{FROM}}'/$from}"
    line="${line//'{{FROM_AGENT}}'/$from_agent}"
    line="${line//'{{FROM_AGENT_SUFFIX}}'/$from_agent_suffix}"
    line="${line//'{{TO}}'/$canon}"
    line="${line//'{{TO_INPUT}}'/$to}"
    line="${line//'{{CREATED}}'/$created}"
    line="${line//'{{SLUG}}'/$slug}"
    line="${line//'{{TITLE}}'/$title}"
    printf '%s\n' "$line"
  done < "$_INTERCOM_TEMPLATE" > "$outfile"

  intercom_register 2>/dev/null   # so the recipient (or a reply) can resolve us by alias

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
  printf '    → now write the brief body into that file (replace the placeholder comment).\n'
}

cmd_claim() {
  local inbox="" force=0
  inbox="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *)       shift ;;
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
  intercom_register >/dev/null 2>&1
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

cmd_pickup() {
  local slug="" grow=0
  slug="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --grow) grow=1; shift ;;
      *)      shift ;;
    esac
  done
  [ -n "$slug" ] || _ic_die "pickup: missing <slug>. Usage: intercom pickup <slug> [--grow]"
  slug="$(_ic_sanitize_slug "$slug")"
  local id inbox msg
  id="$(intercom_identity)"
  inbox="$(intercom_inbox_dir "$id")"
  msg="$inbox/$slug.md"
  [ -f "$msg" ] || _ic_die "pickup: no pending message '$slug' in your inbox ($inbox)."

  if [ "$grow" -eq 1 ]; then
    printf '🌱 intercom: promote message → workitem\n'
    printf '    message: %s\n' "$msg"
    printf '    next: run /vdm:crystal-grow %s, seed the workitem from the body above,\n' "$slug"
    printf '          then archive with: /vdm:intercom pickup %s\n' "$slug"
    return 0
  fi

  local donedir dest tmp
  donedir="$inbox/_done"
  mkdir -p "$donedir" 2>/dev/null || _ic_die "pickup: cannot create $donedir"
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
  mv "$msg" "$dest" 2>/dev/null || _ic_die "pickup: failed to archive $msg"
  printf '✅ intercom: archived → %s\n' "$dest"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  identity)                   cmd_identity "$@" ;;
  whoami)                     cmd_whoami "$@" ;;
  store)                      cmd_store "$@" ;;
  register)                   cmd_register "$@" ;;
  names)                      cmd_names "$@" ;;
  directory|who|list|agents)  cmd_directory "$@" ;;
  resolve)                    cmd_resolve "$@" ;;
  check|inbox)                cmd_check "$@" ;;
  send)                       cmd_send "$@" ;;
  claim)                      cmd_claim "$@" ;;
  pickup)                     cmd_pickup "$@" ;;
  ""|-h|--help|help)
    cat <<'HELP'
intercom — central cross-agent/cross-session mailbox (/vdm:intercom)

  intercom identity                     print this repo's canonical identity
  intercom whoami                       identity + names + aliases + registration status
  intercom store                        print the resolved store root
  intercom register [--name N]... [--describe D] [--same-project]
                                        register this repo in the agent directory
                                        (--name: how the user calls it; --same-project:
                                        confirm this clone's remote as the same project)
  intercom names [add|rm] [--for ID] <name>...
                                        list / edit an agent's human names
  intercom directory [-v]               every registered agent (aka: who, list, agents)
  intercom resolve <name>               which agent does <name> address?
  intercom check [--count]              list (or count) pending messages for this repo
  intercom send <to> <slug> [--title T] [--from-agent A] [--to ID] [--first-contact]
                                        stage a message addressed to <to> (identity, alias
                                        or name); unknown target = hard stop with next steps.
                                        --to <identity>: deliver there and record <to> as
                                        that agent's name (after the user said whom they meant)
  intercom claim <inbox> [--force]      move an unclaimed inbox that was addressed to one of
                                        your names into your own inbox
  intercom pickup <slug> [--grow]       archive a message (or promote with --grow)
HELP
    ;;
  *) _ic_die "unknown subcommand '$sub' (try: identity|whoami|store|register|names|directory|resolve|check|send|claim|pickup)" ;;
esac
