#!/bin/bash
# crystal-cave.sh — overview renderer for /vdm:crystal-cave.
#
# Replaces ad-hoc `for f in **/workitem.md; ...` loops the assistant used to
# improvise: a single invocation produces the fully-rendered overview text,
# the skill prints it verbatim. Counts, tiers, icons, group ordering, column
# widths all decided here so the output is deterministic across sessions.
#
# Layout (by-root grouping, no per-row `└─ path` lines):
#
#   🔮 N roots · A active · P paused · B backlog · D done
#      /vdm:crystal-cave --all   /vdm:crystal-cave <slug>
#
#   ⚠ Singleton (per-root) violation: ...     [only if violated]
#
#   <root-1> (1 active · 2 ready)
#     ● <short-slug>      <type>      <updated>
#     ○ <short-slug>      <type>      <updated>
#
#   <root-2> (1 paused · 1 idea)
#     ⏸ <short-slug>      <type>      <updated>
#     ◦ <short-slug>                  <updated>
#
#   Done: N crystals (use --all)
#   ⚠ Non-canonical statuses: N workitems.    [only if drift detected]
#   Legend: ● active · ⏸ paused · ○ ready · ◦ idea
#
# Single-root mode collapses group headers (only one trivial group).
# --all flag adds Terminal tier (done/cancelled/superseded) to the output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/crystal-path.sh" 2>/dev/null || {
  echo "crystal-cave: lib/crystal-path.sh not found relative to $SCRIPT_DIR" >&2
  exit 1
}

INCLUDE_TERMINAL=0
for arg in "$@"; do
  case "$arg" in
    --all) INCLUDE_TERMINAL=1 ;;
    *) ;;  # unknown flags ignored — keep room for future without breaking
  esac
done

ROOTS=$(resolve_crystal_roots)
ROOT_COUNT=$(printf '%s\n' "$ROOTS" | grep -c '.' 2>/dev/null || true)
ROOT_COUNT=${ROOT_COUNT:-0}
SINGLETON_MODE=$(derive_singleton_mode)

# ----------------------------------------------------------------------------
# Build metadata table
#
# 10 tab-separated columns per workitem — kept aligned so the awk renderer
# below can address by $N consistently.
#
#   $1  group         leading slug segment (root parent for multi-root, "." for single-root)
#   $2  tier_order    0 active · 1 paused · 2 ready/draft · 3 idea · 4 terminal · 5 non-canonical
#   $3  updated_key   YYYY-MM-DD for sort (missing → 0000-00-00 so empty values sink)
#   $4  short_slug    slug without group prefix
#   $5  tier          active|paused|pre-work|terminal|non-canonical
#   $6  status        resolved status (alias-applied)
#   $7  type          session-type, with fallback to type
#   $8  updated       raw last-updated for display
#   $9  description   optional one-liner for cave/base overview
#   $10 icon          ●/⏸/○/◦/✓/!
# ----------------------------------------------------------------------------

build_meta() {
  local all_items f raw resolved tier slug type updated description group short to icon
  all_items=$(find_workitems)
  [ -z "$all_items" ] && return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    raw=$(extract_frontmatter_field "$f" status)
    [ -z "$raw" ] && continue
    resolved=$(_apply_status_alias "$raw")
    tier=$(derive_status_tier "$resolved")
    slug=$(extract_slug "$f")
    type=$(extract_frontmatter_field "$f" session-type)
    [ -z "$type" ] && type=$(extract_frontmatter_field "$f" type)
    updated=$(extract_frontmatter_field "$f" "last-updated")
    description=$(extract_frontmatter_field "$f" description)
    case "$slug" in
      */*) group="${slug%%/*}"; short="${slug#*/}" ;;
      *)   group="."; short="$slug" ;;
    esac
    case "$tier" in
      active)   to=0; icon='●' ;;
      paused)   to=1; icon='⏸' ;;
      pre-work)
        case "$resolved" in
          idea) to=3; icon='◦' ;;
          *)    to=2; icon='○' ;;
        esac ;;
      terminal) to=4; icon='✓' ;;
      *)        to=5; icon='!' ;;
    esac
    printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$group" "$to" "${updated:-0000-00-00}" "$short" "$tier" "$resolved" \
      "${type:-}" "${updated:-}" "${description:-}" "$icon"
  done <<<"$all_items"
}

META=$(build_meta)

if [ -z "$META" ]; then
  printf '🔮 No crystals found.\n'
  exit 0
fi

count_tier() {
  printf '%s\n' "$META" | awk -F'\t' -v t="$1" '$5==t' | grep -c '.' 2>/dev/null || true
}
N_ACTIVE=$(count_tier active);        N_ACTIVE=${N_ACTIVE:-0}
N_PAUSED=$(count_tier paused);        N_PAUSED=${N_PAUSED:-0}
N_BACKLOG=$(count_tier pre-work);     N_BACKLOG=${N_BACKLOG:-0}
N_TERMINAL=$(count_tier terminal);    N_TERMINAL=${N_TERMINAL:-0}
N_NONCANON=$(count_tier non-canonical); N_NONCANON=${N_NONCANON:-0}

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------

if [ "$ROOT_COUNT" -gt 1 ]; then
  printf '🔮 %d roots · %d active · %d paused · %d backlog · %d done\n' \
    "$ROOT_COUNT" "$N_ACTIVE" "$N_PAUSED" "$N_BACKLOG" "$N_TERMINAL"
else
  first_root=$(printf '%s\n' "$ROOTS" | head -n 1)
  rel_root="${first_root#"$PWD"/}"
  [ -z "$rel_root" ] && rel_root="$first_root"
  printf '🔮 Crystals in %s · %d active · %d paused · %d backlog · %d done\n' \
    "$rel_root" "$N_ACTIVE" "$N_PAUSED" "$N_BACKLOG" "$N_TERMINAL"
fi
printf '   /vdm:crystal-cave --all   /vdm:crystal-cave <slug>\n'
printf '\n'

# ----------------------------------------------------------------------------
# Singleton invariant — report scoped to derived mode (DL #5 in crystal-multi-root)
# ----------------------------------------------------------------------------

if [ "$SINGLETON_MODE" = "global" ] && [ "$N_ACTIVE" -gt 1 ]; then
  printf '⚠ Singleton (global) violation: %d active workitems (should be 1)\n' "$N_ACTIVE"
  printf '%s\n' "$META" | awk -F'\t' '$5=="active" {
    if ($1==".") printf "    %s\n", $4
    else         printf "    %s/%s\n", $1, $4
  }'
  printf '\n'
elif [ "$SINGLETON_MODE" = "per-root" ]; then
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    n=$(printf '%s\n' "$META" | awk -F'\t' -v g="$g" '$5=="active" && $1==g' | grep -c '.' 2>/dev/null || echo 0)
    if [ "$n" -gt 1 ]; then
      printf '⚠ Singleton (per-root) violation: root `%s` has %d active workitems\n' "$g" "$n"
      printf '%s\n' "$META" | awk -F'\t' -v g="$g" '$5=="active" && $1==g {
        printf "    %s/%s\n", $1, $4
      }'
      printf '\n'
    fi
  done < <(printf '%s\n' "$META" | awk -F'\t' '$5=="active" {print $1}' | sort -u)
fi

# ----------------------------------------------------------------------------
# Filter + sort the visible rows
#   k1: group (alpha)        — stable group ordering between runs
#   k2: tier_order (asc)     — active first, then paused, ready/draft, idea
#   k3: updated_key (desc)   — recent first inside the same tier
#   k4: short slug (alpha)   — tie-break
# ----------------------------------------------------------------------------

FILTERED=$(printf '%s\n' "$META" | awk -F'\t' -v term="$INCLUDE_TERMINAL" '
  $5=="non-canonical" { next }
  $5=="terminal" && !term { next }
  { print }
')

SORTED=$(printf '%s\n' "$FILTERED" | sort -t$'\t' -k1,1 -k2,2n -k3,3r -k4,4)

# ----------------------------------------------------------------------------
# Render — group header (suppressed in single-group case) + rows
# ----------------------------------------------------------------------------

printf '%s\n' "$SORTED" | awk -F'\t' '
function pad(s, w,   out) {
  out = s
  while (length(out) < w) out = out " "
  return out
}
{
  rows[NR] = $0
  groupOf[NR] = $1
  if (!($1 in seen)) { seen[$1] = 1; distinct++ }
  nrows = NR
}
function max_short(g,   i, F, n, m) {
  m = 0
  for (i=1; i<=nrows; i++) if (groupOf[i] == g) {
    n = split(rows[i], F, "\t")
    if (length(F[4]) > m) m = length(F[4])
  }
  return m
}
function max_type(g,   i, F, n, m) {
  m = 0
  for (i=1; i<=nrows; i++) if (groupOf[i] == g) {
    n = split(rows[i], F, "\t")
    if (F[6] == "idea") continue   # idea hides type — do not dilate column
    if (length(F[7]) > m) m = length(F[7])
  }
  return m
}
function group_counts_str(g,   i, F, n, na, np, nr, ni, nt, parts) {
  na=0; np=0; nr=0; ni=0; nt=0
  for (i=1; i<=nrows; i++) if (groupOf[i] == g) {
    n = split(rows[i], F, "\t")
    if (F[5]=="active") na++
    else if (F[5]=="paused") np++
    else if (F[5]=="pre-work" && F[6]=="idea") ni++
    else if (F[5]=="pre-work") nr++
    else if (F[5]=="terminal") nt++
  }
  parts = ""
  if (na>0) parts = parts (parts ? " · " : "") na " active"
  if (np>0) parts = parts (parts ? " · " : "") np " paused"
  if (nr>0) parts = parts (parts ? " · " : "") nr " ready"
  if (ni>0) parts = parts (parts ? " · " : "") ni " idea"
  if (nt>0) parts = parts (parts ? " · " : "") nt " done"
  return parts
}
END {
  if (nrows == 0) exit
  single_group = (distinct == 1)
  prev = ""
  maxw = 0; typew = 0
  for (i=1; i<=nrows; i++) {
    n = split(rows[i], F, "\t")
    g = F[1]
    if (g != prev) {
      if (prev != "") print ""
      if (!single_group || g != ".") {
        label = (g==".") ? "(no group)" : g
        printf "%s (%s)\n", label, group_counts_str(g)
      }
      maxw = max_short(g)
      typew = max_type(g)
      prev = g
    }
    icon    = F[10]
    status  = F[6]
    short   = F[4]
    type    = F[7]
    updated = F[8]
    desc    = F[9]
    # Idea rows hide the type column (status implies type)
    if (status == "idea") type = ""
    type_padded = pad(type, typew)
    desc_suffix = (desc != "") ? "  — \"" desc "\"" : ""
    if (typew == 0)
      printf "  %s %s   %s%s\n", icon, pad(short, maxw), updated, desc_suffix
    else
      printf "  %s %s   %s   %s%s\n", icon, pad(short, maxw), type_padded, updated, desc_suffix
  }
}
'

# ----------------------------------------------------------------------------
# Footer summary lines
# ----------------------------------------------------------------------------

if [ "$N_TERMINAL" -gt 0 ] && [ "$INCLUDE_TERMINAL" -eq 0 ]; then
  printf '\nDone: %d crystals (use /vdm:crystal-cave --all for details)\n' "$N_TERMINAL"
fi

if [ "$N_NONCANON" -gt 0 ]; then
  printf '\n⚠ Non-canonical statuses: %d workitems. The assistant will offer remap targets.\n' "$N_NONCANON"
fi

printf '\nLegend: ● active · ⏸ paused · ○ ready · ◦ idea'
[ "$INCLUDE_TERMINAL" -eq 1 ] && printf ' · ✓ done'
printf '\n'

exit 0
