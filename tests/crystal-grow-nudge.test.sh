#!/bin/bash
# crystal-grow-nudge.test.sh — the Stop hook that asks a session for a crystal
# when its answer reads like a plan and it has written into no workitem.
#
# Field case (agent machines, 2026-10-21): a question about a vulnerability grew
# into work for several days — a five-step plan, four questions to the owner,
# decisions arriving as "1. Yes 2. … 4. OK" — and the crystal was born only when
# the owner asked "we are working in a crystal, right?". 11 decisions and 10
# sidetracks were then rebuilt from the chat. Measured afterwards: of 116 crystal
# births since 2026-09-15, 8 began with the owner asking, every one of them in a
# repository that already had active crystals — so the condition is the
# session's ("wrote no workitem"), not the repository's (late-grow DL #3, #5).
#
# What this file holds:
#   - the shape: ≥5 numbered steps or ≥2 questions, code blocks not counted;
#   - the condition: a session that already wrote a workitem, or ran
#     crystal-grow, is not asked;
#   - once per session, silent while the hook itself keeps the turn going;
#   - the channel: additionalContext for the Stop event, never systemMessage,
#     which reaches only the user.
#
# Run: bash tests/crystal-grow-nudge.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: as a child of a live `git
# commit` the inherited GIT_INDEX_FILE would point the fixture's `git add` at
# that commit's index (tests/gates.test.sh, 2026-09-03), and the session's
# author and editor are not this file's either.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

# Nor the machine's git config: git 2.54 runs a hook declared there
# (`hook.<name>.command`) on every commit, a fixture's included — the case is
# in tests/gates.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${CRYSTAL_GROW_NUDGE:-$REPO_ROOT/plugins/vdm/scripts/crystal-grow-nudge.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'crystal-grow-nudge tests need jq — skipping (0 assertions).\n'
  exit 0
fi
# Half the cases below expect silence, and a hook that is not there is silent
# too: without this line they would pass against nothing.
if [ ! -f "$HOOK" ]; then
  printf '  ✗ no hook at %s — the silence cases would pass against nothing\n\n0 passed, 1 failed\n' "$HOOK"
  exit 1
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t grownudge)
TMP=$(cd "$TMP" && pwd -P)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The once-per-session state lives under TMPDIR (lib/reminder-throttle.sh).
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude"
( cd "$PROJ" && git init -q )

TR_CLEAN="$TMP/clean.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"what do we do"}}' > "$TR_CLEAN"
TR_WROTE="$TMP/wrote.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/x/docs/tasks/foo/workitem.md","content":"..."}}]}}' > "$TR_WROTE"
TR_EDITED="$TMP/edited.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/x/tasks/bar/workitem.md","old_string":"a","new_string":"b"}}]}}' > "$TR_EDITED"
TR_GREW="$TMP/grew.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Skill","input":{"skill":"vdm:crystal-grow","args":"foo"}}]}}' > "$TR_GREW"

PLAN=$'Here is the plan:\n\n1. Update the servers\n2. Pause the containers\n3. Move the service\n4. Write to both agents\n5. Verify the backup\n\nGo?'
TWO_Q=$'Two things are yours. Should the old archives stay? And do we turn auto-updates on?'
SMALL=$'Done:\n1. one\n2. two\n3. three\n4. four\nAnything else?'
FENCED=$'Run this:\n\n```\n1. a\n2. b\n3. c\n4. d\n5. e\n```\n\nThat is all.'
URLQ=$'See https://example.com/x?a=1 and https://example.com/y?b=2 for the details.'

# run <session> <transcript> <message> [stop_hook_active]
run() {
  jq -n --arg s "$1" --arg t "$2" --arg m "$3" --argjson a "${4:-false}" \
    '{session_id:$s, transcript_path:$t, hook_event_name:"Stop", stop_hook_active:$a, last_assistant_message:$m}' \
    | ( cd "$PROJ" && bash "$HOOK" 2>/dev/null )
}

echo "== a plan-shaped answer from a session that wrote no workitem =="
out=$(run s1 "$TR_CLEAN" "$PLAN")
eq "RED: five numbered steps → one nudge, for the Stop event" "Stop" \
   "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
case "$ctx" in *"/vdm:crystal-grow"*) ok "…naming /vdm:crystal-grow" ;; *) bad "…naming /vdm:crystal-grow" "$ctx" ;; esac
case "$ctx" in *"/vdm:crystal-bud"*) ok "…and the active crystal as the other home" ;; *) bad "…and the active crystal as the other home" "$ctx" ;; esac
eq "…never as systemMessage, which reaches only the user" "" \
   "$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)"
eq "RED: once per session — the same session is not asked again" "" "$(run s1 "$TR_CLEAN" "$PLAN")"
eq "…another session is" "Stop" \
   "$(run s2 "$TR_CLEAN" "$PLAN" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)"

echo "== the shape =="
eq "two questions to the user → a nudge" "Stop" \
   "$(run s3 "$TR_CLEAN" "$TWO_Q" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)"
eq "four steps and one question → silence" "" "$(run s4 "$TR_CLEAN" "$SMALL")"
eq "numbered lines inside a code block do not count" "" "$(run s5 "$TR_CLEAN" "$FENCED")"
eq "a question mark inside a URL is not a question" "" "$(run s6 "$TR_CLEAN" "$URLQ")"
eq "an empty answer → silence" "" "$(run s7 "$TR_CLEAN" "")"

echo "== the condition: this session, not the repository =="
eq "a session that wrote a workitem is not asked" "" "$(run s8 "$TR_WROTE" "$PLAN")"
eq "…nor one that edited one" "" "$(run s9 "$TR_EDITED" "$PLAN")"
eq "…nor one that ran crystal-grow" "" "$(run s10 "$TR_GREW" "$PLAN")"
eq "a transcript not on disk yet is no evidence of a write → nudge" "Stop" \
   "$(run s11 "$TMP/missing.jsonl" "$PLAN" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)"
eq "a session asked once is not asked again after it wrote nothing" "" "$(run s11 "$TMP/missing.jsonl" "$PLAN")"

echo "== silence =="
eq "while the hook itself keeps the turn going (stop_hook_active)" "" "$(run s12 "$TR_CLEAN" "$PLAN" true)"
printf '{"crystal":{"enabled":false}}\n' > "$PROJ/.claude/vdm-plugins.json"
eq "crystal disabled → silence" "" "$(run s13 "$TR_CLEAN" "$PLAN")"
printf '{"crystal":{"grow-nudge":false}}\n' > "$PROJ/.claude/vdm-plugins.json"
eq "crystal.grow-nudge: false → silence" "" "$(run s14 "$TR_CLEAN" "$PLAN")"
rm -f "$PROJ/.claude/vdm-plugins.json"
eq "…and the default is on" "Stop" \
   "$(run s15 "$TR_CLEAN" "$PLAN" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
