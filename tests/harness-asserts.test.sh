#!/bin/bash
# harness-asserts.test.sh — a suite's negative assertion must not pass on
# nothing.
#
# The incident (2026-09-25, tests/reminders-dispatch.test.sh). A red test for
# the docs-sync JSON fix was written as
#     says_not "…no octal escape leaks through" "$dsctx" '\320'
# where $dsctx was the context DECODED from the hook's JSON. The JSON was the
# very thing that was broken, so the decode produced an empty string — and an
# empty string does not mention \320. The assertion was green while the defect
# it was written against was present, and it was caught by reading the test
# again, not by running it.
#
# An empty haystack contains nothing, so "does not mention X" passes on it
# whatever the code did, including when the code never ran. So every
# `says_not` / `expect_not_says` under tests/ FAILS on an empty haystack, and a
# case where silence is the expected outcome asserts silence as such. The
# property is checked by RUNNING each helper, not by reading it: the helper is
# cut out of its suite and must answer
#     empty haystack → fail · clean haystack → pass · needle present → fail.
#
# RED half: the same probe is run against a naive helper written here. If that
# one stops failing, the probe has gone blind — the defect it exists for, one
# level up.
#
# Run: bash tests/harness-asserts.test.sh   (exit 0 = all pass)

set -u

# No git in here, but the isolation suite requires the scrub of every harness
# (tests/gates-harness-isolation.test.sh) — a rule with an exception is a rule
# someone has to remember.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

NEGATIVE_HELPERS="says_not expect_not_says"
EXPECTED="empty=BAD clean=OK dirty=BAD"

# helper_def <file> <name> — the function <name> as <file> defines it, from its
# opening line to the one that balances its braces.
helper_def() {
  awk -v name="$2" '
    !on && $0 ~ ("^[[:space:]]*" name "\\(\\)[[:space:]]*\\{") { on = 1 }
    on {
      print
      line = $0
      depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
      if (depth <= 0) exit
    }
  ' "$1"
}

# probe <definition> <name> — the helper's three verdicts, with ok/bad stubbed.
probe() {
  bash -c '
    ok()  { printf OK; }
    bad() { printf BAD; }
    eval "$1"
    printf "empty=%s clean=%s dirty=%s" \
      "$("$2" d "" needle)" "$("$2" d "some output" needle)" "$("$2" d "a needle here" needle)"
  ' _ "$1" "$2" 2>&1
}

echo "== every negative helper under tests/ refuses an empty haystack =="
n=0
for f in "$REPO_ROOT"/tests/*.sh; do
  [ "$f" = "$REPO_ROOT/tests/harness-asserts.test.sh" ] && continue
  for name in $NEGATIVE_HELPERS; do
    grep -qE "^[[:space:]]*$name\\(\\)" "$f" || continue
    n=$((n + 1))
    got=$(probe "$(helper_def "$f" "$name")" "$name")
    if [ "$got" = "$EXPECTED" ]; then
      ok "tests/$(basename "$f"): $name fails on nothing, passes clean, fails on the needle"
    else
      bad "tests/$(basename "$f"): $name" "expected [$EXPECTED], got [$got]"
    fi
  done
done
if [ "$n" -gt 0 ]; then
  ok "$n negative helpers found and probed"
else
  bad "no negative helper found under tests/ — the probe is looking in the wrong place"
fi

echo "== RED: the probe sees a helper without the guard =="
naive='says_not() { case "$2" in *"$3"*) bad "$1" "x" ;; *) ok "$1" ;; esac; }'
got=$(probe "$naive" says_not)
if [ "$got" = "empty=OK clean=OK dirty=BAD" ]; then
  ok "a naive helper passes on an empty haystack — and the probe says so"
else
  bad "the probe no longer tells a naive helper apart" "got [$got]"
fi

printf '\nharness-asserts: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
