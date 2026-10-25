#!/bin/bash
# crystal-hydrate.sh — SessionStart hook. Implements Decision Log #23 Layer 1:
# at session start, surface active crystals so the assistant can Read the
# workitem(s) for context before doing anything else.
#
# Output: JSON hookSpecificOutput with additionalContext — same shape used
# by docs-sync-reminder.sh. Silent when zero active crystals exist AND no
# non-canonical drift to flag.
#
# Singleton invariant (DL #5 in crystal-multi-root):
#   - global   — exactly 1 active workitem repo-wide (DL #11 in crystal-design)
#   - per-root — exactly 1 active workitem per resolved root (multi-root setups)
#   - off      — no invariant; explicit user override
# Violation surfaces in the header so the user notices drift rather than
# silently working on the wrong one.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0

# Warm the root cache in THIS shell before anything fans out into subshells.
# The memo inside resolve_crystal_roots is process-scoped, and every use of it
# below sits inside `$(...)`, `< <(...)` or a pipeline — a subshell inherits the
# cache but cannot fill it. Without this line the tree is rescanned once per
# call site (measured: 7× per hook run on an 11-root vault).
if command -v vdm_prime_crystal_roots >/dev/null 2>&1; then
  vdm_prime_crystal_roots
fi
fi

cat >/dev/null 2>&1 || true

all_items=$(find_workitems)
active=""
if [ -n "$all_items" ]; then
  active=$(printf '%s\n' "$all_items" | filter_status "in-progress")
fi
non_canon_count=0
if [ -n "$all_items" ]; then
  non_canon_count=$(printf '%s\n' "$all_items" | audit_non_canonical | grep -c '.' 2>/dev/null || true)
  non_canon_count=${non_canon_count:-0}
fi

# Dormant crystals holding a promise past due. The singleton invariant sends a
# crystal to dormant, and a pause is the state in which a date is easiest to
# miss: on one machine 14 of the 22 crystals with promises past due were dormant,
# in nine projects, and the start named none of them (late-grow Sidetrack #1,
# 2026-10-25). One line, slugs and counts; the dates themselves are in
# /vdm:crystal-cave. One pass over the whole list, silent at zero.
dormant_due=""
if [ -n "$all_items" ] && command -v due_counts_batch >/dev/null 2>&1; then
  dormant=$(printf '%s\n' "$all_items" | filter_status "dormant")
  if [ -n "$dormant" ]; then
    while IFS=$'\t' read -r f od _; do
      [ "${od:-0}" -gt 0 ] 2>/dev/null || continue
      dormant_due="${dormant_due:+${dormant_due}, }$(extract_slug "$f") (${od})"
    done < <(printf '%s\n' "$dormant" | due_counts_batch | sort)
  fi
fi

[ -z "$active" ] && [ "$non_canon_count" -eq 0 ] && [ -z "$dormant_due" ] && exit 0

singleton_mode=$(derive_singleton_mode 2>/dev/null || printf 'global')
roots_count=$(resolve_crystal_roots | grep -c '.' 2>/dev/null || echo 0)

# Detect singleton violation. Active count is the line count when non-empty.
active_count=0
if [ -n "$active" ]; then
  active_count=$(printf '%s\n' "$active" | grep -c '.' 2>/dev/null || echo 0)
fi

_per_root_active_counts() {
  # Reads workitem paths on stdin; prints each root's parent segment, one per
  # workitem. Caller can pipe through sort|uniq -c to get per-root counts.
  local f slug
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    slug=$(extract_slug "$f")
    case "$slug" in
      */*) printf '%s\n' "${slug%%/*}" ;;
      *)   printf '(root)\n' ;;
    esac
  done
}

violation=""
case "$singleton_mode" in
  global)
    if [ "${active_count:-0}" -gt 1 ]; then
      violation="⚠ Singleton violation: ${active_count} active workitems (should be 1)."
      violation="${violation}\\nResolve by switching extras to status:dormant — see Decision Log #11 in crystal-design."
    fi
    ;;
  per-root)
    overflow=$(printf '%s\n' "$active" | _per_root_active_counts | sort | uniq -c | awk '$1 > 1')
    if [ -n "$overflow" ]; then
      violation="⚠ Singleton (per-root) violation: at least one root has multiple active workitems."
      violation="${violation}\\nResolve by switching extras to status:dormant in those roots."
    fi
    ;;
  off|*) : ;;
esac

# Header — singular vs plural / mode hint.
header=""
if [ -n "$active" ]; then
  if [ -n "$violation" ]; then
    header="[crystal] ${violation}"
  elif [ "${active_count:-0}" -eq 1 ]; then
    header="[crystal] Active workitem. Read it before continuing — workitem.md = source of truth (every decision → \`## Decision Log\`, every observation → \`/vdm:crystal-bud\`; chat decays under compaction):"
  else
    header="[crystal] ${active_count} active workitems (mode: ${singleton_mode}). Read the relevant one(s) — workitem.md = source of truth (every decision → \`## Decision Log\`, every observation → \`/vdm:crystal-bud\`; chat decays under compaction):"
  fi
fi

# Body — flat for single-root, group-by-root for multi-root.
body=""
if [ -n "$active" ]; then
  if [ "${roots_count:-1}" -le 1 ]; then
    # Single-root: one line per workitem with Read hint
    # The path as it stands from the project root, where the roots were found.
    # It was `crystal.path` (default docs/tasks) plus the path under the root,
    # and a project whose crystals live in tasks/ was told to Read a file under
    # docs/tasks/ that does not exist (late-grow, 2026-10-25).
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd -P)
    body=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      slug=$(extract_slug "$f")
      n=$(count_unchecked "$f")
      # A promise whose due date (`(due:)`, `[due::]`, `⏰ <date>`) has passed. Surfaced here
      # because session start is the moment a stale checklist is still cheap to
      # notice — the failure it answers to is a checklist that reads as current
      # for six weeks (checkbox-decay-signal, field report from executor).
      # Silent at zero: the marker is optional, so most crystals show nothing.
      od=$(count_overdue "$f")
      ref="${f#"$top"/}"
      if [ "${od:-0}" -gt 0 ]; then
        body="${body}  - ${slug}: ${n} open, ⏰${od} ПРОСРОЧЕНО  (Read ${ref})\\n"
      else
        body="${body}  - ${slug}: ${n} open  (Read ${ref})\\n"
      fi
    done <<<"$active"
  else
    # Multi-root: group-by-root via format_active_summary
    summary=$(printf '%s\n' "$active" | format_active_summary)
    # summary is already multi-line "  - root: items..."; convert to \n-escaped
    body=$(printf '%s\n' "$summary" | awk '{ printf "%s\\n", $0 }')
  fi
fi

# Promises bound to an event — `when:` on an open item. Nothing watches the
# event: the session that promised «I'll delete them once all 30 have arrived»
# is gone, and «22 open» buries the one item holding an irreversible step
# (a project's agent, 2026-10-23; wrap-skill DL #15). Each such item is printed whole, so
# the session checks the event before anything behind it. Active crystals
# only, like the list above.
waits=""
if [ -n "$active" ] && command -v _unchecked_lines >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    slug=$(extract_slug "$f")
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      w=${w#*"- [ ] "}; w=${w//\\/\\\\}; w=${w//\"/\\\"}; w=${w//$'\t'/ }
      waits="${waits}  ⏳ ${slug}: ${w}\\n"
    done < <(_unchecked_lines "$f" | grep -E '(^|[[:space:]([])when:')
  done <<<"$active"
fi
if [ -n "$waits" ]; then
  waits="\\nWaiting for an event — nothing watches it. Check the event first, before the step behind it:\\n${waits}"
fi
body="${body}${waits}"
if [ -n "$dormant_due" ]; then
  body="${body}${body:+\\n}⏰ Dormant, with promises past due — a pause does not move a date: ${dormant_due//\"/\\\"}. /vdm:crystal-cave shows the dates.\\n"
fi

# Audit line — always last if non-canonical present.
audit_line=""
if [ "$non_canon_count" -gt 0 ]; then
  audit_line="\\n⚠ Non-canonical statuses: ${non_canon_count} workitems. /vdm:crystal-cave to triage."
fi

# Assemble. footer: cave hint (only when there's active content to navigate).
footer=""
if [ -n "$active" ]; then
  footer="\\n→ /vdm:crystal-cave for full view (sidetracks + decision log)."
fi

context="${header}\\n${body}${footer}${audit_line}"
# Trim leading/trailing escaped-newlines for cleanliness.
context=$(printf '%s' "$context" | sed 's/^\\n//; s/\\n$//')

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
exit 0
