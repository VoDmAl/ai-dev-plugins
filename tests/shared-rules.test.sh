#!/bin/bash
# shared-rules.test.sh — the cross-project rules layer (SessionStart hook).
#
# The promise (field request, hq, 2026-09-18): a rule about how the
# assistant works, written once, reaches EVERY session on the machine — "write
# it in one contour, open another, see it there". The assertions below are that
# promise, plus the two ways such a layer fails quietly: a rules file that
# exists but does not load, and a file that grows until it is truncated.
#
# Run: bash tests/shared-rules.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/shared-rules.sh

set -u

# Scrub git's per-invocation environment (see gates-harness-isolation.test.sh):
# run from inside a pre-commit gate, a harness inherits the commit's index.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at a copy and watched go red.
HOOK="${SHARED_RULES_HOOK:-$REPO_ROOT/plugins/vdm/scripts/shared-rules.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac; }
eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t sharedrules)
trap 'chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/vdm" "$TMP/project-a" "$TMP/project-b/sub" "$TMP/not-a-repo"
git -C "$TMP/project-a" init -q . ; git -C "$TMP/project-b" init -q .
RULES="$HOME/.claude/vdm/rules.md"
run() { ( cd "$1" && printf '{"session_id":"t","source":"startup"}' | bash "$HOOK" ); }

echo "== no rules, no output =="
out="$(run "$TMP/project-a")"; rc=$?
eq "no rules file ⇒ exit 0" "$rc" "0"
eq "…and nothing at all" "$out" ""
printf '  \n\n\t\n' > "$RULES"
eq "a blank rules file ⇒ nothing" "$(run "$TMP/project-a")" ""

echo "== written once, seen everywhere =="
printf '## A self-description is a claim, not a fact\n\nRecord it as "X says Y".\n' > "$RULES"
for d in "$TMP/project-a" "$TMP/project-b/sub" "$TMP/not-a-repo" "$HOME"; do
  out="$(run "$d")"
  says "the rule reaches a session in $(basename "$d")" "$out" "A self-description is a claim, not a fact"
done
out="$(run "$TMP/project-a")"
says "the header names where the rules live" "$out" "$RULES"
says "…and that a project must not copy them" "$out" "do not copy them"
eq "the hook exits 0 — it never blocks" "$(run "$TMP/project-a" >/dev/null; echo $?)" "0"

echo "== a layer that fails must say so =="
chmod 000 "$RULES"
out="$(run "$TMP/project-a")"; rc=$?
if [ -r "$RULES" ]; then
  ok "unreadable file — skipped: running as a user who can read anything"
else
  eq "an unreadable rules file ⇒ still exit 0" "$rc" "0"
  says "…and it says the rules did NOT load" "$out" "NOT loaded"
fi
chmod 644 "$RULES"

echo "== every rule reaches the session, as its first paragraph =="
# Field case (2026-10-07): the harness puts a hook's text output longer than
# about 10 000 characters into a file and hands the session a 2 KB preview. The
# layer then carried 12 288 bytes of a 16 918-byte file and was put away at
# 1 034 session starts in a week — sessions saw the header and half a rule.
# Now the heading and first paragraph of each rule ride; the rest is read from
# the file. A file well over the old ceiling must deliver every rule, whole.
{
  printf '# Cross-project rules\n\nA preamble about the file itself.\n\n'
  i=1; while [ $i -le 12 ]; do
    printf '## Правило номер %02d\n\nСамо правило номер %02d — две фразы. Вторая фраза правила %02d.\n\n' "$i" "$i" "$i"
    j=0; while [ $j -lt 20 ]; do printf 'BODY-ONLY строка обоснования %02d-%02d, таблицы и случаи.\n' "$i" "$j"; j=$((j+1)); done
    printf '\nOrigin: проект, 2026-10-07 — случай.\n\n'
    i=$((i+1))
  done
} > "$RULES"
size="$(wc -c < "$RULES" | tr -d ' ')"
[ "$size" -gt 16000 ] && ok "fixture is past the old 12 KB ceiling ($size bytes)" \
  || bad "fixture is past the old 12 KB ceiling" "it is $size bytes"
RAW="$TMP/out.bin"; run "$TMP/project-a" > "$RAW"; out="$(cat "$RAW")"
n=0; i=1; while [ $i -le 12 ]; do case "$out" in *"Само правило номер $(printf %02d $i)"*) n=$((n+1)) ;; esac; i=$((i+1)); done
eq "RED: all twelve rules reach the session" "$n" "12"
says_not "…as first paragraphs: the body stays in the file" "$out" "BODY-ONLY"
says_not "…and the preamble about the file does not ride" "$out" "A preamble about the file"
says_not "…nothing is reported as cut" "$out" "did not fit"
says "the header says where the reasons and cases are" "$out" "read a rule's section when it applies"
bytes="$(wc -c < "$RAW" | tr -d ' ')"
[ "$bytes" -le 9000 ] && ok "RED: the output stays under the harness threshold ($bytes ≤ 9000 bytes)" \
  || bad "RED: the output stays under the harness threshold" "$bytes bytes"

echo "== rules that do not fit are named, never cut in the middle =="
{
  i=1; while [ $i -le 30 ]; do
    printf '## Длинное правило %02d\n\n' "$i"
    j=0; while [ $j -lt 6 ]; do printf 'Первый абзац правила %02d слишком длинный, строка %d, кириллица.\n' "$i" "$j"; j=$((j+1)); done
    printf '\n'
    i=$((i+1))
  done
} > "$RULES"
run "$TMP/project-a" > "$RAW"; out="$(cat "$RAW")"
bytes="$(wc -c < "$RAW" | tr -d ' ')"
[ "$bytes" -le 9000 ] && ok "over budget, the output still stays under it ($bytes bytes)" \
  || bad "over budget, the output still stays under it" "$bytes bytes"
says "…the rules that did not fit are counted" "$out" "rule(s) did not fit the layer"
says "…named, so the session knows they exist" "$out" "Длинное правило 30"
says "…and where to read them" "$out" "$RULES"
says "…and the author is told what to shorten" "$out" "Shorten first paragraphs"
says "a rule that fitted arrives whole" "$out" "Первый абзац правила 01 слишком длинный, строка 5"
if python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$RAW" 2>/dev/null; then
  ok "the output is valid UTF-8 — no letter split"
else
  bad "the output is valid UTF-8 — no letter split" "the hook output does not decode as UTF-8"
fi

echo "== a file with no rules is delivered by whole lines =="
{
  i=0; while [ $i -lt 400 ]; do printf 'Строка без заголовков номер %03d — чтобы файл стал больше лимита.\n' "$i"; i=$((i+1)); done
} > "$RULES"
run "$TMP/project-a" > "$RAW"; out="$(cat "$RAW")"
says "an oversized file without rules is truncated, and says so" "$out" "Truncated"
bytes="$(wc -c < "$RAW" | tr -d ' ')"
[ "$bytes" -le 9000 ] && ok "…under the threshold ($bytes bytes)" || bad "…under the threshold" "$bytes bytes"
if python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$RAW" 2>/dev/null; then
  ok "…valid UTF-8"
else
  bad "…valid UTF-8" "the hook output does not decode as UTF-8"
fi
last="$(LC_ALL=C sed '/Truncated: the rules file/,$d' "$RAW" | LC_ALL=C sed '/^$/d' | tail -1)"
case "$last" in
  "Строка без заголовков номер "*"больше лимита.") ok "…and ends on a whole line" ;;
  *) bad "…and ends on a whole line" "last line before the notice is cut" ;;
esac

echo "== --measure, for /vdm:learn before it writes a rule =="
printf '## Короткое правило\n\nОдна фраза.\n\nОбоснование.\n' > "$RULES"
out="$(bash "$HOOK" --measure 2>&1)"; rc=$?
eq "a layer that fits ⇒ exit 0" "$rc" "0"
says "…and says how much it carries" "$out" "of 9000 bytes"
{
  i=1; while [ $i -le 30 ]; do
    printf '## Длинное правило %02d\n\n' "$i"
    j=0; while [ $j -lt 6 ]; do printf 'Первый абзац правила %02d слишком длинный, строка %d, кириллица.\n' "$i" "$j"; j=$((j+1)); done
    printf '\n'; i=$((i+1))
  done
} > "$RULES"
out="$(bash "$HOOK" --measure 2>&1)"; rc=$?
eq "a layer that does not fit ⇒ exit 1" "$rc" "1"
says "…and names what did not fit" "$out" "did not fit"

echo "== wiring =="
hj="$REPO_ROOT/plugins/vdm/hooks/hooks.json"
if command -v jq >/dev/null 2>&1; then
  eq "registered as a SessionStart hook" \
     "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("/scripts/shared-rules.sh"))] | length' "$hj")" "1"
else
  says "registered as a SessionStart hook" "$(cat "$hj")" "scripts/shared-rules.sh"
fi
[ -x "$REPO_ROOT/plugins/vdm/scripts/shared-rules.sh" ] && ok "the hook is executable" || bad "the hook is not executable"
says "the learn skill names the address" "$(cat "$REPO_ROOT/plugins/vdm/skills/learn/SKILL.md")" "~/.claude/vdm/rules.md"

printf '\nshared-rules: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
