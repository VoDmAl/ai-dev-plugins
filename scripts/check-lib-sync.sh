#!/bin/bash
# Verifies that plugins/vdm/lib/ and plugins/vdm-git/lib/ stay byte-identical
# modulo the MIRRORED-FILE cross-reference that names the opposite plugin.
# Used by .githooks/pre-commit and the lib-sync CI workflow.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

VDM_LIB="plugins/vdm/lib"
VDM_GIT_LIB="plugins/vdm-git/lib"

if [ ! -d "$VDM_LIB" ] || [ ! -d "$VDM_GIT_LIB" ]; then
  echo "lib-sync: one of the lib directories is missing — nothing to check"
  exit 0
fi

# Normalize the only legal differences: the cross-reference comments that name
# the *other* plugin. Everything else must match byte-for-byte.
normalize() {
  sed -E '
    s|plugins/vdm-git/lib|plugins/X/lib|g
    s|plugins/vdm/lib|plugins/X/lib|g
    s|the vdm-git copy|the X copy|g
    s|the vdm copy|the X copy|g
  '
}

drift=0

for f in "$VDM_LIB"/*; do
  base=$(basename "$f")
  counterpart="$VDM_GIT_LIB/$base"

  if [ ! -f "$counterpart" ]; then
    echo "lib-sync: MISSING — $counterpart has no counterpart for $f" >&2
    drift=1
    continue
  fi

  if ! diff <(normalize < "$f") <(normalize < "$counterpart") >/dev/null; then
    echo "lib-sync: DRIFT — $base differs between vdm/lib and vdm-git/lib" >&2
    diff -u <(normalize < "$f") <(normalize < "$counterpart") | head -40 >&2 || true
    drift=1
  fi
done

# Also catch files that exist only in vdm-git/lib.
for f in "$VDM_GIT_LIB"/*; do
  base=$(basename "$f")
  if [ ! -f "$VDM_LIB/$base" ]; then
    echo "lib-sync: ORPHAN — $f has no counterpart in $VDM_LIB" >&2
    drift=1
  fi
done

if [ "$drift" -eq 0 ]; then
  echo "lib-sync: ✓ plugins/vdm/lib/ and plugins/vdm-git/lib/ are in sync"
fi

exit "$drift"
