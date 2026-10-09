#!/bin/bash
# crystal-stop-reminder.test.sh — the Stop hook's "source edited but workitem.md
# untouched" check: what it walks, and how many times.
#
# Field case (hook-timeout-fail-open, DL #9, re-measured 2026-10-08): on a note
# vault with eleven active crystals the hook ran one `find` per crystal, each
# descending into every directory it meant to exclude (`-not -path` does not
# prune), without the project's crystal.capture-exclude. 10 s a walk; in a week
# the hook hit its 30 s ceiling on 96 of its 115 recorded runs there, and every
# turn there ended with that wait. The capture reminder had been fixed for the
# same three defects a month earlier; the Stop hook kept its own copy of the
# walk. Now both take the rule from lib/crystal-path.sh (vdm_crystal_walk_prunes).
#
# What this file holds:
#   - one tree walk, whatever the number of crystals (RED on the per-crystal loop);
#   - the answer per crystal is the one the per-crystal loop gave: a crystal is
#     named when some file is newer than its workitem, and only then;
#   - capture-exclude, `.stversions` and the crystal roots are pruned, also when
#     the session's cwd is a symlink to the project.
#
# No commit anywhere: crystal roots are found through `git ls-files`, and
# `git add` is enough for that.
#
# Run: bash tests/crystal-stop-reminder.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: as a child of a live `git
# commit` the inherited GIT_INDEX_FILE would point the fixture's `git add` at
# that commit's index (tests/gates.test.sh, 2026-09-03), and the session's
# author and editor are not this file's either.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${CRYSTAL_STOP_REMINDER:-$REPO_ROOT/plugins/vdm/scripts/crystal-stop-reminder.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t stopreminder)
# Physical path: the symlinked-cwd case below builds its own logical one.
TMP=$(cd "$TMP" && pwd -P)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The find journal sits outside every project, or the journal itself would be
# a file newer than the workitems.
STATE="$TMP/state"; SHIM="$TMP/shim"
mkdir -p "$STATE" "$SHIM"
REAL_FIND=$(type -P find)
# Not `exec`: the shim outlives find to journal how it ended — a walk the hook
# stopped reading dies of a broken pipe, one read to the end exits 0.
cat >"$SHIM/find" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$STATE/find.log"
"$REAL_FIND" "\$@"
rc=\$?
printf '%s %s\n' "\$rc" "\$*" >>"$STATE/find.rc"
exit \$rc
EOF
chmod +x "$SHIM/find"

# project <dir> <slug>... — a git work tree with one in-progress crystal with
# an open item per slug, a src/ file, an excluded data/ directory and a
# Syncthing archive. Every file starts in 2019; a case moves what it needs.
project() {
  local dir="$1" slug; shift
  mkdir -p "$dir/.claude" "$dir/src" "$dir/data" "$dir/.stversions/src"
  for slug in "$@"; do
    mkdir -p "$dir/tasks/$slug"
    printf -- '---\nslug: %s\nstatus: in-progress\n---\n# %s\n\n- [ ] open\n' "$slug" "$slug" \
      >"$dir/tasks/$slug/workitem.md"
  done
  printf '{"crystal":{"capture-exclude":["data"]}}\n' >"$dir/.claude/vdm-plugins.json"
  printf 'echo hi\n' >"$dir/src/main.sh"
  printf 'rows\n' >"$dir/data/rows.csv"
  printf 'echo old\n' >"$dir/.stversions/src/main~20261001.sh"
  ( cd "$dir" && git init -q . && git add -A >/dev/null 2>&1 )
  "$REAL_FIND" "$dir" -path "$dir/.git" -prune -o -type f -exec touch -t 201901010000 {} +
}
# at <time> <file>... — set mtimes, [[CC]YY]MMDDhhmm as touch -t takes them.
at() { local t="$1"; shift; touch -t "$t" "$@"; }

# run <cwd> — the way the harness calls a Stop hook: cwd = the project, the
# event JSON on stdin, the find shim first on PATH. Prints the message text.
run() {
  rm -f "$STATE/find.log" "$STATE/find.rc"
  ( cd "$1" && printf '{"session_id":"t"}' \
      | PATH="$SHIM:$PATH" TMPDIR="$STATE" bash "$HOOK" 2>/dev/null ) \
    | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('systemMessage',''))
except ValueError: pass"
}
# named — the crystals in the hook's nudge, or "-" when it gave none.
named() {
  local line
  line=$(printf '%s\n' "$1" | grep '📌' | sed -e 's/^📌 //' -e 's/: source edited.*//')
  printf '%s\n' "${line:--}"
}
walks() { grep -c -- '-newer' "$STATE/find.log" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
printf '\none walk, whatever the number of crystals\n'
# ---------------------------------------------------------------------------
# Nothing is newer than any workitem: the case in which the old loop walked
# the tree once per crystal, to the end each time.
P2="$TMP/two"; project "$P2" a1 a2
at 202001010000 "$P2"/tasks/*/workitem.md
out=$(run "$P2")
case "$out" in *"a1: 1 unchecked"*) ok "the canary: the hook ran and saw the crystals" ;;
  *) bad "the canary: the hook ran and saw the crystals" "$out" ;; esac
eq "two crystals: one walk" "1" "$(walks)"

P8="$TMP/eight"; project "$P8" b1 b2 b3 b4 b5 b6 b7 b8
at 202001010000 "$P8"/tasks/*/workitem.md
out=$(run "$P8")
eq "RED: eight crystals: still one walk" "1" "$(walks)"
eq "…and with nothing newer, no crystal is named" "-" "$(named "$out")"

# ---------------------------------------------------------------------------
printf '\nthe answer per crystal is the one a walk per crystal gave\n'
# ---------------------------------------------------------------------------
P="$TMP/proj"; project "$P" alpha beta gamma
at 202001010000 "$P/tasks/alpha/workitem.md"
at 202201010000 "$P/tasks/beta/workitem.md"
at 202401010000 "$P/tasks/gamma/workitem.md"

at 202301010000 "$P/src/main.sh"
eq "a file between two crystals names the older ones only" "alpha, beta" "$(named "$(run "$P")")"

at 202501010000 "$P/src/main.sh"
eq "a file newer than all of them names all of them" "alpha, beta, gamma" "$(named "$(run "$P")")"

at 201901010000 "$P/src/main.sh"
eq "a file older than all of them names none" "-" "$(named "$(run "$P")")"

# The newest file is the answer, wherever the walk meets it. Two newer files,
# and the same case with their times swapped: whichever order find takes, in
# one of the two the less new file comes first.
mkdir -p "$P/src/a" "$P/src/z"
printf 'x\n' >"$P/src/a/one.sh"; printf 'y\n' >"$P/src/z/two.sh"
at 202101010000 "$P/src/a/one.sh"; at 202301010000 "$P/src/z/two.sh"
first=$(named "$(run "$P")")
at 202301010000 "$P/src/a/one.sh"; at 202101010000 "$P/src/z/two.sh"
second=$(named "$(run "$P")")
eq "the newest file decides, not the first one found" "alpha, beta|alpha, beta" "$first|$second"
at 201901010000 "$P/src/a/one.sh" "$P/src/z/two.sh"

# The walk stops at the first file newer than every crystal: then all of them
# are named, and reading on cannot change it. More such files than a pipe
# buffers (64 KiB), so a walk read to the end and one cut short end differently.
mkdir -p "$P/src/many"
( cd "$P/src/many" && touch -t 202501010000 f{1..3000}-a-name-long-enough-to-fill-the-pipe.sh )
out=$(run "$P")
eq "a file newer than every crystal names them all" "alpha, beta, gamma" "$(named "$out")"
rc=$(grep -- '-newer' "$STATE/find.rc" 2>/dev/null | tail -1 | cut -d' ' -f1)
if [ -n "$rc" ] && [ "$rc" != 0 ]; then ok "…and the walk stops there (find ended by the closed pipe, rc $rc)"
else bad "…and the walk stops there (find ended by the closed pipe)" "find exit status: [${rc}] — read to the end"; fi
rm -rf "$P/src/many"

# ---------------------------------------------------------------------------
printf '\nwhat is not work does not count\n'
# ---------------------------------------------------------------------------
at 202501010000 "$P/data/rows.csv"
eq "RED: a file under crystal.capture-exclude is not evidence" "-" "$(named "$(run "$P")")"
at 201901010000 "$P/data/rows.csv"

at 202501010000 "$P/.stversions/src/main~20261001.sh"
eq "RED: Syncthing's archive of old versions is not evidence" "-" "$(named "$(run "$P")")"
at 201901010000 "$P/.stversions/src/main~20261001.sh"

# Another crystal's workitem is newer than alpha's — it lives under the crystal
# root, which is pruned. The cwd the hook is given may be a symlink to the
# project (macOS: /var → /private/var), while the roots come back physical.
ln -s "$P" "$TMP/link"
eq "a newer workitem of another crystal is not evidence" "-" "$(named "$(run "$P")")"
eq "RED: …nor when the session's cwd is a symlink to the project" "-" "$(named "$(run "$TMP/link")")"

printf '\ncrystal-stop-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
