#!/bin/bash
# docs-sync-reminder.test.sh — the UserPromptSubmit hook that names the
# documents an uncommitted change may leave behind, as pairs (lib/docs-pairs.py,
# whose own rules are pinned in tests/docs-pairs.test.sh).
#
# What this file holds: the hook speaks only with a pair and is silent
# otherwise (docs/tasks/docs-sync-signal: 94 reminders with one list, one skill
# run), and what it costs does not grow with the number of changed files — the
# hook it replaced ran a pipeline per changed file, 75 launches with two
# changes and 249 with twenty (Sidetrack #8, docs/tasks/crystal-wake/workitem.md).
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

# fixture <name> — a repository whose one commit holds a README, the code
# file src/app.py and twenty module documents; prints its path.
fixture() {
  local d="$REAL/$1" i
  mkdir -p "$d/src" "$d/docs"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  printf 'x\n' > "$d/README.md"
  printf 'cfg = load(old_option=True)\nrun()\n' > "$d/src/app.py"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
    printf '# Module %s\n' "$i" > "$d/docs/module-$i.md"
  done
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
printf '\nthe hook speaks only with a pair\n'
# ---------------------------------------------------------------------------
R=$(fixture speaks)
printf '# Setup\nThe app reads `old_option` at start.\n' > "$R/docs/setup.md"
( cd "$R" && git add docs/setup.md && git commit -qm setup ) >/dev/null 2>&1
eq "a clean tree: silent" "" "$(context_of "$R")"
printf 'Notes.\n' >> "$R/docs/module-01.md"
eq "a change of documents alone: silent" "" "$(context_of "$R")"
printf 'cfg = load()\nrun()\n' > "$R/src/app.py"
CTX=$(context_of "$R")
says "RED: code that rewrote what a document names: the document, with the name" "$CTX" \
  "docs/setup.md — \`old_option\`"
says "…said as what it is: a document that did not change with the code" "$CTX" "did not change with it"
says "…and where the rest of the work lives" "$CTX" "/vdm:docs-sync"
says_not "RED: no list of every document any more" "$CTX" "Project docs"
says_not "…nor of every changed file" "$CTX" "Changed files"
printf 'Setup now says nothing of it.\n' > "$R/docs/setup.md"
eq "the same change with the document updated: silent" "" "$(context_of "$R")"

R=$(fixture see)
printf '# @see docs/module-07.md\ncfg = load(old_option=True)\nrun()\n' > "$R/src/app.py"
says "an @see in the changed code names its document" "$(context_of "$R")" \
  "docs/module-07.md — @see in src/app.py"

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
# Three documents are shown, and the other seventeen are counted: the count is
# what proves that every file was read.
says "canary: the counted run read every changed file" "$out20" "+17 more"
eq "RED: twenty changed files cost what two do" "$two" "$twenty"

printf '\ndocs-sync-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
