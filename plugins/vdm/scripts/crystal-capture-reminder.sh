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
# Throttle: per session_id, default 600s. Override via crystal.capture-throttle
# (seconds). State file at ${TMPDIR:-/tmp}/vdm-crystal-capture/<session>.
# touch'd only after emit, so the first qualifying prompt always fires.
#
# Budget: <5s. Fails open everywhere — a broken hook must never block work.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || exit 0

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
fire="no"
if [ "$mode" = "proactive" ]; then
  fire="yes"
else
  # Build find exclusions from resolved crystal roots + standard noise dirs.
  # Single-quote each glob inside the string — without that, the eval call
  # below would expand globs *before* `find` sees them, turning
  # `-not -path ./.git/*` into `-not -path ./.git/HEAD ./.git/config ...`,
  # which silently no-ops the exclusion.
  excludes=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rel="${r#"$PWD"/}"
    case "$rel" in
      /*) excludes="$excludes -not -path '$rel/*'" ;;
      *)  excludes="$excludes -not -path './$rel/*'" ;;
    esac
  done < <(resolve_crystal_roots 2>/dev/null)

  excludes="$excludes -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' -not -path './.claude/*' -not -path './.serena/*' -not -path './.obsidian/*'"

  while IFS= read -r workitem; do
    [ -n "$workitem" ] || continue
    [ -f "$workitem" ] || continue
    # eval is acceptable here: excludes string is built from path strings we
    # constructed ourselves, not from external input. find -newer is the
    # whole point — checking "anything newer than this file" in one pass.
    newer=$(eval "find . -newer \"$workitem\" -type f $excludes 2>/dev/null" | head -1)
    if [ -n "$newer" ]; then
      fire="yes"
      break
    fi
  done <<<"$active"
fi

[ "$fire" = "yes" ] || exit 0

# Throttle check. Per-session state file; only enforced in smart mode.
# proactive intentionally bypasses throttle — if the user opted into noise
# they get noise.
if [ "$mode" = "smart" ]; then
  session_id="default"
  if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
    extracted=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    [ -n "$extracted" ] && session_id="$extracted"
  fi
  throttle_seconds=$(vdm_config_read "crystal" "capture-throttle" "600")
  case "$throttle_seconds" in
    ''|*[!0-9]*) throttle_seconds=600 ;;
  esac

  state_dir="${TMPDIR:-/tmp}/vdm-crystal-capture"
  mkdir -p "$state_dir" 2>/dev/null || true
  state_file="$state_dir/$session_id"

  if [ -f "$state_file" ]; then
    last=0
    if stat -f %m "$state_file" >/dev/null 2>&1; then
      last=$(stat -f %m "$state_file" 2>/dev/null || echo 0)
    else
      last=$(stat -c %Y "$state_file" 2>/dev/null || echo 0)
    fi
    now=$(date +%s)
    delta=$((now - last))
    if [ "$delta" -lt "$throttle_seconds" ]; then
      exit 0
    fi
  fi

  # Touch state to start the throttle window from this emit.
  touch "$state_file" 2>/dev/null || true
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
