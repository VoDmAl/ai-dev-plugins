#!/bin/bash
# crystal-lint-bash.test.sh — `crystal-lint.sh --bash-hook`, PostToolUse on
# Bash: a workitem a shell command changed is checked against HEAD after the
# fact, by the rules the write gates apply to Write, Edit and MultiEdit.
#
# Field case (late-grow DL #6, Sidetrack #3, 2026-10-25): seven of nine sessions
# looked at closely wrote their workitem with `python3 - <<EOF … write_text`,
# `open(p,'w')` or `sed -i`, one of them flipping `status: in-progress` to
# `done` that way. crystal-completion-guard and the canon gate hold the three
# write tools only, so none of it was checked before the commit — and only
# where a pre-commit gate is wired. Letters had the same side door, closed by
# looking at the disk after the command (comms-sent-check, outgoing-ladder DL #6).
#
# What this file holds:
#   - the three rules on a workitem new to git: the canon, an open sidetrack
#     without a checkbox, a terminal status with obligations left;
#   - a clean workitem, a command that names no workitem (no process at all),
#     another tool, a directory outside git, crystal off: silence;
#   - against HEAD: only what the change brought — an unchanged file, a prose
#     edit, an old Decision Log entry are not named, a new one without its
#     fields is, and so is a flip to done.
#
# No commit anywhere: the HEAD cases borrow a commit of this repository through
# objects/info/alternates, as tests/docs-pairs.test.sh does.
#
# Run: bash tests/crystal-lint-bash.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/crystal-lint.sh (--bash-hook)

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="${CRYSTAL_LINT:-$REPO_ROOT/plugins/vdm/scripts/crystal-lint.sh}"
# A workitem that holds the canon, at a commit of this repository: the donor
# for every fixture below, and the HEAD the borrowed fixture points at.
DONOR_SHA=5090caf
DONOR_PATH=docs/tasks/late-grow/workitem.md

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"${2:0:600}" ;; esac; }
says_not() {
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3"$'\n'"${2:0:600}" ;; *) ok "$1" ;; esac
}

command -v python3 >/dev/null 2>&1 || { printf 'needs python3 — 0 assertions\n'; exit 0; }
DONOR=$(git -C "$REPO_ROOT" show "$DONOR_SHA:$DONOR_PATH" 2>/dev/null)
if [ -z "$DONOR" ]; then
  printf '  ✗ the donor %s:%s is not in this clone — every case below would pass against nothing\n\n0 passed, 1 failed\n' "$DONOR_SHA" "$DONOR_PATH"
  exit 1
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystallintbash)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# The git journal sits outside every fixture.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
REAL_GIT=$(type -P git)
cat >"$SHIM/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/git.log"
exec "$REAL_GIT" "\$@"
EOF
REAL_PY=$(type -P python3)
cat >"$SHIM/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/py.log"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$SHIM/git" "$SHIM/python3"

# hook <cwd> <tool> <command> — the way the harness calls a PostToolUse hook.
# Prints "<exit>|<stderr>".
hook() {
  local payload err rc
  payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"t","hook_event_name":"PostToolUse","tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]},"tool_response":{"stdout":""}}))' "$2" "$3")
  rm -f "$TMP/git.log" "$TMP/py.log"
  err=$( { cd "$1" && printf '%s' "$payload" | PATH="$SHIM:$PATH" bash "$LINT" --bash-hook 2>&1 >/dev/null; } ); rc=$?
  printf '%s|%s' "$rc" "$err"
}
rc_of()  { printf '%s' "${1%%|*}"; }
err_of() { printf '%s' "${1#*|}"; }

PY=$'python3 - <<\'EOF\'\np=\'docs/tasks/demo/workitem.md\'\ns=open(p).read()\nopen(p,\'w\').write(s)\nEOF'

# fresh <dir> — a repository without a commit, the donor as a new workitem.
fresh() {
  mkdir -p "$1/docs/tasks/demo"
  git -C "$1" init -q
  printf '%s\n' "$DONOR" >"$1/docs/tasks/demo/workitem.md"
  git -C "$1" add -A
}

echo "== a workitem new to git, changed by a shell command =="
F="$TMP/clean"; fresh "$F"
out=$(hook "$F" Bash "$PY")
eq "a workitem that holds the canon → silence" "0|" "$out"

F="$TMP/done"; fresh "$F"
sed -i.bak 's/^status: in-progress$/status: done/' "$F/docs/tasks/demo/workitem.md"; rm -f "$F/docs/tasks/demo/workitem.md.bak"
out=$(hook "$F" Bash "sed -i '' 's/^status: in-progress\$/status: done/' docs/tasks/demo/workitem.md")
eq "RED: flipped to done with open items → named (exit 2)" "2" "$(rc_of "$out")"
says "…with the obligations left" "$(err_of "$out")" "Unchecked items"
says "…and the word that it already happened" "$(err_of "$out")" "already on disk"

F="$TMP/offcanon"; fresh "$F"
python3 - "$F/docs/tasks/demo/workitem.md" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = re.sub(r'\n## Текущая модель\n.*?(?=\n## )', '\n', s, flags=re.S)
open(p, 'w', encoding='utf-8').write(s)
EOF
out=$(hook "$F" Bash "$PY")
eq "RED: a required section dropped → named (exit 2)" "2" "$(rc_of "$out")"
says "…by the canon" "$(err_of "$out")" "Текущая модель"

F="$TMP/orphan"; fresh "$F"
python3 - "$F/docs/tasks/demo/workitem.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = s.replace('\n## Next actions', '\n### #3. A card with no checkbox\n\n**Возникло в:** DL #5\n**Описание:** x\n\n**Status:** open\n\n## Next actions', 1)
open(p, 'w', encoding='utf-8').write(s)
EOF
out=$(hook "$F" Bash "$PY")
eq "RED: an open sidetrack without a checkbox → named (exit 2)" "2" "$(rc_of "$out")"
says "…by its number" "$(err_of "$out")" "#3. A card with no checkbox"

echo "== silence =="
F="$TMP/other"; fresh "$F"
sed -i.bak 's/^status: in-progress$/status: done/' "$F/docs/tasks/demo/workitem.md"; rm -f "$F/docs/tasks/demo/workitem.md.bak"
out=$(hook "$F" Bash "ls -la && git status --short")
eq "RED-guard: a command that names no workitem → silence, though one is broken" "0|" "$out"
eq "…and not one process for it" "0" "$(grep -c . "$TMP/git.log" 2>/dev/null || echo 0)"
eq "another tool (the --hook mode's) → silence" "0|" "$(hook "$F" Write "docs/tasks/demo/workitem.md")"
N="$TMP/nogit"; mkdir -p "$N/docs/tasks/demo"; printf '%s\n' "$DONOR" | sed 's/^status: in-progress$/status: done/' >"$N/docs/tasks/demo/workitem.md"
eq "outside a git work tree → silence" "0|" "$(hook "$N" Bash "$PY")"
mkdir -p "$F/.claude"; printf '{"crystal":{"enabled":false}}\n' >"$F/.claude/vdm-plugins.json"
eq "crystal off → silence" "0|" "$(hook "$F" Bash "$PY")"

echo "== against HEAD: only what the change brought =="
B="$TMP/borrowed"; mkdir -p "$B"; git -C "$B" init -q
git -C "$REPO_ROOT" rev-parse --git-path objects | ( cd "$REPO_ROOT" && xargs -I{} sh -c 'cd "{}" && pwd' ) \
  >"$B/.git/objects/info/alternates"
full=$(git -C "$REPO_ROOT" rev-parse "$DONOR_SHA")
( cd "$B" && git update-ref refs/heads/main "$full" && git symbolic-ref HEAD refs/heads/main \
    && git read-tree HEAD && git checkout-index -f -- "$DONOR_PATH" ) >/dev/null 2>&1
W="$B/$DONOR_PATH"
if [ -f "$W" ]; then ok "the borrowed fixture: HEAD at $DONOR_SHA, the workitem checked out"
else bad "the borrowed fixture: HEAD at $DONOR_SHA, the workitem checked out"; fi
LG=$'python3 - <<\'EOF\'\np=\'docs/tasks/late-grow/workitem.md\'\nopen(p,\'w\').write(open(p).read())\nEOF'

touch "$W"
eq "unchanged since HEAD, only touched → silence" "0|" "$(hook "$B" Bash "$LG")"
# Silence alone holds nothing here: the donor holds the canon, so a lint would
# be silent too. A committed workitem written under an older canon, rewritten
# byte for byte by a no-op `sed -i`, would not be — so the same bytes as HEAD
# are not linted at all.
eq "RED-guard: …and not linted: no python3 launched for it" "0" "$(grep -c . "$TMP/py.log" 2>/dev/null || echo 0)"

python3 - "$W" <<'EOF'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = s.replace('## Назначение\n', '## Назначение\n\nОдна строка прозы, дописанная через python.\n', 1)
open(p, 'w', encoding='utf-8').write(s)
EOF
eq "a prose edit → silence: older Decision Log entries are not re-checked" "0|" "$(hook "$B" Bash "$LG")"

cp "$W" "$TMP/prose.md"
python3 - "$W" <<'EOF'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = s.replace('\n## Sidetracks', '\n### #6 / 2026-10-25 / Решение записано прозой\n\nБез полей.\n\n## Sidetracks', 1)
open(p, 'w', encoding='utf-8').write(s)
EOF
out=$(hook "$B" Bash "$LG")
eq "RED: a Decision Log entry added without its fields → named (exit 2)" "2" "$(rc_of "$out")"
says "…that entry" "$(err_of "$out")" "Решение записано прозой"
says "…under its real path" "$(err_of "$out")" "$DONOR_PATH"

cp "$TMP/prose.md" "$W"
sed -i.bak 's/^status: in-progress$/status: done/' "$W"; rm -f "$W.bak"
out=$(hook "$B" Bash "sed -i '' 's/^status: in-progress\$/status: done/' $DONOR_PATH")
eq "RED: flipped to done against HEAD → named (exit 2)" "2" "$(rc_of "$out")"
says "…with the obligations left" "$(err_of "$out")" "Unchecked items"

printf '\ncrystal-lint-bash: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
