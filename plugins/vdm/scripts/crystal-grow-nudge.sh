#!/bin/bash
# crystal-grow-nudge.sh — Stop hook: an answer that reads like a plan, from a
# session that has written into no workitem, gets one nudge per session to give
# the work a crystal before the next decision.
#
# Field case (agent machines, 2026-10-21): a question about a vulnerability grew
# into work for several days. The second answer was a five-step plan with four
# questions to the owner; the agent wrote down "a crystal is needed — I will
# create it at the implementation step"; decisions then arrived as answers to
# numbered questions. The crystal was born when the owner asked "we are working
# in a crystal, right?", and 11 decisions and 10 sidetracks were rebuilt from
# the chat. The skill knew every one of these signals, but its body is in
# context only once it is invoked; before that a session sees one line of
# description, and no hook speaks while no crystal is active.
#
# The condition is the session's, not the repository's. Of 116 crystal births
# since 2026-09-15, 8 began with the owner asking, and in all 8 the repository
# already had active crystals: "no active crystal" would have caught none of
# them (late-grow DL #3, #5).
#
# Hook protocol (Claude Code hooks reference, Stop):
#   - the answer arrives as `last_assistant_message`; the transcript may not hold
#     it yet when Stop runs, so the transcript is read only for earlier turns —
#     did this session write a workitem?
#   - the nudge goes out as `hookSpecificOutput.additionalContext`: the
#     conversation continues, so the assistant can propose the crystal itself.
#     `systemMessage` reaches only the user — 15 of 15 never reached the model
#     in one session — and would leave the word "crystal" to the owner again;
#   - silent while `stop_hook_active`: its own continuation does not ask again.
#
# Cheap: after the first nudge every turn of the session ends at the state-file
# check; before it, most turns end at the shape test. The transcript is read
# only for an answer that already reads like a plan.
#
# Off with `crystal.grow-nudge: false` (or crystal off). Silent without jq.
#
# @see docs/tasks/late-grow/workitem.md — DL #4, DL #5

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/reminder-throttle.sh" 2>/dev/null || exit 0

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
  [ "$(vdm_config_read "crystal" "grow-nudge" "true")" = "false" ] && exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

KEY="crystal-grow-nudge"
MIN_STEPS=5       # numbered steps of a plan (the skill's plan shape, signal 3)
MIN_QUESTIONS=2   # questions left to the user

# Once per session: the state file of the shared throttle exists from the first
# nudge on, and a window this long never closes within a session.
sid=$(_vdm_reminder_session_id "$payload")
_vdm_reminder_throttle_check "$KEY" 999999999 "$sid" && exit 0

IFS=$'\t' read -r active transcript < <(printf '%s' "$payload" \
  | jq -r '[(.stop_hook_active // false | tostring), (.transcript_path // "")] | @tsv' 2>/dev/null)
[ "${active:-false}" = "true" ] && exit 0

msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)
[ -n "$msg" ] || exit 0

# The shape. Lines inside a code block are an example, not a plan; a question
# mark is a question only where a sentence ends — not inside a URL.
read -r steps questions < <(printf '%s\n' "$msg" | awk '
  /^[[:space:]]*```/ { fence = !fence; next }
  fence { next }
  /^[[:space:]]*[0-9]+[.)][[:space:]]/ { s++ }
  { line = $0; q += gsub(/\?([[:space:]]|$|[)"*_`»])/, "", line) }
  END { print s + 0, q + 0 }')
[ "${steps:-0}" -ge "$MIN_STEPS" ] || [ "${questions:-0}" -ge "$MIN_QUESTIONS" ] || exit 0

# The condition: this session has not written a workitem, nor run crystal-grow.
# A transcript that is not on disk is no evidence of a write.
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  if grep -qE '"name":"(Write|Edit|MultiEdit)".*"file_path":"[^"]*/tasks/[^/"]+/workitem\.md"|"skill":"[^"]*crystal-grow' "$transcript" 2>/dev/null; then
    exit 0
  fi
fi

ctx="[crystal] This answer reads like a plan (${steps} numbered steps, ${questions} questions to the user), and this session has written into no workitem. What lives only in the chat is lost at the next compaction. If the work outlives this turn, propose a crystal now, before the next decision: /vdm:crystal-grow, named by the task rather than the current step, or record it in an active crystal (## Decision Log, /vdm:crystal-bud). If it does not, say so in one line. Asked once per session."

jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
_vdm_reminder_throttle_touch "$KEY" "$sid"
exit 0
