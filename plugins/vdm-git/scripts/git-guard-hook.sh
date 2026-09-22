#!/bin/bash
# git-guard-hook.sh — the PreToolUse entry point for the git guard.
#
# The guard itself is `git-guard-hook.py`, and it was registered directly as
# `python3 .../git-guard-hook.py`. That made the *interpreter* part of the
# gate's trust chain without anything watching it: with `python3` absent the
# hook exits 127, and the harness blocks only on 2 — so `git commit` and
# `git push` sailed through on exactly the machines least likely to notice.
# Measured 2026-09-21 alongside the same defect in three other hooks; see
# lib/gate-guard.sh for the law and the field report behind it.
#
# This wrapper keeps the guard fail-closed:
#
#   python3 present, guard reaches a verdict  → 0 (allow) or 2 (block), verbatim
#   python3 missing / guard crashes / no file → block IF the raw payload looks
#                                               like a git commit or push,
#                                               otherwise stay out of the way
#
# The "looks like" test is a grep over the raw payload, so it needs nothing
# that could itself be missing. It is approximate by construction: in a shell
# without python3 a command that merely mentions committing may be refused.
# That is the correct direction to be wrong in — the alternative is a guard
# that silently is not there.
#
# Hook protocol (Claude Code):
#   stdin   JSON {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
#   exit 0  allow
#   exit 2  block; stderr is returned to the assistant as feedback

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

GUARD="$SELF_DIR/git-guard-hook.py"

payload=$(cat)
[ -z "$payload" ] && exit 0

guard_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE 'git[^"]{0,200}(commit|push)' 2>/dev/null || return 1
  return 0
}

guard_unverified() {
  guard_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "git-guard" "$1" \
      "a command that looks like \`git commit\` or \`git push\` — whether the guard would have allowed it was never decided" \
      "install python3 — the guard is a python script — and try again, or" \
      "if this command is not a commit or a push, run it in a form that does not mention them"
  else
    printf '\n[git-guard] NOT CHECKED — %s\n  A commit/push-shaped command arrived and the guard could not run.\n\n' "$1" >&2
  fi
  exit 2
}

command -v python3 >/dev/null 2>&1 || guard_unverified "python3 is not on PATH"
[ -f "$GUARD" ] || guard_unverified "guard not found at $GUARD"

printf '%s' "$payload" | python3 "$GUARD"
rc=$?

# The guard returns 0 (allow) or 2 (block). Anything else — a crash, an invalid
# payload it refused to parse, a killed process — is not a verdict.
case "$rc" in
  0|2) exit "$rc" ;;
  *)   guard_unverified "the guard exited $rc without reaching a verdict" ;;
esac
