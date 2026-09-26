#!/bin/bash
# crystal-path.test.sh — tests for crystal root resolution, and specifically for
# the two halves of the globstar defect.
#
# `globstar` arrived in bash 4.0; macOS ships 3.2. The bare
# `shopt -s nullglob globstar` form therefore printed
#
#     shopt: globstar: invalid shell option name
#
# on stderr — and since `crystal-lint.sh --hook` runs from PostToolUse, that
# line reached the assistant as the FIRST line of the canon verdict. Noise in a
# gate's own output is how gates get switched off.
#
# The louder half is the easy one. The quiet half is the defect: without
# globstar, `**` degrades to `*` and matches exactly one level, so
# `packages/**/tasks` finds `packages/x/tasks` and misses `packages/x/y/tasks`
# — a crystal root that is simply never scanned, with nothing said. That is the
# suite's recurring failure mode (docs/model/suite.md → "механизм молча подменил
# область"), and the rule it earned is that a mechanism which narrows its own
# scope must SAY SO.
#
# So there are two things to test and they are not the same thing:
#   - the noise is gone (regression);
#   - the silence is gone too (the actual fix).
#
# Run: bash tests/crystal-path.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/lib/crystal-path.sh — _expand_globs_under_root
# @see docs/tasks/git-guard-explicit-file-list/workitem.md — Sidetrack #6

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
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/plugins/vdm/lib/crystal-path.sh"
CFG="$REPO_ROOT/plugins/vdm/lib/config-read.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
expect_not_says() {
  # An empty haystack contains nothing, so absence there proves nothing
  # (tests/harness-asserts.test.sh). Silence is asserted as silence.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }
  case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac
}
expect_silent() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystalpath)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Build a project with roots at two depths, so single-level and recursive
# expansion give measurably different answers.
new_project() {
  local d="$TMP/$1"; shift
  rm -rf "$d"; mkdir -p "$d/.claude"
  mkdir -p "$d/packages/shallow/tasks" "$d/packages/deep/nested/tasks"
  # Auto-scan discovers roots through `git ls-files`, so the directories have to
  # hold something tracked. Empty directories do not exist as far as git is
  # concerned, and a fixture of empty dirs would test nothing while looking like
  # it tested everything.
  printf 'x\n' > "$d/packages/shallow/tasks/.keep"
  printf 'x\n' > "$d/packages/deep/nested/tasks/.keep"
  ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 )
  if [ $# -gt 0 ]; then
    printf '{\n  "crystal": {\n    "paths": [%s]\n  }\n}\n' "$1" > "$d/.claude/vdm-plugins.json"
  fi
  printf '%s' "$d"
}

# Resolve roots in <dir>; stdout and stderr captured separately.
resolve_out() {
  ( cd "$1" && bash -c ". '$CFG' 2>/dev/null; . '$LIB'; resolve_crystal_roots" 2>/dev/null )
}
resolve_err() {
  ( cd "$1" && bash -c ". '$CFG' 2>/dev/null; . '$LIB'; resolve_crystal_roots" 2>&1 >/dev/null )
}

printf '\n=== the noise ===\n'
# The regression: ordinary globs must not make the library complain about the
# shell it is running on. This is what reached the assistant in front of every
# canon verdict on macOS.

d=$(new_project plain '"packages/shallow/tasks"')
err=$(resolve_err "$d")
expect_silent "a literal path: no shopt complaint, a clean stderr" "$err"

d=$(new_project autoscan)
err=$(resolve_err "$d")
expect_silent "auto-scan resolves with a clean stderr" "$err"

printf '\n=== the silence ===\n'
# The defect proper. On a shell without globstar, a `**` glob quietly scans one
# level. The library must say which glob is affected and what the consequence
# is — naming the glob matters, because "some root may be missing" is not
# actionable and gets ignored.

d=$(new_project starstar '"packages/**/tasks"')
err=$(resolve_err "$d")
out=$(resolve_out "$d")

if bash -c 'shopt -s globstar' 2>/dev/null; then
  # bash >= 4: `**` works, so there is nothing to warn about and both roots
  # must be found.
  expect_silent "globstar available ⇒ no warning" "$err"
  expect_says "globstar available ⇒ deep root found" "$out" "packages/deep/nested/tasks"
else
  # bash 3.2: the warning is the whole point.
  expect_says "warns that ** cannot expand" "$err" "globstar"
  expect_says "warning names the affected glob" "$err" "packages/**/tasks"
  expect_says "warning states the consequence" "$err" "NOT scanned"
  expect_says "warning offers a way out" "$err" "crystal.paths"
  expect_says "shallow root still resolves" "$out" "packages/shallow/tasks"
  expect_not_says "deep root is genuinely missed (this is what is announced)" \
    "$out" "packages/deep/nested/tasks"
fi

# A glob without `**` must never trigger the warning, whatever the shell.
d=$(new_project nostar '"packages/shallow/tasks", "packages/deep/nested/tasks"')
err=$(resolve_err "$d")
expect_silent "globs without ** produce no warning" "$err"
out=$(resolve_out "$d")
expect_says "explicit paths find the shallow root" "$out" "packages/shallow/tasks"
expect_says "explicit paths find the deep root" "$out" "packages/deep/nested/tasks"

# Several `**` globs must warn once, not once per glob. A warning repeated per
# entry turns a real signal into wallpaper.
d=$(new_project twostars '"packages/**/tasks", "apps/**/tasks"')
err=$(resolve_err "$d")
n=$(printf '%s\n' "$err" | grep -c 'has no `globstar`' || true)
if bash -c 'shopt -s globstar' 2>/dev/null; then
  expect_eq "globstar available ⇒ zero warnings for two ** globs" "0" "$n"
else
  expect_eq "two ** globs warn exactly once" "1" "$n"
fi

printf '\n=== resolution still works ===\n'
# Guard against a fix that silences the shell and breaks the function.

d=$(new_project functional)
out=$(resolve_out "$d")
expect_says "auto-scan finds the shallow root" "$out" "packages/shallow/tasks"
expect_says "auto-scan finds the deep root" "$out" "packages/deep/nested/tasks"

d=$(new_project absolute "\"$TMP/functional/packages/shallow/tasks\"")
out=$(resolve_out "$d")
expect_says "absolute glob is respected" "$out" "packages/shallow/tasks"

printf '\n=== filter_status: cost is O(1) processes, not O(candidates) ===\n'
# The defect this replaces: filter_status called extract_frontmatter_field per
# path, and that spawned an awk per file. 51 candidates cost 51 processes.
#
# Why a COUNT and not a stopwatch: process spawn scales with machine load, not
# with repository size, so the wall-clock symptom (a UserPromptSubmit hook
# timing out and having its output discarded — executor, 2026-09-04, 15.3s
# for this phase alone at load average 101) only reproduces on a busy machine.
# The count reproduces anywhere and is the actual invariant: whatever the
# candidate list, the work is one pass.
fs_awk_count() {
  # fs_awk_count <n-candidates> — build n synthetic workitems, run filter_status
  # under xtrace, and count how many awk processes the trace shows.
  local n="$1" d="$TMP/fsprobe-$1" i
  rm -rf "$d"; mkdir -p "$d"
  for i in $(seq 1 "$n"); do
    mkdir -p "$d/w$i"
    printf -- '---\nstatus: in-progress\n---\nbody\n' >"$d/w$i/workitem.md"
  done
  find "$d" -name workitem.md | bash -c "
    set -u
    . '$CFG' 2>/dev/null
    . '$LIB' 2>/dev/null
    set -x
    filter_status in-progress >/dev/null
  " 2>&1 | grep -c 'awk'
}
few=$(fs_awk_count 3)
many=$(fs_awk_count 30)
expect_eq "3 candidates ⇒ one awk process"  "1" "$few"
expect_eq "30 candidates ⇒ still one"       "1" "$many"

# And the answer must not have changed while getting cheaper.
mkdir -p "$TMP/fsmix/a" "$TMP/fsmix/b" "$TMP/fsmix/c"
printf -- '---\nstatus: in-progress\n---\n'  >"$TMP/fsmix/a/workitem.md"
printf -- '---\nstatus: done\n---\n'         >"$TMP/fsmix/b/workitem.md"
printf -- 'no frontmatter at all\n'            >"$TMP/fsmix/c/workitem.md"
mix=$(find "$TMP/fsmix" -name workitem.md | sort | bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; filter_status in-progress")
expect_eq "only the in-progress file survives the filter" "$TMP/fsmix/a/workitem.md" "$mix"
mixdone=$(find "$TMP/fsmix" -name workitem.md | sort | bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; filter_status done")
expect_eq "…and asking for done returns the other one"    "$TMP/fsmix/b/workitem.md" "$mixdone"
mixtier=$(find "$TMP/fsmix" -name workitem.md | sort | bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; filter_status tier:active")
expect_eq "…and the tier: form still resolves"            "$TMP/fsmix/a/workitem.md" "$mixtier"

printf '\n=== status aliases: loaded once, not once per workitem ===\n'
# The batch above left one process per workitem standing, where a project has a
# config: each status is resolved inside `$(_apply_status_alias …)`, and the
# "once per shell process" memo was set in that subshell and died with it —
# one `jq` per workitem, per call. audit_non_canonical kept an awk per workitem
# besides. crystal-stop-reminder, at the end of every turn, went 44 → 116
# launches between 2 and 20 workitems (Sidetrack #13,
# docs/tasks/crystal-wake/workitem.md). Counted by shims, not by xtrace: the
# launches that matter happen inside subshells.
ALIAS_SHIMS="$TMP/alias-shims"
mkdir -p "$ALIAS_SHIMS"
for tool in jq awk; do
  real=$(type -P "$tool" 2>/dev/null) || continue
  cat > "$ALIAS_SHIMS/$tool" <<EOF
#!/bin/bash
printf '%s\n' "$tool" >> "\$LAUNCH_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$ALIAS_SHIMS/$tool"
done
# alias_project <name> <n> — n workitems under a config that aliases `wip` to
# in-progress: w1 is `wip`, w2 `bogus`, the rest `ready`. Prints its path.
alias_project() {
  local d="$TMP/$1" i st
  rm -rf "$d"; mkdir -p "$d/.claude" "$d/docs/tasks"
  ( cd "$d" && git init -q . 2>/dev/null )
  printf '{"crystal":{"status-aliases":{"wip":"in-progress"}}}\n' > "$d/.claude/vdm-plugins.json"
  i=1
  while [ "$i" -le "$2" ]; do
    case "$i" in 1) st=wip ;; 2) st=bogus ;; *) st=ready ;; esac
    mkdir -p "$d/docs/tasks/w$i"
    printf -- '---\nstatus: %s\n---\n' "$st" > "$d/docs/tasks/w$i/workitem.md"
    i=$((i + 1))
  done
  printf '%s' "$d"
}
# alias_launches <dir> <function> — "<jq> <awk>" launched by <function> reading
# every workitem of <dir> on stdin; its output is left in $TMP/alias.out.
alias_launches() {
  find "$1/docs/tasks" -name workitem.md | sort > "$TMP/alias.list"
  : > "$TMP/alias.log"
  ( cd "$1" && LAUNCH_LOG="$TMP/alias.log" PATH="$ALIAS_SHIMS:$PATH" \
      bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; $2" < "$TMP/alias.list" > "$TMP/alias.out" 2>/dev/null )
  printf '%s %s' "$(grep -c '^jq$' "$TMP/alias.log")" "$(grep -c '^awk$' "$TMP/alias.log")"
}
A2=$(alias_project alias2 2)
A20=$(alias_project alias20 20)

fs2=$(alias_launches "$A2" "filter_status in-progress")
fs2_out=$(cat "$TMP/alias.out")
fs20=$(alias_launches "$A20" "filter_status in-progress")
# Canary: the alias was applied, so the config was read on the counted path.
expect_eq "canary: filter_status reads the alias (wip counts as in-progress)" \
  "$A2/docs/tasks/w1/workitem.md" "$fs2_out"
expect_eq "RED: filter_status — 20 workitems cost the jq and awk that 2 do" "$fs2" "$fs20"

nc2=$(alias_launches "$A2" "audit_non_canonical")
nc2_out=$(cat "$TMP/alias.out")
nc20=$(alias_launches "$A20" "audit_non_canonical")
expect_eq "canary: audit_non_canonical names the bogus status and not the aliased one" \
  "$A2/docs/tasks/w2/workitem.md" "$nc2_out"
expect_eq "RED: audit_non_canonical — 20 workitems cost the jq and awk that 2 do" "$nc2" "$nc20"

# The memo belongs to a place. Loaded in one project, it must not answer in
# another: there `wip` is no alias, so it is a non-canonical status.
PLAIN=$(new_project plain-status)
mkdir -p "$PLAIN/docs/tasks/w1"
printf -- '---\nstatus: wip\n---\n' > "$PLAIN/docs/tasks/w1/workitem.md"
moved=$(cd "$A2" && bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null
  _load_status_aliases
  cd '$PLAIN'
  printf '%s\n' '$PLAIN/docs/tasks/w1/workitem.md' | audit_non_canonical")
expect_eq "aliases loaded in one project do not answer in another" \
  "$PLAIN/docs/tasks/w1/workitem.md" "$moved"

# Scripts with a status loop of their own must load the aliases before it, as
# the library's loops do. Found by what they call, not by a list kept here.
unloaded=""
for sc in "$REPO_ROOT"/plugins/*/scripts/*.sh; do
  grep -qE '_apply_status_alias|derive_status_tier' "$sc" 2>/dev/null || continue
  grep -q '_load_status_aliases' "$sc" 2>/dev/null || unloaded="$unloaded $(basename "$sc")"
done
expect_eq "every script that resolves statuses itself loads the aliases first" "" "$unloaded"

printf '\n=== overdue promises: the projection, not a cleverer scanner ===\n'
# A checkbox has no decay signal of its own — every other signal in this suite
# compares two artifacts on disk, and an unchecked item has no second operand.
# The answer (docs-distill DL #19) is a better PROJECTION: the date the promise
# named. These assert the projection is read exactly, and — as important — that
# it stays SILENT where nothing was named, because a mandatory date would
# produce invented ones and a signal allowed to lie stops being read.
OD="$TMP/overdue.md"
cat > "$OD" <<'FIXTURE'
---
status: in-progress
---
## Next actions
- [ ] long overdue (due: 2026-07-22)
- [ ] overdue by one day (due: 2026-09-03)
- [ ] due exactly today — not yet late (due: 2026-09-04)
- [ ] future (due: 2026-12-31)
- [ ] no date at all — legal, owes nothing
- [x] done, though it was late (due: 2026-01-01)
- [ ] malformed, day-first (due: 22-07-2026)
- [ ] malformed, prose (due: soon)

```markdown
- [ ] the syntax being DOCUMENTED, not promised (due: 2026-01-01)
```
FIXTURE

n=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; count_overdue '$OD' 2026-09-04")
expect_eq "two past dates are overdue"                      "2" "$n"
first=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; list_overdue '$OD' 2026-09-04" | head -1 | cut -f1)
expect_eq "…and the earliest is reported with its date"     "2026-07-22" "$first"
text=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; list_overdue '$OD' 2026-09-04" | head -1 | cut -f2)
expect_eq "…with the marker stripped from the promise text" "long overdue" "$text"

# The boundary that is easiest to get wrong by one day, in the direction that
# matters: reporting something as late on the day it is due erodes trust in the
# signal faster than missing it by a day.
today_only=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; count_overdue '$OD' 2026-09-04")
tomorrow=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; count_overdue '$OD' 2026-09-05")
expect_eq "due today is NOT overdue"      "2" "$today_only"
expect_eq "…and is overdue tomorrow"      "3" "$tomorrow"

# A malformed date is worse than none: it READS as a projection while being
# invisible to the detector. Absent is legal; broken is not.
mal=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; audit_malformed_due '$OD'" | grep -c '.')
expect_eq "both malformed dates are flagged"           "2" "$mal"
malq=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; audit_malformed_due '$OD'" | grep -c 'no date at all')
expect_eq "…and an absent date is NOT flagged"         "0" "$malq"

printf '\n=== fenced examples are not obligations ===\n'
# Found by construction 2026-09-04: checkbox-decay-signal'"'"'s own workitem
# documents the `(due:)` syntax inside a fence, and every obligation-counter in
# the suite read that example as a promise. Consequence, not hypothetical: the
# workitem that TEACHES the format could never reach status:done.
unchecked=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; count_unchecked '$OD'")
expect_eq "the fenced example is not an obligation"    "7" "$unchecked"
fenced_od=$(bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; list_overdue '$OD' 2026-09-04" | grep -c 'DOCUMENTED')
expect_eq "…nor a phantom overdue promise"             "0" "$fenced_od"

printf '\n=== an item is its checkbox line and its continuation ===\n'
# Field report (echelon, 2026-09-25, crystal-wake DL #1): a correctly written
# date on the wrapped tail of a long item was neither overdue nor malformed —
# invisible. The census that day found 3 more live ones on the machine, every
# one the last line of a hard-wrapped item, one of them already overdue in
# silence. Hard-wrapping is how every agent here writes, and `(due:)` closes
# the sentence — so it lands on the continuation. The item's text is its
# checkbox line plus every deeper-indented line under it (blank lines inside
# included); it ends at a line no deeper than the checkbox or at the next
# checkbox. The COUNT of obligations does not change: one per checkbox.
IT="$TMP/items.md"
cat > "$IT" <<'FIXTURE'
---
status: in-progress
---
## Next actions
- [ ] short, on one line (due: 2026-09-01)
- [ ] a long item that wraps onto the next
      line, where the date sits (due: 2026-09-02)
- [ ] an item with nested bullets:
  - first detail;
  - second detail

  and a paragraph after a blank line (due: 2026-09-03)
- [ ] an item whose wrapped line carries a broken date
      (due: 03-09-2026)
- [x] a done item that wraps
      onto a dated line (due: 2026-01-01)
- [ ] a parent item
  - [ ] a nested checkbox with its own date (due: 2026-09-04)
- [ ] an item followed by a heading
## Another section
Prose at column zero (due: 2026-09-05) is not a promise.
- [ ] an item with a fence inside it
      ```
      - [ ] documented, not promised (due: 2026-01-01)
      ```
      then its own date (due: 2026-09-06)
FIXTURE
lib() { bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; $1"; }
expect_eq "RED: dates on continuation lines count — five overdue" \
  "5" "$(lib "count_overdue '$IT' 2026-09-30")"
expect_eq "…the wrapped one among them" \
  "2026-09-02" "$(lib "list_overdue '$IT' 2026-09-30" | cut -f1 | grep -x 2026-09-02)"
expect_eq "…and the one after nested bullets and a blank line" \
  "2026-09-03" "$(lib "list_overdue '$IT' 2026-09-30" | cut -f1 | grep -x 2026-09-03)"
expect_eq "…and the one after a fence inside the item" \
  "2026-09-06" "$(lib "list_overdue '$IT' 2026-09-30" | cut -f1 | grep -x 2026-09-06)"
expect_eq "GREEN: a done item's wrapped date is not overdue" \
  "0" "$(lib "list_overdue '$IT' 2026-09-30" | grep -c 2026-01-01)"
expect_eq "GREEN: prose at column zero is not a promise" \
  "0" "$(lib "list_overdue '$IT' 2026-09-30" | grep -c 2026-09-05)"
expect_eq "GREEN: a nested checkbox keeps its own date — it is not the parent's" \
  "1" "$(lib "list_overdue '$IT' 2026-09-30" | grep -c 2026-09-04)"
expect_eq "RED: a broken date on a continuation line is flagged" \
  "1" "$(lib "audit_malformed_due '$IT'" | grep -c '03-09-2026')"
expect_eq "GREEN: the count is still one per checkbox (8 open, fence and [x] out)" \
  "8" "$(lib "count_unchecked '$IT'")"

# The brief's own shape, verbatim in structure.
EB="$TMP/echelon-shape.md"
cat > "$EB" <<'FIXTURE'
## Next actions
- [ ] п. 4, command-center. При заходе видна очередь встреч: … Подтверждения после перезапуска 25.09:
  - `git status` чист;
  - …

  Первую настоящую дельту SSO/Beta command-center подтвердит после следующего сбора. Сам не проверяю — решение владельца 25.09 (due: 2026-09-28)
FIXTURE
expect_eq "RED: the echelon shape — overdue on 2026-09-29" "1" "$(lib "count_overdue '$EB' 2026-09-29")"

# Where the form came from. The template's own dated example has wrapped its
# `(due:)` onto the continuation line since the day the signal shipped (2.24.0),
# so every crystal that copied the example got a date the reader never saw. The
# example a template teaches must be one the reader can see.
TPL="$REPO_ROOT/plugins/vdm/templates/workitem-template.md"
expect_eq "RED: the template's own dated example is read (overdue once its date passes)" \
  "2026-12-31" "$(lib "list_overdue '$TPL' 2027-01-01" | cut -f1)"

printf '\n=== root resolution: found once, and found at all ===\n'
# Two defects found during the 2.24.0 acceptance run, both of the same shape as
# everything else this suite keeps rediscovering: a mechanism that LOOKS like it
# works. The memo inside resolve_crystal_roots carried a comment claiming it made
# a hook call O(1); it had in fact never been hit, because every caller reaches it
# from inside a subshell, which inherits the cache but cannot fill it.
GITP="$TMP/gitproj"
rm -rf "$GITP"; mkdir -p "$GITP/docs/tasks/alpha"
( cd "$GITP" && git init -q . 2>/dev/null )
printf -- '---\nstatus: in-progress\n---\n' >"$GITP/docs/tasks/alpha/workitem.md"

# (1) An untracked tasks/ tree — exactly the state crystal-grow leaves behind,
# before anyone runs `git add`. The git branch of the auto-scan returns
# unconditionally, so a miss here is silent and total: hydrate shows nothing,
# cave says "No crystals found", the capture reminder finds no active workitem.
found=$(cd "$GITP" && bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; resolve_crystal_roots" | grep -c 'docs/tasks')
expect_eq "an untracked tasks/ tree is still a crystal root" "1" "$found"

# …and once indexed it is still found exactly once (no double-listing from
# --cached and --others both reporting the same path).
( cd "$GITP" && git add -A 2>/dev/null )
found2=$(cd "$GITP" && bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; resolve_crystal_roots" | grep -c 'docs/tasks')
expect_eq "…and an indexed one is found exactly once"        "1" "$found2"

# (2) The scan happens ONCE per process, not once per call site. Counted by
# wrapping the scanner itself: the counter file is appended from subshells too,
# so a cache that only ever warms a child shows up immediately.
COUNTER="$TMP/scan.count"
: >"$COUNTER"
( cd "$GITP" && bash -c "
  . '$CFG' 2>/dev/null
  . '$LIB' 2>/dev/null
  eval \"orig_\$(declare -f _auto_scan_tasks_dirs)\"
  _auto_scan_tasks_dirs() { printf 'scan\n' >>'$COUNTER'; orig__auto_scan_tasks_dirs \"\$@\"; }
  vdm_prime_crystal_roots
  # the fan-out a real hook performs: every one of these is a subshell
  n=\$(resolve_crystal_roots | grep -c '.')
  find_workitems >/dev/null
  r=\$(resolve_crystal_root)
  m=\$(derive_singleton_mode)
" ) >/dev/null 2>&1
scans=$(grep -c '.' "$COUNTER" 2>/dev/null || echo 0)
expect_eq "primed: the tree is scanned once for the whole process" "1" "$scans"

# Without priming, the same fan-out rescans — this is the defect, kept as an
# executable statement of it rather than a comment that could go stale.
: >"$COUNTER"
( cd "$GITP" && bash -c "
  . '$CFG' 2>/dev/null
  . '$LIB' 2>/dev/null
  eval \"orig_\$(declare -f _auto_scan_tasks_dirs)\"
  _auto_scan_tasks_dirs() { printf 'scan\n' >>'$COUNTER'; orig__auto_scan_tasks_dirs \"\$@\"; }
  n=\$(resolve_crystal_roots | grep -c '.')
  r=\$(resolve_crystal_root)
" ) >/dev/null 2>&1
unprimed=$(grep -c '.' "$COUNTER" 2>/dev/null || echo 0)
if [ "$unprimed" -gt 1 ]; then
  ok "unprimed: the same fan-out rescans (why the priming call exists)"
else
  bad "unprimed: the same fan-out rescans (why the priming call exists)" "expected >1, got $unprimed"
fi

# Every script that resolves roots must prime. This is the obligation the fix
# rests on, and memory is not an acceptable enforcement for it.
missing=""
for sc in "$REPO_ROOT"/plugins/vdm/scripts/crystal-capture-reminder.sh \
          "$REPO_ROOT"/plugins/vdm/scripts/crystal-cave.sh \
          "$REPO_ROOT"/plugins/vdm/scripts/crystal-hydrate.sh \
          "$REPO_ROOT"/plugins/vdm/scripts/crystal-stop-reminder.sh \
          "$REPO_ROOT"/plugins/vdm/scripts/list-open-crystals.sh \
          "$REPO_ROOT"/plugins/vdm/scripts/crystal-migrate-scan.sh; do
  grep -q 'vdm_prime_crystal_roots' "$sc" 2>/dev/null || missing="$missing $(basename "$sc")"
done
expect_eq "every root-resolving script primes the cache" "" "$missing"

printf '\n=== names are bytes ===\n'
# In line output git quotes any path holding a byte outside ASCII, so a crystal
# whose every path under tasks/ held one — a Cyrillic slug is enough — gave the
# root `…/"docs/tasks`, which exists nowhere. hydrate, cave and capture saw
# nothing, while the `find` fallback outside git found it at once (Sidetrack #9,
# docs/tasks/crystal-wake/workitem.md). Read with -z, the names arrive raw, and
# that has a trap of its own: an index entry that is not UTF-8 at all — APFS
# will not store such a file, a git index will — makes macOS `tr` stop and
# `sort` drop everything in a UTF-8 locale. So these run from one.
U8=en_US.UTF-8
roots_u8() {  # roots_u8 <dir> — resolve_crystal_roots from a UTF-8 locale, stderr kept
  ( cd "$1" && LC_ALL=$U8 bash -c ". '$CFG' 2>/dev/null; . '$LIB' 2>/dev/null; resolve_crystal_roots" 2>&1 )
}

CYR="$TMP/cyrproj"
rm -rf "$CYR"; mkdir -p "$CYR/docs/tasks/кристалл"
( cd "$CYR" && git init -q . 2>/dev/null )
printf -- '---\nstatus: in-progress\n---\n' >"$CYR/docs/tasks/кристалл/workitem.md"
( cd "$CYR" && git add -A 2>/dev/null )
roots=$(roots_u8 "$CYR")
expect_says "RED: a crystal whose only path under tasks/ is Cyrillic is found" "$roots" "/docs/tasks"
expect_not_says "…and no quoted root is invented" "$roots" '"'

BADIX="$TMP/badindex"
rm -rf "$BADIX"; mkdir -p "$BADIX/docs/tasks/alpha"
( cd "$BADIX" && git init -q . 2>/dev/null )
printf -- '---\nstatus: in-progress\n---\n' >"$BADIX/docs/tasks/alpha/workitem.md"
( cd "$BADIX" && git add -A 2>/dev/null
  blob=$(printf 'x\n' | git hash-object -w --stdin)
  git update-index --add --cacheinfo "100644,$blob,a$(printf '\377')/tasks/x/workitem.md" 2>/dev/null )
roots=$(roots_u8 "$BADIX")
expect_says "RED: an index entry that is not UTF-8 does not erase the other roots" "$roots" "/docs/tasks"
expect_not_says "…and no tool complains in their place" "$roots" "Illegal byte sequence"

# A root is a directory on disk. The scan reads the index, and an index can
# name a `tasks/` that is not there: one deleted and not yet staged, or one
# whose name no file system here will hold — the entry above. Handed on, that
# root sorted first, and every tool downstream met its bytes: the completion
# guard joined the roots with `tr` and lost the real `docs/tasks` behind it
# (Sidetrack #12, docs/tasks/crystal-wake/workitem.md).
expect_eq "RED: …and the tasks/ that no file system here can hold is not a root" \
  "1" "$(printf '%s\n' "$roots" | LC_ALL=C grep -c .)"

GONE="$TMP/gone"
rm -rf "$GONE"; mkdir -p "$GONE/docs/tasks/alpha"
( cd "$GONE" && git init -q . 2>/dev/null )
printf -- '---\nstatus: in-progress\n---\n' >"$GONE/docs/tasks/alpha/workitem.md"
( cd "$GONE" && git add -A 2>/dev/null
  blob=$(printf 'x\n' | git hash-object -w --stdin)
  git update-index --add --cacheinfo "100644,$blob,old/tasks/x/workitem.md" 2>/dev/null )
roots=$(roots_u8 "$GONE")
expect_says "a tasks/ that is only in the index leaves the real root in place" "$roots" "/docs/tasks"
expect_not_says "RED: …and is not a root itself — deleted, not yet staged" "$roots" "/old/tasks"

printf '\n=== the mirror ===\n'
# lib/ is mirrored across both plugins by invariant; a fix applied to one copy
# only would pass every test above and ship broken to vdm-git.
#
# Ask the gate, do not re-derive its rule: the two files differ legitimately in
# one line — the cross-reference header, where each names the OTHER copy — and a
# plain `diff -q` reports that as divergence. Restating the comparison here
# would be a second copy of the rule, which is the failure this suite keeps
# rediscovering.
if bash "$REPO_ROOT/scripts/check-lib-sync.sh" >/dev/null 2>&1; then
  ok "both plugin copies of crystal-path.sh are in sync"
else
  bad "both plugin copies of crystal-path.sh are in sync" "check-lib-sync.sh went red"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
