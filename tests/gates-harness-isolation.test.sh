#!/bin/bash
# gates-harness-isolation.test.sh — the harness must not write into the commit
# it is being run by.
#
# The incident this file exists for. `.githooks/pre-commit` gate 6 runs
# `tests/gates.test.sh` as a child of a live `git commit`. Git exports its
# plumbing environment to hooks, and for a pathspec commit (`git commit --
# <paths>`, the form `git-guard-prepare` hands out) `GIT_INDEX_FILE` names a
# TEMPORARY INDEX inside the real `.git/` holding exactly the tree about to be
# committed. The harness builds a throwaway clone deliberately WITHOUT
# `tests/`, then runs `git add -A` in it. With the variable inherited, that
# `git add -A` wrote into the pending commit's index and recorded the deletion
# of every `tests/*` path.
#
# Commit c60f05f (2026-09-04) therefore shipped without eight test files that
# were never touched on disk — their mtimes still read weeks old afterwards.
# Same shape as the 2026-08-27 incident, "the commit lost six files and
# captured one", whose three hypotheses were all refuted and whose cause was
# recorded as never established. Hypothesis #2 there was GIT_INDEX_FILE
# leakage; it was dropped as unreproducible because reproducing it needs gate 6
# to actually fire, and gate 6 is conditional on a gate file being staged.
#
#   A harness that runs inside a hook inherits the caller's git session.
#   Prove the scrub, or the observer edits the observation.
#
# What this asserts, and why in this shape: the failure is invisible from the
# harness's own output — it passed all 54 assertions while corrupting the
# commit. So the observation is made from OUTSIDE: poison the environment with
# an index we control, run the harness, and compare that index byte for byte.
#
# RED half. A green run here proves nothing on its own — an assertion that
# never fires is the defect it is written against. So the same probe is run
# against a copy of the harness with the scrub line stripped out, and that copy
# MUST corrupt the index. If the red half stops failing, this test has gone
# blind and the assertion below is worthless.
#
# Run: bash tests/gates-harness-isolation.test.sh   (exit 0 = all pass)
#
# @see tests/gates.test.sh — the scrub block at the top
# @see .githooks/pre-commit — gate 6, which runs both files
# @see docs/model/suite.md — «Когда диагностика провалилась: детекция без теории причины»

set -u

# ---------------------------------------------------------------------------
# This file is ALSO run from the pre-commit hook, so it inherits the same
# poisoned environment it exists to detect — and the first version did not
# scrub it. Result, observed 2026-09-04: `mk_bait`'s `git init` + `git add -A`
# followed the inherited GIT_DIR/GIT_INDEX_FILE home, wrote a blob into the
# bait repo's object store but the entry into the real commit's index, and the
# commit died with `invalid object … for 'tests/some.test.sh'`. The probe
# written to catch the bug had the bug.
#
#   A test that must poison an environment has to own that environment first.
#
# So: scrub here, and re-inject the poison ONLY into the subshell that runs the
# harness under test (see run_probe).
# ---------------------------------------------------------------------------
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$REPO_ROOT/tests/gates.test.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gatesiso)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The bait: a file that stands in for the real repo's temporary commit index.
# Its content is irrelevant — all that matters is whether a `git` command
# somewhere inside the harness writes to it.
mk_bait() {
  # mk_bait <path> — prints nothing on success, "ERR: …" on failure.
  local repo="$TMP/bait-repo"
  rm -rf "$repo"; mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q .
    git config user.email t@t
    git config user.name  t
    mkdir -p tests
    printf 'x\n' > tests/some.test.sh
    printf 'y\n' > kept.txt
    git add -A
  ) >/dev/null 2>&1
  # Never silent. A missing index here means the git environment is not what
  # this test assumes, and every verdict below would be meaningless — which is
  # exactly how the first version passed both halves for the wrong reason.
  if [ ! -f "$repo/.git/index" ]; then
    printf 'ERR: bait repo has no index — git env is not clean\n'
    return 1
  fi
  cp "$repo/.git/index" "$1" 2>/dev/null || { printf 'ERR: could not copy bait index\n'; return 1; }
  return 0
}

# run_probe <harness-path> — runs the harness with a poisoned git environment
# and prints "changed", "intact", or an "ERR: …" line. A verdict is only
# meaningful if the bait actually exists at both readings: "missing" and
# "unchanged" must never render as the same word.
run_probe() {
  local harness="$1"
  local bait="$TMP/bait.index"
  rm -f "$bait"
  local err
  err=$(mk_bait "$bait") || { printf '%s\n' "$err"; return 0; }

  local before after
  before=$(cksum < "$bait" 2>/dev/null) || { printf 'ERR: bait unreadable before the run\n'; return 0; }
  [ -n "$before" ] || { printf 'ERR: bait empty before the run\n'; return 0; }

  # Exactly what git hands a pre-commit hook during a pathspec commit. GIT_DIR
  # is included because the harness also runs `git init`, which honours it.
  (
    cd "$REPO_ROOT" || exit 1
    GIT_INDEX_FILE="$bait" \
    GIT_DIR="$REPO_ROOT/.git" \
    GIT_PREFIX="" \
      bash "$harness" --setup-only
  ) >/dev/null 2>&1

  [ -f "$bait" ] || { printf 'ERR: bait vanished during the run\n'; return 0; }
  after=$(cksum < "$bait" 2>/dev/null) || { printf 'ERR: bait unreadable after the run\n'; return 0; }
  [ -n "$after" ] || { printf 'ERR: bait empty after the run\n'; return 0; }

  if [ "$before" = "$after" ]; then printf 'intact\n'; else printf 'changed\n'; fi
}

# ---------------------------------------------------------------------------
printf '\nRED: without the scrub, the harness edits the caller'"'"'s index\n'
# ---------------------------------------------------------------------------
# A copy of the live harness with the scrub removed — not a hand-written
# imitation of it. An imitation would drift from the real setup block and start
# passing for the wrong reason.
UNSCRUBBED="$TMP/gates-unscrubbed.sh"
sed 's/^unset GIT_INDEX_FILE /unset VDM_NOTHING_AT_ALL /' "$HARNESS" > "$UNSCRUBBED"

if grep -q '^unset VDM_NOTHING_AT_ALL' "$UNSCRUBBED"; then
  ok "the unscrubbed copy really lost its scrub"
else
  bad "the unscrubbed copy really lost its scrub" \
      "the scrub line moved or was renamed — this probe is no longer testing anything"
fi

verdict=$(run_probe "$UNSCRUBBED")
if [ "$verdict" = changed ]; then
  ok "unscrubbed harness corrupts the inherited index (the bug, reproduced)"
else
  bad "unscrubbed harness corrupts the inherited index (the bug, reproduced)" \
      "expected 'changed', got '$verdict' — the probe no longer observes the failure it was written for"
fi


# ---------------------------------------------------------------------------
printf '\nGREEN: the live harness leaves it byte-identical\n'
# ---------------------------------------------------------------------------
verdict=$(run_probe "$HARNESS")
if [ "$verdict" = intact ]; then
  ok "live harness leaves the inherited index untouched"
else
  bad "live harness leaves the inherited index untouched" \
      "expected 'intact', got '$verdict' — the scrub is not covering every path"
fi

# ---------------------------------------------------------------------------
printf '\nthe scrub covers every variable that can redirect a git command\n'
# ---------------------------------------------------------------------------
# Cheap structural backstop for the variables a probe cannot easily provoke.
# Named individually so a future edit that drops one is reported by name
# rather than by a silent behavioural change.
for v in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
         GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE; do
  if grep -qE "^unset .*\b${v}\b|^      .*\b${v}\b" "$HARNESS"; then
    ok "scrub names $v"
  else
    bad "scrub names $v" "not found in the unset block"
  fi
done

# ---------------------------------------------------------------------------
printf '\nevery test harness carries the scrub, not just the ones a gate runs today\n'
# ---------------------------------------------------------------------------
# The scrub used to live only in the two suites a gate happened to run, which
# made isolation a property of the SCHEDULE rather than of the harness. On
# 2026-09-22 gate 7 was widened to run two more suites, and the first of them
# called `git add -A` in its fixture: 158 index entries of the pending commit
# became 9 fixture paths. Nothing about those suites had changed — only who
# invoked them.
#
# So the invariant is stated over every file, with no predicate about whether
# it "uses git": a harness never wants the caller's git session, and a rule
# with an exception is a rule someone has to remember to apply.
#
# And over every NAME. Until 2026-10-03 this asked only that the block exist,
# and the block named where the repository is — not who signs the commit or
# whether an editor opens, which a commit hands its hooks as well. The first
# suite to read the signature (tests/pii-scan.test.sh) went red in the hook and
# green by hand. Eight blocks also lacked four of the location names. Each file
# is now asked for each name, and a gap is reported by file and by name.
SESSION_VARS="GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX
  GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR"

# scrub_missing <file> — the session names the file's scrub does not unset, or
# "the whole block" when it has none. The block is the statement that opens with
# `unset GIT_INDEX_FILE` at the start of a line, with its continuation lines.
scrub_missing() {
  local block v missing=""
  block=$(awk '/^unset GIT_INDEX_FILE /{on=1} on{print; if ($0 !~ /\\$/) exit}' "$1")
  if [ -z "$block" ]; then printf 'the whole block'; return 0; fi
  for v in $SESSION_VARS; do
    printf '%s\n' "$block" | grep -qw -- "$v" || missing="$missing $v"
  done
  printf '%s' "${missing# }"
}

# The check watched failing before it is trusted (tests/gates.test.sh, header).
FX="$TMP/scrub-fixture.sh"
printf '#!/bin/bash\nset -u\nunset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \\\n      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \\\n      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true\n' > "$FX"
got=$(scrub_missing "$FX")
case "$got" in
  *GIT_AUTHOR_NAME*GIT_COMMITTER_DATE*GIT_EDITOR*) ok "RED: a block that names only the location is caught, by name" ;;
  *) bad "RED: a block that names only the location is caught, by name" "got: [${got}]" ;;
esac
printf '#!/bin/bash\nset -u\necho no scrub here\n' > "$FX"
got=$(scrub_missing "$FX")
if [ "$got" = "the whole block" ]; then
  ok "RED: a file with no block is caught"
else
  bad "RED: a file with no block is caught" "got: [${got}]"
fi
got=$(scrub_missing "$HARNESS")
if [ -z "$got" ]; then
  ok "GREEN: the live gate harness names every variable"
else
  bad "GREEN: the live gate harness names every variable" "missing: $got"
fi

for f in "$REPO_ROOT"/tests/*.test.sh; do
  name=$(basename "$f")
  missing=$(scrub_missing "$f")
  if [ -z "$missing" ]; then
    ok "$name scrubs the session a commit hands its hooks"
  else
    bad "$name scrubs the session a commit hands its hooks" \
        "missing: $missing — the block right after \`set -u\`, see tests/gates.test.sh"
  fi
done

# ---------------------------------------------------------------------------
# The regression guard for what happened on 2026-09-04: this file must survive
# being run from inside a poisoned git session, because that is how the hook
# runs it. Without the scrub at the top, `mk_bait` followed GIT_DIR home, left
# no bait behind, and both verdicts above rendered as passes on a file that did
# not exist. Re-invoke self under exactly that poison; the guard variable stops
# the recursion at one level.
# ---------------------------------------------------------------------------
if [ -z "${VDM_ISO_SELFTEST:-}" ]; then
  printf '\nthe probe itself survives a poisoned session\n'
  poisoned_index="$TMP/selftest.index"
  : > "$poisoned_index"
  if (
       VDM_ISO_SELFTEST=1 \
       GIT_INDEX_FILE="$poisoned_index" \
       GIT_DIR="$REPO_ROOT/.git" \
       GIT_PREFIX="" \
         bash "${BASH_SOURCE[0]}"
     ) >/dev/null 2>&1; then
    ok "runs clean when invoked from a poisoned git session"
  else
    bad "runs clean when invoked from a poisoned git session" \
        "the probe is only sound when it owns its own git environment"
  fi
  if [ ! -s "$poisoned_index" ]; then
    ok "…and wrote nothing into the session's index"
  else
    bad "…and wrote nothing into the session's index" \
        "the probe leaked into the index it was handed"
  fi
fi

printf '\ngates-harness-isolation: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
