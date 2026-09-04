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
cleanup() { rm -rf "$TMP"; }
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

printf '\ndistill-scan: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
