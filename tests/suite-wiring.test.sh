#!/bin/bash
# suite-wiring.test.sh — no test suite is left without a gate that runs it.
#
# The finding (2026-09-25). Nine of the twenty-one suites under tests/ were run
# by no gate of .githooks/pre-commit — crystal-lint's, crystal-path's,
# intercom's, distill-scan's, fffd's among them. Each was complete, each had
# red cases, and each was green only for whoever remembered to run it: the
# anti-pattern "a gate counted as wired because its file is present"
# (docs/llm/soft-guidance-vs-deterministic-gates.md), met on our own tests.
#
# The fix is a rule, not a list: a suite is named after what it tests.
# tests/<name>.test.sh owns plugins/*/{scripts,lib,bin}/<name>[.<ext>] and every
# file there whose name starts with "<name>-" (intercom-common.sh → intercom),
# and a staged suite owns itself. The rule lives once, in scripts/suites-for.sh;
# the pre-commit calls it to decide what to run, and this file calls it to prove
# the property:
#
#   every tests/*.test.sh is run by an explicit `run_suite <name>` of the
#   pre-commit, or owns at least one file the name-keyed gate can see.
#
# This reads the gate list rather than running a commit — a commit per suite
# would cost minutes. What it proves is that a trigger EXISTS; that the suite
# then passes is the suite's own business.
#
# RED half: the same check is run against a pre-commit that does not call the
# rule, and against a suite named after nothing. Both must be reported.
#
# Run: bash tests/suite-wiring.test.sh   (exit 0 = all pass)

set -u

# Scrub the inherited git session — see tests/gates.test.sh. This suite asks
# git for the tracked file list and runs inside a live `git commit`.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES_FOR="$REPO_ROOT/scripts/suites-for.sh"
PRECOMMIT="$REPO_ROOT/.githooks/pre-commit"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t suitewiring)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$SUITES_FOR" ]; then
  bad "the rule exists at scripts/suites-for.sh" "missing: $SUITES_FOR"
  printf '\nsuite-wiring: %s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

owners() { printf '%s\n' "$@" | bash "$SUITES_FOR" | tr '\n' ' ' | sed 's/ $//'; }

echo "== the rule: a suite owns what it is named after =="
expect_eq "a script named after its suite"          "$(owners plugins/vdm/scripts/distill-scan.sh)" "distill-scan"
expect_eq "a dash-prefix: intercom-common → intercom" "$(owners plugins/vdm/scripts/intercom-common.sh)" "intercom"
expect_eq "a longer name: fffd-precommit-check → fffd" "$(owners plugins/vdm-git/scripts/fffd-precommit-check.sh)" "fffd"
expect_eq "any extension: crystal-lint.py"          "$(owners plugins/vdm/scripts/crystal-lint.py)" "crystal-lint"
expect_eq "a lib file, in either plugin"            "$(owners plugins/vdm-git/lib/crystal-path.sh)" "crystal-path"
expect_eq "a helper with no extension"              "$(owners plugins/vdm-git/bin/git-guard-prepare)" "git-guard-prepare"
expect_eq "both a full name and its prefix own it"  "$(owners plugins/vdm-comms/scripts/comms-pending.py)" "comms-pending comms"
expect_eq "a staged suite owns itself"              "$(owners tests/intercom.test.sh)" "intercom"
expect_eq "each owner is named once"                "$(owners plugins/vdm/scripts/intercom.sh plugins/vdm/scripts/intercom-common.sh)" "intercom"
expect_eq "outside scripts/lib/bin — nobody"        "$(owners README.md plugins/vdm/hooks/hooks.json)" ""
expect_eq "a name no suite carries — nobody"        "$(owners plugins/vdm/scripts/zz-nothing-owns-this.sh)" ""
expect_eq "a suite that does not exist — nobody"    "$(owners tests/zz-no-such.test.sh)" ""

# explicit_suites <pre-commit> — names the pre-commit runs by name, comments out.
explicit_suites() {
  sed -nE '/^[[:space:]]*#/d
           s/^[[:space:]]*run_suite(_quiet)?[[:space:]]+([a-z0-9-]+)([[:space:]].*)?$/\2/p
           s#^[[:space:]]*bash[[:space:]]+tests/([a-z0-9-]+)\.test\.sh.*#\1#p' "$1" | sort -u
}
# name_keyed_suites <pre-commit> — what the rule reaches, IF the pre-commit calls it.
name_keyed_suites() {
  if grep -qE '^[^#]*scripts/suites-for\.sh' "$1"; then
    git -C "$REPO_ROOT" ls-files 'plugins/*/scripts/*' 'plugins/*/lib/*' 'plugins/*/bin/*' \
      | bash "$SUITES_FOR" | sort -u
  fi
}
# unreachable <pre-commit> <suite-name>... — the names no trigger can run.
unreachable() {
  local pc="$1" reach n; shift
  reach=" $( { explicit_suites "$pc"; name_keyed_suites "$pc"; } | tr '\n' ' ') "
  for n in "$@"; do
    case "$reach" in *" $n "*) ;; *) printf '%s\n' "$n" ;; esac
  done
}

ALL=$(for f in "$REPO_ROOT"/tests/*.test.sh; do n=${f##*/}; printf '%s\n' "${n%.test.sh}"; done)
N_ALL=$(printf '%s\n' "$ALL" | grep -c .)

echo "== every suite has a trigger =="
orphans=$(unreachable "$PRECOMMIT" $ALL)
if [ -z "$orphans" ]; then
  ok "all $N_ALL suites under tests/ are run by some gate"
else
  bad "every suite under tests/ is run by some gate" \
      "no trigger for: $(printf '%s' "$orphans" | tr '\n' ' ')— name the suite after its subject, or add a run_suite line"
fi

echo "== RED: the check sees what it exists for =="
sed '/scripts\/suites-for\.sh/d' "$PRECOMMIT" > "$TMP/pre-commit.no-rule"
without=$(unreachable "$TMP/pre-commit.no-rule" $ALL | grep -c .)
if [ "$without" -gt 0 ]; then
  ok "a pre-commit that does not call the rule leaves $without suites without a trigger — and the check says so"
else
  bad "the check still reports orphans when the rule is not called" "it reported none — it has gone blind"
fi
expect_eq "a suite named after nothing is reported" \
  "$(unreachable "$PRECOMMIT" zz-named-after-nothing)" "zz-named-after-nothing"

printf '\nsuite-wiring: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
