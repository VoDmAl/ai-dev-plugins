#!/bin/bash
# reminder-emit.sh — the one place a vdm UserPromptSubmit reminder hands over
# what it has to say.
#
# Single-copy lib file on purpose: only the vdm reminders sing in the chorus
# that scripts/reminders.sh conducts. git-guard lives in vdm-git, is installed
# separately, and speaks on its own.
#
# Two modes, chosen by the caller's environment, never by the reminder:
#
#   direct   (VDM_REMINDER_FRAGMENT unset) — print the hook JSON with the full
#            text, exactly as each reminder did before the dispatcher existed.
#            Tests and manual runs keep working unchanged.
#
#   fragment (VDM_REMINDER_FRAGMENT=<dir>) — write <dir>/<name> and print
#            nothing. The dispatcher runs every reminder in parallel and then
#            composes ONE section out of the fragments.
#
# Why a file per reminder rather than stdout: the reminders run concurrently,
# and interleaved writes to one pipe would splice one reminder's text into
# another's. A file per name cannot collide.
#
# Fragment format, three lines:
#   1  tier   — 1: carries a measurement of THIS turn's state (what changed,
#                  what drifted, what is waiting). 2: a standing habit prompt
#                  that says the same thing every time.
#   2  short  — one line; used when the reminder is not alone and is tier 2
#   3  full   — the text the reminder would print on its own
# Both texts are already JSON-escaped (literal \n, never a raw newline) — they
# are the same strings the direct mode embeds.

# _vdm_reminder_emit <name> <tier> <short> <full>
_vdm_reminder_emit() {
  local name="$1" tier="$2" short="$3" full="$4" dir="${VDM_REMINDER_FRAGMENT:-}"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    printf '%s\n%s\n%s\n' "$tier" "$short" "$full" > "$dir/$name" 2>/dev/null || true
    return 0
  fi
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$full"
}
