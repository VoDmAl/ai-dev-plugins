#!/bin/bash
# fffd.test.sh — RED TESTS for the U+FFFD guard on both of its surfaces.
#
# U+FFFD is what a truncated multi-byte codepoint decodes to. It is produced by
# a batch write and found weeks later, so the only useful guard is one that
# runs at commit time without anyone remembering it.
#
# Both surfaces are tested, and they exist for different reasons:
#
#   * `git-guard-prepare` — covers every commit the assistant prepares, which
#     is where the corruption comes from. No installation step.
#   * `fffd-precommit-check.sh` — covers commits made by hand or from an IDE,
#     which the helper never sees. Needs installing per clone.
#
# The pre-commit surface reads the STAGED blob, not the working tree, and the
# difference is the whole point of a pre-commit gate: an unstaged fix does not
# travel with the commit, and an unstaged breakage is not part of it either.
# Both directions are asserted below.
#
# Run: bash tests/fffd.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm-git/bin/git-guard-prepare
# @see plugins/vdm-git/scripts/fffd-precommit-check.sh

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
PREP="$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare"
CHECK="$REPO_ROOT/plugins/vdm-git/scripts/fffd-precommit-check.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { case "$2" in *"$3"*) bad "$1" "should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fffd)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

new_repo() {
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d/tmp"
  (
    cd "$d" || exit 1
    git init -q .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    printf 'base\n' > .keep
    git add .keep
    git commit -qm base
  )
  printf '%s' "$d"
}

# A Cyrillic word with one letter cut in half — the shape the origin incident
# produced, written as raw bytes so the fixture cannot be "fixed" by an editor.
corrupt_text() { printf 'Проверка \xef\xbf\xbd\xef\xbf\xbdкста\n'; }

echo "== git-guard-prepare: the surface with no installation step =="

d=$(new_repo prep); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'чистый текст\n' > clean.md
git add clean.md
out=$("$PREP" "[*] clean" 2>&1); rc=$?
expect_exit "GREEN: clean Cyrillic file prepares fine" 0 "$rc"
expect_says "GREEN: it emits the commit line" "$out" "git commit -F"

corrupt_text > broken.md
git add broken.md
out=$("$PREP" "[*] broken" 2>&1); rc=$?
expect_exit "RED: staged U+FFFD ⇒ exit 1" 1 "$rc"
expect_says "RED: names the file" "$out" "broken.md"
expect_says "RED: explains what the character means" "$out" "truncated"
expect_not_says "RED: and emits no commit line" "$out" "git commit -F"

# The refusal must be fixable the obvious way and then get out of the way.
printf 'Проверка текста\n' > broken.md
git add broken.md
out=$("$PREP" "[*] fixed" 2>&1); rc=$?
expect_exit "GREEN: after the fix it prepares" 0 "$rc"

# Only the named paths are inspected: a corrupt file nobody staged is not this
# commit's problem.
corrupt_text > unrelated.md
out=$("$PREP" "[*] subset" -- clean.md 2>&1); rc=$?
expect_exit "GREEN: an unstaged corrupt file is not inspected" 0 "$rc"

echo ""
echo "== fffd-precommit-check: the surface that reads the STAGED blob =="

d=$(new_repo hook); cd "$d" || exit 1
printf 'чисто\n' > a.md
git add a.md
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "GREEN: clean index ⇒ exit 0" 0 "$rc"

corrupt_text > b.md
git add b.md
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "RED: corrupt staged blob ⇒ exit 1" 1 "$rc"
expect_says "RED: names the file" "$out" "b.md"

# STAGED, not working tree — in both directions.
printf 'исправлено\n' > b.md            # fixed on disk, NOT staged
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "RED: an unstaged fix does not clear the index" 1 "$rc"

git add b.md
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "GREEN: staging the fix clears it" 0 "$rc"

corrupt_text > c.md                      # corrupt on disk, never staged
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "GREEN: unstaged corruption is not this commit's problem" 0 "$rc"

d=$(new_repo empty); cd "$d" || exit 1
out=$(bash "$CHECK" 2>&1); rc=$?
expect_exit "GREEN: nothing staged ⇒ exit 0" 0 "$rc"

out=$(cd "$TMP" && bash "$CHECK" 2>&1); rc=$?
expect_exit "RED: outside a repository it refuses rather than passing" 1 "$rc"

printf '\nfffd: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
