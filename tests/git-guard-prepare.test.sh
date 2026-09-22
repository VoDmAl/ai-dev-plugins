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
expect_silent() {
  # expect_silent <desc> <output>
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi
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

printf '\n=== superseding a prepared line ===\n'
# The incident this section exists for: a line was prepared, the owner sent
# corrections instead of running it, a second line was prepared — and the FIRST
# one, still in the scrollback and still perfectly valid, was the one that ran.
# The commit went out carrying the superseded message, and nothing said so.
#
# So the contract is not "two preps must not overwrite each other" — that was
# the old one, and it is what kept the stale line alive. It is the opposite:
# preparing again must KILL the earlier line, loudly enough that running it
# fails rather than committing something that has moved on.

# msg_path <emitted command> — the -F argument, unquoted. shell_quote always
# single-quotes, so the first quoted field is the message path.
msg_path() { printf '%s' "$1" | sed -e "s/^git commit -F '//" -e "s/'.*$//"; }

d=$(new_repo supersede); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt
git add a.txt
stale=$("$PREP" "[*] first wording")
fresh=$("$PREP" "[*] corrected wording" 2>/dev/null)

if [ "$(msg_path "$stale")" = "$(msg_path "$fresh")" ]; then
  bad "the second prep gets its own message file" "both preps point at $(msg_path "$fresh")"
else
  ok "the second prep gets its own message file"
fi
if [ -e "$(msg_path "$stale")" ]; then
  bad "the superseded message file is deleted" "$(msg_path "$stale") survived"
else
  ok "the superseded message file is deleted"
fi

run_emitted "$stale" >/dev/null 2>&1; rc=$?
expect_exit "the superseded line refuses to run" 128 "$rc"
expect_eq "the superseded line commits nothing" "base" "$(git log -1 --format=%s)"
run_emitted "$fresh" >/dev/null 2>&1
expect_eq "the current line commits the corrected message" "[*] corrected wording" "$(git log -1 --format=%s)"

# Deleting is not enough on its own: a freed name can be handed out again, and
# then an older scrollback line is silently re-pointed at a newer message. So a
# path is never issued twice, not even after its prep was properly consumed.
d=$(new_repo no_reuse); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt; git add a.txt
c1=$("$PREP" "[*] one")
run_emitted "$c1" >/dev/null 2>&1
printf 'b\n' > b.txt; git add b.txt
c2=$("$PREP" "[*] two")
if [ "$(msg_path "$c1")" = "$(msg_path "$c2")" ]; then
  bad "a consumed prep's path is not issued again" "reused $(msg_path "$c1")"
else
  ok "a consumed prep's path is not issued again"
fi

# Whatever the history, at most one trio survives. Nineteen live message files
# in one session's TMPDIR is what the previous scheme left behind, and every one
# of them was a runnable command.
d=$(new_repo one_trio); cd "$d" || exit 1
export TMPDIR="$d/tmp"
i=1
while [ $i -le 4 ]; do
  printf '%s\n' "$i" > "f$i.txt"; git add "f$i.txt"
  "$PREP" "[*] prep $i" >/dev/null 2>&1
  i=$((i+1))
done
expect_eq "one message file survives four preps" "1" "$(ls -1 "$TMPDIR"/*.txt   2>/dev/null | grep -c .)"
expect_eq "one paths file survives four preps"   "1" "$(ls -1 "$TMPDIR"/*.paths 2>/dev/null | grep -c .)"
expect_eq "one meta file survives four preps"    "1" "$(ls -1 "$TMPDIR"/*.meta  2>/dev/null | grep -c .)"
# The survivor must be a matched set — a message paired with someone else's path
# list would commit one prep's wording over the other's files.
surv=$(ls -1 "$TMPDIR"/*.txt); surv="${surv%.txt}"
if [ -f "$surv.paths" ] && [ -f "$surv.meta" ]; then
  ok "the surviving message file has its own companions"
else
  bad "the surviving message file has its own companions" "incomplete trio: $surv"
fi

# Files from the pre-token scheme carry no .meta. They are precisely what
# accumulated, and they go without comment: HEAD moved past them long ago, so
# there is nothing to report — only litter to clear.
d=$(new_repo legacy); cd "$d" || exit 1
export TMPDIR="$d/tmp"
br=$(git symbolic-ref --quiet --short HEAD)
legacy="$TMPDIR/$(basename "$d")-${br}-commit"
printf 'stale message\n' > "$legacy.txt"
: > "$legacy.paths"
printf 'x\n' > a.txt; git add a.txt
out=$("$PREP" "[*] fresh" 2>&1 >/dev/null)
if [ -e "$legacy.txt" ] || [ -e "$legacy.paths" ]; then
  bad "a pre-token leftover is swept" "$legacy.txt survived"
else
  ok "a pre-token leftover is swept"
fi
expect_silent "sweeping an already-audited leftover says nothing" "$out"

# Unborn HEAD: no commits at all, so every prep's recorded HEAD is empty. The
# empty value must not read as "this prep was consumed" — nor make each prep
# take a fresh name and leak the ones before it.
d="$TMP/unborn"; rm -rf "$d"; mkdir -p "$d/tmp"
cd "$d" || exit 1
git init -q .; git config user.email t@t; git config user.name t
export TMPDIR="$d/tmp"
printf 'a\n' > a.txt; git add a.txt
"$PREP" "[*] one" > /dev/null 2>&1
out=$("$PREP" "[*] two" 2>&1 >/dev/null)
expect_eq "unborn HEAD leaves one message file" "1" "$(ls -1 "$TMPDIR"/*.txt 2>/dev/null | grep -c .)"
expect_says "unborn HEAD still reports the superseded line" "$out" "never run"

printf '\n=== detector: did the commit match what was prepared? ===\n'
# The reason this exists: a commit lost six files and gained one that was never
# named, and nothing noticed for two days. Three hypotheses about the cause were
# raised and all three refuted. A detector needs no theory of the cause — which
# is why it is the right answer to a defect that resists diagnosis.
#
# It must be silent on ordinary git usage. A detector that cries wolf gets
# ignored, and an ignored detector is worse than an absent one, so the
# false-positive cases below carry as much weight as the true-positive ones.

# TRUE POSITIVE: a neighbour stages an extra file; the bare form sweeps it in.
d=$(new_repo detect_extra); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'mine\n' > mine.txt
git add mine.txt
"$PREP" "[*] only mine" > /dev/null          # declares: mine.txt
printf 'theirs\n' > theirs.txt
git add theirs.txt                            # the neighbour
git commit -qm "[*] only mine"                # bare form — sweeps both
printf 'next\n' > next.txt; git add next.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_says "detector reports the swept-in path" "$out" "theirs.txt"
expect_says "detector labels it SWEPT IN" "$out" "SWEPT IN"
expect_not_says "detector does not accuse the intended path" "$out" "  mine.txt"

# TRUE POSITIVE: an empty commit against a non-empty declaration — the exact
# shape of e46e697.
d=$(new_repo detect_empty); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > a.txt
git add a.txt
"$PREP" "[*] declares a.txt" > /dev/null
git reset -q a.txt                            # something unstages it
git commit -q --allow-empty -m "[*] declares a.txt"
printf 'n\n' > n.txt; git add n.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_says "detector catches the empty commit" "$out" "EMPTY COMMIT"
expect_says "detector names what was expected" "$out" "a.txt"

# TRUE POSITIVE: a non-empty commit that dropped one of the declared paths.
# Distinct branch from the empty case above, with its own wording — and the
# wording matters, because a declared path whose content already matched HEAD
# drops out legitimately, so this report has to stay a warning rather than an
# accusation.
d=$(new_repo detect_dropped); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > a.txt; printf 'y\n' > b.txt
git add a.txt b.txt
"$PREP" "[*] declares both" > /dev/null      # declares: a.txt, b.txt
git reset -q b.txt                            # b.txt falls out of the index
git commit -qm "[*] declares both"
printf 'n\n' > n.txt; git add n.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_says "detector reports the dropped path" "$out" "b.txt"
expect_says "dropped path uses the NOT COMMITTED wording" "$out" "NOT COMMITTED"
expect_not_says "non-empty commit is not called empty" "$out" "EMPTY COMMIT"

# FALSE POSITIVE 1: the commit matches the declaration exactly ⇒ silence.
d=$(new_repo detect_clean); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > a.txt; printf 'y\n' > b.txt
git add a.txt b.txt
cmd=$("$PREP" "[*] clean")
run_emitted "$cmd" >/dev/null 2>&1
printf 'n\n' > n.txt; git add n.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_silent "exact match ⇒ detector silent" "$out"

# FALSE POSITIVE 2: HEAD moved by something that is not this prep's commit
# (amend, rebase, an unrelated commit). Not the detector's business.
d=$(new_repo detect_unrelated); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > a.txt
git add a.txt
"$PREP" "[*] declares a.txt" > /dev/null
printf 'z\n' > z.txt; git add z.txt
git commit -qm "a completely different commit"   # different message
printf 'n\n' > n.txt; git add n.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_silent "unrelated commit ⇒ detector silent" "$out"

# FALSE POSITIVE 3: nothing committed yet — the prep is still pending. The
# detector must not accuse a commit that never happened. The supersession notice
# on the same stderr is a different statement about a different thing, and it is
# required here, so this asserts the absence of the accusation rather than
# silence.
d=$(new_repo detect_pending); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'x\n' > a.txt
git add a.txt
"$PREP" "[*] pending" > /dev/null
printf 'y\n' > b.txt; git add b.txt
out=$("$PREP" "[*] second" 2>&1 >/dev/null)
expect_not_says "unconsumed prep ⇒ no accusation about a commit" "$out" "does not match what was prepared"
expect_not_says "unconsumed prep ⇒ nothing labelled SWEPT IN" "$out" "SWEPT IN"
expect_says "unconsumed prep ⇒ the earlier line is declared void" "$out" "never run"

# The audit must run ONCE. A record left behind would re-accuse the same commit
# on every later prep, which is how a real signal becomes background noise.
d=$(new_repo detect_once); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'mine\n' > mine.txt
git add mine.txt
"$PREP" "[*] once" > /dev/null
printf 'theirs\n' > theirs.txt; git add theirs.txt
git commit -qm "[*] once"
printf 'n\n' > n.txt; git add n.txt
out1=$("$PREP" "[*] n1" 2>&1 >/dev/null)
printf 'm\n' > m.txt; git add m.txt
out2=$("$PREP" "[*] n2" 2>&1 >/dev/null)
expect_says "first prep after the bad commit reports it" "$out1" "theirs.txt"
expect_not_says "second prep does not repeat the accusation" "$out2" "theirs.txt"
expect_not_says "second prep does not repeat the SWEPT IN label" "$out2" "SWEPT IN"

# Standalone mode, for a post-commit hook or a by-hand check.
d=$(new_repo detect_standalone); cd "$d" || exit 1
export TMPDIR="$d/tmp"
printf 'mine\n' > mine.txt
git add mine.txt
"$PREP" "[*] standalone" > /dev/null
printf 'theirs\n' > theirs.txt; git add theirs.txt
git commit -qm "[*] standalone"
out=$("$PREP" --verify-last 2>&1 >/dev/null); rc=$?
expect_exit "--verify-last exits 0 even when it complains" 0 "$rc"
expect_says "--verify-last reports the swept-in path" "$out" "theirs.txt"

# Paths with spaces and non-ASCII must survive the round trip through the
# sidecar and be reported readably, not as octal escapes.
d=$(new_repo detect_quoting); cd "$d" || exit 1
export TMPDIR="$d/tmp"
mkdir -p sub
printf 'x\n' > "sub/имя с пробелом.txt"
git add "sub/имя с пробелом.txt"
"$PREP" "[*] quoted" > /dev/null
printf 'theirs\n' > theirs.txt; git add theirs.txt
git commit -qm "[*] quoted"
printf 'n\n' > n.txt; git add n.txt
out=$("$PREP" "[*] next" 2>&1 >/dev/null)
expect_not_says "detector does not print octal escapes" "$out" '\3'

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
