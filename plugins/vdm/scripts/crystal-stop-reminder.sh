#!/bin/bash
# crystal-stop-reminder.sh — Stop hook, silent reminder about active crystals
# with open items. Implements the visibility leg of Decision Log #7.
#
# Hook protocol (Claude Code): runs at the end of an assistant turn. Output
# is informational — we never block, never set `decision: block`. The reminder
# is here to defend against context pressure: if assistant forgets about an
# active workitem, this surfaces it once per turn.
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

active=$(find_workitems | filter_status "in-progress")
[ -z "$active" ] && exit 0

# Build a one-line-per-crystal summary. Only crystals with `- [ ]` items get
# surfaced — fully-checked-but-still-in-progress workitems are a normal
# intermediate state (e.g. user paused before flipping status:done).
lines=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$(count_unchecked "$f")
  [ "${n:-0}" -gt 0 ] || continue
  slug=$(extract_slug "$f")
  root=$(resolve_crystal_root)
  rel="${f#"$root"/}"
  case "$rel" in
    */workitem.md) ref="docs/tasks/$rel" ;;
    *)             ref="docs/tasks/$rel" ;;
  esac
  # Use the configured crystal root prefix, not a hardcoded "docs/tasks/".
  cfg_rel=$(vdm_config_read "crystal" "path" "docs/tasks")
  ref="${cfg_rel%/}/$rel"
  lines="${lines}  - ${slug}: ${n} unchecked  (${ref})\n"
done <<<"$active"

[ -z "$lines" ] && exit 0

# Emit a JSON hook-specific output the same way other vdm hooks do
# (UserPromptSubmit / SessionStart accept this shape; for Stop the harness
# treats it as advisory context attached to the turn).
context="[crystal] Active workitems with open items — finish or migrate before declaring done:\n${lines}\n→ /vdm:crystal-cave for full view; /vdm:crystal-cut <slug> to close."

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "Stop",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
exit 0
