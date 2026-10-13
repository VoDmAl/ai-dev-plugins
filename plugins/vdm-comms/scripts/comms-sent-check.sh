#!/bin/bash
# comms-sent-check.sh — PostToolUse (Bash): an outgoing letter that a shell
# command left marked sent without proof.
#
# The draft guard (comms-draft-guard.sh) holds Write, Edit and MultiEdit before
# they run. The shell it cannot hold: what `sed -i`, a python `replace` or
# `cat > …-out.md` will leave on disk is not in the command's text. And the shell
# is how letters are mostly marked sent — 322 Bash calls against 163 Write and
# Edit on this machine's transcripts, September–October 2026 (crystal
# `outgoing-ladder`, DL #6). So this hook looks after the command: every
# `*/comms/*-out.md` that differs from HEAD or is not committed yet, and that is
# sent without `sent-proof:` while HEAD does not have it sent, is named back to
# the assistant. The comparison lives in comms_sent_proof.py.
#
# Run after the fact, it cannot stop the write; it stops the next step — the
# report that the letter went out — while the file is still on disk to fix.
#
# Exit: 0 nothing to say / 2 named (stderr returns to the assistant as feedback).
# Fail-closed when it cannot run on a command that could have touched a letter —
# see lib/gate-guard.sh.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "comms" || exit 0
fi

payload=$(cat)
[ -z "$payload" ] && exit 0

# Dependency-free fast path, without a process: a call whose payload names no
# letter and writes no `sent:` is not ours. That is nearly every Bash call.
case "$payload" in
  *comms*|*-out.md*|*sent:*) ;;
  *) exit 0 ;;
esac

check_unverified() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' 2>/dev/null || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "comms-sent-check" "$1" \
      "a shell command that could have touched an outgoing letter ran — whether it left one marked sent without proof was never checked" \
      "install python3 so the hook can compare the letters with HEAD, or" \
      "check by hand: an outgoing letter not sent in HEAD carries \`sent:\` only with \`sent-proof:\` beside it"
  else
    printf '\n[comms-sent-check] NOT CHECKED — %s\n  A shell command that could have touched an outgoing letter ran, and the check could not.\n\n' "$1" >&2
  fi
  exit 2
}

SENT_PROOF="$SELF_DIR/comms_sent_proof.py"
command -v python3 >/dev/null 2>&1 || check_unverified "python3 is needed to compare the letters with HEAD"
[ -f "$SENT_PROOF" ] || check_unverified "comms_sent_proof.py is missing next to the hook"

printf '%s' "$payload" | python3 "$SENT_PROOF"
rc=$?
case "$rc" in
  0) exit 0 ;;
  2) exit 2 ;;
  *) check_unverified "the check ended without a verdict (exit $rc)" ;;
esac
