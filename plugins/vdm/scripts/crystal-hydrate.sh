#!/bin/bash
# crystal-hydrate.sh — SessionStart hook. Implements Decision Log #23 Layer 1:
# at session start, surface active crystals so the assistant can Read the
# workitem(s) for context before doing anything else.
#
# Output: JSON hookSpecificOutput with additionalContext — same shape used
# by docs-sync-reminder.sh. Silent when zero active crystals exist.
#
# Singleton invariant (Decision Log #11): exactly one active crystal at a
# time. If multiple are found, surface the violation explicitly so the user
# notices the drift rather than silently working on the wrong one.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

cat >/dev/null 2>&1 || true

active=$(find_workitems | filter_status "in-progress")
[ -z "$active" ] && exit 0

cfg_rel=$(vdm_config_read "crystal" "path" "docs/tasks")
cfg_rel="${cfg_rel%/}"
root=$(resolve_crystal_root)

count=0
lines=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  slug=$(extract_slug "$f")
  n=$(count_unchecked "$f")
  rel="${f#"$root"/}"
  ref="${cfg_rel}/${rel}"
  lines="${lines}  - ${slug}: ${n} open  (Read ${ref})\n"
done <<<"$active"

if [ "$count" -gt 1 ]; then
  header="[crystal] ⚠ Singleton violation: ${count} active workitems (should be 1).\\nResolve by switching others to status:dormant — see Decision Log #11."
else
  header="[crystal] Active workitem in this repo. Read the workitem file before continuing if it's relevant to this session:"
fi

context="${header}\n${lines}\n→ /vdm:crystal-cave for full view (sidetracks + decision log)."

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
exit 0
