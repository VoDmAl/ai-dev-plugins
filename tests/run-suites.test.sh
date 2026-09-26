#!/bin/bash
# run-suites.test.sh — RED TESTS for the runner that runs the pre-commit's
# suites side by side (scripts/run-suites.sh; Sidetrack #6,
# docs/tasks/crystal-wake/workitem.md).
#
# What the runner promises, and how each promise would fail without a sound:
#   * a failing suite fails the run and shows everything it printed — a runner
#     that swallows a failure turns every gate behind it into one that passes;
#   * a passing suite shows one line, its summary;
#   * results come in the order the suites were named, not the order they ended;
#   * the suites really run at the same time. Checked by a rendezvous, not by a
#     stopwatch: two suites each wait for the other's mark, which only a
#     parallel run can give them — and the same pair run one at a time must
#     fail, or the check proves nothing;
#   * every suite has a TMPDIR of its own, the one store the hooks share by
#     default;
#   * a suite that cannot start is a failure, not a silence.
#
# Run: bash tests/run-suites.test.sh   (exit 0 = all pass)
set -u

# No git in here, but the isolation suite requires the scrub of every harness
# (tests/gates-harness-isolation.test.sh) — a rule with an exception is a rule
# someone has to remember.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${RUN_SUITES_BIN:-$REPO_ROOT/scripts/run-suites.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }
expect_silent() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }
expect_before() { # expect_before <desc> <haystack> <first> <second> — both present, in that order
  local rest="${2#*"$3"}"
  if [ "$rest" = "$2" ]; then bad "$1" "output did not mention: $3"; return; fi
  case "$2" in *"$4"*) ;; *) bad "$1" "output did not mention: $4"; return ;; esac
  case "$rest" in *"$4"*) ok "$1" ;; *) bad "$1" "'$4' comes before '$3'" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t runsuites)
trap 'rm -rf "$TMP"' EXIT
S="$TMP/suites"; M="$TMP/marks"
mkdir -p "$S" "$M"

cat > "$S/ok-a.test.sh" <<'EOF'
echo "  ✓ a detail nobody needs when it passes"
printf '\nok-a: 3 passed, 0 failed\n\n'
EOF
cat > "$S/bad-b.test.sh" <<'EOF'
echo "  ✗ the detail that explains the failure"
printf '\nbad-b: 1 passed, 1 failed\n'
exit 1
EOF
cat > "$S/slow-c.test.sh" <<'EOF'
sleep 1
echo "slow-c: 1 passed, 0 failed"
EOF
cat > "$S/fast-d.test.sh" <<'EOF'
echo "fast-d: 1 passed, 0 failed"
EOF
for n in e f; do
  cat > "$S/tmp-$n.test.sh" <<EOF
printf '%s\n' "\$TMPDIR" > "$M/tmpdir-$n"
echo "tmp-$n: 1 passed, 0 failed"
EOF
done
# rv-x and rv-y each leave a mark and wait for the other's, for up to 5 s.
for pair in "x y" "y x"; do
  set -- $pair
  cat > "$S/rv-$1.test.sh" <<EOF
: > "$M/rv-$1"
i=0
while [ ! -e "$M/rv-$2" ]; do
  i=\$((i + 1))
  [ "\$i" -le 50 ] || { echo "rv-$1: no partner within 5 s — the suites ran one after another"; exit 1; }
  sleep 0.1
done
echo "rv-$1: 1 passed, 0 failed"
EOF
done

run() { OUT=$(SUITES_DIR="$S" bash "$RUN" "$@" 2>&1); RC=$?; }

echo "== a pass is one line, a failure is everything =="
run ok-a fast-d
expect_exit "every suite passed → exit 0" 0 "$RC"
expect_says "a passing suite shows its summary, even with blank lines after it" "$OUT" "ok-a: 3 passed, 0 failed"
expect_not_says "…and not its details" "$OUT" "a detail nobody needs"
run ok-a bad-b
expect_exit "RED: one suite failed → the run fails" 1 "$RC"
expect_says "…and the failure shows what it printed" "$OUT" "the detail that explains the failure"
expect_says "…under a line that names it" "$OUT" "bad-b.test.sh exited 1"
expect_says "the passing neighbour still reports" "$OUT" "ok-a: 3 passed, 0 failed"

echo ""
echo "== order: as named, not as finished =="
run slow-c fast-d
expect_before "RED: the slow suite named first is reported first" "$OUT" "slow-c:" "fast-d:"

echo ""
echo "== isolation: a TMPDIR of its own =="
run tmp-e tmp-f
te=$(cat "$M/tmpdir-e" 2>/dev/null); tf=$(cat "$M/tmpdir-f" 2>/dev/null)
if [ -n "$te" ] && [ -n "$tf" ]; then ok "canary: both suites reported their TMPDIR"
else bad "canary: both suites reported their TMPDIR" "e=[$te] f=[$tf]"; fi
if [ -n "$te" ] && [ "$te" != "$tf" ]; then ok "RED: two suites never share a TMPDIR"
else bad "RED: two suites never share a TMPDIR" "e=[$te] f=[$tf]"; fi
if [ -n "$te" ] && [ "$te" != "${TMPDIR:-}" ]; then ok "…nor the caller's"
else bad "…nor the caller's" "suite=[$te] caller=[${TMPDIR:-}]"; fi

echo ""
echo "== side by side: a rendezvous, not a stopwatch =="
rm -f "$M"/rv-*
OUT=$(SUITES_DIR="$S" SUITES_JOBS=2 bash "$RUN" rv-x rv-y 2>&1); RC=$?
expect_exit "RED: two suites that wait for each other both pass" 0 "$RC"
rm -f "$M"/rv-*
OUT=$(SUITES_DIR="$S" SUITES_JOBS=1 bash "$RUN" rv-x rv-y 2>&1); RC=$?
expect_exit "canary: one at a time the same pair fails — the rendezvous can tell" 1 "$RC"
expect_says "…and says why" "$OUT" "no partner"

echo ""
echo "== a suite that cannot start =="
run no-such-suite
expect_exit "RED: a missing suite is a failure, not a silence" 1 "$RC"
expect_says "…and it is named" "$OUT" "no-such-suite.test.sh exited"

echo ""
echo "== nothing to run =="
run
expect_exit "no suites → exit 0" 0 "$RC"
expect_silent "…and nothing printed" "$OUT"

echo ""
echo "== the hook: this suite runs outside the runner, whichever gate named it first =="
# The hook's queue block, run on its own against a fake tests/ — behaviour, not
# the text of the hook. The first version returned early when a gate had
# already queued this suite (gate 11 does: a staged suite owns itself), and the
# runner ended up judging itself; seen in its own first run.
PRE="${PRECOMMIT_BIN:-$REPO_ROOT/.githooks/pre-commit}"
block=$(sed -n '/^# >>> suite queue/,/^# <<< suite queue/p' "$PRE")
case "$block" in *queued_suites*) ok "canary: the hook's queue block is found" ;;
  *) bad "canary: the hook's queue block is found" "no '# >>> suite queue' … '# <<< suite queue' block in $PRE" ;; esac
H="$TMP/hook"; mkdir -p "$H/tests"
printf 'echo "DIRECT-RAN"\n' > "$H/tests/run-suites.test.sh"
OUT=$(cd "$H" && bash -c "$block"'
run_suite gates
run_suite run-suites
run_suite_now run-suites
run_suite_now run-suites
run_suite run-suites
printf "queue=[%s]\n" "$(queued_suites)"' 2>&1)
expect_says "RED: queued first by a gate, the runner's suite still runs directly" "$OUT" "DIRECT-RAN"
n=$(printf '%s\n' "$OUT" | grep -c 'DIRECT-RAN')
if [ "$n" = 1 ]; then ok "…exactly once"; else bad "…exactly once" "ran $n times"; fi
expect_says "RED: …and it leaves the queue, the others stay" "$OUT" "queue=[ gates]"

printf '\nrun-suites: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
