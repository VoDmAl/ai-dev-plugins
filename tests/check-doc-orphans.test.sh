#!/bin/bash
# check-doc-orphans.test.sh — what the orphan audit counts as a long-lived doc.
#
# The audited set is what the repository carries. A file git ignores lives on
# one machine: no clone has it, and every discovery hook the audit counts — a
# line in CLAUDE.md, a comment in source, a synthesis document — would point
# from a tracked file at nothing. Field case (a project, 2026-10-22): its
# CLAUDE.md allows a gitignored local-only reply draft in docs/llm/, and writing
# one was blocked as an orphan. Whether a file is ignored is git's verdict,
# never re-derived here. A tracked file stays audited even when a pattern
# matches it, because git does not call a tracked file ignored. Synthesis
# documents already took that verdict: distill-scan lists them through
# `git ls-files --exclude-standard`.
#
# No commit anywhere: the fixture is `git init` plus `git add`.
#
# Run: bash tests/check-doc-orphans.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/check-doc-orphans.sh
# @see plugins/vdm/scripts/orphan-guard-hook.sh

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

# Nor the machine's git config: a global excludesFile would ignore files the
# fixture means to keep, and git 2.54 runs a hook declared there on commands of
# its own (the case is in tests/gates.test.sh).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="${CHECK_DOC_ORPHANS:-$REPO_ROOT/plugins/vdm/scripts/check-doc-orphans.sh}"
HOOK="${ORPHAN_GUARD_HOOK:-$REPO_ROOT/plugins/vdm/scripts/orphan-guard-hook.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
exits()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
says()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
says_not() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac; }
silent()   { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t orphans)
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

P="$TMP/proj"
mkdir -p "$P/docs/llm" "$P/docs/model"
git -C "$P" init -q
printf 'docs/llm/*-prep.md\ndocs/model/*-local.md\n' > "$P/.gitignore"
printf '# Reply draft\nLocal only.\n' > "$P/docs/llm/reply-prep.md"
printf '# Fragment\nNothing points here.\n' > "$P/docs/llm/frag.md"
printf '# Заметка\nAn orphan with a name outside ASCII.\n' > "$P/docs/llm/заметка.md"
printf '# Kept draft\nTracked although the pattern matches it.\n' > "$P/docs/llm/kept-prep.md"
git -C "$P" add -f docs/llm/kept-prep.md
[ -n "$(git -C "$P" ls-files docs/llm/kept-prep.md)" ] || { echo "fixture: kept-prep.md is not tracked" >&2; exit 1; }
printf -- '---\ntype: model\nquestion: "local notes"\ncovers:\n  - docs/llm/\nobserved: 2026-10-22\n---\n# Local synthesis\n' \
  > "$P/docs/model/notes-local.md"

audit() { bash "$AUDIT" --project-root "$P" "$@" 2>&1; }

echo "== one file: a file git ignores is not audited =="
out="$(audit --quiet --file docs/llm/reply-prep.md)"; rc=$?
exits "RED: a gitignored docs/llm/ file ⇒ exit 0" 0 "$rc"
silent "…and nothing said" "$out"
out="$(audit --quiet --file "$P/docs/llm/reply-prep.md")"; rc=$?
exits "RED: …given by its absolute path too" 0 "$rc"
out="$(audit --quiet --file docs/llm/frag.md)"; rc=$?
exits "control: an orphan beside it in the same fixture ⇒ exit 1" 1 "$rc"
says "…named" "$out" "docs/llm/frag.md has no discovery hook"
out="$(audit --quiet --file docs/llm/kept-prep.md)"; rc=$?
exits "a tracked file the pattern matches is still audited ⇒ exit 1" 1 "$rc"
out="$(audit --quiet --file docs/model/notes-local.md)"; rc=$?
exits "a gitignored synthesis document ⇒ exit 0 (distill-scan does not list it)" 0 "$rc"

echo "== the whole set =="
out="$(audit)"; rc=$?
exits "orphans remain ⇒ exit 1" 1 "$rc"
says "…the untracked orphan is named" "$out" "docs/llm/frag.md"
says "…the tracked one too" "$out" "docs/llm/kept-prep.md"
says "…and one named outside ASCII, which git quotes unless asked for -z" "$out" "docs/llm/заметка.md"
says_not "RED: …the gitignored draft is not" "$out" "reply-prep.md"
says "RED: …and the count leaves it out" "$out" "3 orphan(s) found"

echo "== a set where every doc is ignored =="
Q="$TMP/only-ignored"
mkdir -p "$Q/docs/llm"
git -C "$Q" init -q
printf 'docs/llm/\n' > "$Q/.gitignore"
printf '# Local\n' > "$Q/docs/llm/a.md"
out="$(bash "$AUDIT" --project-root "$Q" 2>&1)"; rc=$?
exits "RED: nothing left to audit ⇒ exit 0" 0 "$rc"
says "…said as such, not as a crash" "$out" "nothing to audit"

echo "== outside git nothing is ignored =="
N="$TMP/no-git"
mkdir -p "$N/docs/llm"
printf 'docs/llm/*-prep.md\n' > "$N/.gitignore"
printf '# Draft\n' > "$N/docs/llm/x-prep.md"
out="$(bash "$AUDIT" --project-root "$N" --quiet --file docs/llm/x-prep.md 2>&1)"; rc=$?
exits "a .gitignore without a repository decides nothing ⇒ exit 1" 1 "$rc"
out="$(bash "$AUDIT" --project-root "$N" 2>&1)"; rc=$?
exits "…in the whole set too ⇒ exit 1" 1 "$rc"
says "…named" "$out" "docs/llm/x-prep.md"

echo "== the hook =="
hook() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"cwd":"%s"}' "$1" "$P" |
    CLAUDE_PROJECT_DIR="$P" bash "$HOOK" 2>&1
}
out="$(hook "$P/docs/llm/reply-prep.md")"; rc=$?
exits "RED: writing a gitignored draft is not blocked ⇒ exit 0" 0 "$rc"
silent "…and nothing said" "$out"
out="$(hook "$P/docs/llm/frag.md")"; rc=$?
exits "control: writing an orphan beside it is blocked ⇒ exit 2" 2 "$rc"
says "…with the remedy" "$out" "discovery hook"

printf '\ncheck-doc-orphans: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
