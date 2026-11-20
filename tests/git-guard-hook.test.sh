#!/bin/bash
# git-guard-hook.test.sh — the lists of files git-guard prints when it stops a
# commit.
#
# The assertion this file exists for: a file is named as itself. The block
# message tells the assistant what is staged and what could be, so that the
# hand-off names explicit paths. The lists came from `git diff --cached
# --name-status` and `git status --porcelain` in line form, where git quotes a
# path holding any byte outside ASCII — `"docs/\320\227…"` — and the quoted form
# is not a path anyone can stage. A Cyrillic file was listed as a string that
# `git add` then refused (Sidetrack #9, docs/tasks/crystal-wake/workitem.md).
#
# Run: bash tests/git-guard-hook.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: the fixture below runs
# `git init` / `git add` / `git commit`, and as a child of a live `git commit`
# the inherited GIT_INDEX_FILE would point them at that commit's index
# (tests/gates.test.sh, 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM VDX_HQ CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Nor the machine's git config: git 2.54 runs a hook declared there
# (`hook.<name>.command`) on every commit, a fixture's included — the case is
# in tests/gates.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/plugins/vdm-git/scripts/git-guard-hook.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gitguardhook)
trap 'rm -rf "$TMP"' EXIT

FX="$TMP/repo"
mkdir -p "$FX/docs"
( cd "$FX" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' > "$FX/README.md"
( cd "$FX" && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'x\n' > "$FX/docs/Заметка.md"
( cd "$FX" && git add -- "docs/Заметка.md" ) >/dev/null 2>&1
printf 'y\n' > "$FX/Черновик.txt"
printf 'z\n' >> "$FX/README.md"

# The command is assembled, not written out, as tests/hook-fail-closed.test.sh
# does for the same payload.
cmd="git "; cmd="${cmd}commit -m x"
python3 -c 'import json, sys; json.dump({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}, open(sys.argv[3], "w"))' \
  "$cmd" "$FX" "$TMP/p-commit.json"

OUT=$(cd "$FX" && LC_ALL=en_US.UTF-8 CLAUDE_PROJECT_DIR="$FX" bash "$HOOK" < "$TMP/p-commit.json" 2>&1)
RC=$?

# ---------------------------------------------------------------------------
printf '\nthe lists name files as themselves\n'
# ---------------------------------------------------------------------------
# The canary first: without a block there is no message, and every assertion
# below would be about nothing.
eq "canary: the commit is blocked" 2 "$RC"
says "…and the message lists what is staged" "$OUT" "STAGED"
says "RED: a staged Cyrillic file is listed as itself" "$OUT" "docs/Заметка.md"
says "RED: an untracked Cyrillic file is listed as itself" "$OUT" "Черновик.txt"
says "…next to an ASCII one" "$OUT" "README.md"
says_not "RED: …and no quoted octal leaks into the list" "$OUT" '\320'

# ---------------------------------------------------------------------------
printf '\na name that is not UTF-8 does not empty the lists\n'
# ---------------------------------------------------------------------------
# With -z the names arrive raw, and a strict decode of one that is not UTF-8
# raises; run_git turns any exception into "no output". The list then came back
# empty, and the message told the assistant to stage what was already staged.
# APFS will not store such a name; a git index will, so the entry is written
# straight into the index.
FB="$TMP/badname"
mkdir -p "$FB/docs"
( cd "$FB" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' > "$FB/README.md"
( cd "$FB" && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'x\n' > "$FB/docs/Заметка.md"
( cd "$FB" && git add -- "docs/Заметка.md" &&
  blob=$(git hash-object -w README.md) &&
  git update-index --add --cacheinfo "100644,$blob,b$(printf '\377')d.txt" ) >/dev/null 2>&1
python3 -c 'import json, sys; json.dump({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}, open(sys.argv[3], "w"))' \
  "$cmd" "$FB" "$TMP/p-badname.json"

OUT=$(cd "$FB" && LC_ALL=en_US.UTF-8 CLAUDE_PROJECT_DIR="$FB" bash "$HOOK" < "$TMP/p-badname.json" 2>&1)
RC=$?
eq "canary: the commit is blocked" 2 "$RC"
says "RED: the staged Cyrillic file is still listed" "$OUT" "docs/Заметка.md"
says_not "RED: …and the message does not claim nothing is staged" "$OUT" "STAGED: none"
says "…with both entries counted" "$OUT" "STAGED (2 file(s))"

# ---------------------------------------------------------------------------
printf '\nthe grant: a project that lets the assistant push or commit\n'
# ---------------------------------------------------------------------------
# docs/tasks/git-commit-privilege, DL #2, #3. The hook asks the helper for the
# grant, read from the committed vdm-plugins.json: a plain push goes through, a
# forced one does not, a raw commit is still sent to the prep, and a grant that
# lives only in the working tree grants nothing.
payload() {
  python3 -c 'import json, sys; json.dump({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}, open(sys.argv[3], "w"))' \
    "$1" "$2" "$3"
}
FG="$TMP/grant"
mkdir -p "$FG/.claude"
( cd "$FG" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf '{"git-guard":{"assistant":["commit","push"]}}\n' > "$FG/.claude/vdm-plugins.json"
( cd "$FG" && git add -A && git commit -qm init ) >/dev/null 2>&1
pcmd="git "; pcmd="${pcmd}push"

payload "$pcmd origin master" "$FG" "$TMP/p-push.json"
OUT=$(cd "$FG" && bash "$HOOK" < "$TMP/p-push.json" 2>&1); RC=$?
eq "RED: a plain push under the grant goes through" 0 "$RC"

payload "$pcmd --force origin master" "$FG" "$TMP/p-force.json"
OUT=$(cd "$FG" && bash "$HOOK" < "$TMP/p-force.json" 2>&1); RC=$?
eq "RED: …a forced one does not" 2 "$RC"
says "…and the refusal says why" "$OUT" "is not among the options a granted push may carry"

( cd "$FG" && git config remote.origin.mirror true )
payload "$pcmd origin master" "$FG" "$TMP/p-mirror.json"
OUT=$(cd "$FG" && bash "$HOOK" < "$TMP/p-mirror.json" 2>&1); RC=$?
eq "RED: …nor a plain one from a repository whose config mirrors" 2 "$RC"
says "…and the refusal names the key" "$OUT" "remote.origin.mirror"
( cd "$FG" && git config --unset remote.origin.mirror )

payload "$cmd" "$FG" "$TMP/p-gcommit.json"
OUT=$(cd "$FG" && bash "$HOOK" < "$TMP/p-gcommit.json" 2>&1); RC=$?
eq "a raw commit under the grant is still blocked" 2 "$RC"
says "RED: …and sent to the prep, which commits itself" "$OUT" "goes through the helper"

FW="$TMP/grant-tree"
mkdir -p "$FW/.claude"
( cd "$FW" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' > "$FW/README.md"
( cd "$FW" && git add -A && git commit -qm init ) >/dev/null 2>&1
printf '{"git-guard":{"assistant":["push"]}}\n' > "$FW/.claude/vdm-plugins.json"
payload "$pcmd" "$FW" "$TMP/p-tree.json"
OUT=$(cd "$FW" && bash "$HOOK" < "$TMP/p-tree.json" 2>&1); RC=$?
eq "RED: a grant only in the working tree grants nothing" 2 "$RC"
says "…the push is blocked as before" "$OUT" "BLOCKED — git push"

# ---------------------------------------------------------------------------
printf '\nthe command matcher: every case in scripts/test-git-guard-hook.py\n'
# ---------------------------------------------------------------------------
# The table was written with the matcher and run by hand only: no gate called
# it. On 2026-09-26 the 23 cases added to it were red on the matcher of the
# time — `git -C <dir> commit`, `bash -c 'git commit'`, a commit after a
# here-string (Sidetrack #18, docs/tasks/crystal-wake/workitem.md).
CASES_OUT=$(python3 "$REPO_ROOT/scripts/test-git-guard-hook.py" 2>&1); RC=$?
n=$(printf '%s\n' "$CASES_OUT" | grep -cE '✓|✗')
if [ "$n" -ge 70 ]; then ok "canary: the table ran ($n cases)"
else bad "canary: the table ran" "only $n cases — the table was cut or did not load"; fi
if [ "$RC" = 0 ]; then ok "RED: every case in the table holds"
else bad "RED: every case in the table holds" "$(printf '%s\n' "$CASES_OUT" | grep -A1 '✗' | head -20)"; fi

printf '\ngit-guard-hook: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
