#!/bin/bash
# crystal-capture-reminder.sh — UserPromptSubmit hook. In-flight discipline:
# when an active workitem exists, remind the assistant to capture decisions
# to `## Decision Log` and observations as sidetracks. Counterpart to the
# terminal-discipline hooks (crystal-hydrate at start, crystal-stop-reminder
# at end, crystal-completion-guard at done-transition).
#
# Smart by design — does not fire on every prompt. Mechanical reminders cost
# ~500 chars × N turns of context budget for zero marginal value once the
# discipline is internalised. This hook fires only when a real
# "work-happening-without-capture" gap is detected, with a per-session
# throttle on top.
#
# Modes (vdm-plugins.json → crystal.capture-mode):
#   silent     — never fires
#   smart      — fires when (active workitem exists) AND (source files newer
#                than the workitem.md exist) AND (throttle window elapsed).
#                Default.
#   proactive  — fires every prompt while an active workitem exists. Use
#                when onboarding or when the user wants maximum noise.
#
# Scan cost: crystal.capture-exclude (array of project-relative paths) prunes
# subtrees that are content rather than source. Empty by default.
#
# Throttle: per session_id, default 600s. Override via crystal.capture-throttle
# (seconds). State lives with the shared helper (lib/reminder-throttle.sh):
# ${TMPDIR:-/tmp}/vdm-reminder-throttle/crystal-capture-<session>, touch'd
# only after emit, so the first qualifying prompt always fires. The window is
# checked *before* the scan, so prompts inside it cost nothing.
#
# Budget: <5s by design; the 15s in hooks.json is margin for a cold page cache,
# not licence. Fails open everywhere — a broken hook must never block work.
#
# Tests: tests/crystal-capture-reminder.test.sh

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

# Capture the payload — UserPromptSubmit delivers JSON on stdin with
# session_id we need for the throttle key. Read once, fall back to "default"
# session if jq/payload missing (throttle still works, just shared across
# concurrent sessions — acceptable degraded mode).
payload=""
payload=$(cat 2>/dev/null || true)

mode=$(vdm_config_read "crystal" "capture-mode" "smart")
[ "$mode" = "silent" ] && exit 0

# Find active workitems. Silent if none — no crystal, no in-flight discipline
# to remind about.
all_items=$(find_workitems 2>/dev/null)
[ -z "$all_items" ] && exit 0
active=$(printf '%s\n' "$all_items" | filter_status "in-progress" 2>/dev/null)
[ -z "$active" ] && exit 0

# Smart mode: only fire when there's work-without-capture evidence.
# Heuristic: at least one source file under project root is newer than at
# least one active workitem.md. Excludes git internals, dependency dirs,
# all resolved crystal roots (the workitem itself sits under one of those),
# and assistant-state dirs (.claude, .serena).
#
# Why source-newer-than-workitem: it directly models "you've been editing
# code but haven't touched the workitem capture". If both are stale, the
# session is dormant and noise would be counterproductive. If both are
# fresh, capture is already in flight — also no signal needed.
# Throttle gate — checked BEFORE the scan, not after. The scan is the expensive
# part (a tree walk per active workitem); running it on every prompt only to
# discard the result inside the throttle window is pure waste, and on a
# content-heavy repo it overran the hook's own time budget, so the harness
# killed the hook and discarded its output. Order is now: cheap gate →
# expensive evidence → emit.
# proactive intentionally bypasses the throttle — if the user opted into noise
# they get noise.
sid="default"
if [ "$mode" = "smart" ] && command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
  sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
  throttle=$(vdm_config_read "crystal" "capture-throttle" "600")
  if _vdm_reminder_throttle_check "crystal-capture" "$throttle" "$sid"; then
    exit 0
  fi
fi

fire="no"
if [ "$mode" = "proactive" ]; then
  fire="yes"
else
  # Build the find prune list from resolved crystal roots + standard noise
  # dirs. `-prune` rather than `-not -path`: the latter still descends into
  # every excluded directory and stats every file inside it, the former skips
  # the subtree outright. Measured on a 35k-note vault: 3.2s -> 0.4s per pass.
  # Single-quote each glob inside the string — without that, the eval call
  # below would expand globs *before* `find` sees them, silently no-opping the
  # exclusion.
  prunes=""
  _add_prune() {
    if [ -z "$prunes" ]; then prunes="$1"; else prunes="$prunes -o $1"; fi
  }
  # Roots come back as PHYSICAL paths (git resolves symlinks for the toplevel)
  # while $PWD may be the logical one — on macOS /tmp and /var are symlinks
  # into /private. Strip against both; otherwise the prune never matches, the
  # crystal root is scanned like source, and every sibling file under tasks/
  # counts as "evidence".
  pwd_phys=$(pwd -P 2>/dev/null) || pwd_phys="$PWD"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rel="${r#"$pwd_phys"/}"
    if [ "$rel" = "$r" ]; then rel="${r#"$PWD"/}"; fi
    case "$rel" in
      /*) _add_prune "-path '$rel'" ;;
      *)  _add_prune "-path './$rel'" ;;
    esac
  done < <(resolve_crystal_roots 2>/dev/null)

  # Noise dirs matched by name, so nested copies are pruned too.
  for n in .git node_modules vendor .claude .serena .obsidian; do
    _add_prune "-name '$n'"
  done

  # Project-declared exclusions (crystal.capture-exclude, array of paths
  # relative to the project root). The standard noise list covers tooling
  # dirs; a content-heavy repo — a note vault, a media archive, a dataset —
  # carries tens of thousands of files that are content, not source, and
  # walking them is the whole cost of this hook. Absent config = scan
  # everything, which is the right default for a code repo.
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    x="${x#./}"
    x="${x%/}"
    case "$x" in
      *"'"*) continue ;;
      /*) _add_prune "-path '$x'" ;;
      *)  _add_prune "-path './$x'" ;;
    esac
  done < <(vdm_config_read_array "crystal" "capture-exclude" 2>/dev/null)

  while IFS= read -r workitem; do
    [ -n "$workitem" ] || continue
    [ -f "$workitem" ] || continue
    # eval is acceptable here: the prune string is built from path strings we
    # constructed ourselves, not from external input. find -newer is the
    # whole point — checking "anything newer than this file" in one pass.
    newer=$(eval "find . \\( $prunes \\) -prune -o -newer '$workitem' -type f -print" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
      fire="yes"
      break
    fi
  done <<<"$active"
fi

[ "$fire" = "yes" ] || exit 0

# Reset the throttle window now that we know we are emitting.
if [ "$mode" = "smart" ] && command -v _vdm_reminder_throttle_touch >/dev/null 2>&1; then
  _vdm_reminder_throttle_touch "crystal-capture" "$sid"
fi

# Render the reminder. Brief — every char costs context. List active slugs
# inline so the assistant knows WHICH file is the capture target without
# having to re-resolve.
slugs=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  s=$(extract_slug "$f" 2>/dev/null)
  [ -n "$s" ] || continue
  if [ -z "$slugs" ]; then
    slugs="$s"
  else
    slugs="$slugs, $s"
  fi
done <<<"$active"

ctx="[crystal] Active: ${slugs} — workitem.md = source of truth (chat decays under compaction)."
ctx="${ctx}\\n📌 Work happened this segment without workitem capture. Before next compaction, mirror:"
ctx="${ctx}\\n  • Decision taken (chose X over Y, raised a threshold, deviated from plan, user-confirmed non-obvious choice)? → append to \`## Decision Log\`"
ctx="${ctx}\\n  • Observation / ecosystem block / follow-up / implicit dep? → /vdm:crystal-bud"
ctx="${ctx}\\n  • Resolved a Next-action item? → flip \`- [ ]\` → \`[x]\` in workitem.md"

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$ctx"
exit 0
