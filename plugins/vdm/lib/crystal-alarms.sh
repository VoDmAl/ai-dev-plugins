#!/bin/bash
# crystal-alarms.sh — a date a crystal, or a card in it, was put off to. Sourced
# after crystal-path.sh, by crystal-hydrate.sh and crystal-cave.sh: the start of a
# session and the overview say the same thing.
#
# A date written down is an obligation only if something reads it. Two forms had
# nothing behind them (crystal `crystal-wake`, DL #3, #4):
#
#   * `deferred-until: YYYY-MM-DD` in the frontmatter, the owner's «postponed
#     till» (echelon's brief, 2026-09-25). It means something for a crystal not in
#     work, pre-work or paused: an active one is being worked on, and a terminal
#     one has nothing to come back to.
#   * `**Status:** deferred (deadline: YYYY-MM-DD)` on a sidetrack card, and the
#     `deferred (YYYY-MM-DD)` the completion guard prints. crystal-cut promised it
#     «surfaces again on/after deadline», and no code did: 22 cards on the machine
#     said `deferred`, none with a date, 2026-09-25. Read in every status, closed
#     crystals included: a card is put off at closing as often as not. It goes
#     quiet when the card's status changes.
#
# It rings on the date itself, unlike `(due:)`, which is overdue the day after: a
# due date is a last day, and this is the day to come back. A date that is not one
# is named, the same law as `(due:)`: it reads as an alarm and rings nothing. Prose
# in a card's brackets, `deferred (after the release)`, claims no date and says
# nothing. A fence is not a card, nor a `**Status:**` outside `## Sidetracks`.
#
# One awk over every file, whatever the number of crystals (crystal-cave's cost
# test holds it); a process or two per item that rings, and those are few.

# _crystal_alarm_scan [today] — workitem paths on stdin. Prints, tab-separated:
#   field <path> <status> <date>          past the date
#   field-bad <path> <status> <what is written>
#   card <path> <status> <date> <n> <title>
#   card-bad <path> <status> <what is written> <n> <title>
_crystal_alarm_scan() {
  local today="${1:-}" f
  local files=()
  [ -n "$today" ] || today="$(_vdm_today)"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v today="$today" -v OFS='\t' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function is_date(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
    function unquote(s) {
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    # The reader splits on tabs, and bash folds adjacent ones: an empty field
    # would shift the next into its place.
    function nz(s) { return s == "" ? "?" : s }
    function settle_field() {
      if (raw == "") return
      if (!is_date(raw)) print "field-bad", FILENAME_NOW, nz(status), raw
      else if (raw <= today) print "field", FILENAME_NOW, nz(status), raw
      raw = ""
    }
    FNR == 1 {
      settle_field()
      FILENAME_NOW = FILENAME; status = ""; raw = ""
      head = 0; fence = 0; section = 0; n = ""; title = ""
      if ($0 ~ /^---[ \t\r]*$/) { head = 1; next }
    }
    head {
      if ($0 ~ /^---[ \t\r]*$/) { head = 0; settle_field(); next }
      if ($0 ~ /^status:/) { status = $0; sub(/^status:[ \t]*/, "", status); sub(/[ \t]+#.*$/, "", status); status = unquote(trim(status)) }
      if ($0 ~ /^deferred-until:/) { raw = $0; sub(/^deferred-until:[ \t]*/, "", raw); sub(/[ \t]+#.*$/, "", raw); raw = unquote(trim(raw)) }
      next
    }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / { section = ($0 ~ /^## +Sidetracks[ \t\r]*$/); next }
    !section { next }
    /^### / {
      n = ""; title = trim(substr($0, 5))
      sub(/^Sidetrack[ \t]+/, "", title)
      if (match(title, /^#?[0-9]+/)) {
        n = substr(title, RSTART, RLENGTH); sub(/^#/, "", n)
        title = substr(title, RSTART + RLENGTH); sub(/^[.:)]?[ \t]*/, "", title)
      }
      next
    }
    /^\*\*Status:\*\*/ {
      v = $0; sub(/^\*\*Status:\*\*[ \t]*/, "", v)
      if (v !~ /^deferred/ || !match(v, /\(.*\)/)) next
      inner = trim(substr(v, RSTART + 1, RLENGTH - 2))
      claimed = sub(/^deadline:[ \t]*/, "", inner)
      if (is_date(inner)) { if (inner <= today) print "card", FILENAME_NOW, nz(status), inner, nz(n), nz(title) }
      else if (claimed && inner != "") print "card-bad", FILENAME_NOW, nz(status), inner, nz(n), nz(title)
    }
    END { settle_field() }
  ' "${files[@]}" 2>/dev/null
}

# crystal_alarm_text [today] — workitem paths on stdin; the lines to show, as they
# stand, nothing when no alarm rings. The status goes through the project's
# aliases: call _load_status_aliases in the calling shell first.
crystal_alarm_text() {
  local kind file status value n title resolved tier slug ref top="" out=""
  while IFS=$'\t' read -r kind file status value n title; do
    resolved="$(_apply_status_alias "$status")"
    case "$kind" in field|field-bad)
      tier="$(derive_status_tier "$resolved")"
      case "$tier" in pre-work|paused) ;; *) continue ;; esac
      ;;
    esac
    slug="$(extract_slug "$file")"
    # The path as it stands from the project root, as in the list of active
    # crystals. Asked once, and only when something rings.
    [ -n "$top" ] || top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd -P)
    ref="${file#"$top"/}"
    case "$kind" in
      field)
        out="${out}  - ${slug} (${resolved}): deferred until ${value}, and the date has come: bring it back to work, or move the date  (Read ${ref})"$'\n' ;;
      field-bad)
        out="${out}  - ${slug}: deferred-until: ${value} is not a date, this alarm will not ring  (Read ${ref})"$'\n' ;;
      card)
        out="${out}  - ${slug} (${resolved}): Sidetrack #${n} «${title}» deferred until ${value}, and the date has come: come back to it: a new crystal, or cancelled  (Read ${ref})"$'\n' ;;
      card-bad)
        out="${out}  - ${slug}: Sidetrack #${n}: deferred (deadline: ${value}) is not a date, this alarm will not ring  (Read ${ref})"$'\n' ;;
    esac
  done < <(_crystal_alarm_scan "${1:-}")
  [ -n "$out" ] || return 0
  printf '⏰ Put off to a date, and the date has come; each line stays until the date or the status changes:\n%s' "$out"
}
