#!/bin/bash
# memory-scope.test.sh — a memory record names whose lesson it is.
#
# The promise (crystal hq-lessons-up, DL #3, DL #4): a record written without a
# `scope` gets one reminder in the act of writing; an `hq` or `conduct` lesson
# not lifted yet is named at session start. `scope` is read wherever `type` is
# — at the top of the frontmatter or under `metadata:` — because both shapes
# are common (measured 2026-10-07: 463 and 782 records on this machine).
#
# No commit anywhere: the fixtures are plain files under an isolated HOME.
#
# Run: bash tests/memory-scope.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/memory-scope.py

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${MEMORY_SCOPE_HOOK:-$REPO_ROOT/plugins/vdm/scripts/memory-scope-hook.sh}"
CHECK="${MEMORY_SCOPE_CHECK:-$REPO_ROOT/plugins/vdm/scripts/memory-scope-check.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac; }
silent()   { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t memscope)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
PROJ="$TMP/work/Some Project.x"
ENC="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
HMEM="$HOME/.claude/projects/$ENC/memory"
mkdir -p "$PROJ/.claude/memory" "$HMEM" "$PROJ/docs"

# hook <path> — run the PostToolUse hook as the harness would, after a Write.
hook() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"cwd":"%s"}' "$1" "$PROJ" |
    CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK"
}
rec() { mkdir -p "$(dirname "$1")"; printf -- '---\n%s\n---\n\nBody.\n' "$2" > "$1"; }

echo "== a record written without scope gets one reminder =="
rec "$PROJ/.claude/memory/no-scope.md" $'name: no-scope\ntype: feedback'
out="$(hook "$PROJ/.claude/memory/no-scope.md")"
says "RED: no scope ⇒ a reminder" "$out" "no \`scope:\`"
says "…naming the record" "$out" "no-scope.md"
says "…and the three classes" "$out" "conduct — how the assistant works"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="PostToolUse"' 2>/dev/null; then
  ok "…as PostToolUse additionalContext, not as an error"
else
  bad "…as PostToolUse additionalContext, not as an error" "$out"
fi
rec "$HMEM/home-no-scope.md" $'name: home\nmetadata:\n  type: feedback'
says "the harness's own memory directory is covered too" "$(hook "$HMEM/home-no-scope.md")" "home-no-scope.md"

echo "== scope is read where type is =="
rec "$PROJ/.claude/memory/top.md" $'name: top\ntype: project\nscope: project'
silent "scope at the top ⇒ silent" "$(hook "$PROJ/.claude/memory/top.md")"
rec "$PROJ/.claude/memory/nested.md" $'name: nested\nmetadata:\n  type: feedback\n  scope: hq'
silent "RED: scope under metadata: ⇒ silent" "$(hook "$PROJ/.claude/memory/nested.md")"
rec "$PROJ/.claude/memory/odd.md" $'name: odd\ntype: feedback\nscope: everyone'
says "a value outside the three is named" "$(hook "$PROJ/.claude/memory/odd.md")" "\`scope: everyone\` is not one of"

echo "== what is not a record is left alone =="
printf '# index\n- [x](x.md)\n' > "$PROJ/.claude/memory/MEMORY.md"
silent "the MEMORY.md index ⇒ silent" "$(hook "$PROJ/.claude/memory/MEMORY.md")"
rec "$PROJ/docs/note.md" $'name: note\ntype: feedback'
silent "a file outside memory ⇒ silent" "$(hook "$PROJ/docs/note.md")"
printf 'no frontmatter at all\n' > "$PROJ/.claude/memory/plain.md"
silent "a record with no frontmatter ⇒ silent" "$(hook "$PROJ/.claude/memory/plain.md")"
out="$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$PROJ/.claude/memory/no-scope.md" | bash "$HOOK")"
silent "a Read ⇒ silent" "$out"
rc=0; hook "$PROJ/.claude/memory/no-scope.md" >/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok "the reminder never blocks — exit 0" || bad "the reminder never blocks — exit 0" "exit $rc"

echo "== session start names hq and conduct lessons not lifted yet =="
rm -f "$PROJ/.claude/memory/"*.md "$HMEM/"*.md
out="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CHECK" </dev/null)"
silent "nothing waiting ⇒ silent" "$out"
rec "$PROJ/.claude/memory/hq-waits.md" $'name: hq-waits\ntype: feedback\nscope: hq'
rec "$HMEM/conduct-waits.md" $'name: conduct-waits\nmetadata:\n  type: feedback\n  scope: conduct'
rec "$PROJ/.claude/memory/already-up.md" $'name: already-up\ntype: feedback\nscope: conduct\nshared: rules.md → Disagree with the user out loud'
rec "$PROJ/.claude/memory/local.md" $'name: local\ntype: project\nscope: project'
rec "$PROJ/.claude/memory/empty-shared.md" $'name: empty-shared\ntype: feedback\nscope: hq\nshared:'
out="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$CHECK" </dev/null)"
says "RED: three lessons are waiting" "$out" "3 lesson(s) marked hq or conduct"
says "…one from the project's memory" "$out" "hq-waits"
says "…one from the harness's, found by the project's path" "$out" "conduct-waits"
says "…an empty shared: is not a home" "$out" "empty-shared"
says_not "…a lifted lesson is not named" "$out" "already-up"
says_not "…nor a project lesson" "$out" "local"

echo "== wiring =="
hj="$REPO_ROOT/plugins/vdm/hooks/hooks.json"
says "the reminder is a PostToolUse hook" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(h["command"] for g in d["hooks"]["PostToolUse"] for h in g["hooks"]))' "$hj")" "memory-scope-hook.sh"
says "the line is a SessionStart hook" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(h["command"] for g in d["hooks"]["SessionStart"] for h in g["hooks"]))' "$hj")" "memory-scope-check.sh"
for f in memory-scope-hook.sh memory-scope-check.sh memory-scope.py; do
  [ -x "$REPO_ROOT/plugins/vdm/scripts/$f" ] && ok "$f is executable" || bad "$f is not executable"
done

printf '\nmemory-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
