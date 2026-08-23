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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAVE="$REPO_ROOT/plugins/vdm/scripts/crystal-cave.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
says_not() {
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

printf '\ncrystal-cave: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
