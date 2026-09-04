#!/bin/bash
# crystal-migrate-scan.test.sh — synthetic-legacy tests for the migrate scanner
# and the shared date helper. Exercises the mechanical core the /vdm:crystal-migrate
# skill depends on: bucket-guess heuristics (DL #4), status-tier derivation, unchecked
# counting, and date derivation with both the git path and the non-git fallback
# (Sidetrack #3 / cs:p1-85f4 — projects without git must still work).
#
# Run: bash tests/crystal-migrate-scan.test.sh   (exit 0 = all pass)
set -u

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
echo ""
printf 'crystal-migrate-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
