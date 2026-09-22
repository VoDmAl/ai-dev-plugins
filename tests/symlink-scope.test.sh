#!/bin/bash
# symlink-scope.test.sh — CONFORMANCE TEST: both engines must agree on which
# files are inside a crystal root when the project is reached through a symlink.
#
# The defect this pins down (measured 2026-09-21): crystal roots are resolved
# through `git rev-parse --show-toplevel`, which returns the REAL path, while
# the path in a hook payload is whatever the harness was handed. On macOS a
# project under /tmp or /var arrives as /var/… against a root of /private/var/…,
# the prefix comparison fails, and the file is judged outside every root. The
# gate then exits 0 on a genuine violation — silent, and indistinguishable from
# a clean tree. `abspath` (python) and string prefixes (bash) both normalise
# relativeness and neither resolves symlinks, so both engines had it.
#
# Two implementations answer the same question from different inputs — one from
# a tool-input string, one from a path on disk — so they are forced copies, and
# forced copies are kept honest by conformance rather than consolidation: ONE
# fixture, EVERY engine, the test fails when they disagree.
#
# Both directions are asserted: in-scope through the symlink must be caught, and
# genuinely-outside must still be ignored — a fix that makes everything in scope
# would pass the first half and destroy the gate.
#
# Run: bash tests/symlink-scope.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/crystal-completion-guard.py — _is_workitem_path
# @see plugins/vdm/scripts/crystal-lint.sh — is_workitem_path / canonicalize_path

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Overridable so the suite can be pointed at a PRE-FIX copy of the plugin and
# watched to fail. A test that has only ever been run against the fixed code
# proves that the code passes it, not that it would have caught the defect.
PLUGIN_DIR="${SYMLINK_SCOPE_PLUGIN_DIR:-$REPO_ROOT/plugins/vdm}"
GUARD="$PLUGIN_DIR/scripts/crystal-completion-guard.sh"
LINT="$PLUGIN_DIR/scripts/crystal-lint.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t symscope)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

REAL=$(cd "$TMP" && pwd -P)          # the real path, whatever mktemp handed back
LINK="$TMP/link"                      # a symlink pointing at the project
mkdir -p "$REAL/proj/docs/tasks/specimen" "$REAL/proj/src"
ln -s "$REAL/proj" "$LINK"
( cd "$REAL/proj" && git init -q . ) >/dev/null 2>&1

WI_REAL="$REAL/proj/docs/tasks/specimen/workitem.md"
WI_LINK="$LINK/docs/tasks/specimen/workitem.md"

# Canonical body, one open obligation, terminal status — a real violation.
cat > "$WI_REAL" <<'EOF'
---
title: "specimen"
slug: specimen
status: done
session-type: other
created: 2026-09-21
last-updated: 2026-09-21
---

# specimen

## Назначение

x

## Текущая модель

- x

## Sidetracks

## Next actions

- [ ] an open obligation

## References

- none
EOF

# A file that is genuinely not a workitem, reached through the same symlink.
printf 'print("hi")\n' > "$REAL/proj/src/app.py"

payload() { # payload <path> <content-file>
  python3 - "$1" "$2" "$REAL/proj" <<'PY'
import json, sys
path, content_file, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(content_file, encoding="utf-8").read() if content_file != "-" else "x"
print(json.dumps({"tool_name": "Write",
                  "tool_input": {"file_path": path, "content": content},
                  "cwd": cwd}))
PY
}

echo "== the path arrives through a symlink — both engines must still see it =="

OUT=$(cd "$REAL/proj" && payload "$WI_LINK" "$WI_REAL" | bash "$GUARD" 2>&1); rc=$?
expect_exit "completion-guard: terminal status + open item ⇒ exit 2" 2 "$rc"

# The linter needs the file to be non-canonical to speak; strip a section from
# a copy so the check is about SCOPE, not about this particular file's shape.
NONCANON="$REAL/proj/docs/tasks/specimen/workitem.md"
python3 - "$NONCANON" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read().replace("## Текущая модель\n\n- x\n\n", "")
s = s.replace("status: done", "status: in-progress")
open(p, "w", encoding="utf-8").write(s)
PY
OUT=$(cd "$REAL/proj" && payload "$WI_LINK" "$NONCANON" | bash "$LINT" --hook 2>&1); rc=$?
expect_exit "crystal-lint: off-canon workitem ⇒ exit 2" 2 "$rc"

echo ""
echo "== the same path, given in its real form — unchanged behaviour =="

OUT=$(cd "$REAL/proj" && payload "$WI_REAL" "$NONCANON" | bash "$LINT" --hook 2>&1); rc=$?
expect_exit "crystal-lint: real path still in scope ⇒ exit 2" 2 "$rc"

echo ""
echo "== scope is not blindness: out-of-scope stays out, symlink or not =="

OUT=$(cd "$REAL/proj" && payload "$LINK/src/app.py" "-" | bash "$LINT" --hook 2>&1); rc=$?
expect_exit "crystal-lint: source file through the symlink ⇒ exit 0" 0 "$rc"

OUT=$(cd "$REAL/proj" && payload "$LINK/src/app.py" "-" | bash "$GUARD" 2>&1); rc=$?
expect_exit "completion-guard: source file through the symlink ⇒ exit 0" 0 "$rc"

OUTSIDE="$TMP/outside.md"
printf -- '---\nstatus: done\n---\n\n- [ ] x\n' > "$OUTSIDE"
OUT=$(cd "$REAL/proj" && payload "$OUTSIDE" "$OUTSIDE" | bash "$GUARD" 2>&1); rc=$?
expect_exit "completion-guard: a file outside the project ⇒ exit 0" 0 "$rc"

printf '\nsymlink-scope: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
