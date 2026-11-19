#!/bin/bash
# git-guard-stop-check.test.sh — the answer that hands off a commit line is
# checked against the line waiting in this session and repository.
#
# Field case (a project, 2026-11-17): the prep refused twice, the assistant's
# grep cut the refusal away, and it handed the owner the newest script of the
# shared sh/ directory — another project's commit. The owner: «git guard … должен
# такое брать на себя полностью» (docs/tasks/git-guard-line-handoff).
#
# No commit anywhere: every fixture has an unborn HEAD, so the suite runs
# without committing and the assistant can run it.
#
# Run: bash tests/git-guard-stop-check.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm-git/scripts/git-guard-stop-check.sh
# @see plugins/vdm-git/bin/git-guard-prepare (--check-handoff)

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM VDX_HQ CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${GIT_GUARD_STOP_CHECK:-$REPO_ROOT/plugins/vdm-git/scripts/git-guard-stop-check.sh}"
PREP="$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3 — got: ${2:0:200}" ;; esac; }
not_says() { case "$2" in *"$3"*) bad "$1" "output mentioned: $3" ;; *) ok "$1" ;; esac; }
silent()   { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: ${2:0:200}…"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq is needed for this suite"; exit 1; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gitguardstop)
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export TMPDIR="$TMP/tmp" HOME="$TMP/home"
export GIT_GUARD_STATE_DIR="$TMP/state" GIT_GUARD_SHORT_DIR="$TMP/state/sh" GIT_GUARD_SYNC_CHECK=off
mkdir -p "$TMPDIR" "$HOME"

repo() { git -C "$1" init -q 2>/dev/null || { mkdir -p "$1" && git -C "$1" init -q; }; }
# prep <repo> <session> <subject> <file> — stage the file, prepare; stdout as printed.
prep() {
  printf 'x\n' > "$1/$4"; git -C "$1" add -- "$4"
  ( cd "$1" && CLAUDE_CODE_SESSION_ID="$2" bash "$PREP" "$3" -- "$4" 2>/dev/null )
}
# stop <repo> <session> <answer> [active] — the hook's additionalContext, or nothing.
stop() {
  jq -n --arg c "$1" --arg s "$2" --arg m "$3" --argjson a "${4:-false}" \
    '{session_id: $s, cwd: $c, stop_hook_active: $a, last_assistant_message: $m}' \
    | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

echo "== the waiting line itself passes =="
A="$TMP/alpha"; mkdir -p "$A"; repo "$A"
out=$(prep "$A" s1 "[*] alpha" a.txt)
line=$(printf '%s\n' "$out" | head -1)
call=$(printf '%s\n' "$out" | sed -n 's/^# short call: //p')
[ -n "$line" ] && [ -n "$call" ] && ok "the canary: the prep printed a line and its short call" \
  || bad "the canary: the prep printed a line and its short call" "[$out]"
silent "an answer with no commit line → silent" "$(stop "$A" s1 'Done. Tests pass.')"
silent "the full line of the waiting prep → silent" "$(stop "$A" s1 "Run this: \`$line\`")"
silent "its short call → silent" "$(stop "$A" s1 "Still waiting: \`$call\`")"
tilde_call="sh ~${call#sh "$HOME"}"
silent "its short call spelled with ~ → silent" "$(stop "$A" s1 "Still waiting: \`$tilde_call\`")"

echo "== another project's line is named back, with the right one =="
B="$TMP/beta"; mkdir -p "$B"; repo "$B"
other=$(prep "$B" s9 "[*] beta" b.txt | sed -n 's/^# short call: //p')
[ -n "$other" ] && [ "$other" != "$call" ] && ok "the canary: another repository has its own short call" \
  || bad "the canary: another repository has its own short call" "[$other] vs [$call]"
out=$(stop "$A" s1 "Run: \`$other\`")
says "RED: another project's short call → named back" "$out" "not the one waiting"
says "…with the line that waits here" "$out" "[*] alpha"
says "…and its short call" "$out" "$call"
out=$(stop "$A" s1 "Run: \`${tilde_call%.sh}x.sh\` and \`$other\`")
says "RED: a foreign call among others is still found" "$out" "not the one waiting"

echo "== another session's line in the same repository =="
out=$(stop "$A" s2 "Run: \`$call\`")
says "RED: session s1's line handed off from session s2 → named back" "$out" "no line of this session waits"

echo "== a prep that refused: nothing waits, any line is named back =="
C="$TMP/gamma"; mkdir -p "$C"; repo "$C"
long=$(printf '[*] %0130d' 0)
refused=$(prep "$C" s3 "$long" c.txt)
[ -z "$refused" ] && ok "the canary: the over-long subject is refused and prints no line" \
  || bad "the canary: the over-long subject is refused and prints no line" "[$refused]"
out=$(stop "$C" s3 "Commit with: \`$other\`")
says "RED: nothing waits here and the answer hands off a line → named back" "$out" "no line of this session waits"
says "…saying the prep may have refused" "$out" "refused"
says "…and to read its whole output" "$out" "unfiltered"

echo "== where it stays silent =="
silent "its own continuation (stop_hook_active) → silent" "$(stop "$A" s1 "Run: \`$other\`" true)"
silent "outside a repository → silent" "$(stop "$TMP/home" s1 "Run: \`$other\`")"
mkdir -p "$A/.claude"; printf '{"git-guard":{"enabled":false}}\n' > "$A/.claude/vdm-plugins.json"
silent "git-guard switched off in the project → silent" "$(stop "$A" s1 "Run: \`$other\`")"
rm -f "$A/.claude/vdm-plugins.json"
not_says "a number that only looks like a token in prose → no complaint" \
  "$(stop "$A" s1 'Measured 1795122329-3720 ms on the second run.')" "not the one waiting"

echo
echo "git-guard-stop-check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
