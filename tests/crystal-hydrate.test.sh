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
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

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
says_not "…nor about dormant crystals, when none is past due" "$out" "Dormant"

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
says "RED: the dormant crystal and its overdue count" "$out" "parked (2)"
says "…under a line that says what the pause hides" "$out" "Dormant, with promises past due"
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
says "RED: the start is not silent then" "$out" "asleep (1)"

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

printf '\ncrystal-hydrate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
