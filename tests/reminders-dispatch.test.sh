#!/bin/bash
# reminders-dispatch.test.sh — RED TESTS for the vdm reminder dispatcher.
#
# Measured before this existed (every local transcript, 2026-09-22): the vdm
# reminders never spoke alone, and 48% of interactive turns on which anything
# spoke carried four or five independent blocks of equal weight. The
# dispatcher's job is to turn that chorus into one section with an order.
#
# What is asserted, and why in this shape:
#
#   * ORDER IS NOT FINISH ORDER. The children run in parallel; the fixture
#     makes the most important one finish LAST, so a dispatcher that prints in
#     arrival order fails here rather than passing by timing luck.
#   * ONE SPEAKER IS UNCHANGED. "Never longer than before" is half the success
#     criterion: a lone reminder must come through byte-for-byte, no header.
#   * THE SLOWEST CHILD COSTS ONLY ITSELF. One registration is one point of
#     failure; the deadline is what keeps a slow tree walk from silencing the
#     other five. Proven with a child that sleeps past the deadline.
#   * A CRASHING CHILD COSTS ONLY ITSELF.
#   * A PLUGIN CACHE IS NOT A PROJECT. Silence there even when every child
#     would speak.
#
# Run: bash tests/reminders-dispatch.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/reminders.sh
# @see plugins/vdm/lib/reminder-emit.sh
# @see docs/tasks/reminder-hierarchy/workitem.md

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
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="${REMINDERS_DISPATCH:-$REPO_ROOT/plugins/vdm/scripts/reminders.sh}"
LIBDIR="$REPO_ROOT/plugins/vdm/lib"
HOOKS_JSON="$REPO_ROOT/plugins/vdm/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t dispatch)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export TMPDIR="$TMP/state"; mkdir -p "$TMPDIR"

PROJ="$TMP/proj"; mkdir -p "$PROJ"

# kid <dir> <name> <tier> <delay-seconds> <short> <full> [crash]
kid() {
  local dir="$1" name="$2" tier="$3" delay="$4" short="$5" full="$6" crash="${7:-}"
  mkdir -p "$dir"
  {
    printf '#!/bin/bash\n'
    printf 'sleep %s\n' "$delay"
    [ -n "$crash" ] && printf 'exit 1\n'
    printf '. %q\n' "$LIBDIR/reminder-emit.sh"
    printf '_vdm_reminder_emit %q %q %q %q\n' "$name" "$tier" "$short" "$full"
  } > "$dir/$name-reminder.sh"
}

# dispatch <kids-dir> [deadline] [cwd] → sets CTX (additionalContext or empty), RAW, ELAPSED
dispatch() {
  local kids="$1" deadline="${2:-25}" cwd="${3:-$PROJ}" s e
  s=$(python3 -c 'import time; print(time.time())')
  RAW=$( cd "$cwd" && printf '{"session_id":"t"}' | \
         CLAUDE_PROJECT_DIR="$cwd" VDM_REMINDERS_DIR="$kids" VDM_REMINDERS_DEADLINE="$deadline" \
         bash "$DISPATCH" 2>/dev/null )
  e=$(python3 -c 'import time; print(time.time())')
  ELAPSED=$(python3 -c "print('%.1f' % ($e - $s))")
  CTX=$(printf '%s' "$RAW" | python3 -c "
import json, sys
t = sys.stdin.read()
if not t.strip(): sys.exit(0)
print(json.loads(t)['hookSpecificOutput']['additionalContext'], end='')" 2>/dev/null)
}

printf '\nnobody speaks, one speaks\n'

K="$TMP/k0"; mkdir -p "$K"
dispatch "$K"
eq "nobody spoke ⇒ no output at all" "$RAW" ""

K="$TMP/k1"
kid "$K" docs-sync 1 0 "docs short" '[docs-sync] alone\nsecond line'
dispatch "$K"
eq "one speaker ⇒ its own text, byte for byte" "$CTX" "$(printf '[docs-sync] alone\nsecond line')"
says_not "…and no header" "$CTX" "[vdm]"

printf '\nthe chorus: one section, ranked, habits folded\n'

K="$TMP/k2"
# crystal is the most important AND finishes last; docs-sync finishes first.
kid "$K" crystal-capture 1 1 "crystal short" '[crystal] CAPTURE-FULL'
kid "$K" docs-sync       1 0 "docs short"    '[docs-sync] DOCS-FULL'
kid "$K" changelog       2 0 "changelog-SHORT" '[changelog] CHANGELOG-FULL'
kid "$K" learn           2 0 "learn-SHORT"     '[learn] LEARN-FULL'
dispatch "$K"
printf '%s' "$RAW" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "the output is one valid hook JSON" || bad "the output is one valid hook JSON" "$RAW"
says "the header counts the speakers" "$CTX" "[vdm] 4 reminders this turn"
pos() { python3 -c "import sys; print(sys.argv[1].find(sys.argv[2]))" "$CTX" "$1"; }
c=$(pos CAPTURE-FULL); d=$(pos DOCS-FULL); h=$(pos "Standing habits")
[ "$c" -ge 0 ] && [ "$d" -ge 0 ] && [ "$c" -lt "$d" ] \
  && ok "RED: rank, not arrival — crystal first although it finished last" \
  || bad "RED: rank, not arrival — crystal first although it finished last" "crystal@$c docs@$d"
[ "$d" -lt "$h" ] && ok "measurements come before the habit line" || bad "measurements come before the habit line" "docs@$d habits@$h"
says "the habits are folded into one line, by their short form" "$CTX" "changelog-SHORT · learn-SHORT"
says_not "…and their full text is not repeated" "$CTX" "CHANGELOG-FULL"
says_not "…for either of them" "$CTX" "LEARN-FULL"

K="$TMP/k3"
kid "$K" changelog 2 0 "changelog-SHORT" '[changelog] CHANGELOG-FULL'
kid "$K" learn     2 0 "learn-SHORT"     '[learn] LEARN-FULL'
dispatch "$K"
says "habits alone still make one section" "$CTX" "[vdm] 2 reminders"
says "…with the folded line" "$CTX" "changelog-SHORT · learn-SHORT"

printf '\nfailure costs only the one that failed\n'

K="$TMP/k4"
kid "$K" crystal-capture 1 4 "crystal short" '[crystal] SLOW-FULL'
kid "$K" docs-sync       1 0 "docs short"    '[docs-sync] FAST-FULL'
kid "$K" learn           2 0 "learn-SHORT"   '[learn] LEARN-FULL'
dispatch "$K" 1
says "RED: a child past the deadline does not silence the others" "$CTX" "FAST-FULL"
says_not "…and is itself dropped" "$CTX" "SLOW-FULL"
python3 -c "import sys; sys.exit(0 if float('$ELAPSED') < 3.5 else 1)" \
  && ok "…and the dispatcher returned on the deadline (${ELAPSED}s), not on the straggler" \
  || bad "…and the dispatcher returned on the deadline, not on the straggler" "took ${ELAPSED}s"

K="$TMP/k5"
kid "$K" crystal-capture 1 0 "x" '[crystal] CRASH-FULL' crash
kid "$K" docs-sync       1 0 "docs short" '[docs-sync] SURVIVOR-FULL'
dispatch "$K"
says "a crashing child does not take the others down" "$CTX" "SURVIVOR-FULL"
says_not "…and leaves nothing behind" "$CTX" "CRASH-FULL"

printf '\na plugin cache is not a project\n'

CACHE="$TMP/settings/.claude/plugins/cache/some-vendor/some-plugin/0.2.42"
mkdir -p "$CACHE"
dispatch "$TMP/k2" 25 "$CACHE"
eq "every child would speak, and still silence" "$RAW" ""

printf '\nregistration and the real children\n'

n=$(python3 -c "
import json
d = json.load(open('$HOOKS_JSON'))
print(sum(len(b['hooks']) for b in d['hooks'].get('UserPromptSubmit', [])))")
eq "vdm registers exactly ONE UserPromptSubmit hook" "$n" "1"
cmd=$(python3 -c "
import json
d = json.load(open('$HOOKS_JSON'))
h = d['hooks']['UserPromptSubmit'][0]['hooks'][0]; print(h['command'], h['timeout'])")
says "…and it is the dispatcher" "$cmd" "scripts/reminders.sh"
t=${cmd##* }
[ "$t" -gt 25 ] && ok "…with a timeout above the dispatcher's own deadline ($t s)" \
                || bad "…with a timeout above the dispatcher's own deadline" "timeout $t"

FX="$TMP/fx"; mkdir -p "$FX/docs/tasks/probe" "$FX/src"
( cd "$FX" && git init -q . ) >/dev/null 2>&1
cat > "$FX/docs/tasks/probe/workitem.md" <<'WI'
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
printf 'a\n' > "$FX/src/a.py"
rm -rf "$TMPDIR/vdm-reminder-throttle"
dispatch "$REPO_ROOT/plugins/vdm/scripts" 25 "$FX"
says "real children: one section" "$CTX" "[vdm]"
c=$(pos "[crystal]"); h=$(pos "Standing habits")
[ "$c" -ge 0 ] && [ "$h" -gt "$c" ] && ok "real children: crystal before the habits" \
                                   || bad "real children: crystal before the habits" "crystal@$c habits@$h"
dispatch "$REPO_ROOT/plugins/vdm/scripts" 25 "$FX"
eq "real children, next turn: the throttle still holds, through the dispatcher" "$RAW" ""

direct=$( cd "$FX" && TMPDIR="$TMP/state2" bash "$REPO_ROOT/plugins/vdm/scripts/learn-reminder.sh" \
          <<<'{"session_id":"z"}' 2>/dev/null )
says "a child run by hand still prints its own hook JSON" "$direct" '"hookEventName": "UserPromptSubmit"'

# valid <label> <json> — the hook output parses as JSON, the way the harness reads it.
valid() {
  printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "$1" || bad "$1" "$(printf '%s' "$2" | head -c 400)"
}

printf '\ntext that is not valid JSON costs only itself\n'

# The field report (command-center, 2026-09-25): git put a Cyrillic path in
# quotes with octal escapes, docs-sync pasted it into its text, and the one
# raw `"` made the whole section unparseable — every other reminder of that
# turn went with it. Any reminder can produce such text; the contract that each
# one escapes itself held until the first one did not.
K="$TMP/k6"
kid "$K" docs-sync       1 0 "docs short"    '[docs-sync] Project docs (2): "gaps/Taxradar-\320\241.md", ok.md'
kid "$K" crystal-capture 1 0 "crystal short" '[crystal] NEIGHBOUR-FULL'
dispatch "$K"
valid "RED: a fragment with a raw quote and a bad escape still yields valid hook JSON" "$RAW"
says "RED: …the neighbour is delivered" "$CTX" "NEIGHBOUR-FULL"
says "RED: …the broken text is delivered too, escaped" "$CTX" 'gaps/Taxradar-'
says "RED: …and named as a defect of that reminder, not passed off as normal" "$CTX" "docs-sync: this reminder's text was not valid JSON"

K="$TMP/k7"
kid "$K" docs-sync 1 0 "docs short" "$(printf '[docs-sync] RAW-FIRST\nRAW-SECOND')"
kid "$K" learn     2 0 "learn-SHORT" '[learn] LEARN-FULL'
dispatch "$K"
valid "RED: a raw newline inside a fragment does not break the JSON" "$RAW"
says "RED: …and both of its lines arrive" "$CTX" "RAW-SECOND"
says "RED: …and the habit line survives next to it" "$CTX" "learn-SHORT"

direct=$( printf '. %q\n_vdm_reminder_emit probe 1 %q %q\n' "$LIBDIR/reminder-emit.sh" \
            'short "q"' 'full "q" \3 end' | bash 2>/dev/null )
valid "RED: run by hand, a reminder with broken text still prints valid JSON" "$direct"

printf '\ndocs-sync: paths git would quote\n'

# The real child, in a repository whose .md names are exactly what git quotes:
# Cyrillic, a space, a double quote. Before the fix all three came out in
# `"…\320…"` form, broke the JSON, and — for a changed file — also failed the
# `[ -f ]` test, so its @see references were silently skipped.
DS="$TMP/ds"; mkdir -p "$DS/docs" "$DS/src"
( cd "$DS" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'a\n' > "$DS/docs/Документ с пробелом.md"
printf 'b\n' > "$DS/docs/quote\"name.md"
printf 'c\n' > "$DS/README.md"
( cd "$DS" && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'x\n' > "$DS/src/app.py"
printf '# @see docs/Документ с пробелом.md\n' > "$DS/docs/Новый.md"
ds=$( cd "$DS" && TMPDIR="$TMP/state3" bash "$REPO_ROOT/plugins/vdm/scripts/docs-sync-reminder.sh" \
        <<<'{"session_id":"ds"}' 2>/dev/null )
valid "RED: docs-sync over Cyrillic, space and quote paths prints valid JSON" "$ds"
dsctx=$(printf '%s' "$ds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"], end="")' 2>/dev/null)
says "RED: …the Cyrillic path with a space reads as itself" "$dsctx" "docs/Документ с пробелом.md"
says "RED: …the path with a quote reads as itself" "$dsctx" 'docs/quote"name.md'
says "RED: …a changed Cyrillic file is listed as itself" "$dsctx" "docs/Новый.md"
says_not "RED: …and no octal escape leaks through" "$ds" '\320'

# The byte half, seen on a live repository on this machine: index entries whose
# names are not UTF-8 at all — APFS will not store such a file, a git index
# will — show as deleted in `git status`. docs-sync read them with -z and then
# ran `tr` and `sed` over the names in the user's locale; in a UTF-8 one macOS
# stops at the first bad byte, and the hook printed "Changed files (4)" and one
# name cut in half (Sidetrack #9, docs/tasks/crystal-wake/workitem.md).
DB="$TMP/dsbytes"; mkdir -p "$DB/src"
( cd "$DB" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' > "$DB/README.md"; printf 'x\n' > "$DB/src/omega.py"; printf 'x\n' > "$DB/src/zeta.py"
( cd "$DB" && git add -A && git commit -qm init ) >/dev/null 2>&1
( cd "$DB" && blob=$(printf 'x\n' | git hash-object -w --stdin) &&
  git update-index --add --cacheinfo "100644,$blob,a$(printf '\320')b.jpg" ) >/dev/null 2>&1
printf 'y\n' >> "$DB/src/omega.py"; printf 'y\n' >> "$DB/src/zeta.py"
db=$( cd "$DB" && LC_ALL=en_US.UTF-8 TMPDIR="$TMP/state4" \
        bash "$REPO_ROOT/plugins/vdm/scripts/docs-sync-reminder.sh" <<<'{"session_id":"db"}' 2>"$TMP/db.err" )
dbctx=$(printf '%s' "$db" | python3 -c '
import json, sys
print(json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))["hookSpecificOutput"]["additionalContext"], end="")' 2>/dev/null)
says "RED: a name that is not UTF-8 does not cut the list of changed files" "$dbctx" "src/zeta.py"
says "RED: …the file after it is listed too" "$dbctx" "src/omega.py"
if [ -s "$TMP/db.err" ]; then bad "RED: …and no tool complains about the bytes" "$(head -c 160 "$TMP/db.err")"
else ok "RED: …and no tool complains about the bytes"; fi

printf '\nwaiting costs nothing per tick\n'
# The dispatcher runs on every prompt of every project. It used to wait for its
# children by polling — `$(jobs -rp)` and a `sleep 0.1` every tick — so a slow
# child cost it a process per 100 ms on top of the child's own, and the prompt
# waited up to 100 ms after the last child had already finished. The property:
# how long the children take changes nothing about what the dispatcher itself
# starts. Counted, not timed — a count holds on a loaded machine.
SHIMS="$TMP/dispatch-shims"; mkdir -p "$SHIMS"
for tool in sleep pkill mktemp rm mkdir sed cat date jq python3 bash; do
  real=$(type -P "$tool" 2>/dev/null) || continue
  cat > "$SHIMS/$tool" <<EOF
#!/bin/bash
printf x >> "\$LAUNCH_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$SHIMS/$tool"
done
launches_waiting_for() {  # launches_waiting_for <seconds> — one child that takes that long
  local kids="$TMP/tick-$1" log="$TMP/tick-$1.log"
  kid "$kids" docs-sync 1 "$1" "docs short" '[docs-sync] slow'
  : > "$log"
  ( cd "$PROJ" && printf '{"session_id":"tick"}' | \
    LAUNCH_LOG="$log" PATH="$SHIMS:$PATH" CLAUDE_PROJECT_DIR="$PROJ" \
    VDM_REMINDERS_DIR="$kids" VDM_REMINDERS_DEADLINE=25 bash "$DISPATCH" >/dev/null 2>&1 )
  wc -c < "$log" | tr -d ' '
}
quick=$(launches_waiting_for 0.2)
slow=$(launches_waiting_for 1.5)
if [ "${quick:-0}" -gt 0 ]; then ok "the counter sees the dispatcher run ($quick launches)"
else bad "the counter sees the dispatcher run" "counted ${quick:-nothing}"; fi
eq "RED: a child 1.3 s slower costs the dispatcher no extra launches" "$slow" "$quick"

printf '\nreminders-dispatch: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
