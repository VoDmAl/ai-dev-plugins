#!/bin/bash
# crystal-cave.test.sh — tests for the overview renderer, focused on the audit
# lines rather than on cosmetics.
#
# Why this file exists. The structural-canon audit was added to crystal-cave and
# looked fine on this repo's own tree — which is clean, so both "working" and
# "silently broken" render identically. It was in fact broken: crystal-lint exits
# 1 when it FINDS violations (its success case here, not an error), and the
# caller had `LINT_SUMMARY=$(...) || LINT_SUMMARY=""`, discarding the output
# exactly when it had something to say. A clean tree can never show that.
#
#   An audit must be tested against a tree that has something to audit.
#
# So every assertion here runs against a fixture repo containing, on purpose,
# one canonical workitem, one off-canon workitem, and one legacy import.
#
# Run: bash tests/crystal-cave.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment before anything else. A test harness
# run from inside a live `git commit` (which is what a pre-commit gate is)
# inherits GIT_INDEX_FILE / GIT_DIR pointing at THAT commit — and every `git`
# call against a throwaway fixture then writes into the user's real commit
# instead. Measured 2026-09-22 on this file's sibling: one `git add -A` in a
# fixture replaced all 158 entries of the pending commit's index with 9
# fixture paths. The commit survived only because the objects were missing.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAVE="$REPO_ROOT/plugins/vdm/scripts/crystal-cave.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing
  # (tests/harness-asserts.test.sh). Silence is asserted as silence.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystalcave)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cd "$TMP" || exit 1
git init -q .; git config user.email t@t; git config user.name t
mkdir -p docs/tasks/good docs/tasks/broken docs/tasks/imported

cat >docs/tasks/good/workitem.md <<'EOF'
---
title: "Good"
slug: good
status: in-progress
session-type: prd-work
created: 2026-08-23
last-updated: 2026-08-23
---
# Good
## Назначение
x
## Текущая модель
x
## Sidetracks
x
## Next actions
- [ ] x
## References
x
EOF

# Off canon: the shape a neighbour-copying agent produces.
cat >docs/tasks/broken/workitem.md <<'EOF'
---
title: "Broken"
slug: broken
status: ready
created: 2026-08-23
last-updated: 2026-08-23
---
# Broken
## START HERE
x
EOF

# Legacy import: informational, never a violation.
cat >docs/tasks/imported/workitem.md <<'EOF'
---
title: "Imported"
slug: imported
status: ready
crystal-schema: legacy
created: 2024-03-01
last-updated: 2024-03-01
---
# Imported
## Whatever it had
x
EOF

git add -A >/dev/null 2>&1

OUT=$(bash "$CAVE" 2>&1)

# ---------------------------------------------------------------------------
printf '\nstructural canon audit (the tree HAS violations)\n'
# ---------------------------------------------------------------------------
says "off-canon workitem is marked on its row" "$OUT" "off-canon"
says "footer counts the off-canon workitems"   "$OUT" "Off-canon shape: 1"
says "legacy import is marked on its row"      "$OUT" "legacy"
says "footer counts legacy imports"            "$OUT" "Legacy schema"
says "footer warns against copying legacy"     "$OUT" "Do not infer"
says "points at the detail command"            "$OUT" "crystal-lint.sh --all"

# The two axes must stay separate: every status here is canonical, so the
# STATUS audit line must not appear even though the SHAPE audit did.
says_not "status audit stays silent (separate axis)" "$OUT" "Non-canonical statuses"

# The canonical workitem must not be marked.
good_line=$(printf '%s\n' "$OUT" | grep ' good ' || true)
case "$good_line" in
  *off-canon*|*legacy*) bad "canonical workitem carries no marker" "got: $good_line" ;;
  *)                    ok  "canonical workitem carries no marker" ;;
esac

# ---------------------------------------------------------------------------
printf '\nrendering still works\n'
# ---------------------------------------------------------------------------
says "lists all three crystals" "$OUT" "broken"
says "renders the header"       "$OUT" "🔮"
says "renders the legend"       "$OUT" "Legend:"

# ---------------------------------------------------------------------------
printf '\nclean tree stays quiet (no false audit lines)\n'
# ---------------------------------------------------------------------------
rm -rf docs/tasks/broken docs/tasks/imported
git add -A >/dev/null 2>&1
OUT_CLEAN=$(bash "$CAVE" 2>&1)
says_not "no off-canon footer on a clean tree" "$OUT_CLEAN" "Off-canon shape"
says_not "no legacy footer on a clean tree"    "$OUT_CLEAN" "Legacy schema"
says     "still renders the surviving crystal" "$OUT_CLEAN" "good"

# ---------------------------------------------------------------------------
printf '\ncost: counted in launches, not seconds\n'
# ---------------------------------------------------------------------------
# The overview read each workitem with processes of its own — four or five
# awk for the frontmatter, a grep for the slug, an awk for the canon verdict,
# five more for dates — and resolved the roots again for every one, because
# the call that fills their memo stood in the branch that runs only when the
# library is missing: about twenty launches a workitem, 731 in the plugins
# repository (Sidetrack #14, docs/tasks/crystal-wake/workitem.md).
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"
for tool in awk sed grep sort find git date head tail tr cat cut wc dirname basename jq python3 mkdir uniq; do
  real=$(type -P "$tool" 2>/dev/null) || continue
  cat > "$SHIMS/$tool" <<EOF
#!/bin/bash
printf x >> "\$LAUNCH_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$SHIMS/$tool"
done
# cost_repo <dir> <n> — two crystal roots and n workitems between them, each
# with a description, an overdue promise and a malformed date, so that every
# per-workitem step has something to do.
cost_repo() {
  local d="$1" i root
  mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t )
  i=1
  while [ "$i" -le "$2" ]; do
    root=a; [ $((i % 2)) -eq 0 ] && root=b
    mkdir -p "$d/$root/tasks/w$i"
    printf -- '---\nslug: w%s\nstatus: ready\nsession-type: research\nlast-updated: 2026-09-01\ndescription: "item %s"\n---\n- [ ] late (due: 2020-01-01)\n- [ ] vague (due: soon)\n' \
      "$i" "$i" > "$d/$root/tasks/w$i/workitem.md"
    i=$((i + 1))
  done
  ( cd "$d" && git add -A ) >/dev/null 2>&1
}
# cave_launches <dir> — launches of one overview; its output is left in
# $TMP/cave.out, to show which path the counted run took.
cave_launches() {
  : > "$TMP/cave.log"
  ( cd "$1" && LAUNCH_LOG="$TMP/cave.log" PATH="$SHIMS:$PATH" bash "$CAVE" > "$TMP/cave.out" 2>&1 )
  wc -c < "$TMP/cave.log" | tr -d ' '
}
cost_repo "$TMP/cost2" 2
cost_repo "$TMP/cost20" 20
c2=$(cave_launches "$TMP/cost2")
c20=$(cave_launches "$TMP/cost20")
out20=$(cat "$TMP/cave.out")
# Canaries: the counter sees something, and the counted run did the per-workitem
# work — a slug under the second root, every overdue promise, every bad date.
if [ "${c2:-0}" -gt 0 ]; then ok "canary: the counter sees the overview ($c2 launches with two workitems)"
else bad "canary: the counter sees the overview" "no launch counted"; fi
says "canary: the counted run lists the last workitem under its root" "$out20" "w20"
says "canary: …counts every overdue promise" "$out20" "Overdue promises: 20"
says "canary: …and every malformed date" "$out20" 'Malformed `due:` markers: 20'
if [ "$c2" = "$c20" ]; then ok "RED: twenty workitems cost what two do ($c20)"
else bad "RED: twenty workitems cost what two do" "2 workitems: $c2 launches, 20: $c20"; fi

printf '\ncrystal-cave: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
