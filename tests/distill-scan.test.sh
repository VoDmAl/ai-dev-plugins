#!/bin/bash
# distill-scan.test.sh — tests for the synthesis-tier resolver and drift detector.
#
# The assertion this file exists for. `newer_inputs` used to stop after 3 hits
# and the caller printed exactly what it got, saying nothing about the rest.
# That is a truncation that lies in the SAFE direction: the reader sees three
# names and concludes those are the changes. Found 2026-08-22 while rebuilding
# `docs/model/suite.md` — the cap was consumed by the first two `covers:`
# entries, so `plugins/vdm/scripts/`, which had just gained an entire new
# subsystem, was never walked at all. Six inputs had drifted; the signal named
# three and looked complete.
#
#   A bounded list that does not say it is bounded reads as the whole list.
#
# Run: bash tests/distill-scan.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment before anything else. This file runs
# `git init` / `git add` / `git commit` inside throwaway fixtures; if it is ever
# executed as a child of a live `git commit` (a hook, a harness), the inherited
# GIT_INDEX_FILE / GIT_DIR point at THAT commit's index and every fixture write
# would land in the user's real commit instead. Cost of the line: nothing. Cost
# of omitting it, measured 2026-09-03 on tests/gates.test.sh: eight test files
# swept into an unrelated commit.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$REPO_ROOT/plugins/vdm/scripts/distill-scan.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
says_not() {
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}
count_is() {
  # count_is <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t distillscan)
cleanup() { rm -rf "$TMP" ${TMP2:+"$TMP2"}; }
trap cleanup EXIT

cd "$TMP" || exit 1
git init -q . 2>/dev/null
git config user.email t@t; git config user.name t

mkdir -p docs/model src/alpha src/beta

cat >docs/model/whole.md <<'EOF'
---
type: model
question: "how the parts fit"
covers:
  - src/alpha/
  - src/beta/
observed: 2020-01-01
---
# Whole
EOF

# The synthesis is older than everything that follows.
touch -t 202001010000 docs/model/whole.md

seed() { printf 'x\n' >"$1"; }
for i in 1 2 3; do seed "src/alpha/a$i.txt"; done
for i in 1 2 3; do seed "src/beta/b$i.txt"; done
git add -A >/dev/null 2>&1

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
printf '\nignored files are not inputs\n'
# ---------------------------------------------------------------------------
# The drift half of the scanner used to walk the tree with `find` plus a
# hand-written `-not -path` list (.git, node_modules, vendor) — a second copy of
# a rule git already owns, and incomplete like every second copy. It let
# `__pycache__/*.pyc` count as an input; python regenerates those on every
# import, so the synthesis document reported itself perpetually stale. A signal
# that is always on is a signal nobody reads.
#
# The discovery half of the SAME script had it right, with a comment calling
# `--exclude-standard` load-bearing. Correct in one place, re-derived wrongly
# twenty lines below.
mkdir -p src/alpha/__pycache__ node_modules/pkg
printf 'ignored\n' > .gitignore
printf '__pycache__/\n*.pyc\nbuild/\n' >> .gitignore
printf 'x\n' > src/alpha/__pycache__/mod.cpython-314.pyc
mkdir -p src/alpha/build && printf 'x\n' > src/alpha/build/out.o
git add -A >/dev/null 2>&1

OUT=$(bash "$SCAN" --drift-all)
says_not "gitignored .pyc is not an input" "$OUT" ".pyc"
says_not "gitignored build output is not an input" "$OUT" "build/out.o"
says "real source still counts as an input" "$OUT" "src/alpha/a1.txt"

# An untracked but NOT ignored file must still count: the edit that caused the
# drift is usually the one not yet committed.
printf 'x\n' > src/alpha/fresh.txt
OUT=$(bash "$SCAN" --drift-all)
says "untracked-but-not-ignored file counts" "$OUT" "src/alpha/fresh.txt"
rm -f src/alpha/fresh.txt .gitignore
rm -rf src/alpha/__pycache__ src/alpha/build node_modules
git add -A >/dev/null 2>&1

printf '\ndrift truncation must be visible\n'
# ---------------------------------------------------------------------------
OUT=$(bash "$SCAN" --drift)
says "reports the drifted document" "$OUT" "docs/model/whole.md"
says "names the first input"        "$OUT" "src/alpha/a1.txt"
# 6 newer inputs, 3 shown ⇒ must announce 3 more.
says "announces what it did not name" "$OUT" "и ещё 3"

shown=$(printf '%s\n' "$OUT" | grep -c '  ← src/')
count_is "names exactly DRIFT_SHOW inputs" 3 "$shown"

# The crux: a covers entry AFTER the cap must still be counted. Before the fix
# the second directory was never walked, so its files were invisible.
ALL=$(bash "$SCAN" --drift-all)
says "--drift-all reaches the later covers entry" "$ALL" "src/beta/b1.txt"
all_shown=$(printf '%s\n' "$ALL" | grep -c '  ← src/')
count_is "--drift-all names every input" 6 "$all_shown"
says_not "--drift-all has no truncation notice" "$ALL" "усечён"

# ---------------------------------------------------------------------------
printf '\nno false truncation notice when everything fits\n'
# ---------------------------------------------------------------------------
# A gate that over-reports gets ignored: with ≤3 inputs there must be no tail.
rm -f src/alpha/a2.txt src/alpha/a3.txt src/beta/b2.txt src/beta/b3.txt
OUT=$(bash "$SCAN" --drift)
says     "still reports the document"        "$OUT" "docs/model/whole.md"
says_not "no truncation line when it fits"   "$OUT" "и ещё"

# ---------------------------------------------------------------------------
printf '\nsilence when the synthesis is current\n'
# ---------------------------------------------------------------------------
touch docs/model/whole.md
OUT=$(bash "$SCAN" --drift)
if [ -z "$OUT" ]; then ok "current synthesis ⇒ empty output"; else bad "current synthesis ⇒ empty output" "$OUT"; fi
bash "$SCAN" --drift >/dev/null 2>&1
count_is "exit 0 even with nothing to say" 0 "$?"

# ---------------------------------------------------------------------------
printf '\n--list still works\n'
# ---------------------------------------------------------------------------
OUT=$(bash "$SCAN" --list)
says "lists the document"  "$OUT" "docs/model/whole.md"
says "prints the question" "$OUT" "how the parts fit"
says "prints covers"       "$OUT" "src/alpha/"

# ---------------------------------------------------------------------------
printf '\ncontent confirmation: mtime proposes, git history decides\n'
# ---------------------------------------------------------------------------
# mtime answers "was this written after that", which is not the question. The
# question is whether the input's CONTENT changed since the synthesis was
# written. Observed 2026-09-04 on a clone of this repo: an edit to a covered
# file followed by `git checkout -- <file>` leaves the tree byte-identical to
# HEAD and still raises drift. The only way for a reader to clear it is to
# re-stamp `observed:` — recording a verification that verified nothing — and a
# signal permitted to cry wolf gets dismissed unread, which is the failure this
# scanner exists to prevent.
#
# The fixture above never commits, so it exercises the mtime-only path (which
# is also what a non-git project gets). This one commits, which is what arms
# the content confirmation.
TMP2=$(mktemp -d 2>/dev/null || mktemp -d -t distillscan2)
cd "$TMP2" || exit 1
git init -q . 2>/dev/null
git config user.email t@t; git config user.name t

mkdir -p docs/model src
printf 'alpha\n' > src/a.txt
cat >docs/model/m.md <<'EOF'
---
type: model
question: "how src fits together"
covers:
  - src/
observed: 2026-09-04
---
# M
EOF
git add -A >/dev/null 2>&1
git commit -qm base >/dev/null 2>&1

sleep 1
printf 'alpha\nexperiment\n' > src/a.txt   # tried an edit…
git checkout -- src/a.txt                  # …and changed our mind
OUT=$(bash "$SCAN" --drift)
if [ -z "$OUT" ]; then ok "reverted edit ⇒ no drift (content is what it was)"
else bad "reverted edit ⇒ no drift (content is what it was)" "$OUT"; fi

# The guard against a filter that simply silences everything: a REAL change
# must still be reported, in each of the three shapes git can express it.
sleep 1
printf 'alpha\nreal\n' > src/a.txt
OUT=$(bash "$SCAN" --drift)
says "uncommitted content change still drifts" "$OUT" "src/a.txt"

git add -A >/dev/null 2>&1
git commit -qm "change a" >/dev/null 2>&1
OUT=$(bash "$SCAN" --drift)
says "committed content change still drifts" "$OUT" "src/a.txt"

sleep 1
printf 'new\n' > src/b.txt                 # never committed at all
OUT=$(bash "$SCAN" --drift)
says "untracked new input still drifts" "$OUT" "src/b.txt"

# And it must fall silent once the synthesis is honestly rebuilt — the whole
# point of the signal is that a real rebuild clears it.
git add -A >/dev/null 2>&1
git commit -qm "commit b" >/dev/null 2>&1
printf '\nrebuilt\n' >> docs/model/m.md
git add -A >/dev/null 2>&1
git commit -qm "rebuild synthesis" >/dev/null 2>&1
sleep 1
touch src/a.txt src/b.txt                  # mtime newer, content untouched
OUT=$(bash "$SCAN" --drift)
if [ -z "$OUT" ]; then ok "rebuilt synthesis ⇒ silent again"
else bad "rebuilt synthesis ⇒ silent again" "$OUT"; fi

# The filter must not pretend to know more than it does. While the synthesis
# itself carries uncommitted edits, git cannot tell what that edit already
# covered, so the confirmation disarms and plain mtime is back in charge.
printf '\nwip\n' >> docs/model/m.md         # synthesis dirty, deliberately
sleep 1
touch src/a.txt
OUT=$(bash "$SCAN" --drift)
says "dirty synthesis ⇒ filter disarms, mtime rules" "$OUT" "src/a.txt"
git checkout -- docs/model/m.md

cd "$TMP" || exit 1

printf '\ndistill-scan: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
