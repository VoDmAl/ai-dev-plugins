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
# Must be cheap — it runs at the end of every turn — and silent (zero output)
# when there's nothing to report. Cheap is the script's job; the 30 s `timeout`
# in hooks.json is only a ceiling against a hang. At 5 s that ceiling dropped
# this reminder on 24 % of turns under load (hook-timeout-fail-open, 2026-10-01).

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

# Detect "work-without-capture" at end of turn — for any active workitem
# with open items, check if any source file under project root is newer than
# the workitem.md. If yes, the assistant edited code without mirroring the
# work into workitem capture; emit an extra soft hint. Same heuristic as
# crystal-capture-reminder but at end-of-turn boundary instead of next-prompt
# boundary, and with the same prune rule (vdm_crystal_walk_prunes).
#
# ONE walk, whatever the number of crystals. It used to be one `find` per
# crystal, each descending into every excluded directory: 10 s a walk on an
# 11-crystal note vault, and the hook hit its 30 s ceiling on 96 of 115 runs
# there in a week (docs/tasks/hook-timeout-fail-open, DL #9). The answer is
# unchanged — a crystal is named when some file is newer than its workitem,
# i.e. when the newest such file is. The walk lists files newer than ANY of
# them; the newest of those is kept with bash's own `-nt`, no process per file,
# and the walk stops as soon as one file is newer than every crystal, because
# then all of them are named. Fails open: a find that errors finds nothing.
# `-nt` in /bin/bash 3.2 compares whole seconds where `find -newer` compares
# nanoseconds, so "newer" here means by a second at least: a source file and a
# workitem written in the same second were edited together, and that is no
# work-without-capture.
work_without_capture=""
if [ -n "$active_with_open" ]; then
  prunes=$(vdm_crystal_walk_prunes)
  newers=""
  wi_newest=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    # A quote in the path would break out of the quoting below; such a path is
    # pathological for a workitem, and skipping it costs only its own answer.
    case "$f" in *"'"*) continue ;; esac
    newers="${newers:+$newers -o }-newer '$f'"
    if [ -z "$wi_newest" ] || [ "$f" -nt "$wi_newest" ]; then wi_newest="$f"; fi
  done <<<"$active_with_open"

  newest=""
  if [ -n "$newers" ]; then
    # eval is acceptable here: both strings are built from paths we
    # constructed ourselves, each pattern single-quoted inside.
    while IFS= read -r p; do
      if [ -z "$newest" ] || [ "$p" -nt "$newest" ]; then
        newest="$p"
        [ "$newest" -nt "$wi_newest" ] && break
      fi
    done < <(eval "find . \\( $prunes \\) -prune -o \\( $newers \\) -type f -print" 2>/dev/null)
  fi

  if [ -n "$newest" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      [ "$newest" -nt "$f" ] || continue
      slug=$(extract_slug "$f")
      if [ -z "$work_without_capture" ]; then
        work_without_capture="$slug"
      else
        work_without_capture="${work_without_capture}, ${slug}"
      fi
    done <<<"$active_with_open"
  fi
fi

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

# Work-without-capture nudge — appended only when source edits this segment
# never made it into workitem.md. Phrased as a question, not a directive,
# because the assistant may legitimately have nothing worth recording.
capture_nudge=""
if [ -n "$work_without_capture" ]; then
  capture_nudge="\\n📌 ${work_without_capture}: source edited but workitem.md untouched — decisions taken or observations worth recording? (\`## Decision Log\` / \`/vdm:crystal-bud\`)"
fi

context="${header}\\n${lines}${footer}${capture_nudge}${audit_line}"
context=$(printf '%s' "$context" | sed 's/\\n\\n*$//')

# Stop hook protocol: top-level fields only. `hookSpecificOutput` is valid for
# PreToolUse / UserPromptSubmit / PostToolUse / PostToolBatch — not Stop. Use
# `systemMessage` to inject visible context into the next turn.
printf '{\n  "systemMessage": "%s"\n}\n' "$context"
exit 0
