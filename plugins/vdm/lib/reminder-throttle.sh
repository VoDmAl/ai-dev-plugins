#!/bin/bash
# reminder-throttle.sh — shared throttle + session-id helpers used by the
# UserPromptSubmit reminder hooks (learn, changelog, docs-sync,
# crystal-capture). Mechanical per-prompt reminders cost ~500 chars × N
# turns of context budget for zero marginal value once a discipline is
# internalised, so the standard pattern is: smart-trigger AND throttle.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/reminder-throttle.sh.
# Drift is caught by scripts/check-lib-sync.sh in .githooks/pre-commit; any change
# here MUST be applied to the vdm-git copy in the same commit.
#
# All functions fail open — a broken helper must never break the hook
# pipeline. Worst case: the reminder fires more often than intended.

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

# _vdm_reminder_throttle_check <key> <seconds> [session_id]
# Returns 0 if the caller IS throttled (should exit silently),
#         1 if the caller is NOT throttled (proceed with emit).
# Reads mtime of "${TMPDIR:-/tmp}/vdm-reminder-throttle/<key>-<sid>"; if the
# file is newer than <seconds> ago, the caller is still in its throttle
# window. mtime check uses stat -f (BSD/macOS) with stat -c fallback (GNU).
_vdm_reminder_throttle_check() {
  local key="$1" seconds="$2" sid="${3:-default}"
  case "$seconds" in
    ''|*[!0-9]*) seconds=600 ;;
  esac
  local state_dir="${TMPDIR:-/tmp}/vdm-reminder-throttle"
  local state_file="$state_dir/${key}-${sid}"
  [ -f "$state_file" ] || return 1
  local last=0
  if stat -f %m "$state_file" >/dev/null 2>&1; then
    last=$(stat -f %m "$state_file" 2>/dev/null || echo 0)
  else
    last=$(stat -c %Y "$state_file" 2>/dev/null || echo 0)
  fi
  local now
  now=$(date +%s)
  local delta=$((now - last))
  if [ "$delta" -lt "$seconds" ]; then
    return 0
  fi
  return 1
}

# _vdm_reminder_throttle_touch <key> [session_id]
# Resets the throttle window — call after a successful emit so the next
# check fires `<seconds>` from now, not from the previous emit.
_vdm_reminder_throttle_touch() {
  local key="$1" sid="${2:-default}"
  local state_dir="${TMPDIR:-/tmp}/vdm-reminder-throttle"
  mkdir -p "$state_dir" 2>/dev/null || true
  touch "$state_dir/${key}-${sid}" 2>/dev/null || true
}
