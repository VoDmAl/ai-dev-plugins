#!/bin/bash
# docs-sync-reminder.test.sh — the UserPromptSubmit hook that lists the changed
# files, their @see references and the docs a change may have left behind.
#
# The assertion this file exists for: what the hook costs does not grow with
# the number of changed files. Steps 3 and 4 ran a pipeline per changed file —
# `sed | grep | head | tr | sed` for @see references, `tr | sed | grep | grep`
# for keywords — and escaped two strings for each file with a reference: 75
# launches with two changed files, 249 with twenty (Sidetrack #8,
# docs/tasks/crystal-wake/workitem.md). The first half of the file pins what
# those steps extract, so that a rewrite is held to the old answers.
#
# Run: bash tests/docs-sync-reminder.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: the fixtures below run
# `git init` / `git add` / `git commit`, and as a child of a live `git commit`
# the inherited GIT_INDEX_FILE would point them at that commit's index
# (tests/gates.test.sh, 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/plugins/vdm/scripts/docs-sync-reminder.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"$2" ;; esac
}
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t docssync)
trap 'rm -rf "$TMP"' EXIT
REAL=$(cd "$TMP" && pwd -P)

# fixture <name> — a repository with one committed file; prints its path.
fixture() {
  local d="$REAL/$1"
  mkdir -p "$d/src" "$d/docs"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  printf 'x\n' > "$d/README.md"
  ( cd "$d" && git add -A && git commit -qm base ) >/dev/null 2>&1
  printf '%s' "$d"
}
# context_of <repo> — the hook's additionalContext, decoded. A fresh session and
# a fresh throttle directory on every call, so the smart mode's window is open.
# Both come from mktemp, not from a counter: these helpers run inside `$(...)`,
# and a counter bumped there is thrown away with the subshell — every run then
# shared one session, and all but the first met a closed window.
context_of() {
  local t
  t=$(mktemp -d "$REAL/tmp.XXXXXX")
  ( cd "$1" && printf '{"session_id":"%s"}' "${t##*/}" \
      | TMPDIR="$t" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null ) \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null
}

# ---------------------------------------------------------------------------
printf '\nwhat the hook extracts from the changed files\n'
# ---------------------------------------------------------------------------
R=$(fixture extract)
printf '# Alpha module\nThe alpha-module script.\n' > "$R/docs/alpha.md"
cat > "$R/src/alpha-module.sh" <<'EOF'
# @see docs/one.md
# first @see docs/wrong.md, then @see docs/Two.MD
# @see notes.txt
# @see docs/three.md
# @see docs/four.md
# @see docs/five.md
# @see docs/six.md
EOF
printf '# @see docs/eq.md\n' > "$R/src/a=b.sh"
printf '# @see a.md,b.md\n' > "$R/src/commas.sh"
printf 'no references here\n' > "$R/src/plain.sh"
# Staged, so that git names each file: an untracked new directory is reported
# as the one entry `src/`, and the hook would never open a file in it.
( cd "$R" && git add -A ) >/dev/null 2>&1
CTX=$(context_of "$R")

says "canary: the hook speaks" "$CTX" "@see references found:"
says "the last @see on a line, .md in any case, the first five" "$CTX" \
  "src/alpha-module.sh: docs/one.md, docs/Two.MD, docs/three.md, docs/four.md, docs/five.md"
says_not "…not a reference that is not a .md" "$CTX" "notes.txt"
says_not "…nor the sixth" "$CTX" "docs/six.md"
says "a file named like an awk assignment is still a file" "$CTX" "src/a=b.sh: docs/eq.md"
says "a comma inside a token reads as a list, as it always did" "$CTX" "src/commas.sh: a.md, b.md"
says_not "a file with no references is not listed among them" "$CTX" "src/plain.sh:"
says "a keyword from a changed path finds the doc that names it" "$CTX" "Potentially affected docs: docs/alpha.md"

# ---------------------------------------------------------------------------
printf '\ncost: counted in launches, not seconds\n'
# ---------------------------------------------------------------------------
COSTS="$REAL/costs"
mkdir -p "$COSTS"
for tool in git sort awk grep head tail tr sed cat cut wc dirname basename date jq mkdir; do
  real=$(type -P "$tool" 2>/dev/null) || continue
  cat > "$COSTS/$tool" <<EOF
#!/bin/bash
printf x >> "\$LAUNCH_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$COSTS/$tool"
done
# launches <repo> — launches of one hook run, window open; the hook's own
# output is kept in $COSTS/out, to show which path the counted run took.
launches() {
  local t
  t=$(mktemp -d "$REAL/tmp.XXXXXX")
  : > "$COSTS/log"
  ( cd "$1" && printf '{"session_id":"%s"}' "${t##*/}" \
      | TMPDIR="$t" CLAUDE_PROJECT_DIR="$1" LAUNCH_LOG="$COSTS/log" PATH="$COSTS:$PATH" \
        bash "$HOOK" > "$COSTS/out" 2>/dev/null )
  wc -c < "$COSTS/log" | tr -d ' '
}
# changed <repo> <n> — n changed files, each with its own name and an @see,
# staged so that git lists every one of them.
changed() {
  local i=1
  while [ "$i" -le "$2" ]; do
    printf '# @see docs/module-%02d.md\n' "$i" > "$1/src/module-$i.sh"
    i=$((i + 1))
  done
  ( cd "$1" && git add -A ) >/dev/null 2>&1
}
R2=$(fixture two);     changed "$R2" 2
R20=$(fixture twenty); changed "$R20" 20
two=$(launches "$R2")
twenty=$(launches "$R20")
out20=$(cat "$COSTS/out")
# Two canaries: the counter sees something, and what it saw is the per-file
# path — a hook that left early costs the same whatever it was given, and would
# pass the comparison below without ever running the steps it is about.
if [ "${two:-0}" -gt 0 ]; then ok "canary: the counter sees the hook ($two launches with two changes)"
else bad "canary: the counter sees the hook" "no launch counted"; fi
says "canary: the counted run read every changed file" "$out20" "src/module-20.sh: docs/module-20.md"
eq "RED: twenty changed files cost what two do" "$two" "$twenty"

printf '\ndocs-sync-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
