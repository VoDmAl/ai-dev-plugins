#!/bin/bash
# crystal-stop-reminder.sh — Stop hook, silent reminder about active crystals
# with open items. Implements the visibility leg of Decision Log #7.
#
# Hook protocol (Claude Code): runs at the end of an assistant turn. Output
# is informational — we never block, never set `decision: block`. The reminder
# is here to defend against context pressure: if assistant forgets about an
# active workitem, this surfaces it once per turn.
#
# Output formats follow crystal-multi-root DL #13:
#   single-root: flat list with Read hints
#   multi-root:  group-by-root summary (slug only, fewer chars per row)
# Audit line appended when non-canonical drift detected.
#
# Budget: 5s. Must be silent (zero output) when there's nothing to report.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

# Drain hook stdin — we don't use it, but consuming it prevents SIGPIPE on
# some shells.
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

# Filter active to only items with unchecked > 0 — fully-checked-but-still-
# in-progress workitems are a normal intermediate state (e.g. user paused
# before flipping status:done).
active_with_open=""
if [ -n "$active" ]; then
  active_with_open=$(while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(count_unchecked "$f")
    [ "${n:-0}" -gt 0 ] && printf '%s\n' "$f"
  done <<<"$active")
fi

[ -z "$active_with_open" ] && [ "$non_canon_count" -eq 0 ] && exit 0

roots_count=$(resolve_crystal_roots | grep -c '.' 2>/dev/null || echo 0)

lines=""
if [ -n "$active_with_open" ]; then
  if [ "${roots_count:-1}" -le 1 ]; then
    cfg_rel=$(vdm_config_read "crystal" "path" "docs/tasks")
    cfg_rel="${cfg_rel%/}"
    root=$(resolve_crystal_root)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n=$(count_unchecked "$f")
      slug=$(extract_slug "$f")
      rel="${f#"$root"/}"
      ref="${cfg_rel}/${rel}"
      lines="${lines}  - ${slug}: ${n} unchecked  (${ref})\\n"
    done <<<"$active_with_open"
  else
    summary=$(printf '%s\n' "$active_with_open" | format_active_summary)
    lines=$(printf '%s\n' "$summary" | awk '{ printf "%s\\n", $0 }')
  fi
fi

# Header
if [ -n "$lines" ]; then
  header="[crystal] Active workitems with open items — finish or migrate before declaring done:"
else
  header="[crystal] No active workitems, but drift detected:"
fi

# Audit line
audit_line=""
if [ "$non_canon_count" -gt 0 ]; then
  audit_line="\\n⚠ Non-canonical statuses: ${non_canon_count} workitems. /vdm:crystal-cave to triage."
fi

# Footer
footer=""
if [ -n "$lines" ]; then
  footer="\\n→ /vdm:crystal-cave for full view; /vdm:crystal-cut <slug> to close."
fi

context="${header}\\n${lines}${footer}${audit_line}"
context=$(printf '%s' "$context" | sed 's/\\n\\n*$//')

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "Stop",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
exit 0
