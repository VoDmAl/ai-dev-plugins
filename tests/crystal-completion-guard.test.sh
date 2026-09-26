#!/bin/bash
# crystal-completion-guard.test.sh — the primary crystal gate: the PreToolUse
# hook that stops a workitem from being written as `done` with open items.
#
# The assertion this file exists for: the gate sees every crystal root, whatever
# else the index holds. It joined the roots with `tr '\n' ':'` in the user's
# locale, and the root scan could hand it a root that exists nowhere — a
# `tasks/` named only by an index entry whose directory is not UTF-8, which
# APFS will not store. That root sorted first, `tr` stopped on its byte, and
# the real `docs/tasks` behind it was lost: in such a repository the gate saw no
# workitem at all (Sidetrack #12, docs/tasks/crystal-wake/workitem.md).
#
# Run: bash tests/crystal-completion-guard.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: the fixtures below run
# `git init` / `git add`, and as a child of a live `git commit` the inherited
# GIT_INDEX_FILE would point them at that commit's index (tests/gates.test.sh,
# 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/plugins/vdm/scripts/crystal-completion-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t completionguard)
trap 'rm -rf "$TMP"' EXIT
# The real path: roots come from `git rev-parse`, which resolves symlinks, and a
# payload path under /var would miss a root under /private/var
# (tests/symlink-scope.test.sh).
REAL=$(cd "$TMP" && pwd -P)

# fixture <name> <box> — a repo with one workitem at docs/tasks/specimen,
# `status: done`, its one item in <box>; prints the repo's path.
fixture() {
  local d="$REAL/$1"
  mkdir -p "$d/docs/tasks/specimen"
  ( cd "$d" && git init -q . ) >/dev/null 2>&1
  cat > "$d/docs/tasks/specimen/workitem.md" <<EOF
---
title: "specimen"
slug: specimen
status: done
session-type: other
created: 2026-09-26
last-updated: 2026-09-26
---

# specimen

## Next actions

$2 an obligation
EOF
  ( cd "$d" && git add -A ) >/dev/null 2>&1
  printf '%s' "$d"
}
# badname <repo> — an index entry whose directory above tasks/ is not UTF-8.
# APFS will not store such a name; a git index will, so it goes in directly.
badname() {
  ( cd "$1" && blob=$(printf 'x\n' | git hash-object -w --stdin) &&
    git update-index --add --cacheinfo "100644,$blob,a$(printf '\377')/tasks/x/workitem.md" ) >/dev/null 2>&1
}
# guard <repo> — a Write of the workitem's own content, run from a UTF-8 locale;
# sets OUT and RC.
guard() {
  local wi="$1/docs/tasks/specimen/workitem.md"
  OUT=$(cd "$1" && python3 -c 'import json, sys; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": sys.argv[1], "content": open(sys.argv[1], encoding="utf-8").read()}, "cwd": sys.argv[2]}))' "$wi" "$1" \
        | LC_ALL=en_US.UTF-8 bash "$GUARD" 2>&1)
  RC=$?
}

# ---------------------------------------------------------------------------
printf '\nthe gate sees every root, whatever else the index holds\n'
# ---------------------------------------------------------------------------
# The canary first: a gate that blocks nothing would pass every case below it.
R=$(fixture plain '- [ ]')
guard "$R"
eq "canary: done with an open item is blocked" 2 "$RC"

R=$(fixture badname '- [ ]')
badname "$R"
guard "$R"
eq "RED: …still blocked next to a tasks/ whose name is not UTF-8" 2 "$RC"
says_not "…and no tool complains about the bytes" "$OUT" "Illegal byte sequence"

R=$(fixture badname-clean '- [x]')
badname "$R"
guard "$R"
eq "done with every item checked passes there" 0 "$RC"

printf '\ncrystal-completion-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
