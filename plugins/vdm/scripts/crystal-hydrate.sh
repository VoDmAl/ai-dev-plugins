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

[ -z "$active" ] && [ "$non_canon_count" -eq 0 ] && exit 0

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
    header="[crystal] Active workitem. Read the workitem file before continuing if relevant to this session:"
  else
    header="[crystal] ${active_count} active workitems (mode: ${singleton_mode}). Read the relevant one(s) before continuing:"
  fi
fi

# Body — flat for single-root, group-by-root for multi-root.
body=""
if [ -n "$active" ]; then
  if [ "${roots_count:-1}" -le 1 ]; then
    # Single-root: one line per workitem with Read hint
    cfg_rel=$(vdm_config_read "crystal" "path" "docs/tasks")
    cfg_rel="${cfg_rel%/}"
    root=$(resolve_crystal_root)
    body=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      slug=$(extract_slug "$f")
      n=$(count_unchecked "$f")
      rel="${f#"$root"/}"
      ref="${cfg_rel}/${rel}"
      body="${body}  - ${slug}: ${n} open  (Read ${ref})\\n"
    done <<<"$active"
  else
    # Multi-root: group-by-root via format_active_summary
    summary=$(printf '%s\n' "$active" | format_active_summary)
    # summary is already multi-line "  - root: items..."; convert to \n-escaped
    body=$(printf '%s\n' "$summary" | awk '{ printf "%s\\n", $0 }')
  fi
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
