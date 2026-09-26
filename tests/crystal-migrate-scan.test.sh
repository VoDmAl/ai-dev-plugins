#!/bin/bash
# crystal-migrate-scan.test.sh — synthetic-legacy tests for the migrate scanner
# and the shared date helper. Exercises the mechanical core the /vdm:crystal-migrate
# skill depends on: bucket-guess heuristics (DL #4), status-tier derivation, unchecked
# counting, and date derivation with both the git path and the non-git fallback
# (Sidetrack #3 / cs:p1-85f4 — projects without git must still work).
#
# Run: bash tests/crystal-migrate-scan.test.sh   (exit 0 = all pass)
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
SCAN="$REPO_ROOT/plugins/vdm/scripts/crystal-migrate-scan.sh"
DATES="$REPO_ROOT/plugins/vdm/scripts/crystal-dates.sh"

PASS=0
FAIL=0
check() {
  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
check_nonempty() {
  # check_nonempty <description> <actual>
  if [ -n "$2" ]; then
    PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  ✗ %s (was empty)\n' "$1"
  fi
}

# col <tsv> <basename-fragment> <column-number>
col() {
  grep "/$2	" "$1" 2>/dev/null | head -n1 | cut -f"$3"
}
# col_by_end <tsv> <path-suffix> <column> — match a full path ending
row_for() {
  grep "$2	" "$1" 2>/dev/null | head -n1
}

TMP_GIT=$(mktemp -d 2>/dev/null || mktemp -d -t cmscan)
TMP_NOGIT=$(mktemp -d 2>/dev/null || mktemp -d -t cmscanng)
cleanup() { rm -rf "$TMP_GIT" "$TMP_NOGIT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture: a git-backed legacy tree
# ---------------------------------------------------------------------------
mkdir -p "$TMP_GIT/docs/tasks"
LG="$TMP_GIT/docs/tasks"

cat >"$LG/PRD.md" <<'EOF'
# Product Requirements

Some spec prose describing the feature. No frontmatter, no checkboxes.

## Goals
## Non-goals
EOF

cat >"$LG/prompt-summarizer.md" <<'EOF'
You are a helpful summarizer. Reusable prompt artifact, not task work.
EOF

cat >"$LG/auth-refactor.md" <<'EOF'
---
title: "Auth refactor"
status: in-progress
---
# Auth refactor

## Next actions
- [ ] swap JWT lib
- [ ] migrate sessions
EOF

cat >"$LG/idea-dark-mode.md" <<'EOF'
---
title: "Dark mode"
status: idea
---
# Dark mode — someday
EOF

cat >"$LG/scratch.md" <<'EOF'
just a line of text with no structure at all
EOF

cat >"$LG/frozen-thing.md" <<'EOF'
---
status: frozen
---
# Frozen
## Detail
Structured prose under a non-canonical status.
EOF

( cd "$TMP_GIT" && git init -q && git add -A && \
  git -c user.email=t@t -c user.name=t commit -qm init ) 2>/dev/null

OUT="$TMP_GIT/scan.tsv"
bash "$SCAN" "$LG" >"$OUT" 2>/dev/null

echo "== git-backed scan =="

check "PRD.md → name_hint spec"        "spec"        "$(col "$OUT" 'PRD.md' 9)"
check "PRD.md → bucket reference"      "reference"   "$(col "$OUT" 'PRD.md' 10)"
check "prompt-* → name_hint asset"     "asset"       "$(col "$OUT" 'prompt-summarizer.md' 9)"
check "prompt-* → bucket out-of-scope" "out-of-scope" "$(col "$OUT" 'prompt-summarizer.md' 10)"
check "auth-refactor → tier active"    "active"      "$(col "$OUT" 'auth-refactor.md' 6)"
check "auth-refactor → 2 unchecked"    "2"           "$(col "$OUT" 'auth-refactor.md' 7)"
check "auth-refactor → bucket workitem" "workitem"   "$(col "$OUT" 'auth-refactor.md' 10)"
check "idea-* → tier pre-work"         "pre-work"    "$(col "$OUT" 'idea-dark-mode.md' 6)"
check "idea-* → bucket workitem"       "workitem"    "$(col "$OUT" 'idea-dark-mode.md' 10)"
check "scratch → bucket ambiguous"     "ambiguous"   "$(col "$OUT" 'scratch.md' 10)"
# Non-canonical status is surfaced by the tier column (drift signal for DL #5),
# but a frontmatter'd file is still guessed as a tracked work-unit.
check "frozen → tier non-canonical"    "non-canonical" "$(col "$OUT" 'frozen-thing.md' 6)"
check "frozen → bucket workitem"       "workitem"    "$(col "$OUT" 'frozen-thing.md' 10)"

# Dates present via git (author date = commit time).
check_nonempty "auth-refactor → created (git)" "$(col "$OUT" 'auth-refactor.md' 2)"
check_nonempty "auth-refactor → updated (git)" "$(col "$OUT" 'auth-refactor.md' 3)"

# Header present, hidden dirs pruned (none here, but assert no crash + rows).
ROWS=$(grep -vc '^#' "$OUT")
check "6 files scanned"                "6"           "$ROWS"

# ---------------------------------------------------------------------------
# Fixture: a NON-git legacy tree (Sidetrack #3 fallback)
# ---------------------------------------------------------------------------
echo "== non-git fallback =="
mkdir -p "$TMP_NOGIT/tasks"
cat >"$TMP_NOGIT/tasks/loose-note.md" <<'EOF'
---
status: draft
---
# Loose note
- [ ] one thing
EOF

OUT2="$TMP_NOGIT/scan.tsv"
bash "$SCAN" "$TMP_NOGIT/tasks" >"$OUT2" 2>/dev/null

check "non-git → tier pre-work"        "pre-work"    "$(col "$OUT2" 'loose-note.md' 6)"
check "non-git → 1 unchecked"          "1"           "$(col "$OUT2" 'loose-note.md' 7)"
check_nonempty "non-git → created (fs birthtime)" "$(col "$OUT2" 'loose-note.md' 2)"
check_nonempty "non-git → updated (fs mtime)"     "$(col "$OUT2" 'loose-note.md' 3)"

# Direct date-helper CLI on the non-git file.
D=$(bash "$DATES" "$TMP_NOGIT/tasks/loose-note.md")
check_nonempty "crystal-dates.sh CLI emits a date pair" "$D"

# ---------------------------------------------------------------------------
# Multiple targets in one scan (monorepo-like / mixed roots)
# ---------------------------------------------------------------------------
echo "== multi-target scan =="
OUT3="$TMP_GIT/scan-multi.tsv"
bash "$SCAN" "$LG" "$TMP_NOGIT/tasks" >"$OUT3" 2>/dev/null
check_nonempty "multi-target includes git-tree file"  "$(col "$OUT3" 'auth-refactor.md' 1)"
check_nonempty "multi-target includes non-git file"   "$(col "$OUT3" 'loose-note.md' 1)"
check "multi-target scans both roots (6+1 rows)"      "7" "$(grep -vc '^#' "$OUT3")"

# ---------------------------------------------------------------------------
# Dates in a batch: the answers derive_dates gives, file by file
# ---------------------------------------------------------------------------
# The scan asked for dates per file — a work-tree probe, two logs, a tail, a
# dirname, a basename — and read every other signal with a process or more of
# its own: about seventeen launches a file (Sidetrack #15,
# docs/tasks/crystal-wake/workitem.md). derive_dates_batch answers a whole
# directory with one log where that is exact, and must answer exactly what
# derive_dates answers wherever it does not.
echo "== dates: the batch answers what derive_dates answers =="
TMP_D=$(mktemp -d 2>/dev/null || mktemp -d -t cmdates)
trap 'rm -rf "$TMP_GIT" "$TMP_NOGIT" "$TMP_D"' EXIT
# commit_at <repo> <date> <message> — a commit authored and committed on <date>.
commit_at() {
  ( cd "$1" && git add -A && GIT_AUTHOR_DATE="$2T12:00:00" GIT_COMMITTER_DATE="$2T12:00:00" \
      git -c user.email=t@t -c user.name=t commit -qm "$3" ) >/dev/null 2>&1
}
# same_answers <label> <dir> — derive_dates_batch over every .md under <dir>
# against derive_dates on each of them; prints nothing, records the check.
same_answers() {
  local batch single
  batch=$(cd "$REPO_ROOT" && bash -c '. "$1"; find "$2" -name "*.md" -not -path "*/.git/*" | sort | derive_dates_batch "$2"' _ "$DATES" "$2" 2>&1)
  single=$(cd "$REPO_ROOT" && bash -c '. "$1"; find "$2" -name "*.md" -not -path "*/.git/*" | sort | while IFS= read -r f; do printf "%s\t%s\n" "$f" "$(derive_dates "$f")"; done' _ "$DATES" "$2" 2>&1)
  check "$1" "$single" "$batch"
}

# Linear history: the batch path. Created and updated differ; one file moves
# within the directory, which a directory-wide log with renames on would read
# as a rename and a one-file log reads as an add. Two names test the reading of
# the log itself: one the line form would print quoted, and `@root.md`, whose
# token starts with `@` — at the repository root a path is not prefixed by a
# directory, and a reader that sorts tokens by spelling instead of by position
# takes it for a commit header and dates the next file by it.
LIN="$TMP_D/linear"; mkdir -p "$LIN/tasks/one" "$LIN/tasks/two"
( cd "$LIN" && git init -q . )
printf 'a\n' > "$LIN/tasks/one/workitem.md"; printf 'b\n' > "$LIN/tasks/two/workitem.md"
printf 'c\n' > "$LIN/tasks/old-name.md"; printf 'r\n' > "$LIN/@root.md"
printf 'q\n' > "$LIN/tasks/заметка \"q\".md"
commit_at "$LIN" 2026-01-01 first
printf 'a2\n' >> "$LIN/tasks/one/workitem.md"; printf 'r2\n' >> "$LIN/@root.md"
commit_at "$LIN" 2026-02-02 second
( cd "$LIN" && git mv tasks/old-name.md tasks/new-name.md ) >/dev/null 2>&1
commit_at "$LIN" 2026-03-03 third
check "linear: created is the first add"      "2026-01-01" "$(cd "$REPO_ROOT" && bash -c '. "$1"; printf "%s\n" "$2/tasks/one/workitem.md" | derive_dates_batch "$2"' _ "$DATES" "$LIN" | cut -f2)"
check "linear: updated is the last touch"     "2026-02-02" "$(cd "$REPO_ROOT" && bash -c '. "$1"; printf "%s\n" "$2/tasks/one/workitem.md" | derive_dates_batch "$2"' _ "$DATES" "$LIN" | cut -f3)"
check "linear: a moved file was added by the move" "2026-03-03" "$(cd "$REPO_ROOT" && bash -c '. "$1"; printf "%s\n" "$2/tasks/new-name.md" | derive_dates_batch "$2"' _ "$DATES" "$LIN" | cut -f2)"
same_answers "linear: every file, batch = per file" "$LIN"

# A merge in the history: the batch steps aside and derive_dates answers. The
# merge itself changes a file — the shape that moved dates on this machine
# (DL #9): the file's own log names the merge as its last change, and a merge
# prints no status line, so a directory-wide log has nothing to date it by. A
# merge that changes nothing proves nothing here: the batch would agree with or
# without the guard, and this fixture used to be exactly that.
MRG="$TMP_D/merged"; mkdir -p "$MRG/tasks/x"
( cd "$MRG" && git init -q . && git checkout -qb main ) >/dev/null 2>&1
printf 'x\n' > "$MRG/tasks/x/workitem.md"; commit_at "$MRG" 2026-01-01 base
( cd "$MRG" && git checkout -qb side ) >/dev/null 2>&1
printf 'side\n' > "$MRG/tasks/side.md"; commit_at "$MRG" 2026-02-02 side
( cd "$MRG" && git checkout -q main ) >/dev/null 2>&1
printf 'y\n' >> "$MRG/tasks/x/workitem.md"; commit_at "$MRG" 2026-03-03 main
( cd "$MRG" && git -c user.email=t@t -c user.name=t merge -q --no-ff --no-commit side ) >/dev/null 2>&1
printf 'edited in the merge\n' >> "$MRG/tasks/side.md"; commit_at "$MRG" 2026-04-04 merge
check_nonempty "canary: the merge fixture has a merge" "$(git -C "$MRG" rev-list --merges HEAD 2>/dev/null)"
check "canary: the merge changed tasks/side.md against both parents" "2" \
  "$(for p in 1 2; do git -C "$MRG" diff --name-only "HEAD^$p" HEAD 2>/dev/null; done | grep -cx 'tasks/side.md')"
check "merge in history: a merge that changed the file is its last change" "2026-04-04" \
  "$(cd "$REPO_ROOT" && bash -c '. "$1"; printf "%s\n" "$2/tasks/side.md" | derive_dates_batch "$2"' _ "$DATES" "$MRG" | cut -f3)"
same_answers "merge in history: batch = per file" "$MRG"

# A nested repository and an untracked file: each answered from its own truth.
# The outer repository once tracked the inner file itself, so its log names the
# same path with other dates — the collision the nested-repository exclusion is
# for. Without it this fixture agreed either way, like the merge one above.
NST="$TMP_D/nested"; mkdir -p "$NST/tasks/inner/tasks"
( cd "$NST" && git init -q . )
printf 'o\n' > "$NST/tasks/outer.md"; printf 'i\n' > "$NST/tasks/inner/tasks/in.md"
commit_at "$NST" 2026-01-01 outer
( cd "$NST/tasks/inner" && git init -q . )
printf 'i2\n' >> "$NST/tasks/inner/tasks/in.md"; commit_at "$NST/tasks/inner" 2026-05-05 inner
check "canary: the outer repository's log names the inner file" "tasks/inner/tasks/in.md" \
  "$(git -C "$NST" log --format= --name-only 2>/dev/null | grep -x 'tasks/inner/tasks/in.md')"
printf 'u\n' > "$NST/tasks/untracked.md"
check "nested: a file in the inner repository has its dates" "2026-05-05" "$(cd "$REPO_ROOT" && bash -c '. "$1"; printf "%s\n" "$2/tasks/inner/tasks/in.md" | derive_dates_batch "$2/tasks"' _ "$DATES" "$NST" | cut -f2)"
same_answers "nested and untracked: batch = per file" "$NST"

# Cost: the whole scan, counted in launches — twenty files cost what two do.
SHIMS="$TMP_D/shims"; mkdir -p "$SHIMS"
for tool in awk sed grep sort find git date head tail tr cat cut wc dirname basename stat mkdir uniq; do
  real=$(type -P "$tool" 2>/dev/null) || continue
  cat > "$SHIMS/$tool" <<EOF
#!/bin/bash
printf x >> "\$LAUNCH_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$SHIMS/$tool"
done
# cost_tree <dir> <n> — a committed tree of n workitems with a heading, a
# checkbox and a status each, so that every signal has something to read.
cost_tree() {
  local i=1
  mkdir -p "$1/tasks"
  ( cd "$1" && git init -q . )
  while [ "$i" -le "$2" ]; do
    mkdir -p "$1/tasks/w$i"
    printf -- '---\nstatus: ready\n---\n# W%s\n- [ ] x\n' "$i" > "$1/tasks/w$i/workitem.md"
    i=$((i + 1))
  done
  commit_at "$1" 2026-06-06 base
}
scan_launches() {  # scan_launches <dir> — launches of one scan; output kept in $TMP_D/scan.out
  : > "$TMP_D/launch.log"
  ( cd "$1" && LAUNCH_LOG="$TMP_D/launch.log" PATH="$SHIMS:$PATH" bash "$SCAN" "$1/tasks" > "$TMP_D/scan.out" 2>/dev/null )
  wc -c < "$TMP_D/launch.log" | tr -d ' '
}
cost_tree "$TMP_D/c2" 2
cost_tree "$TMP_D/c20" 20
c2=$(scan_launches "$TMP_D/c2")
c20=$(scan_launches "$TMP_D/c20")
if [ "${c2:-0}" -gt 0 ]; then PASS=$((PASS + 1)); printf '  ✓ canary: the counter sees the scan (%s launches for two files)\n' "$c2"
else FAIL=$((FAIL + 1)); printf '  ✗ canary: the counter sees the scan (no launch counted)\n'; fi
check "canary: the counted scan read all twenty, dated by git" "20 2026-06-06" \
  "$(grep -vc '^#' "$TMP_D/scan.out") $(grep -v '^#' "$TMP_D/scan.out" | cut -f3 | sort -u)"
check "RED: twenty files cost what two do" "$c2" "$c20"

# ---------------------------------------------------------------------------
echo ""
printf 'crystal-migrate-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
