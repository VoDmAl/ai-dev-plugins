#!/bin/bash
# intercom.sh — CLI dispatcher for the /vdm:intercom skill.
#
#   intercom identity                     print this repo's canonical identity
#   intercom store                        print the resolved store root
#   intercom register                     register this repo in the store registry
#   intercom check [--count]              list (or count) pending messages
#   intercom send <to> <slug> [--title T] [--from-agent A]
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

cmd_identity() { intercom_identity; printf '\n'; }

cmd_store() { intercom_store_root; printf '\n'; }

cmd_register() {
  intercom_register
  local id; id="$(intercom_identity)"
  printf 'registered: %s → %s\n' "$id" "$(intercom_inbox_dir "$id")"
}

cmd_check() {
  local count_only=0
  [ "${1:-}" = "--count" ] && count_only=1
  intercom_register   # checking your inbox is the natural "I exist" moment
  local id n
  id="$(intercom_identity)"
  n="$(intercom_inbox_count "$id")"; [ -n "$n" ] || n=0
  if [ "$count_only" -eq 1 ]; then
    printf '%s\n' "$n"
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    printf '📭 intercom: no pending messages for `%s`.\n' "$id"
    return 0
  fi
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
  local to="" slug="" title="" from_agent=""
  to="${1:-}"; [ $# -gt 0 ] && shift
  slug="${1:-}"; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)          title="${2:-}"; shift 2 ;;
      --title=*)        title="${1#--title=}"; shift ;;
      --from-agent)     from_agent="${2:-}"; shift 2 ;;
      --from-agent=*)   from_agent="${1#--from-agent=}"; shift ;;
      *)                shift ;;
    esac
  done
  [ -n "$to" ]   || _ic_die "send: missing <target>. Usage: intercom send <target> <slug> [--title T] [--from-agent A]"
  [ -n "$slug" ] || _ic_die "send: missing <slug>."
  slug="$(_ic_sanitize_slug "$slug")"
  [ -n "$slug" ] || _ic_die "send: slug is empty after sanitization."

  local canon rc from created inbox outfile
  canon="$(intercom_resolve_target "$to")"; rc=$?
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

  intercom_register   # so the recipient (or a reply) can resolve us by alias

  printf '✉️  intercom: staged message → %s\n' "$outfile"
  if [ "$to" != "$canon" ]; then
    printf '    from: %s   to: %s (resolved from "%s")\n' "$from" "$canon" "$to"
  else
    printf '    from: %s   to: %s\n' "$from" "$canon"
  fi
  if [ "$rc" -eq 2 ]; then
    printf '    ⚠️  no project is registered as "%s" yet — created a fresh inbox `%s`.\n' "$to" "$canon"
    printf '        The recipient sees it only if their canonical identity == "%s"\n' "$canon"
    printf '        (verify there with: intercom identity). If it differs, set intercom.identity\n'
    printf '        in their .claude/vdm-plugins.json, or resend to the correct slug.\n'
  fi
  printf '    → now write the brief body into that file (replace the placeholder comment).\n'
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
  identity)      cmd_identity "$@" ;;
  store)         cmd_store "$@" ;;
  register)      cmd_register "$@" ;;
  check|inbox)   cmd_check "$@" ;;
  send)          cmd_send "$@" ;;
  pickup)        cmd_pickup "$@" ;;
  ""|-h|--help|help)
    cat <<'EOF'
intercom — central cross-agent/cross-session mailbox (/vdm:intercom)

  intercom identity                     print this repo's canonical identity
  intercom store                        print the resolved store root
  intercom register                     register this repo in the store registry
  intercom check [--count]              list (or count) pending messages for this repo
  intercom send <to> <slug> [--title T] [--from-agent A]
                                        stage a message addressed to <to>
  intercom pickup <slug> [--grow]       archive a message (or promote with --grow)
EOF
    ;;
  *) _ic_die "unknown subcommand '$sub' (try: identity|store|register|check|send|pickup)" ;;
esac
