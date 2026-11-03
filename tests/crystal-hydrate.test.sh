#!/bin/bash
# crystal-hydrate.test.sh — the session-start line shows what waits for an event.
#
# Field case (a project's agent, 2026-10-23): the assistant promised «I'll delete the
# sites from the server once all 30 files have arrived on the second NAS», the
# session was restarted, and the next one opened with the owner asking where
# that was being watched. Nowhere: the crystal held the item without its
# condition, and the start line said «22 open». An open item carrying `when:`
# names an event nothing watches; the start line prints each one whole, so the
# session checks the event before the step behind it (wrap-skill DL #15).
#
# No commit anywhere: the fixtures are staged, never committed.
#
# Run: bash tests/crystal-hydrate.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/crystal-hydrate.sh

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM VDX_HQ CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Nor the machine's git config: a global excludesFile would hide files the
# fixture means to show, and git 2.54 runs a hook declared there on commands of
# its own (the case is in tests/gates.test.sh).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${CRYSTAL_HYDRATE:-$REPO_ROOT/plugins/vdm/scripts/crystal-hydrate.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"; esac; }
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing
  # (tests/harness-asserts.test.sh). Silence is asserted as silence.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystalhydrate)
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home"; mkdir -p "$HOME"

# crystal <repo> <slug> <status> <body> — one workitem, staged
crystal() {
  mkdir -p "$1/docs/tasks/$2"
  printf -- '---\ntitle: "%s"\nslug: %s\nstatus: %s\n---\n\n# %s\n\n## Next actions\n\n%s\n' \
    "$2" "$2" "$3" "$2" "$4" > "$1/docs/tasks/$2/workitem.md"
  git -C "$1" add -- "docs/tasks/$2/workitem.md"
}
hydrate() { ( cd "$1" && printf '{}' | bash "$HOOK" 2>/dev/null ); }

echo "== an item that waits for an event is shown whole =="
R="$TMP/waits"; mkdir -p "$R"; git -C "$R" init -q
crystal "$R" demo in-progress '- [ ] a plain open item
- [ ] nas-b: sha256 of all 30 files, then delete the sites — when: all 30 have arrived on nas-b; check: `sha256sum -c "list"`
- [x] an earlier wait, done — when: the reply came
```
- [ ] an example in a fence — when: never
```'
crystal "$R" parked dormant '- [ ] a parked wait — when: someday'
out="$(hydrate "$R")"
says "RED: the item is printed, under its crystal" "$out" "⏳ demo: nas-b: sha256 of all 30 files, then delete the sites — when: all 30 have arrived on nas-b"
says "RED: …with what to do first" "$out" "Check the event first, before the step behind it"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "…in valid hook JSON, quotes and backticks of the item included"
else
  bad "…in valid hook JSON, quotes and backticks of the item included" "${out:0:200}"
fi
says_not "a closed item is not a wait" "$out" "the reply came"
says_not "an example inside a fence is not a wait" "$out" "in a fence"
says_not "a dormant crystal is not listed, its waits neither" "$out" "someday"
says_not "a plain open item stays in the count, not in the list" "$out" "⏳ demo: a plain"
says "…and the count still holds every open item" "$out" "demo: 2 open"

echo "== no wait, no word about one =="
Q="$TMP/quiet"; mkdir -p "$Q"; git -C "$Q" init -q
crystal "$Q" calm in-progress '- [ ] something to do, whenever: it is not a marker'
out="$(hydrate "$Q")"
says "the crystal is listed as before" "$out" "calm: 1 open"
says_not "…and nothing is said about waiting" "$out" "Waiting for an event"
says_not "…nor about crystals not in work, when none is past due" "$out" "Not in work"

# Field count (late-grow Sidetrack #1, 2026-10-25): 22 crystals on one machine
# held promises past due; 14 of them were dormant, in nine projects, and the
# session start named none of those. The singleton invariant sends a crystal to
# dormant, and a pause is the state in which a date is easiest to miss.
echo "== a dormant crystal's date past due is named =="
D="$TMP/dormant"; mkdir -p "$D"; git -C "$D" init -q
crystal "$D" now in-progress '- [ ] the current work'
crystal "$D" parked dormant '- [ ] answer the vendor (due: 2020-01-02)
- [ ] and the second one (due: 2020-03-04)
- [ ] a later one (due: 2999-01-01)'
crystal "$D" later dormant '- [ ] nothing due yet (due: 2999-01-01)'
crystal "$D" closed done '- [x] done long ago (due: 2020-01-01)'
out="$(hydrate "$D")"
says "RED: the dormant crystal, its status and its overdue count" "$out" "parked (dormant, 2)"
says "RED: …under a line that says what the pause hides" "$out" "Not in work, with promises past due"
says_not "a dormant crystal with nothing past due is not named" "$out" "later ("
says_not "…nor a closed one" "$out" "closed ("
says "the active crystal is listed as before" "$out" "now: 1 open"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "…in valid hook JSON"
else
  bad "…in valid hook JSON" "${out:0:200}"
fi

echo "== …also when no crystal is active =="
N="$TMP/noactive"; mkdir -p "$N"; git -C "$N" init -q
crystal "$N" asleep dormant '- [ ] renew the certificate (due: 2020-05-06)'
out="$(hydrate "$N")"
says "RED: the start is not silent then" "$out" "asleep (dormant, 1)"

# An HQ, 2026-10-28: a crystal parked in `ready` by crystal-grow's Mode B, all four
# items due at a meeting, and nothing would say so; the agent swapped active and
# dormant to keep the topic in sight. Measured 2026-11-02: 10 crystals of 319 stood
# in ready, draft or blocked with a date past due. Named with what it is.
echo "== a date past due is named in every status not in work =="
W="$TMP/parkedall"; mkdir -p "$W"; git -C "$W" init -q
crystal "$W" here in-progress '- [ ] the work (due: 2020-01-01)'
crystal "$W" aidea idea '- [ ] an idea (due: 2020-01-01)'
crystal "$W" adraft draft '- [ ] a draft (due: 2020-01-01)'
crystal "$W" aready ready '- [ ] parked by Mode B (due: 2020-01-01)
- [ ] for the same meeting (due: 2020-01-01)'
crystal "$W" ablocked blocked '- [ ] waits on someone (due: 2020-01-01)'
crystal "$W" alater ready '- [ ] not yet (due: 2999-01-01)'
crystal "$W" aclosed done '- [ ] left open (due: 2020-01-01)'
crystal "$W" acut cancelled '- [ ] dropped (due: 2020-01-01)'
crystal "$W" aodd whatever '- [ ] no such status (due: 2020-01-01)'
mkdir -p "$W/docs/tasks/nostatus"
printf -- '- [ ] an artefact, not a workitem (due: 2020-01-01)\n' > "$W/docs/tasks/nostatus/workitem.md"
git -C "$W" add -- docs/tasks/nostatus/workitem.md
out="$(hydrate "$W")"
says "RED: ready, the one an HQ lost, with its count" "$out" "aready (ready, 2)"
says "RED: draft" "$out" "adraft (draft, 1)"
says "RED: idea" "$out" "aidea (idea, 1)"
says "RED: blocked" "$out" "ablocked (blocked, 1)"
says_not "a date not yet past is not named" "$out" "alater ("
says_not "the active crystal is not named here: its own line counts it" "$out" "here (in-progress"
says_not "…nor a terminal one" "$out" "aclosed ("
says_not "…nor a cancelled one" "$out" "acut ("
says_not "…nor a status the audit line is for" "$out" "aodd ("
says_not "…nor a file with no status: it is no workitem" "$out" "nostatus ("
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "…in valid hook JSON"
else
  bad "…in valid hook JSON" "${out:0:200}"
fi

R2="$TMP/parkedonly"; mkdir -p "$R2"; git -C "$R2" init -q
crystal "$R2" onlyready ready '- [ ] parked (due: 2020-01-01)'
out="$(hydrate "$R2")"
says "RED: nothing active, one in ready past due: the start is not silent" "$out" "onlyready (ready, 1)"

# A project's own word for a status means what it maps to, here as everywhere.
AL="$TMP/aliased"; mkdir -p "$AL/.claude"; git -C "$AL" init -q
printf '{"crystal":{"status-aliases":{"queued":"ready"}}}\n' > "$AL/.claude/vdm-plugins.json"
crystal "$AL" mapped queued '- [ ] parked under an alias (due: 2020-01-01)'
out="$(hydrate "$AL")"
says "RED: a status alias is read as what it maps to" "$out" "mapped (ready, 1)"

echo "== the path to Read is the file's own =="
# A project whose crystals live in tasks/, with no crystal.path set, was told to
# Read docs/tasks/<slug>/workitem.md — the setting's default plus the path under
# the root, a file that does not exist (a project on this machine, 2026-10-25).
T="$TMP/bare"; mkdir -p "$T/tasks/here"; git -C "$T" init -q
printf -- '---\nslug: here\nstatus: in-progress\n---\n\n- [ ] open\n' > "$T/tasks/here/workitem.md"
git -C "$T" add -- tasks/here/workitem.md
out="$(hydrate "$T")"
says "RED: Read tasks/here/workitem.md" "$out" "(Read tasks/here/workitem.md)"
says "…and docs/tasks keeps its own" "$(hydrate "$Q")" "(Read docs/tasks/calm/workitem.md)"

echo "== nothing active, nothing past due → silence =="
S="$TMP/silent"; mkdir -p "$S"; git -C "$S" init -q
crystal "$S" resting dormant '- [ ] some day (due: 2999-01-01)'
eq_silent=$(hydrate "$S")
if [ -z "$eq_silent" ]; then ok "silence"; else bad "silence" "${eq_silent:0:200}"; fi

echo "== a live HQ session of the project: the waits go there, the list stays (hq-session-quiet, DL #2) =="
# A python sleeper: macOS hides a platform binary's environment (`sleep`).
SOCKS="$(mktemp -d /tmp/hqsock.XXXXXX)"
env VDX_HQ=1 python3 -c 'import time; time.sleep(300)' & HQ_PID=$!; disown "$HQ_PID" 2>/dev/null || true
trap 'kill "$HQ_PID" 2>/dev/null; rm -rf "$TMP" "$SOCKS"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  { [ -r "/proc/$HQ_PID/environ" ] || ps -wwE -p "$HQ_PID" -o command= 2>/dev/null | grep -q 'VDX_HQ=1'; } && break
  python3 -c 'import time; time.sleep(0.2)'
done
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKS/hq.sock"
hq_session() {  # hq_session <file> <cwd> — the live HQ session, as the harness writes it
  mkdir -p "$HOME/.claude/sessions"
  jq -n --argjson pid "$HQ_PID" --arg cwd "$2" --arg sock "$SOCKS/hq.sock" \
    '{pid:$pid, sessionId:"sid-hq", cwd:$cwd, messagingSocketPath:$sock}' > "$HOME/.claude/sessions/$1"
}
H="$TMP/hqproj"; mkdir -p "$H"; git -C "$H" init -q
crystal "$H" busywork in-progress $'- [ ] delete the sites — when: all 30 files arrived\n- [ ] answer the agent (due: 2020-01-01)'
crystal "$H" parkedwork dormant '- [ ] an old promise (due: 2020-01-01)'
says_all() {  # the three signals, each with what names it
  says "$1: what waits for an event" "$2" "Waiting for an event"
  says "$1: past due in the list" "$2" "ПРОСРОЧЕНО"
  says "$1: past due out of work" "$2" "Not in work"
}
out="$(CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says_all "without an HQ session" "$out"
hq_session hq.json "$H"
out="$(CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says "RED: with one, the active crystal is still listed" "$out" "busywork: 2 open"
says_not "RED: …and nothing waits for an event" "$out" "Waiting for an event"
says_not "RED: …nothing past due in the list" "$out" "ПРОСРОЧЕНО"
says_not "RED: …nothing past due out of work" "$out" "Not in work"
says_not "…not even as a mark" "$out" "⏰"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "…valid hook JSON" || bad "…valid hook JSON" "$out"
out="$(VDX_HQ=1 CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says_all "RED: the HQ session itself" "$out"
out="$(VDX_INTERCOM=1 CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says_all "an intercom session" "$out"
out="$(VDX_FOCUSED=1 CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says_all "a focused session, as before (hq-session-quiet, DL #3)" "$out"
H2="$TMP/hqother"; mkdir -p "$H2"; git -C "$H2" init -q
crystal "$H2" elsewhere in-progress $'- [ ] wait — when: something'
out="$(CLAUDE_PROJECT_DIR="$H2" hydrate "$H2")"
says "RED: another project's session stays as it was" "$out" "Waiting for an event"
M="$TMP/hqmulti"; mkdir -p "$M/a/tasks/one" "$M/b/tasks/two"; git -C "$M" init -q
printf -- '---\nslug: one\nstatus: in-progress\n---\n\n- [ ] late (due: 2020-01-01)\n' > "$M/a/tasks/one/workitem.md"
printf -- '---\nslug: two\nstatus: in-progress\n---\n\n- [ ] open\n' > "$M/b/tasks/two/workitem.md"
git -C "$M" add -- a b
out="$(CLAUDE_PROJECT_DIR="$M" hydrate "$M")"
says "several roots, no HQ session: past due in the summary" "$out" "⏰1"
hq_session hqm.json "$M"
out="$(CLAUDE_PROJECT_DIR="$M" hydrate "$M")"
says "RED: several roots, with one: still listed" "$out" "a: one (1)"
says_not "RED: …without the mark" "$out" "⏰"
kill "$HQ_PID" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$HQ_PID" 2>/dev/null || break; python3 -c 'import time; time.sleep(0.2)'; done
out="$(CLAUDE_PROJECT_DIR="$H" hydrate "$H")"
says_all "RED: closed, the session file left behind" "$out"
rm -rf "$HOME/.claude/sessions"

printf '\ncrystal-hydrate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
