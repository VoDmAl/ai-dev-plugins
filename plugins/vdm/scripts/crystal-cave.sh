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
#   ⚠ Off-canon shape: N workitems.           [only if any]
#   ℹ Legacy schema: N workitems.             [only if any]
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

# Warm the root cache in THIS shell before anything fans out into subshells.
# The memo inside resolve_crystal_roots is process-scoped, and every use of it
# below sits inside `$(...)`, `< <(...)` or a pipeline — a subshell inherits the
# cache but cannot fill it. Without this line the tree is rescanned once per
# call site (measured: 7× per hook run on an 11-root vault).
#
# From 2.24.1 this call stood inside the `|| { … }` above, the branch that runs
# only when the library is missing, so it never ran; the test that required it
# asked only whether the text was in the file (Sidetrack #14,
# docs/tasks/crystal-wake/workitem.md).
if command -v vdm_prime_crystal_roots >/dev/null 2>&1; then
  vdm_prime_crystal_roots
fi

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
#   $11 canon         ""|off-canon|legacy — STRUCTURAL canon, from crystal-lint
#   $12 overdue       count of `- [ ]` items whose `(due: YYYY-MM-DD)` has passed
#
# Structural canon is a SEPARATE axis from the status taxonomy, and the two are
# reported separately on purpose: a workitem can carry a perfectly canonical
# `status:` and a broken shape, or the reverse. Merging them into one warning
# would make each unactionable — the reader could not tell which thing to fix.
#
# The verdict is not re-derived here. crystal-lint owns what "off canon" means
# and is asked for it (`--summary`), the same way check-doc-orphans owns the
# orphan contract for everyone who needs it.
# ----------------------------------------------------------------------------

# Ask the linter once for every workitem; look the verdict up per row below.
# Failure here is never fatal: an overview that refuses to render because a
# validator misbehaved is worse than one missing a column.
#
# `|| true` is load-bearing, not defensive noise. crystal-lint exits 1 when it
# FINDS violations — that is its success case here, not an error — so a bare
# `$(...) || LINT_SUMMARY=""` discards the output precisely when it has
# something to report. That bug was written here first and caught only by
# running the audit against a tree with real violations in it; on a clean tree
# it is invisible, because both branches produce the same empty column.
LINT_SUMMARY=$(bash "$SCRIPT_DIR/crystal-lint.sh" --all --summary 2>/dev/null || true)

# Every workitem once, and everything a row needs read from all of them in a
# fixed number of processes. The loop below used to ask per workitem — four or
# five awk for the frontmatter, a grep for the slug, an awk for the canon
# verdict, three processes for the overdue count, two more for malformed dates —
# about twenty launches a workitem, 731 in this repository (Sidetrack #14,
# docs/tasks/crystal-wake/workitem.md). The rules have not moved: the fields,
# the obligations and the due dates are read by the library's own programs, in
# their batch form.
ALL_ITEMS=$(find_workitems)
DUES=$(printf '%s\n' "$ALL_ITEMS" | due_counts_batch)

build_meta() {
  local f raw type fallback updated description resolved tier group short to icon
  [ -z "$ALL_ITEMS" ] && return 0
  # Once, here: every `$(_apply_status_alias …)` below is a subshell, which
  # can use the aliases but not load them for the next one (Sidetrack #13).
  _load_status_aliases
  while IFS=$'\037' read -r f raw type fallback updated description; do
    [ -n "$f" ] || continue
    [ -z "$raw" ] && continue
    resolved=$(_apply_status_alias "$raw")
    tier=$(derive_status_tier "$resolved")
    _slug_into "$f" "$ROOTS" "$ROOT_COUNT"
    [ -z "$type" ] && type="$fallback"
    case "$_VDM_SLUG" in
      */*) group="${_VDM_SLUG%%/*}"; short="${_VDM_SLUG#*/}" ;;
      *)   group="."; short="$_VDM_SLUG" ;;
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
    # The path leads the row until the join below has used it.
    printf '%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$f" "$group" "$to" "${updated:-0000-00-00}" "$short" "$tier" "$resolved" \
      "${type:-}" "${updated:-}" "${description:-}" "$icon"
  done < <(printf '%s\n' "$ALL_ITEMS" \
             | _extract_frontmatter_batch status session-type type last-updated description)
}

# Two more axes, joined on by path in one pass. The canon verdict is the
# linter's (first line per file wins, as before); a third axis, separate from
# status and from structural canon, is promises whose declared date has passed.
# Zero for every workitem that never named a date — which is most of them, by
# design (checkbox-decay-signal DL #2).
META=$(build_meta | _LINT="$LINT_SUMMARY" _DUES="$DUES" awk -F'\t' '
  BEGIN {
    n = split(ENVIRON["_LINT"], L, "\n")
    for (i = 1; i <= n; i++) {
      split(L[i], c, "\t")
      if (c[1] == "" || (c[1] in canon)) continue
      canon[c[1]] = (c[2] == "violations") ? "off-canon" : ((c[2] == "legacy") ? "legacy" : "")
    }
    n = split(ENVIRON["_DUES"], D, "\n")
    for (i = 1; i <= n; i++) { split(D[i], c, "\t"); if (c[1] != "") od[c[1]] = c[2] + 0 }
  }
  {
    out = $2
    for (i = 3; i <= NF; i++) out = out "\t" $i
    printf "%s\t%s\t%d\n", out, (($1 in canon) ? canon[$1] : ""), (($1 in od) ? od[$1] : 0)
  }
')

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

count_canon() {
  printf '%s\n' "$META" | awk -F'\t' -v c="$1" '$11==c' | grep -c '.' 2>/dev/null || true
}
N_OFFCANON=$(count_canon off-canon); N_OFFCANON=${N_OFFCANON:-0}
N_LEGACY=$(count_canon legacy);      N_LEGACY=${N_LEGACY:-0}

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
    canon   = F[11]
    overdue = F[12] + 0
    # Idea rows hide the type column (status implies type)
    if (status == "idea") type = ""
    type_padded = pad(type, typew)
    desc_suffix = (desc != "") ? "  — \"" desc "\"" : ""
    if (overdue > 0)            desc_suffix = desc_suffix "  ⏰ " overdue " overdue"
    if (canon == "off-canon")   desc_suffix = desc_suffix "  ⚠ off-canon"
    else if (canon == "legacy") desc_suffix = desc_suffix "  ℹ legacy"
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

# Structural canon — a separate axis from status, so a separate line.
if [ "$N_OFFCANON" -gt 0 ]; then
  printf '\n⚠ Off-canon shape: %d workitems. Details: crystal-lint.sh --all\n' "$N_OFFCANON"
fi

# Overdue promises — a third axis again, and the one with no gate behind it: a
# passed date is not an error, it is a promise that slipped, and only a person
# can decide whether to do it, move it or drop it.
# A `due:` that is not a date is worse than no date: it READS as a projection
# while being invisible to the detector — a mechanism silently narrowing its own
# scope, which is this repository's recurring failure mode. Reported separately
# from the count, because the fix is different: not "do the work", but "write
# the date properly or drop the marker".
MALFORMED=$(printf '%s\n' "$DUES" | awk -F'\t' '{ s += $3 } END { print s + 0 }')
if [ "${MALFORMED:-0}" -gt 0 ]; then
  printf '\n⚠ Malformed `due:` markers: %d. They look like a deadline and are invisible to the\n' "$MALFORMED"
  printf '   overdue check. Expected form: `- [ ] promise (due: YYYY-MM-DD)`.\n'
fi

N_OVERDUE=$(printf '%s\n' "$META" | awk -F'\t' '{ s += $12 } END { print s+0 }')
if [ "${N_OVERDUE:-0}" -gt 0 ]; then
  printf '\n⏰ Overdue promises: %d across all crystals. A date that passed is not a failure —\n' "$N_OVERDUE"
  printf '   decide per item: do it, move the date, or drop the promise explicitly.\n'
fi

if [ "$N_LEGACY" -gt 0 ]; then
  printf '\nℹ Legacy schema (crystal-migrate imports): %d workitems — shape not asserted.\n' "$N_LEGACY"
  printf '  Do not infer a workitem'"'"'s shape from these.\n'
fi

printf '\nLegend: ● active · ⏸ paused · ○ ready · ◦ idea'
[ "$INCLUDE_TERMINAL" -eq 1 ] && printf ' · ✓ done'
printf '\n'

exit 0
