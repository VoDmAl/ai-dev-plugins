#!/bin/bash
# intercom reminder — receiver-side "you have pending messages" nudge.
#
# Two parts. ARRIVALS, on by default: a letter that came in while this session
# was open is named once, in the context of the owner's next message — the
# sender did not wake the session because the owner may be at it
# (docs/tasks/intercom-wake-timing, DL #3; see the section below). The general
# REMINDER, everything after that section, stays as it was:
#
# OFF BY DEFAULT (DL #10). Auto-watching for incoming mail is the wrong model:
# a message arriving mid-session is almost always meant for a NEW session, and a
# "you have mail" nudge interrupts active work. Checking is an explicit action
# (`/vdm:intercom check`); opt into the reminder with `/vdm:intercom on`.
#
# Behavior once enabled, governed by .claude/vdm-plugins.json → intercom:
#   enabled=false (default) → never fires
#   mode=silent             → never fires
#   mode=conditional|quiet  → fires whenever the inbox is non-empty (no throttle)
#   mode=smart              → fires when inbox non-empty AND throttle window elapsed
#   mode=proactive          → fires every prompt while inbox non-empty (no throttle)
# Default (no config): enabled=false; when enabled, mode=smart.
#
# The store is a machine-level mailbox OUTSIDE all repos; "inbox" = this repo's
# canonical-identity dir under the store (DL #1, #4). The reminder is inherently
# low-noise: it stays silent whenever the inbox is empty, regardless of mode.
#
# Throttle window: intercom.throttle (seconds), default 600 (10 min). Per-session
# state under ${TMPDIR:-/tmp}/vdm-reminder-throttle/intercom-<session_id>.
# Not mirrored to vdm-git — intercom ships in the vdm plugin only.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-throttle.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/intercom-common.sh" 2>/dev/null || true

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/reminder-emit.sh" 2>/dev/null \
  || _vdm_reminder_emit() { printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$4"; }
command -v _vdm_json_escape >/dev/null 2>&1 \
  || _vdm_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

payload=$(cat 2>/dev/null || true)

# intercom-common must be present to know the inbox; fail open (silent) if not.
command -v intercom_inbox_count >/dev/null 2>&1 || exit 0

# ---------------------------------------------------------------------------
# Arrivals — ON BY DEFAULT, unlike the reminder further down
# (docs/tasks/intercom-wake-timing, DL #3). A sender no longer wakes a session
# the owner may be at — idle under INTERCOM_WAKE_QUIET_MIN, busy, waiting on a
# question — and such a letter must not lie until the next session. It reaches
# the session here instead: as context of the owner's next message, with no
# turn of its own. Only letters that arrived after this session started (the
# ones before it were named by the session-start line), each once per session,
# and none that a session has taken. `intercom.arrival-line: false` turns it off.
# ---------------------------------------------------------------------------

# _ic_arrivals <identity> <session id> — one "`<file>` from `<sender>` — <title>"
# line per letter that arrived during this session and was not named in it
# yet; each one printed is recorded as named. The session's start comes from
# the harness's own session file; no file, no verdict, nothing printed.
_ic_arrivals() {
  local id="$1" sid="$2" sdir sfile started seen f base created epoch title
  case "$sid" in ''|default) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  sdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  sfile="$(grep -l -F "\"$sid\"" "$sdir"/*.json 2>/dev/null | grep -v '\.sync-conflict-' | head -1)"
  [ -n "$sfile" ] || return 0
  started="$(jq -r '.startedAt // empty' "$sfile" 2>/dev/null)"
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  started=$((started / 1000))
  # Every letter is looked at once per session, named or not: this runs on
  # every message the owner sends, and an inbox of old letters would otherwise
  # cost a few processes per letter on each of them.
  seen="${TMPDIR:-/tmp}/vdm-intercom-arrivals/$sid"
  local known=""
  [ -f "$seen" ] && known="$(cat "$seen" 2>/dev/null)"
  mkdir -p "${seen%/*}" 2>/dev/null
  while IFS= read -r f; do
    base="${f##*/}"; base="${base%.md}"
    case $'\n'"$known"$'\n' in *$'\n'"$base"$'\n'*) continue ;; esac
    printf '%s\n' "$base" >> "$seen" 2>/dev/null
    [ -z "$(intercom_fm_field "$f" taken)" ] || continue
    created="$(intercom_fm_field "$f" created)"
    epoch="$(_intercom_epoch_utc "$created")"
    [ -n "$epoch" ] && [ "$epoch" -ge "$started" ] || continue
    title="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')"
    printf '`%s` from `%s` — %s\n' "$base" "$(intercom_fm_field "$f" from)" "${title:-$base}"
  done < <(intercom_inbox_list "$id")
}

arrival_on="$(vdm_config_read intercom arrival-line true)"
enabled="$(vdm_config_read intercom enabled false)"
[ "$arrival_on" = "true" ] || [ "$enabled" = "true" ] || exit 0

id="$(intercom_identity 2>/dev/null)"
count="$(intercom_inbox_count "$id" 2>/dev/null)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# Receiver-side condition: only ever fire when the inbox is non-empty.
[ "$count" -gt 0 ] || exit 0
# A focused session is not called to its inbox (intercom-common.sh → "Focused sessions").
intercom_focused && exit 0

sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')

if [ "$arrival_on" = "true" ]; then
  arrived="$(_ic_arrivals "$id" "$sid")"
  if [ -n "$arrived" ]; then
    n="$(printf '%s\n' "$arrived" | wc -l | tr -d ' ')"
    list="$(printf '%s\n' "$arrived" | sed 's/^/- /')"
    msg="[intercom] 📬 Arrived while the user was in this session — not urgent, and no turn of its own:\n$(_vdm_json_escape "$list")\nAnswer the user's message first. At the end, one line that it waits (/vdm:intercom check); retell nothing else — the user's open steps are still on their screen."
    _vdm_reminder_emit intercom 1 "📬 intercom: ${n} arrived during this session → /vdm:intercom check" "$msg"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# The general reminder — OFF BY DEFAULT (opt-in): read enabled with default
# "false", not vdm_is_enabled (which defaults true). See header — auto-watching
# is off by design.
# ---------------------------------------------------------------------------
[ "$enabled" = "true" ] || exit 0
mode=$(vdm_get_mode "intercom" "smart")
[ "$mode" = "silent" ] && exit 0

case "$mode" in
  conditional|quiet) ;;   # fire, no throttle
  proactive)         ;;   # fire, no throttle
  smart|*)
    throttle=$(vdm_config_read "intercom" "throttle" "600")
    if command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
      if _vdm_reminder_throttle_check "intercom" "$throttle" "$sid"; then
        exit 0
      fi
      _vdm_reminder_throttle_touch "intercom" "$sid"
    fi
    ;;
esac

# JSON-escape the identity (backslash + double-quote) for safe embedding.
id_esc=$(printf '%s' "$id" | sed 's/\\/\\\\/g; s/"/\\"/g')

msg="[intercom] 📬 ${count} pending message(s) for \`${id_esc}\` — not urgent: the user's pending steps come first.\n- Review: /vdm:intercom check\n- Pick up: /vdm:intercom pickup <slug>  (add --grow to promote into a workitem)"

_vdm_reminder_emit intercom 1 \
  "📬 intercom: ${count} pending → /vdm:intercom check" "$msg"
