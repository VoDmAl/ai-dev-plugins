#!/bin/bash
# git-guard-reminder.test.sh — the commit reminder speaks for work, not notes.
#
# Field case (a project, 2026-10-20…22): the assistant's working record — a
# crystal in the branch of a merge request under review — took three of the
# branch's four commits, each with its own push: a pipeline run and an "added 1
# commit" for the reviewer every time, all three bound for main. The owner:
# «Почему так много коммитов и пушей?» What pushed was this reminder, which asks
# for a commit whenever the tree is dirty and a crystal edit makes it dirty. A
# note rides with the next work commit or the session's last (/vdm:wrap).
#
# A note: a file under a crystal root — the lib's own answer, configured or
# auto-scanned — or the assistant's memory in `.claude/memory/`. Not docs/llm/:
# a long-lived doc is part of the work it documents.
#
# No commit anywhere: in a repository without one every tracked file is a
# change, so the fixtures hold only the files a case is about, and the config
# stays out of `git status` through `.git/info/exclude`.
#
# Run: bash tests/git-guard-reminder.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm-git/scripts/git-guard-reminder.sh

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

# Nor the machine's git config: a global excludesFile would hide files the
# fixture means to show, and git 2.54 runs a hook declared there on commands of
# its own (the case is in tests/gates.test.sh).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMINDER="${GIT_GUARD_REMINDER:-$REPO_ROOT/plugins/vdm-git/scripts/git-guard-reminder.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
silent() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: ${2:0:120}…"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gitguardrem)
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export TMPDIR="$TMP/tmp" HOME="$TMP/home"
mkdir -p "$TMPDIR" "$HOME"

# repo <dir> <mode> [crystal.paths json] — a fresh repository whose config
# git does not see.
repo() {
  mkdir -p "$1/.claude"
  git -C "$1" init -q
  if [ -n "${3:-}" ]; then
    printf '{"git-guard":{"mode":"%s"},"crystal":{"paths":%s}}\n' "$2" "$3" > "$1/.claude/vdm-plugins.json"
  else
    printf '{"git-guard":{"mode":"%s"}}\n' "$2" > "$1/.claude/vdm-plugins.json"
  fi
  printf '.claude/vdm-plugins.json\n' >> "$1/.git/info/exclude"
}
put() { mkdir -p "$(dirname "$1/$2")"; printf 'x\n' > "$1/$2"; git -C "$1" add -- "$2"; }
# A session of its own per call: `remind` runs inside $(…), so a counter kept
# in the shell would never move.
remind() { ( cd "$1" && printf '{"session_id":"s%s%s"}' "$RANDOM" "$RANDOM" | bash "$REMINDER" 2>/dev/null ); }

echo "== notes alone ask for no commit =="
R="$TMP/notes"; repo "$R" conditional
put "$R" docs/tasks/demo/workitem.md
put "$R" docs/tasks/demo/references/brief.md
put "$R" .claude/memory/lesson.md
silent "RED: a crystal and the assistant's memory changed ⇒ silent" "$(remind "$R")"
mkdir -p "$R/docs/tasks/fresh"; printf 'x\n' > "$R/docs/tasks/fresh/workitem.md"
silent "RED: …a crystal folder nobody has added yet too" "$(remind "$R")"
put "$R" "docs/tasks/demo/заметка.md"
silent "RED: …and a note named outside ASCII" "$(remind "$R")"
silent "RED: …asked from a subdirectory, where git still names paths from the top" "$(remind "$R/docs/tasks/demo")"

echo "== work beside them asks as before =="
put "$R" src/app.js
out="$(remind "$R")"
says "a source file among the notes ⇒ the reminder" "$out" "[git-guard]"
says "RED: …which says notes alone wait for work" "$out" "NOTES ALONE ARE NO COMMIT"
W="$TMP/llm"; repo "$W" conditional
put "$W" docs/tasks/demo/workitem.md
put "$W" docs/llm/topic.md
says "a docs/llm/ doc is work, not a note ⇒ the reminder" "$(remind "$W")" "[git-guard]"

echo "== the crystal roots are the lib's =="
C="$TMP/configured"; repo "$C" conditional '["work/items"]'
put "$C" work/items/demo/workitem.md
silent "RED: a configured root holds notes ⇒ silent" "$(remind "$C")"
put "$C" docs/tasks/other/workitem.md
says "…and a tasks/ outside the configured roots is not one ⇒ the reminder" "$(remind "$C")" "[git-guard]"

echo "== the default mode =="
S="$TMP/smart"; repo "$S" smart
put "$S" docs/tasks/demo/workitem.md
silent "RED: smart, notes alone, first prompt of a session ⇒ silent" "$(remind "$S")"
put "$S" lib/tool.py
says "smart, work, a fresh session ⇒ the reminder" "$(remind "$S")" "[git-guard]"
P="$TMP/proactive"; repo "$P" proactive
put "$P" docs/tasks/demo/workitem.md
says "proactive still speaks on every prompt" "$(remind "$P")" "[git-guard]"

echo "== a clean tree =="
E="$TMP/clean"; repo "$E" conditional
silent "nothing changed ⇒ silent" "$(remind "$E")"

printf '\ngit-guard-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
