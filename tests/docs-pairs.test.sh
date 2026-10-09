#!/bin/bash
# docs-pairs.test.sh — lib/docs-pairs.py, the pairs "document ↔ what the change
# removed or rewrote" that the docs-sync reminder and git-guard-prepare print.
#
# Field case (echelon, 2026-10-08): the reminder built its list from the path
# components of the dirty files. The project's code sat in `<project>/`, every
# document named the project, and 94 reminders printed the same first ten
# documents by path. The tests below hold the replacement to the opposite:
# a name every document uses links nothing, and the list moves with the change.
#
# No commit anywhere: the change is handed over as a diff (`--diff`), which is
# the whole of what the git modes feed the same code. The one test that needs a
# HEAD borrows this repository's, through objects/info/alternates.
#
# Run: bash tests/docs-pairs.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: as a child of a live `git
# commit` the inherited GIT_INDEX_FILE would point the fixtures at that
# commit's index (tests/gates.test.sh, 2026-09-03), and the session's author
# and editor are not this file's either.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION GIT_OPTIONAL_LOCKS \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP="${DOCS_PAIRS:-$REPO_ROOT/plugins/vdm/lib/docs-pairs.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"$2" ;; esac
}
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3"$'\n'"$2" ;; *) ok "$1" ;; esac
}
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t docspairs)
trap 'rm -rf "$TMP"' EXIT

# repo <name> — an empty repository, no commit; prints its path.
repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q . >/dev/null 2>&1
  printf '%s' "$d"
}
# diff_of <path> <old-line>... — a diff that removes those lines from <path>, as git prints it.
diff_of() {
  local p="$1"; shift
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n@@ -1,%d +0,0 @@\n' \
    "$p" "$p" "$p" "$p" "$#"
  local l
  for l in "$@"; do printf -- '-%s\n' "$l"; done
}
pairs() { ( cd "$1" && shift && python3 "$DP" "$@" 2>&1 ); }

# ---------------------------------------------------------------------------
printf '\na name every document uses links nothing\n'
# ---------------------------------------------------------------------------
R=$(repo field)
mkdir -p "$R/docs"
for i in 01 02 03 04 05 06 07 08 09 10 11; do
  printf '# Part %s\nPart of acme-core.\n' "$i" > "$R/docs/part-$i.md"
done
printf '# Setup\nacme-core reads `old_option` at start.\n' > "$R/docs/setup.md"
printf '# Acme\nacme-core, the project.\n' > "$R/README.md"
diff_of acme-core/main.py 'cfg = load("acme-core", old_option=True)' > "$TMP/field.diff"
OUT=$(pairs "$R" --diff "$TMP/field.diff")
says "RED: the document that names the rewritten identifier is named" "$OUT" "docs/setup.md — \`old_option\`"
says_not "RED: …and not the documents that only name the project" "$OUT" "README.md"
says_not "…nor any part of it" "$OUT" "docs/part-01.md"
eq "…one line, one document" "1" "$(printf '%s\n' "$OUT" | grep -c .)"

# The ceiling is a fifth of the documents, never under two.
R=$(repo ceiling)
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'doc %s\n' "$i" > "$R/d$i.md"; done
printf 'uses shared_name\n' > "$R/d1.md"; printf 'uses shared_name\n' > "$R/d2.md"
printf 'uses wide_name\n' > "$R/d3.md"; printf 'uses wide_name\n' > "$R/d4.md"; printf 'uses wide_name\n' > "$R/d5.md"
diff_of src/x.py 'shared_name = wide_name' > "$TMP/ceil.diff"
OUT=$(pairs "$R" --diff "$TMP/ceil.diff")
says "a name two documents of ten share still pairs" "$OUT" "d1.md — \`shared_name\`"
says_not "…a name three of ten share does not" "$OUT" "wide_name"

# ---------------------------------------------------------------------------
printf '\nwhat counts as an identifier — the old side of code only\n'
# ---------------------------------------------------------------------------
R=$(repo idents)
cat > "$R/guide.md" <<'EOF'
Run with --dry-run. Set MAX_ITEMS. Call loadConfig. Read cfg.retry_limit.
Please re-run it. A self-contained step. The new_thing arrives.
EOF
{
  diff_of tool.sh \
    'run --dry-run "$@"' \
    'echo "$MAX_ITEMS"' \
    'x = loadConfig()' \
    'n = cfg.retry_limit' \
    '# a self-contained step is a comment, not a name' \
    'echo "please re-run it"'
  printf '@@ -10,0 +11 @@\n+new_thing = 1\n'
} > "$TMP/idents.diff"
OUT=$(pairs "$R" --diff "$TMP/idents.diff" --max-ids 9)
says "a --flag pairs" "$OUT" "\`--dry-run\`"
says "an ENV_VAR pairs" "$OUT" "\`MAX_ITEMS\`"
says "a camelCase name pairs" "$OUT" "\`loadConfig\`"
says "a dotted.name pairs" "$OUT" "\`cfg.retry_limit\`"
says_not "a hyphenated word in a message is English, not a name" "$OUT" "re-run"
says_not "…nor in a comment" "$OUT" "self-contained"
says_not "a name only on the new side pairs with nothing — no document can describe it yet" "$OUT" "new_thing"

R=$(repo docs-only)
printf 'names old_option\n' > "$R/a.md"
diff_of b.md 'old_option was here' > "$TMP/docsonly.diff"
eq "a change of documents alone pairs with nothing" "" "$(pairs "$R" --diff "$TMP/docsonly.diff")"
diff_of src/b.py 'old_option = 1' > "$TMP/code.diff"
says "…canary: the same name removed from code does" "$(pairs "$R" --diff "$TMP/code.diff")" "a.md — \`old_option\`"

# A test's removed lines are fixture data; a document describes the code.
R=$(repo testdata)
printf 'names sample_value and README.md\n' > "$R/a.md"
for i in 1 2 3 4 5 6 7 8 9; do printf 'filler\n' > "$R/f$i.md"; done
diff_of tests/x.test.sh 'check sample_value' > "$TMP/t.diff"
eq "a test's fixture line pairs with nothing" "" "$(pairs "$R" --diff "$TMP/t.diff")"
diff_of src/x.sh 'check sample_value' > "$TMP/t2.diff"
says "…canary: the same line in code does" "$(pairs "$R" --diff "$TMP/t2.diff")" "a.md — \`sample_value\`"
diff_of src/y.sh 'cat README.md' > "$TMP/t3.diff"
eq "a document's file name in code is not an identifier" "" "$(pairs "$R" --diff "$TMP/t3.diff")"

# ---------------------------------------------------------------------------
printf '\nwhich documents are candidates\n'
# ---------------------------------------------------------------------------
R=$(repo scope)
mkdir -p "$R/docs/tasks/x/references" "$R/docs/guide"
printf 'old_option\n' > "$R/docs/tasks/x/workitem.md"
printf 'old_option\n' > "$R/docs/tasks/x/references/brief.md"
printf 'old_option\n' > "$R/PROJECT_CHANGELOG.md"
printf 'old_option\n' > "$R/docs/guide/use.md"
for i in 1 2 3 4 5 6 7 8 9; do printf 'filler\n' > "$R/docs/guide/f$i.md"; done
diff_of src/m.py 'old_option = 1' > "$TMP/scope.diff"
OUT=$(pairs "$R" --diff "$TMP/scope.diff")
says "canary: a guide that names it is a candidate" "$OUT" "docs/guide/use.md"
says_not "a crystal is a record, not a description" "$OUT" "workitem.md"
says_not "…nor its references" "$OUT" "brief.md"
says_not "…nor a changelog" "$OUT" "CHANGELOG"
{ cat "$TMP/scope.diff"; diff_of docs/guide/use.md 'old_option'; } > "$TMP/scope2.diff"
eq "a document that is part of the change is not a candidate" "" "$(pairs "$R" --diff "$TMP/scope2.diff")"

# ---------------------------------------------------------------------------
printf '\n@see — a declared link\n'
# ---------------------------------------------------------------------------
R=$(repo see)
mkdir -p "$R/src" "$R/docs"
printf '# One\n' > "$R/docs/one.md"
printf '# Near\n' > "$R/src/near.md"
printf '# @see docs/one.md\n# @see ./near.md\ncode\n' > "$R/src/a.sh"
printf 'diff --git a/src/a.sh b/src/a.sh\n--- a/src/a.sh\n+++ b/src/a.sh\n@@ -3,0 +4 @@\n+more\n' > "$TMP/see.diff"
OUT=$(pairs "$R" --diff "$TMP/see.diff")
says "a changed file's @see pairs, whatever changed in it" "$OUT" "docs/one.md — @see in src/a.sh"
says "…a path relative to the file resolves too" "$OUT" "src/near.md — @see in src/a.sh"
{ cat "$TMP/see.diff"; printf 'diff --git a/docs/one.md b/docs/one.md\n--- a/docs/one.md\n+++ b/docs/one.md\n@@ -1 +1 @@\n-# One\n+# One, updated\n'; } > "$TMP/see2.diff"
says_not "…but not to a document the change already updates" "$(pairs "$R" --diff "$TMP/see2.diff")" "docs/one.md"

# ---------------------------------------------------------------------------
printf '\nranking, the cap, odd paths\n'
# ---------------------------------------------------------------------------
R=$(repo rank)
printf 'alpha_one beta_two\n' > "$R/both.md"
printf 'alpha_one\n' > "$R/one.md"
for i in 1 2 3 4 5 6 7 8; do printf 'filler\n' > "$R/f$i.md"; done
diff_of src/r.py 'alpha_one(beta_two)' > "$TMP/rank.diff"
OUT=$(pairs "$R" --diff "$TMP/rank.diff" --max-docs 1)
# Within a document the rarest name leads: it is the most specific link.
eq "the document sharing the most names comes first, its rarest name first" "both.md — \`beta_two\`, \`alpha_one\`" "$(printf '%s\n' "$OUT" | head -1)"
eq "…and the rest is counted, not dropped" "+1 more" "$(printf '%s\n' "$OUT" | tail -1)"

R=$(repo cyr)
mkdir -p "$R/доки"
printf 'old_option\n' > "$R/доки/Настройка.md"
for i in 1 2 3 4 5 6 7 8 9; do printf 'filler\n' > "$R/f$i.md"; done
printf 'diff --git "a/src/\\321\\204.py" "b/src/\\321\\204.py"\n--- "a/src/\\321\\204.py"\n+++ "b/src/\\321\\204.py"\n@@ -1 +0,0 @@\n-old_option = 1\n' > "$TMP/cyr.diff"
OUT=$(LC_ALL=C PYTHONIOENCODING=utf-8 pairs "$R" --diff "$TMP/cyr.diff")
says "a Cyrillic document path comes out whole" "$OUT" "доки/Настройка.md — \`old_option\`"

R=$(repo nohead)
printf 'old_option\n' > "$R/a.md"
OUT=$(pairs "$R" --worktree); rc=$?
eq "a repository with no commit yet: silent" "" "$OUT"
eq "…and not an error" "0" "$rc"

# ---------------------------------------------------------------------------
printf '\nthe work tree is read without writing the index\n'
# ---------------------------------------------------------------------------
# `git diff HEAD` rewrites .git/index when a file it reads is stat-dirty, even
# with optional locks off (tests/hook-index-writes.test.sh); the reminder runs
# this on a prompt while another session may be committing. That suite cannot
# see it here: its fixture is dirty by mtime alone, and the reminder stops at a
# clean `git status` before the pairs are asked for.
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse --verify -q HEAD 2>/dev/null || true)
if [ -n "$HEAD_SHA" ]; then
  R=$(repo borrowed)
  git -C "$REPO_ROOT" rev-parse --git-path objects | ( cd "$REPO_ROOT" && xargs -I{} sh -c 'cd "{}" && pwd' ) \
    > "$R/.git/objects/info/alternates"
  ( cd "$R" && git update-ref refs/heads/main "$HEAD_SHA" && git symbolic-ref HEAD refs/heads/main \
      && git read-tree -u --reset HEAD && git update-index -q --refresh ) >/dev/null 2>&1
  printf 'x\n' >> "$R/README.md"
  tracked=$(git -C "$R" ls-files | grep -v '^README.md$' | head -1)
  touch -t 202001010000 "$R/$tracked"
  before=$(cksum < "$R/.git/index")
  pairs "$R" --worktree >/dev/null
  eq "RED: --worktree leaves .git/index as it was" "$before" "$(cksum < "$R/.git/index")"
  touch -t 202001010001 "$R/$tracked"
  before=$(cksum < "$R/.git/index")
  ( cd "$R" && GIT_OPTIONAL_LOCKS=0 git diff HEAD --stat >/dev/null 2>&1 )
  if [ "$before" != "$(cksum < "$R/.git/index")" ]; then ok "control: in the same place \`git diff HEAD\` does write it"
  else bad "control: in the same place \`git diff HEAD\` does write it" "the fixture cannot see a write — the test above proves nothing"; fi
else
  bad "this repository has a HEAD to borrow" "no HEAD at $REPO_ROOT"
fi

printf '\ndocs-pairs: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
