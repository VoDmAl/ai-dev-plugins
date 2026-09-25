#!/bin/bash
# shared-rules.test.sh — the cross-project rules layer (SessionStart hook).
#
# The promise (field request, space-hq, 2026-09-18): a rule about how the
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
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at a copy and watched go red.
HOOK="${SHARED_RULES_HOOK:-$REPO_ROOT/plugins/vdm/scripts/shared-rules.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac; }
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

echo "== the layer has a ceiling, and cuts on a line =="
{
  printf '## Правило о кириллице\n\n'
  i=0; while [ $i -lt 400 ]; do printf 'Строка правила номер %03d — чтобы файл стал больше лимита.\n' "$i"; i=$((i+1)); done
} > "$RULES"
RAW="$TMP/out.bin"
run "$TMP/project-a" > "$RAW"
out="$(cat "$RAW")"
says "an oversized file is truncated, and says so" "$out" "Truncated"
says "…naming its real size" "$out" "$(wc -c < "$RULES" | tr -d ' ') bytes"
# Judged on the RAW bytes, in the C locale. A first version extracted the body
# with sed in the user's UTF-8 locale — and BSD sed stops at an illegal byte
# sequence, so a byte-offset cut produced a clean-looking prefix and the test
# passed on exactly the input it exists to catch.
if python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$RAW" 2>/dev/null; then
  ok "the cut never splits a letter (the output is valid UTF-8)"
else
  bad "the cut never splits a letter (the output is valid UTF-8)" "the hook output does not decode as UTF-8"
fi
last="$(LC_ALL=C sed '/Truncated: the rules file/,$d' "$RAW" | LC_ALL=C sed '/^$/d' | tail -1)"
case "$last" in
  "Строка правила номер "*"больше лимита.") ok "…and ends on a whole line" ;;
  *) bad "…and ends on a whole line" "last line before the notice is cut" ;;
esac

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
