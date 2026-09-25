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
#
# That contract used to be trusted, and one slip broke more than the reminder
# that slipped: git put a Cyrillic path in quotes with octal escapes, docs-sync
# pasted it in, the raw `"` made the whole section unparseable, and the harness
# dropped EVERY reminder of that turn (command-center, 2026-09-25). So the
# texts are now checked where they are handed over — here, and again by the
# dispatcher before it prints. A text that breaks the contract is delivered
# escaped and named as a defect: neither lost nor passed off as normal.

# _vdm_json_escape <text> — <text> made safe to sit between the quotes of a JSON
# string. For DATA a reminder interpolates into its text (a path, a title, a
# line of someone's file), never for the text itself, which is written escaped.
# sed/tr/awk rather than ${s//…}: how bash treats backslashes in a pattern
# replacement changed in 5.2, and this has to mean the same on 3.2 and after.
_vdm_json_escape() {
  printf '%s' "$1" \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
                   -e "s/$(printf '\t')/\\\\t/g" -e "s/$(printf '\r')/\\\\r/g" \
    | LC_ALL=C tr -d '\001-\010\013\014\016-\037\177' \
    | LC_ALL=C awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# _vdm_json_text_ok <text> — true when <text> can sit between JSON quotes as it
# is: every backslash opens a valid escape, no raw double quote, no raw control
# character (a raw newline included).
_vdm_json_text_ok() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  local rest
  rest=$(printf '%s' "$1" | LC_ALL=C sed -E 's#\\(["\\/bfnrt]|u[0-9a-fA-F]{4})##g')
  case "$rest" in *\\*|*\"*) return 1 ;; esac
  if printf '%s' "$rest" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
  return 0
}

# _vdm_reminder_text_guard <name> <text> — <text> unchanged when it keeps the
# contract; otherwise escaped, under a line that names <name> as the culprit.
_vdm_reminder_text_guard() {
  if _vdm_json_text_ok "$2"; then printf '%s' "$2"; return 0; fi
  printf "[vdm] %s: this reminder's text was not valid JSON — shown escaped below; this is a defect in the reminder.\\\\n%s" \
    "$1" "$(_vdm_json_escape "$2")"
}

# _vdm_reminder_emit <name> <tier> <short> <full>
_vdm_reminder_emit() {
  local name="$1" tier="$2" short="$3" full="$4" dir="${VDM_REMINDER_FRAGMENT:-}"
  full=$(_vdm_reminder_text_guard "$name" "$full")
  _vdm_json_text_ok "$short" || short=$(_vdm_json_escape "$short")
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    printf '%s\n%s\n%s\n' "$tier" "$short" "$full" > "$dir/$name" 2>/dev/null || true
    return 0
  fi
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$full"
}
