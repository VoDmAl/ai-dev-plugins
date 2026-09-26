#!/bin/bash
# crystal-precommit-check.test.sh — vdm-git's backup crystal gate, the one a
# downstream project wires into its own pre-commit.
#
# The assertion this file exists for: a workitem is checked whatever bytes its
# path holds. The gate read the staged list with `git diff --cached
# --name-only`, and in that form git quotes any path with a byte outside ASCII:
# `"docs/tasks/\320\272…/workitem.md"`. The quoted line matched none of the
# gate's patterns, so a crystal with a Cyrillic slug could be committed as
# `done` with open items, and the gate said nothing — a gate that fails open on
# a name (Sidetrack #9, docs/tasks/crystal-wake/workitem.md).
#
# Until this file the gate had no behavioural suite at all: its wiring snippet
# was tested, the gate behind it was not.
#
# Run: bash tests/crystal-precommit-check.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: the fixtures below run
# `git init` / `git add`, and as a child of a live `git commit` the inherited
# GIT_INDEX_FILE would point them at that commit's index (tests/gates.test.sh,
# 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/plugins/vdm-git/scripts/crystal-precommit-check.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystalprecommit)
trap 'rm -rf "$TMP"' EXIT

# fixture <name> — a fresh repo with a docs/tasks/ root; prints its path.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/docs/tasks"
  ( cd "$d" && git init -q . 2>/dev/null )
  printf '%s' "$d"
}
# workitem <repo> <slug> <status> <checkbox> — writes and stages one workitem.
workitem() {
  mkdir -p "$1/docs/tasks/$2"
  printf -- '---\nslug: %s\nstatus: %s\n---\n\n## Next actions\n\n%s item\n' \
    "$2" "$3" "$4" > "$1/docs/tasks/$2/workitem.md"
  ( cd "$1" && git add -- "docs/tasks/$2/workitem.md" 2>/dev/null )
}
# gate <repo> — runs the gate from a UTF-8 locale; sets OUT and RC.
gate() {
  OUT=$(cd "$1" && LC_ALL=en_US.UTF-8 bash "$GATE" 2>&1)
  RC=$?
}

# ---------------------------------------------------------------------------
printf '\nthe gate blocks, whatever the path holds\n'
# ---------------------------------------------------------------------------
# The canary first: a gate that blocks nothing would pass every case below it.
R=$(fixture ascii)
workitem "$R" alpha done '- [ ]'
gate "$R"
eq "canary: done with an open item under an ASCII slug is blocked" 1 "$RC"
says "…and the message names the slug" "$OUT" "alpha"

R=$(fixture cyrillic)
workitem "$R" 'кристалл' done '- [ ]'
gate "$R"
eq "RED: done with an open item under a Cyrillic slug is blocked" 1 "$RC"
says "…and the message names the slug as itself" "$OUT" "кристалл"

R=$(fixture clean)
workitem "$R" 'кристалл' done '- [x]'
gate "$R"
eq "done with every item checked passes, Cyrillic or not" 0 "$RC"

# One Cyrillic file anywhere under tasks/ — a reference note, untracked even —
# and an ASCII crystal next to it. In line form that file came back quoted,
# the root scan turned it into a second root `…/"docs/tasks`, and `"` sorts
# before `d`: the invented root came first, the gate checked a directory that
# exists nowhere, and every crystal in the repository went through unchecked.
R=$(fixture cyrref)
workitem "$R" alpha done '- [ ]'
mkdir -p "$R/docs/tasks/alpha/references"
printf 'note\n' > "$R/docs/tasks/alpha/references/Заметка.md"
gate "$R"
eq "RED: a Cyrillic file elsewhere under tasks/ does not switch the gate off" 1 "$RC"
says "…and the ASCII crystal is named" "$OUT" "alpha"

# A staged index entry whose name is not UTF-8 at all — APFS will not store
# such a file, a git index will — next to a real violation. Read raw in a
# UTF-8 locale, one such name makes macOS `tr` and `sort` stop or drop the
# list; the violation must still be seen.
R=$(fixture badindex)
workitem "$R" alpha done '- [ ]'
( cd "$R" && blob=$(printf 'x\n' | git hash-object -w --stdin) &&
  git update-index --add --cacheinfo "100644,$blob,docs/tasks/b$(printf '\377')d.md" 2>/dev/null )
gate "$R"
eq "a name that is not UTF-8 in the index does not hide a violation" 1 "$RC"
case "$OUT" in
  *"Illegal byte sequence"*) bad "…and no tool complains about it" "$(printf '%s' "$OUT" | head -c 200)" ;;
  *)                         ok  "…and no tool complains about it" ;;
esac

printf '\ncrystal-precommit-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
