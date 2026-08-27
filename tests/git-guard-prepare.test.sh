#!/bin/bash
# git-guard-prepare.test.sh — RED TESTS for the commit-command emitter.
#
# A gate does not exist until you have watched it FAIL (docs/model/suite.md).
# This helper is not a gate but it makes the same kind of promise: the command
# it prints commits EXACTLY the paths it names and nothing else. Green output
# proves nothing on its own — a command that prints is not a command that
# commits the right thing. So the assertions below check what git actually
# receives after the emitted line goes through a shell, and every refusal path
# is exercised in the direction where it must refuse.
#
# The whole reason this file exists: `git commit -- <paths>` commits the
# WORKING TREE version of those paths, not the staged one. That is a silent
# wrong-content failure, which is exactly the class a test suite has to own
# because no human notices it in review.
#
# Run: bash tests/git-guard-prepare.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm-git/bin/git-guard-prepare
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — DL #4, #5, #6

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_exit() {
  # expect_exit <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi
}
expect_says() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "output did not mention: $3" ;;
  esac
}
expect_not_says() {
  case "$2" in
    *"$3"*) bad "$1" "output should NOT mention: $3" ;;
    *)      ok "$1" ;;
  esac
}
expect_eq() {
  # expect_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ggprep)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fresh repo with one base commit. Each test gets its own so state cannot leak.
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

# Run the emitted command through a shell, as the user would.
run_emitted() { eval "$1"; }

printf '\n=== path list ===\n'

d=$(new_repo basic); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt; printf 'b\n' > b.txt
git add a.txt b.txt
out=$("$PREP" "[*] two files" 2>&1); rc=$?
expect_exit "two staged files → exit 0" 0 "$rc"
expect_says "emits pathspec separator" "$out" " -- "
expect_says "names a.txt" "$out" "'a.txt'"
expect_says "names b.txt" "$out" "'b.txt'"

printf '\n=== the defect from the brief: a parallel session stages its own ===\n'

d=$(new_repo parallel); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'mine\n' > mine.txt
git add mine.txt
cmd=$("$PREP" "[*] mine only")
printf 'theirs\n' > theirs.txt
git add theirs.txt              # neighbouring agent, after prep, before run
run_emitted "$cmd" >/dev/null 2>&1
if git cat-file -e HEAD:theirs.txt 2>/dev/null; then
  bad "foreign staged file kept out of the commit" "theirs.txt leaked into HEAD"
else
  ok "foreign staged file kept out of the commit"
fi
expect_eq "foreign file still staged afterwards" "theirs.txt" "$(git diff --cached --name-only)"

printf '\n=== refusals ===\n'

d=$(new_repo empty); cd "$d" || exit 1
export TMPDIR="$d/tmp"
out=$("$PREP" "[*] nothing" 2>&1); rc=$?
expect_exit "empty index → exit 1" 1 "$rc"
expect_says "empty index names the fix" "$out" "git add"
expect_not_says "empty index emits no command" "$out" "git commit -F"

d=$(new_repo diverge); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'staged\n' > a.txt
git add a.txt
printf 'worktree\n' > a.txt      # edited after `git add`
out=$("$PREP" "[*] diverged" 2>&1); rc=$?
expect_exit "index≠worktree → exit 1" 1 "$rc"
expect_says "divergence names the offending path" "$out" "a.txt"
expect_says "divergence explains the loss" "$out" "discard what is staged"
expect_not_says "divergence emits no command" "$out" "git commit -F"

# The refusal must be scoped to the listed paths, not the whole tree — a stray
# dirty file elsewhere is not a reason to block a commit that never names it.
printf 'staged\n' > b.txt
git add b.txt
printf 'dirty\n' > b.txt
git checkout -q -- a.txt 2>/dev/null || true
git reset -q a.txt
printf 'clean-staged\n' > c.txt
git add c.txt
out=$("$PREP" "[*] scoped" -- c.txt 2>&1); rc=$?
expect_exit "divergence outside the named paths does not block" 0 "$rc"
expect_says "scoped emit names only c.txt" "$out" "'c.txt'"
expect_not_says "scoped emit omits b.txt" "$out" "'b.txt'"

printf '\n=== explicit subset ===\n'

d=$(new_repo subset); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt; printf 'b\n' > b.txt
git add a.txt b.txt
cmd=$("$PREP" "[*] subset" -- a.txt)
expect_not_says "explicit subset omits the unlisted path" "$cmd" "'b.txt'"
run_emitted "$cmd" >/dev/null 2>&1
if git cat-file -e HEAD:b.txt 2>/dev/null; then
  bad "unlisted staged file stays out of the commit" "b.txt leaked into HEAD"
else
  ok "unlisted staged file stays out of the commit"
fi

out=$("$PREP" "[*] bad args" a.txt 2>&1); rc=$?
expect_exit "paths without the -- separator → exit 1" 1 "$rc"
expect_says "bad args explain the separator" "$out" "--"

printf '\n=== renames (the trap the brief got backwards) ===\n'
# git reports `git mv` as ONE rename entry naming only the destination. A
# commit built from that list records the addition without the deletion and
# leaves the old path in the tree. --no-renames is what prevents it.

d=$(new_repo rename); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > old.txt
git add old.txt
git commit -qm "add old.txt"
git mv old.txt new.txt
cmd=$("$PREP" "[*] rename")
expect_says "rename lists the destination" "$cmd" "'new.txt'"
expect_says "rename ALSO lists the source" "$cmd" "'old.txt'"
run_emitted "$cmd" >/dev/null 2>&1
if git cat-file -e HEAD:old.txt 2>/dev/null; then
  bad "old path removed from the commit tree" "old.txt survived the rename commit"
else
  ok "old path removed from the commit tree"
fi
expect_eq "new path present in the commit tree" "x" "$(git show HEAD:new.txt)"

printf '\n=== deletions ===\n'

d=$(new_repo delete); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > gone.txt
git add gone.txt
git commit -qm "add gone.txt"
git rm -q gone.txt
cmd=$("$PREP" "[*] delete")
run_emitted "$cmd" >/dev/null 2>&1
if git cat-file -e HEAD:gone.txt 2>/dev/null; then
  bad "deletion recorded in the commit" "gone.txt still in HEAD"
else
  ok "deletion recorded in the commit"
fi

printf '\n=== nested paths ===\n'
# Every other fixture in this file sits at the repo root. That gap was found the
# hard way: a real commit naming only paths under `tests/` produced an empty
# commit, and the suite could not say whether the pathspec form was to blame
# because it had never once exercised a nested path. The diagnostic
# (references/verify-pathspec-subdir.sh) exonerated the form — but the coverage
# hole was real either way, and a suite that cannot answer "was it us?" is not
# doing its job.

d=$(new_repo nested); cd "$d" || exit 1
export TMPDIR="$d/tmp"
mkdir -p sub/deeper
printf 'x\n' > sub/a.sh
printf 'y\n' > sub/deeper/b.sh
git add sub
cmd=$("$PREP" "[*] nested")
expect_says "nested path is named in full" "$cmd" "'sub/a.sh'"
expect_says "doubly-nested path is named in full" "$cmd" "'sub/deeper/b.sh'"
run_emitted "$cmd" >/dev/null 2>&1
for p in sub/a.sh sub/deeper/b.sh; do
  if git cat-file -e "HEAD:$p" 2>/dev/null; then
    ok "committed from a directory absent in HEAD: $p"
  else
    bad "committed from a directory absent in HEAD: $p" "not in HEAD"
  fi
done

# A sibling left unnamed must survive untouched — the scoping property, checked
# where it is least obvious: inside a directory the commit does create.
d=$(new_repo nested_sibling); cd "$d" || exit 1
export TMPDIR="$d/tmp"
mkdir -p sub
printf 'x\n' > sub/named.sh
printf 'y\n' > sub/unnamed.sh
git add sub
cmd=$("$PREP" "[*] nested subset" -- sub/named.sh)
run_emitted "$cmd" >/dev/null 2>&1
git cat-file -e HEAD:sub/named.sh 2>/dev/null \
  && ok "named sibling committed" || bad "named sibling committed" "missing"
git cat-file -e HEAD:sub/unnamed.sh 2>/dev/null \
  && bad "unnamed sibling stays out" "sub/unnamed.sh leaked" || ok "unnamed sibling stays out"

printf '\n=== path quoting ===\n'
# Non-ASCII, spaces and an embedded single quote must survive the round trip
# through the shell. `-z` is what keeps git from C-quoting the first class.

d=$(new_repo quoting); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > 'кириллица.md'
printf 'x\n' > 'с пробелом.md'
printf 'x\n' > "it's.md"
git add 'кириллица.md' 'с пробелом.md' "it's.md"
cmd=$("$PREP" "[*] quoting")
expect_not_says "no C-quoted octal escapes" "$cmd" '\3'
run_emitted "$cmd" >/dev/null 2>&1
for p in 'кириллица.md' 'с пробелом.md' "it's.md"; do
  if git cat-file -e "HEAD:$p" 2>/dev/null; then
    ok "committed intact: $p"
  else
    bad "committed intact: $p" "not found in HEAD"
  fi
done

printf '\n=== long lists switch to --pathspec-from-file ===\n'

d=$(new_repo longlist); cd "$d" || exit 1
export TMPDIR="$d/tmp"
i=1; while [ $i -le 25 ]; do printf '%s\n' "$i" > "f$i.txt"; i=$((i+1)); done
git add .
cmd=$("$PREP" "[*] many")
expect_says "over threshold uses --pathspec-from-file" "$cmd" "--pathspec-from-file="
expect_says "over threshold uses NUL separation" "$cmd" "--pathspec-file-nul"
run_emitted "$cmd" >/dev/null 2>&1
expect_eq "all 25 paths committed" "25" "$(git show --name-only --format= HEAD | grep -c .)"

# Under the threshold the inline form must be kept — the companion file is an
# escape hatch for unreadable lines, not the default.
d=$(new_repo shortlist); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt
git add a.txt
cmd=$("$PREP" "[*] few")
expect_not_says "under threshold stays inline" "$cmd" "--pathspec-from-file"

printf '\n=== prep file pairing ===\n'
# Two preps against an unmoved HEAD must not overwrite each other, and a
# message file must never be paired with another prep's path list.

d=$(new_repo pairing); cd "$d" || exit 1
export TMPDIR="$d/tmp"
i=1; while [ $i -le 25 ]; do printf '%s\n' "$i" > "g$i.txt"; i=$((i+1)); done
git add .
"$PREP" "[*] first"  > /dev/null
"$PREP" "[*] second" > /dev/null
for f in "$TMPDIR"/*.txt; do
  base="${f%.txt}"
  if [ -f "$base.paths" ]; then
    ok "message file has its own paths companion: $(basename "$f")"
  else
    bad "message file has its own paths companion: $(basename "$f")" "missing $base.paths"
  fi
done

# Unborn HEAD must not leak the literal string "HEAD" into the sentinel and
# make every prep take a fresh suffix.
d="$TMP/unborn"; rm -rf "$d"; mkdir -p "$d/tmp"
cd "$d" || exit 1
git init -q .; git config user.email t@t; git config user.name t
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt; git add a.txt
"$PREP" "[*] one" > /dev/null
"$PREP" "[*] two" > /dev/null
expect_eq "unborn HEAD does not leak suffixes" "1" "$(ls -1 "$TMPDIR"/*.txt 2>/dev/null | grep -c .)"

printf '\n=== documentation agreement ===\n'
# The emitted form is described in three places that reach the assistant. When
# any of them still says the old bare form, agents describe the old form to the
# user regardless of what the script does.

for f in \
  "$REPO_ROOT/plugins/vdm-git/skills/guard/SKILL.md" \
  "$REPO_ROOT/plugins/vdm-git/scripts/git-guard-reminder.sh" \
  "$REPO_ROOT/plugins/vdm-git/scripts/git-guard-hook.py" \
  "$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare"
do
  name=$(basename "$f")
  if grep -q -- "-- <paths>" "$f"; then
    ok "$name documents the pathspec form"
  else
    bad "$name documents the pathspec form" "no '-- <paths>' found"
  fi
done

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
