#!/bin/bash
# git-guard-stop-check.sh — Stop hook: an answer that hands the user a commit
# line or a short call is checked against the line actually waiting in this
# session and repository. One that is not — another project's, another
# session's, one already run, one from a prep that refused — is named back to
# the assistant before the user runs it, with the right line.
#
# The owner, 2026-11-17, through a project's HQ: «передай git guard он должен
# такое брать на себя полностью». Field case behind it: the prep refused twice
# (subject over the ceiling), the assistant's grep cut the refusal away, and it
# took the newest script in the shared sh/ directory — another project's
# commit — and handed it to the owner as this project's. The reminder named the
# right line at every turn; nothing compared it with what the answer said.
#
# What is compared lives in the helper, not here: `git-guard-prepare
# --check-handoff` reads the answer on stdin and knows the scope, the waiting
# line and its short call — one implementation beside --pending. This script
# only finds the answer and passes it on.
#
#   - the answer arrives as `last_assistant_message` (the transcript may not
#     hold it yet when Stop runs);
#   - silent while `stop_hook_active`: its own continuation is not checked again;
#   - most turns end at the first test: an answer naming no prep token
#     (`-commit-<epoch>-<pid>` or `<epoch>-<pid>.sh`) starts no helper.
#
# Output: additionalContext, the way crystal-grow-nudge speaks at Stop — the
# assistant receives it and the turn continues, so the correction reaches the
# user in the same turn. It cannot unsay what is already on the screen; it says
# the right line right under it.
#
# @see plugins/vdm-git/bin/git-guard-prepare (--check-handoff)
# @see docs/tasks/git-guard-line-handoff/workitem.md

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh"

# No optional-locks guard, on purpose (the name stays out of this file: the suite
# below finds guards by it): every git call on this path is a read
# that refreshes nothing — rev-parse, symbolic-ref, and in the helper merge-base
# and log — so no index is written to guard against, and
# tests/hook-index-writes.test.sh holds a guard to being needed (its RED cuts the
# line and wants a write). Its GREEN runs this hook with an answer that names a
# prep, so a refreshing call added here later is caught there.

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

IFS=$'\t' read -r active cwd sid < <(printf '%s' "$payload" \
  | jq -r '[(.stop_hook_active // false | tostring), (.cwd // ""), (.session_id // "")] | @tsv' 2>/dev/null)
[ "${active:-false}" = "true" ] && exit 0

# The project is the session's, from the payload — before its config is read.
[ -z "$cwd" ] || cd "$cwd" 2>/dev/null || exit 0
vdm_is_enabled "git-guard" || exit 0

msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)
case "$msg" in
  *-commit-[0-9]*|*[0-9]-[0-9]*.sh*) ;;
  *) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

reason=$(printf '%s' "$msg" | CLAUDE_CODE_SESSION_ID="$sid" GIT_GUARD_SYNC_CHECK=off \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../bin/git-guard-prepare" --check-handoff 2>/dev/null) && exit 0
[ -n "$reason" ] || exit 0

jq -n --arg c "[git-guard] $reason" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
exit 0
