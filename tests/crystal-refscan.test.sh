#!/bin/bash
# crystal-refscan.test.sh — tests the inbound-reference scanner (crystal-migrate DL #11).
# Verifies style bucketing (frontmatter/wikilink/mdlink/plain) for `find` and prevalence
# reporting for `detect`.
#
# Run: bash tests/crystal-refscan.test.sh   (exit 0 = all pass)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFSCAN="$REPO_ROOT/plugins/vdm/scripts/crystal-refscan.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$2" "$3"; fi
}
contains() {
  # contains <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) PASS=$((PASS+1)); printf '  ✓ %s\n' "$1" ;;
    *)      FAIL=$((FAIL+1)); printf '  ✗ %s (missing: %s)\n' "$1" "$3" ;;
  esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t refscan)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/docs/tasks/a-thing" "$TMP/docs/tasks/b-thing" "$TMP/src"

# frontmatter graph key + a body wikilink — both reference old-slug
cat >"$TMP/docs/tasks/a-thing/workitem.md" <<'EOF'
---
reference-for: [[old-slug/workitem|old-slug]]
relates-to:
  - [[old-slug/workitem|old-slug]]
---
# A thing
See also [[old-slug/workitem|old-slug]] for context.
EOF

# markdown relative link → old-slug
cat >"$TMP/docs/tasks/b-thing/workitem.md" <<'EOF'
# B thing
Related doc: [the pipeline](../old-slug/workitem.md).
EOF

# vault-style bare wikilink → makes wikilink the dominant prose style
cat >"$TMP/note.md" <<'EOF'
Quick note linking [[old-slug]] from the vault root.
EOF

# plain code + prose references
cat >"$TMP/src/app.js" <<'EOF'
// depends on old-slug pipeline output
const x = 1;
EOF
cat >"$TMP/README.md" <<'EOF'
The old-slug component is described in prose here.
EOF

echo "== find old-slug =="
OUT=$(bash "$REFSCAN" find old-slug "$TMP" 2>/dev/null)
printf '%s\n' "$OUT" | sed 's/^/    /'

contains "reports frontmatter (Tier1 graph) bucket" "$OUT" "frontmatter (Tier1 graph"
contains "reports wikilink bucket"                  "$OUT" "wikilink"
contains "reports mdlink bucket"                    "$OUT" "mdlink"
contains "reports plain bucket"                     "$OUT" "plain"

# frontmatter bucket = scalar graph-KEY lines only (`reference-for:`). A YAML block-array
# item (`  - [[...]]` under `relates-to:`) is indistinguishable from a body markdown list by
# a line-based classifier, so it buckets as wikilink — but it is still FOUND, and the skill
# tiers it Tier-1 by LOCATION (file under a crystal root), not by bucket label.
fm_n=$(printf '%s\n' "$OUT" | sed -n 's/.*frontmatter (Tier1 graph, \([0-9]*\)).*/\1/p')
check "frontmatter hit count = 1 (scalar key line)" "1" "${fm_n:-0}"

# wikilink = body wikilink + note.md + the relates-to array item = 3 (array item not lost)
wl_n=$(printf '%s\n' "$OUT" | sed -n 's/.*wikilink *(\([0-9]*\)).*/\1/p')
check "wikilink hit count = 3 (incl relates-to array item)" "3" "${wl_n:-0}"

# plain bucket = app.js comment + README prose = 2
plain_n=$(printf '%s\n' "$OUT" | sed -n 's/.*plain *(\([0-9]*\)).*/\1/p')
check "plain hit count = 2" "2" "${plain_n:-0}"

echo "== find with no hits =="
OUT2=$(bash "$REFSCAN" find nonexistent-xyz "$TMP" 2>/dev/null)
contains "no-hit message" "$OUT2" "none"

echo "== detect =="
OUT3=$(bash "$REFSCAN" detect "$TMP" 2>/dev/null)
printf '%s\n' "$OUT3" | sed 's/^/    /'
contains "detect lists frontmatter-graph" "$OUT3" "frontmatter-graph :"
contains "detect lists wikilink"          "$OUT3" "wikilink"
contains "detect lists mdlink"            "$OUT3" "mdlink"
# wikilink files (a-thing, note) = 2  >  mdlink files (b-thing) = 1  → dominant wikilink
contains "detect dominant = wikilink"     "$OUT3" "dominant prose link style: wikilink"

echo ""
printf 'crystal-refscan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
