#!/bin/bash
# reminder-throttle.test.sh — RED TESTS for the two-axis reminder window.
#
# The defect this file exists for, measured in the field (t23b-content,
# 2026-09-10, six hooks, vdm 2.25.0): the window was wall-clock only, so a
# person who spends longer than the window thinking about each prompt clears it
# on EVERY turn. The hooks then fire on every turn — the reported "ignored 12
# turns in a row". Both incoming letters diagnosed it as "the text never
# changes"; that is the symptom. The cause is that noise is measured in TURNS
# and the window was measuring seconds.
#
# So an emit now needs BOTH windows elapsed, and the tests are written around
# the pair rather than around either one:
#
#   RED   — wall clock elapsed, turn budget NOT met ⇒ still silent. This is the
#           assertion the old implementation fails, and the whole point.
#   GREEN — turn budget met, wall clock NOT elapsed ⇒ still silent. Without it
#           the fix would just move the noise to fast typists.
#   GREEN — no turn argument ⇒ behaviour identical to before the axis existed,
#           because a configured `throttle: 900` still means 900 SECONDS and
#           silently reinterpreting it as turns would be a lie about the unit.
#
# git-guard is covered here too: until 2.14.0 it was the one reminder in the
# suite with `proactive` as its default and no throttle call at all, spending
# 1601 bytes on every prompt in any dirty repository while its five siblings
# spent 0 on a repeat prompt.
#
# Run: bash tests/reminder-throttle.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/lib/reminder-throttle.sh
# @see plugins/vdm-git/scripts/git-guard-reminder.sh
# @see docs/tasks/hook-noise-signal-shape/workitem.md

set -u

# Scrub git's per-invocation environment before anything else. A test harness
# run from inside a live `git commit` (which is what a pre-commit gate is)
# inherits GIT_INDEX_FILE / GIT_DIR pointing at THAT commit — and every `git`
# call against a throwaway fixture then writes into the user's real commit
# instead. Measured 2026-09-22 on this file's sibling: one `git add -A` in a
# fixture replaced all 158 entries of the pending commit's index with 9
# fixture paths. The commit survived only because the objects were missing.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REMINDER_THROTTLE_LIB:-$REPO_ROOT/plugins/vdm/lib/reminder-throttle.sh}"
GITGUARD="${GIT_GUARD_REMINDER:-$REPO_ROOT/plugins/vdm-git/scripts/git-guard-reminder.sh}"
DOCSSYNC="${DOCS_SYNC_REMINDER:-$REPO_ROOT/plugins/vdm/scripts/docs-sync-reminder.sh}"
CAPTURE="${CAPTURE_REMINDER:-$REPO_ROOT/plugins/vdm/scripts/crystal-capture-reminder.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t throttle)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export TMPDIR="$TMP/state"
mkdir -p "$TMPDIR"

# shellcheck disable=SC1090
. "$LIB"

state_of() { printf '%s/vdm-reminder-throttle/%s-%s' "$TMPDIR" "$1" "$2"; }

# verdict <key> <seconds> <sid> [turns] → "emit" | "silent"
verdict() {
  if _vdm_reminder_throttle_check "$1" "$2" "$3" "${4:-}"; then
    printf 'silent'
  else
    printf 'emit'
  fi
}

# age_state <key> <sid> <seconds> — pretend the last emit was N seconds earlier,
# keeping the turn counter untouched. Both the recorded epoch and the mtime are
# moved, so a legacy-format file ages too.
age_state() {
  local f; f="$(state_of "$1" "$2")"
  [ -f "$f" ] || return 0
  AGE_SECONDS="$3" python3 - "$f" <<'PY'
import os, re, sys
p, back = sys.argv[1], int(os.environ["AGE_SECONDS"])
raw = open(p).read().strip()
m = re.match(r"^(\d+)\s+(\d+)$", raw)
if m:
    open(p, "w").write("%d %s\n" % (int(m.group(1)) - back, m.group(2)))
st = os.stat(p)
os.utime(p, (st.st_atime - back, st.st_mtime - back))
PY
}

printf '\nthe pair: an emit needs BOTH windows elapsed\n'

rm -rf "$TMPDIR/vdm-reminder-throttle"
eq "first ever check emits — there is no window yet" "$(verdict k 600 s1 5)" "emit"
_vdm_reminder_throttle_touch k s1
eq "…and the window is now open"  "$(test -f "$(state_of k s1)" && echo yes)" "yes"
eq "immediately after an emit: silent"            "$(verdict k 600 s1 5)" "silent"

age_state k s1 601
eq "RED: wall clock elapsed, turn budget unmet ⇒ STILL SILENT" "$(verdict k 600 s1 5)" "silent"
age_state k s1 601
eq "…second turn, same"                                        "$(verdict k 600 s1 5)" "silent"
age_state k s1 601
eq "…third turn, same"                                         "$(verdict k 600 s1 5)" "silent"
age_state k s1 601
eq "fifth turn with the clock elapsed ⇒ emit"                  "$(verdict k 600 s1 5)" "emit"

rm -rf "$TMPDIR/vdm-reminder-throttle"
verdict k 600 s2 5 >/dev/null; _vdm_reminder_throttle_touch k s2
verdict k 600 s2 5 >/dev/null
verdict k 600 s2 5 >/dev/null
verdict k 600 s2 5 >/dev/null
verdict k 600 s2 5 >/dev/null
eq "GREEN: turn budget met but the clock has NOT elapsed ⇒ silent" "$(verdict k 600 s2 5)" "silent"

printf '\nwithout a turn argument the behaviour is exactly what it was\n'

rm -rf "$TMPDIR/vdm-reminder-throttle"
verdict k 600 s3 >/dev/null; _vdm_reminder_throttle_touch k s3
eq "inside the seconds window: silent" "$(verdict k 600 s3)" "silent"
age_state k s3 601
eq "seconds elapsed, no turn budget given ⇒ emit" "$(verdict k 600 s3)" "emit"

printf '\na state file from before the turn axis is read, not discarded\n'

rm -rf "$TMPDIR/vdm-reminder-throttle"
mkdir -p "$TMPDIR/vdm-reminder-throttle"
: > "$(state_of legacy s4)"                      # the pre-2.31 shape: empty, mtime IS the clock
eq "legacy file, fresh mtime ⇒ silent (no free emit on upgrade)" "$(verdict legacy 600 s4 5)" "silent"
: > "$(state_of legacy2 s4)"
age_state legacy2 s4 601
eq "legacy file, old mtime, turn budget unmet ⇒ silent" "$(verdict legacy2 600 s4 5)" "silent"

printf '\nsessions do not shadow each other\n'

rm -rf "$TMPDIR/vdm-reminder-throttle"
verdict k 600 alpha 5 >/dev/null; _vdm_reminder_throttle_touch k alpha
eq "session alpha is now throttled"        "$(verdict k 600 alpha 5)" "silent"
eq "session beta has its own clean window" "$(verdict k 600 beta 5)"  "emit"

printf '\ngit-guard: the one reminder that had no throttle at all\n'

FX="$TMP/repo"
mkdir -p "$FX"
( cd "$FX" && git init -q . ) >/dev/null 2>&1
printf 'x\n' > "$FX/a.txt"

run_guard() { # run_guard <cwd> → bytes of additionalContext
  ( cd "$1" && printf '{"session_id":"g1"}' | bash "$GITGUARD" 2>/dev/null ) | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)['hookSpecificOutput']['additionalContext']))
except Exception: print(0)"
}

rm -rf "$TMPDIR/vdm-reminder-throttle"
b1=$(run_guard "$FX")
[ "$b1" -gt 0 ] && ok "dirty tree, first prompt ⇒ speaks ($b1 B)" || bad "dirty tree, first prompt ⇒ speaks" "got $b1 B"
b2=$(run_guard "$FX")
eq "RED: second prompt in the same session ⇒ silent" "$b2" "0"
b3=$(run_guard "$FX")
eq "…and the third"                                   "$b3" "0"

( cd "$FX" && git add -A >/dev/null 2>&1 &&
  git -c user.email=t@example.invalid -c user.name=t commit -q -m x >/dev/null 2>&1 )
rm -rf "$TMPDIR/vdm-reminder-throttle"
eq "clean tree ⇒ silent even on the first prompt" "$(run_guard "$FX")" "0"

mkdir -p "$FX/.claude"
printf '{"git-guard":{"mode":"proactive"}}\n' > "$FX/.claude/vdm-plugins.json"
printf 'y\n' > "$FX/b.txt"
rm -rf "$TMPDIR/vdm-reminder-throttle"
p1=$(run_guard "$FX"); p2=$(run_guard "$FX")
[ "$p1" -gt 0 ] && [ "$p2" = "$p1" ] \
  && ok "GREEN: an explicit \`proactive\` still speaks every prompt" \
  || bad "GREEN: an explicit \`proactive\` still speaks every prompt" "got $p1 then $p2"
rm -f "$FX/.claude/vdm-plugins.json"

NOGIT="$TMP/plain"; mkdir -p "$NOGIT"
eq "outside a work tree ⇒ silent" "$(run_guard "$NOGIT")" "0"

printf '\nthe hooks print their OUTPUT, not their INPUT\n'

DOCS="$TMP/docs"
mkdir -p "$DOCS"
( cd "$DOCS" && git init -q . ) >/dev/null 2>&1
i=1
while [ "$i" -le 14 ]; do printf '# doc %s\n' "$i" > "$DOCS/doc-$i.md"; i=$((i + 1)); done
printf 'dirty\n' > "$DOCS/src.py"
rm -rf "$TMPDIR/vdm-reminder-throttle"
out=$( cd "$DOCS" && printf '{"session_id":"d1"}' | bash "$DOCSSYNC" 2>/dev/null )
says "the doc count is the true total"  "$out" "Project docs (14)"
says "…but the list itself is truncated" "$out" "(+4)"
# Order-independent: `find` does not sort, so asserting that one NAMED file is
# missing would pass or fail by luck. Count what was actually listed.
listed=$(printf '%s' "$out" | python3 -c "
import re, sys
t = sys.stdin.read()
m = re.search(r'Project docs \\(\\d+\\): (.*)', t)
print(len(re.findall(r'doc-\\d+\\.md', m.group(1))) if m else -1)")
eq "…to exactly ten entries, whatever order find returned them in" "$listed" "10"

CAP="$TMP/crystal"
mkdir -p "$CAP/docs/tasks/probe" "$CAP/src"
( cd "$CAP" && git init -q . ) >/dev/null 2>&1
cat > "$CAP/docs/tasks/probe/workitem.md" <<'WI'
---
title: "probe"
slug: probe
status: in-progress
session-type: other
created: 2026-09-22
last-updated: 2026-09-22
---

# probe

## Назначение

x

## Текущая модель

- x

## Decision Log

## Sidetracks

## Next actions

- [ ] x

## References

- none
WI
sleep 1
printf 'a\n' > "$CAP/src/a.py"; printf 'b\n' > "$CAP/src/b.py"; printf 'c\n' > "$CAP/src/c.py"
rm -rf "$TMPDIR/vdm-reminder-throttle"
out=$( cd "$CAP" && printf '{"session_id":"c1"}' | bash "$CAPTURE" 2>/dev/null )
says "the capture reminder reports HOW MANY files changed" "$out" "file(s) changed"
says "…and how long the workitem has sat untouched"        "$out" "workitem untouched for"
says_not "…instead of the fixed verdict it used to print"  "$out" "Work happened this segment"

printf '\nreminder-throttle: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
