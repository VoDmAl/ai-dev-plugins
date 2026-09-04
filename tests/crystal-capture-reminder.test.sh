#!/bin/bash
# crystal-capture-reminder.test.sh — tests for the in-flight capture reminder
# (UserPromptSubmit hook).
#
# The assertion this file exists for. The hook proves "work happened without
# capture" by walking the tree for files newer than each active workitem.md.
# That walk used to run on EVERY prompt, before the throttle gate, so on a
# content-heavy repo it overran the hook's own `"timeout": 5`; the harness
# killed it and dropped the output. Reported 2026-09-02 from a live session in
# a note vault (35k notes, 5 active crystals): 8.47s per prompt, the reminder
# delivered zero times, for months. Silent in the only way that matters —
# "nothing to say" and "killed mid-scan" are the same empty output.
#
# Which is why the throttle cannot be proven by looking at the output: inside
# the window a hook that skipped the scan and a hook that died in it look the
# same from outside. So the scan itself is observed — a `find` shim first on
# PATH journals every invocation, and `-newer` is the scan's signature.
# "Silent AND zero scans" is the assertion; "silent" alone proves nothing.
#
# The second pair that matters is capture-exclude: a subtree the project
# declared as content must not count as evidence — and the SAME file, with the
# exclusion removed, must. A scanner that finds nothing at all passes the first
# half; only the second half tells a working exclusion from blindness.
#
#   A green run on a tree with nothing to find proves nothing.
#
# Run: bash tests/crystal-capture-reminder.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/crystal-capture-reminder.sh
# @see plugins/vdm/lib/reminder-throttle.sh — the state-file naming relied on below
# @see docs/model/suite.md — «Цена сравнения: когда второй операнд — дерево, а не файл»

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/plugins/vdm/scripts/crystal-capture-reminder.sh"

if ! command -v jq >/dev/null 2>&1; then
  # Without jq the hook keys every session as "default" and the per-session
  # assertions below collide. Failing loudly beats a green run that tested a
  # degraded mode by accident.
  echo "crystal-capture-reminder: jq is required for this test" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
silent() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi
}
count_is() {
  # count_is <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}
exists() {
  if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi
}
absent() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "should not exist: $2"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t capturereminder)
# Physical path. On macOS mktemp answers under /var, which is a symlink to
# /private/var; `git rev-parse --show-toplevel` resolves symlinks and the hook's
# prune list is built relative to cwd — the symlink case gets its own test
# below, so every other case must run with the two in agreement.
TMP=$(cd "$TMP" && pwd -P)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Three directories, deliberately apart:
#   proj/  — the observed tree, with one active crystal
#   state/ — throttle state and the find journal. OUTSIDE proj/: the hook's
#            state file is touched on emit, and inside the tree it would be
#            "a file newer than the workitem" — evidence manufactured by the
#            detector itself.
#   shim/  — a `find` wrapper first on PATH, journaling every call.
PROJ="$TMP/proj"; STATE="$TMP/state"; SHIM="$TMP/shim"
mkdir -p "$PROJ/.claude" "$PROJ/tasks/alpha" "$PROJ/src" "$STATE" "$SHIM"

REAL_FIND=$(command -v find)
cat >"$SHIM/find" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$STATE/find.log"
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM/find"

cat >"$PROJ/tasks/alpha/workitem.md" <<'EOF'
---
slug: alpha
status: in-progress
---
# alpha
EOF
printf '{}\n' >"$PROJ/.claude/vdm-plugins.json"
printf 'echo hi\n' >"$PROJ/src/main.sh"
# Root discovery goes through `git ls-files`, so the crystal root has to be tracked.
( cd "$PROJ" && git init -q . && git add -A >/dev/null 2>&1 )

OLD=202001010000
age_all() {
  # Push every file in the tree into the past, so the only "newer" file in a
  # case is the one the case creates afterwards. Deterministic on a filesystem
  # with 1s mtime resolution too — nothing relies on "created a moment later".
  "$REAL_FIND" "$PROJ" -path "$PROJ/.git" -prune -o -type f -exec touch -t "$OLD" {} +
}
reset_state() { rm -rf "$STATE/vdm-reminder-throttle"; rm -f "$STATE/find.log"; }
cfg() { printf '%s\n' "$1" >"$PROJ/.claude/vdm-plugins.json"; }

run_hook_from() {
  # run_hook_from <cwd> <session-id> — the way the harness calls it: cwd = the
  # project, the UserPromptSubmit JSON on stdin, PATH with the shim first.
  ( cd "$1" && printf '{"session_id":"%s"}' "$2" \
      | PATH="$SHIM:$PATH" TMPDIR="$STATE" bash "$HOOK" 2>/dev/null )
}
run_hook() { run_hook_from "$PROJ" "$1"; }
scans() {
  # Tree scans since the last reset. `-newer` is the scan's signature —
  # workitem discovery also runs find, without it.
  local n
  n=$(grep -c -- '-newer' "$STATE/find.log" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}
state_file() { printf '%s\n' "$STATE/vdm-reminder-throttle/crystal-capture-$1"; }

# ---------------------------------------------------------------------------
printf '\nevidence ⇒ emit\n'
# ---------------------------------------------------------------------------
reset_state; age_all
printf 'edit\n' >"$PROJ/src/main.sh"                 # newer than the workitem
OUT=$(run_hook s1)
says     "fires when a source file is newer than the workitem" "$OUT" '"hookEventName": "UserPromptSubmit"'
says     "names the active crystal"                            "$OUT" "Active: alpha"
count_is "exactly one scan for one active workitem"            1 "$(scans)"
exists   "throttle window opened on emit"                      "$(state_file s1)"

# ---------------------------------------------------------------------------
printf '\ninside the window: silent AND no scan\n'
# ---------------------------------------------------------------------------
# The crux. Before v2.20.0 the throttle was checked AFTER the scan, so the
# window saved nothing — the tree was walked on every prompt and the result
# thrown away nine times out of ten.
rm -f "$STATE/find.log"
OUT=$(run_hook s1)
silent   "same session inside the window is silent" "$OUT"
count_is "…and the tree was not walked at all"      0 "$(scans)"

# Windows are per session — another session is not shadowed by this one.
rm -f "$STATE/find.log"
OUT=$(run_hook s2)
says     "a different session still fires" "$OUT" "Active: alpha"
count_is "…after its own scan"             1 "$(scans)"

# ---------------------------------------------------------------------------
printf '\nno evidence: silent, but it looked — and the window stays open\n'
# ---------------------------------------------------------------------------
reset_state; age_all
touch "$PROJ/tasks/alpha/workitem.md"                # the workitem is now the newest file
OUT=$(run_hook s3)
silent   "nothing newer than the workitem ⇒ silent"                "$OUT"
count_is "…but it did scan (silence by evidence, not by skipping)" 1 "$(scans)"
absent   "no emit ⇒ throttle untouched"                            "$(state_file s3)"
# So the first qualifying prompt fires — a silent pass does not consume the window.
printf 'edit\n' >"$PROJ/src/main.sh"
OUT=$(run_hook s3)
says "first qualifying prompt after a silent one fires" "$OUT" "Active: alpha"

# ---------------------------------------------------------------------------
printf '\ncapture-exclude: declared content is not evidence — the same file undeclared is\n'
# ---------------------------------------------------------------------------
reset_state; age_all
touch "$PROJ/tasks/alpha/workitem.md"
mkdir -p "$PROJ/_import"
printf 'note\n' >"$PROJ/_import/note.md"             # the ONLY file newer than the workitem
cfg '{"crystal":{"capture-exclude":["_import/"]}}'   # trailing slash on purpose: must be normalised
OUT=$(run_hook s4)
silent   "the only newer file sits in an excluded subtree ⇒ silent" "$OUT"
count_is "…and it did scan"                                          1 "$(scans)"
# Same tree, same session (nothing was emitted, so nothing is throttled),
# exclusion removed: now that file IS the evidence.
cfg '{}'
OUT=$(run_hook s4)
says "the same file with the exclusion removed fires" "$OUT" "Active: alpha"
rm -rf "$PROJ/_import"

# ---------------------------------------------------------------------------
printf '\nnested tooling dirs are pruned by name\n'
# ---------------------------------------------------------------------------
# `-not -path './node_modules/*'` only ever covered the top-level copy; `-name`
# prunes every copy, wherever it sits.
reset_state; age_all
touch "$PROJ/tasks/alpha/workitem.md"
mkdir -p "$PROJ/src/pkg/node_modules/dep"
printf 'x\n' >"$PROJ/src/pkg/node_modules/dep/index.js"
OUT=$(run_hook s5)
silent "a fresh file inside a nested node_modules is not evidence" "$OUT"
rm -rf "$PROJ/src/pkg"

# ---------------------------------------------------------------------------
printf '\nthe crystal root is pruned even when cwd is a symlink to the project\n'
# ---------------------------------------------------------------------------
# Roots resolve through `git rev-parse --show-toplevel`, a PHYSICAL path; the
# prune list is built relative to cwd, which on macOS may be the logical one
# (/tmp → /private/tmp, /var → /private/var). If the two disagree the prune
# never matches, the crystal root is scanned like source, and every sibling
# file under tasks/ becomes evidence.
reset_state; age_all
touch "$PROJ/tasks/alpha/workitem.md"
printf 'scratch\n' >"$PROJ/tasks/alpha/scratch.md"   # newer, but INSIDE the crystal root
ln -s "$PROJ" "$TMP/link"
OUT=$(run_hook_from "$TMP/link" s6)
silent "a file inside the crystal root is not evidence, symlinked cwd or not" "$OUT"
rm -f "$PROJ/tasks/alpha/scratch.md" "$TMP/link"

# ---------------------------------------------------------------------------
printf '\nmodes\n'
# ---------------------------------------------------------------------------
reset_state; age_all
printf 'edit\n' >"$PROJ/src/main.sh"                 # evidence present
cfg '{"crystal":{"capture-mode":"silent"}}'
OUT=$(run_hook s7)
silent   "silent mode never fires" "$OUT"
count_is "…and never scans"        0 "$(scans)"

reset_state; age_all
touch "$PROJ/tasks/alpha/workitem.md"                # no evidence
cfg '{"crystal":{"capture-mode":"proactive"}}'
OUT=$(run_hook s8)
says     "proactive fires without evidence" "$OUT" "Active: alpha"
count_is "…without scanning"                0 "$(scans)"
OUT=$(run_hook s8)
says     "proactive ignores the throttle"   "$OUT" "Active: alpha"
cfg '{}'

# ---------------------------------------------------------------------------
printf '\nno active crystal ⇒ nothing to remind about\n'
# ---------------------------------------------------------------------------
reset_state; age_all
printf 'edit\n' >"$PROJ/src/main.sh"
sed -i.bak 's/^status: in-progress$/status: done/' "$PROJ/tasks/alpha/workitem.md"
rm -f "$PROJ/tasks/alpha/workitem.md.bak"
OUT=$(run_hook s9)
silent   "a done crystal is not active ⇒ silent" "$OUT"
count_is "…and no scan"                          0 "$(scans)"

printf '\ncrystal-capture-reminder: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
