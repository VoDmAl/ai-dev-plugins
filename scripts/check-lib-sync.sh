#!/bin/bash
# Verifies that the lib/ copies shipped by every plugin stay byte-identical
# modulo the MIRRORED-FILE cross-reference that names a sibling plugin.
# Used by .githooks/pre-commit and the lib-sync CI workflow.
#
# Scope is per FILE, not per plugin: for every basename that appears in any
# plugins/*/lib/, all copies of it must agree. A plugin may carry a subset —
# `vdm` needs `crystal-path.sh`, a plugin that has nothing to do with crystals
# does not — and forcing it to vendor files it never sources would be mirroring
# for its own sake. What must not happen is two copies of the SAME file drifting
# apart, which is the defect this gate exists to catch.
#
# Generalised from a hardcoded vdm ↔ vdm-git pair on 2026-09-21, before the
# third plugin landed: the pair form would have accepted a third plugin's lib/
# silently, which is the "gate that narrowed itself without anyone noticing"
# shape described in docs/llm/soft-guidance-vs-deterministic-gates.md.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# Normalize the only legal differences: cross-reference comments that name a
# sibling plugin by path or by prose. Any plugin name is accepted here on
# purpose — the comment's job is to say "there are other copies", and which
# sibling it happens to name carries no information the gate should enforce.
normalize() {
  sed -E '
    s|plugins/[A-Za-z0-9_-]+/lib|plugins/X/lib|g
    s|the [A-Za-z0-9_-]+ copy|the X copy|g
  '
}

# Collect every lib file across all plugins, keyed by basename.
libs=()
while IFS= read -r f; do
  [ -n "$f" ] && libs+=("$f")
done < <(find plugins -mindepth 3 -maxdepth 3 -type f -path 'plugins/*/lib/*' 2>/dev/null | sort)

if [ ${#libs[@]} -eq 0 ]; then
  echo "lib-sync: no plugins/*/lib/ files found — nothing to check"
  exit 0
fi

# Unique basenames.
names=()
while IFS= read -r n; do
  [ -n "$n" ] && names+=("$n")
done < <(for f in "${libs[@]}"; do basename "$f"; done | sort -u)

drift=0
checked=0
solo=()

for name in "${names[@]}"; do
  copies=()
  for f in "${libs[@]}"; do
    [ "$(basename "$f")" = "$name" ] && copies+=("$f")
  done

  # A file that exists in exactly one plugin is not a mirror — it is that
  # plugin's own helper, and nothing can have drifted from it. Reported below
  # as a note rather than a failure: "added to one plugin, forgotten in the
  # other" and "deliberately local to this plugin" are indistinguishable from
  # here, and a gate that cannot tell them apart must not pick for you.
  if [ ${#copies[@]} -lt 2 ]; then
    solo+=("${copies[0]}")
    continue
  fi

  reference="${copies[0]}"
  for counterpart in "${copies[@]:1}"; do
    checked=$((checked + 1))
    if ! diff <(normalize < "$reference") <(normalize < "$counterpart") >/dev/null; then
      echo "lib-sync: DRIFT — $name differs between $(dirname "$reference") and $(dirname "$counterpart")" >&2
      diff -u <(normalize < "$reference") <(normalize < "$counterpart") | head -40 >&2 || true
      drift=1
    fi
  done
done

if [ ${#solo[@]} -gt 0 ]; then
  echo "lib-sync: note — single-copy lib file(s), not mirrored anywhere:"
  for f in "${solo[@]}"; do echo "            $f"; done
fi

if [ "$drift" -eq 0 ]; then
  if [ "$checked" -eq 0 ]; then
    echo "lib-sync: ✓ no mirrored lib file has a second copy — nothing to compare"
  else
    echo "lib-sync: ✓ $checked mirrored lib file pair(s) across plugins/*/lib/ are in sync"
  fi
fi

exit "$drift"
