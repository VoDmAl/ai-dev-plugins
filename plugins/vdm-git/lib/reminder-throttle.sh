#!/bin/bash
# reminder-throttle.sh — shared throttle + session-id helpers used by the
# UserPromptSubmit reminder hooks (learn, changelog, docs-sync,
# crystal-capture, git-guard). Mechanical per-prompt reminders cost ~500 chars
# × N turns of context budget for zero marginal value once a discipline is
# internalised, so the standard pattern is: smart-trigger AND throttle.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm/lib/reminder-throttle.sh.
# Drift is caught by scripts/check-lib-sync.sh in .githooks/pre-commit; any change
# here MUST be applied to the vdm copy in the same commit.
#
# All functions fail open — a broken helper must never break the hook
# pipeline. Worst case: the reminder fires more often than intended.
#
# ---------------------------------------------------------------------------
# TWO AXES, AND WHY THE SECOND ONE HAD TO BE ADDED
#
# Until 2026-09-22 the window was wall-clock only: "silent for N seconds after
# an emit". Measured in the field (t23b-content, vdm 2.25.0, six hooks, 4500
# bytes of additionalContext on a cold window): a person who spends longer than
# the window thinking about each prompt clears it on EVERY turn, so the hook
# fires on every turn — the reported "ignored 12 turns in a row". The reminders
# were not wrong about their subject; they were counting the wrong thing.
#
# Noise is not measured in seconds. It is measured in TURNS: the same text
# arriving on consecutive prompts becomes furniture no matter how long the
# pauses between them were.
#
# So there are now two windows, and an emit needs BOTH to have elapsed:
#
#   seconds — don't repeat myself within a short wall-clock window
#   turns   — don't repeat myself within the next N prompts
#
# Either one alone has a profile it fails on, and "stricter wins" is what makes
# the pair safe to add without touching anybody's configuration: a value that
# used to mean seconds still means seconds, and the turn budget is additive.
# The seconds axis is the one a user has already tuned; the turn axis is the
# one that was missing.
#
# State is one file per (key, session): its CONTENT is "<last-emit-epoch>
# <turns-since-emit>". Content rather than mtime, because the counter has to be
# written on every check and that would keep resetting an mtime-based clock —
# the two axes would then measure the same thing badly. A file left over from
# the mtime era parses as "no timestamp, no count" and is simply re-seeded.
# ---------------------------------------------------------------------------

# Read JSON payload (from $1 if supplied, else stdin) and extract session_id.
# Falls back to "default" when jq is unavailable, payload is missing, or the
# field is absent. Used to key throttle state per-session so concurrent
# sessions don't shadow each other.
_vdm_reminder_session_id() {
  local payload="${1:-}"
  if [ -z "$payload" ]; then
    payload=$(cat 2>/dev/null || true)
  fi
  if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
    local sid
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -n "$sid" ]; then
      printf '%s' "$sid"
      return 0
    fi
  fi
  printf 'default'
}

_vdm_reminder_state_file() {
  local key="$1" sid="${2:-default}"
  printf '%s/vdm-reminder-throttle/%s-%s' "${TMPDIR:-/tmp}" "$key" "$sid"
}

# _vdm_reminder_throttle_check <key> <seconds> [session_id] [turns]
# Returns 0 if the caller IS throttled (should exit silently),
#         1 if the caller is NOT throttled (proceed with emit).
#
# Counts this invocation as one turn whether or not it ends up emitting: the
# unit is "prompts on which I could have spoken", which is what the reader
# experiences. <turns> is optional — omitted, only the wall-clock axis applies
# and the behaviour is exactly what it was before this axis existed.
_vdm_reminder_throttle_check() {
  local key="$1" seconds="$2" sid="${3:-default}" turns="${4:-}"
  case "$seconds" in
    ''|*[!0-9]*) seconds=600 ;;
  esac
  case "$turns" in
    *[!0-9]*) turns="" ;;
  esac

  local state_file last=0 count=0 raw=""
  state_file="$(_vdm_reminder_state_file "$key" "$sid")"
  [ -f "$state_file" ] || return 1

  raw=$(cat "$state_file" 2>/dev/null || true)
  case "$raw" in
    # "<epoch> <count>" — both fields required. A single number is not a
    # half-written record to salvage, it is a shape this helper never wrote.
    [0-9]*' '[0-9]*)
      last=${raw%% *}
      count=${raw#* }
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      ;;
    *)
      # Pre-2.31 state file: empty, the timestamp was its mtime. Read it once
      # so an upgrade mid-session does not hand out a free emit.
      if stat -f %m "$state_file" >/dev/null 2>&1; then
        last=$(stat -f %m "$state_file" 2>/dev/null || echo 0)
      else
        last=$(stat -c %Y "$state_file" 2>/dev/null || echo 0)
      fi
      count=0
      ;;
  esac

  count=$((count + 1))
  printf '%s %s\n' "$last" "$count" > "$state_file" 2>/dev/null || true

  local now delta
  now=$(date +%s)
  delta=$((now - last))
  [ "$delta" -lt "$seconds" ] && return 0
  if [ -n "$turns" ] && [ "$count" -lt "$turns" ]; then
    return 0
  fi
  return 1
}

# _vdm_reminder_throttle_touch <key> [session_id]
# Resets both windows — call after a successful emit so the next check counts
# from here, not from the previous emit.
_vdm_reminder_throttle_touch() {
  local key="$1" sid="${2:-default}" state_dir state_file
  state_dir="${TMPDIR:-/tmp}/vdm-reminder-throttle"
  mkdir -p "$state_dir" 2>/dev/null || true
  state_file="$(_vdm_reminder_state_file "$key" "$sid")"
  printf '%s 0\n' "$(date +%s)" > "$state_file" 2>/dev/null || true
}
