#!/bin/bash
# crystal-stop-reminder.sh — Stop hook: the user's status line at the end of a
# turn — the active crystals with open items. Implements the visibility leg of
# Decision Log #7 (crystal-design).
#
# Hook protocol (Claude Code): runs at the end of an assistant turn. We never
# block, never set `decision: block`. The output is `systemMessage`, and a
# systemMessage reaches the user only: in one session 15 of 15 never reached
# the model (late-grow DL #5, Sidetrack #2). So the text is written for the
# user, and nothing in it asks the assistant to act. What the assistant must
# hear goes elsewhere: the session start (crystal-hydrate) and every user
# prompt (crystal-capture-reminder, which also asks whether source edits made
# it into the workitem — this hook used to ask the same, of no one, and walked
# the whole tree each turn to do it; late-grow DL #7).
#
# Output formats follow crystal-multi-root DL #13:
#   single-root: flat list with paths
#   multi-root:  group-by-root summary (slug only, fewer chars per row)
# Audit line appended when non-canonical drift detected.
#
# Must be cheap — it runs at the end of every turn — and silent (zero output)
# when there's nothing to report. The 30 s `timeout` in hooks.json is only a
# ceiling against a hang (hook-timeout-fail-open, 2026-10-01).

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
    # The path as it stands from the project root, where the roots were found.
    # It was `crystal.path` (default docs/tasks) plus the path under the root,
    # and a project whose crystals live in tasks/ was told to Read a file under
    # docs/tasks/ that does not exist (late-grow, 2026-10-25).
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd -P)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n=$(count_unchecked "$f")
      slug=$(extract_slug "$f")
      ref="${f#"$top"/}"
      lines="${lines}  - ${slug}: ${n} open  (${ref})\\n"
    done <<<"$active_with_open"
  else
    summary=$(printf '%s\n' "$active_with_open" | format_active_summary)
    lines=$(printf '%s\n' "$summary" | awk '{ printf "%s\\n", $0 }')
  fi
fi

# Header
if [ -n "$lines" ]; then
  header="[crystal] Active crystals with open items:"
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
  footer="\\n→ /vdm:crystal-cave for the full view; /vdm:crystal-cut <slug> to close one."
fi

context="${header}\\n${lines}${footer}${audit_line}"
context=$(printf '%s' "$context" | sed 's/\\n\\n*$//')

# `systemMessage` is shown to the user, not given to the model: see the header.
# The model's channel at Stop is `hookSpecificOutput.additionalContext`
# (crystal-grow-nudge uses it), but it continues the conversation — here that
# would be one more turn after every turn while a crystal is active.
printf '{\n  "systemMessage": "%s"\n}\n' "$context"
exit 0
