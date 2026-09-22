#!/bin/bash
# hook-fail-closed.test.sh — RED TESTS for the blocking hooks' behaviour when
# their checker cannot run.
#
# A gate that cannot run returns "nothing wrong", which is indistinguishable
# from a clean tree — so it looks healthy forever while enforcing nothing.
# Measured 2026-09-21 on this suite: with `python3` absent,
# crystal-completion-guard exited 127, crystal-lint and orphan-guard exited 0,
# git-guard exited 127. The harness blocks only on 2, so all four were off.
#
# The law under test (docs/model/suite.md, lib/gate-guard.sh):
#
#   "the check failed" and "the check did not run" are different events,
#   and for a gate the second one blocks too.
#
# Both directions are exercised, and the second matters as much as the first:
#
#   RED   — degraded environment, in-scope payload  ⇒ exit 2, message says
#           NOT CHECKED (a gate that fails without saying why is hostile).
#   GREEN — degraded environment, OUT-of-scope payload ⇒ exit 0. Without this
#           the fix turns into "block everything on a machine without python3",
#           which gets the plugin uninstalled — the same as not existing.
#
# Environments are built as symlink farms so the hooks genuinely cannot see the
# missing tool: PATH holds coreutils and nothing else.
#
#   full      python3 + jq
#   nopy      no python3 (jq present)
#   nojq      no jq (python3 present)
#   crashpy   python3 present but exits 1 with a traceback — the case the first
#             version of this fix missed, because it tested for the tool's
#             PRESENCE rather than for whether the answer meant anything
#
# Run: bash tests/hook-fail-closed.test.sh   (exit 0 = all pass)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_exit() {
  # expect_exit <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi
}
expect_says() {
  # expect_says <desc> <output> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "output did not mention: $3" ;;
  esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t failclosed)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- tool farms --------------------------------------------------------------
TOOLS="bash sh grep sed awk cat tr mktemp date git printf head tail sort uniq
       wc find dirname basename cut env mv rm mkdir readlink stat diff cp touch
       ls tee xargs cmp true false test expr [ realpath id uname"

for d in full nopy nojq crashpy; do mkdir -p "$TMP/bin-$d"; done
for t in $TOOLS; do
  p=$(command -v "$t" 2>/dev/null) || continue
  for d in full nopy nojq crashpy; do ln -sf "$p" "$TMP/bin-$d/$t"; done
done

JQ=$(command -v jq 2>/dev/null || true)
PY=$(command -v python3 2>/dev/null || true)
if [ -z "$PY" ]; then
  echo "hook-fail-closed: python3 not available — cannot build the baseline environment" >&2
  exit 1
fi
if [ -z "$JQ" ]; then
  echo "hook-fail-closed: jq not available — skipping (the nojq/fallback cases need it present elsewhere)" >&2
  exit 0
fi
for d in full nopy crashpy; do ln -sf "$JQ" "$TMP/bin-$d/jq"; done
for d in full nojq;          do ln -sf "$PY" "$TMP/bin-$d/python3"; done
printf '#!/bin/bash\necho "Traceback (most recent call last):" >&2\necho "  ModuleNotFoundError: simulated crash" >&2\nexit 1\n' \
  > "$TMP/bin-crashpy/python3"
chmod +x "$TMP/bin-crashpy/python3"

# --- fixture project ---------------------------------------------------------
# Canonicalised with `pwd -P`, and that is load-bearing rather than tidy: on
# macOS `mktemp -d` hands back a path under /var, which is a symlink to
# /private/var. Crystal roots are resolved through `git rev-parse
# --show-toplevel`, which returns the real path, while a payload built from the
# mktemp path does not — and the gate then finds the file outside every root
# and stays silent for a reason that has nothing to do with what is under test.
# Left uncanonicalised, this fixture reports a passing gate as failing and,
# worse, could report a broken one as passing.
mkdir -p "$TMP/fx/docs/tasks/specimen" "$TMP/fx/docs/llm" "$TMP/fx/src"
FX=$(cd "$TMP/fx" && pwd -P)
( cd "$FX" && git init -q . ) >/dev/null 2>&1

WI="$FX/docs/tasks/specimen/workitem.md"
cat > "$WI" <<'EOF'
---
title: "specimen"
slug: specimen
status: in-progress
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

printf '# orphan\n\nnothing links here\n' > "$FX/docs/llm/orphan.md"
printf 'print("hi")\n' > "$FX/src/app.py"

# --- payloads ----------------------------------------------------------------
# Built with python3 from THIS shell (the farms' python3 is what is under test).
"$PY" - "$TMP" "$FX" "$WI" <<'PY'
import json, os, sys
tmp, fx, wi = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(wi, encoding="utf-8").read()

def put(name, obj):
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False)

def write(path, content):
    return {"tool_name": "Write", "tool_input": {"file_path": path, "content": content}, "cwd": fx}

# in scope: workitem going terminal with an open checkbox
put("p-done.json", write(wi, src.replace("status: in-progress", "status: done")))
# out of scope for the completion gate: same workitem, no terminal status
put("p-inprogress.json", write(wi, src))
# in scope for the canon linter: a workitem write (file on disk is canonical
# here; the degraded runs never get far enough to lint it)
put("p-workitem.json", write(wi, src))
# out of scope for both crystal hooks: a source file
put("p-src.json", write(os.path.join(fx, "src/app.py"), "print('hi')\n"))
# in scope for orphan-guard
put("p-llm.json", write(os.path.join(fx, "docs/llm/orphan.md"), "# orphan\n"))
# out of scope for orphan-guard: ordinary markdown, no docs/llm, no covers:
put("p-readme.json", write(os.path.join(fx, "README.md"), "# readme\n"))
# in scope for git-guard
put("p-commit.json", {"tool_name": "Bash", "tool_input": {"command": "git " + "commit -m x"}, "cwd": fx})
# out of scope for git-guard
put("p-ls.json", {"tool_name": "Bash", "tool_input": {"command": "ls -la"}, "cwd": fx})
PY

GUARD="$REPO_ROOT/plugins/vdm/scripts/crystal-completion-guard.sh"
LINT="$REPO_ROOT/plugins/vdm/scripts/crystal-lint.sh"
ORPHAN="$REPO_ROOT/plugins/vdm/scripts/orphan-guard-hook.sh"
GITGUARD="$REPO_ROOT/plugins/vdm-git/scripts/git-guard-hook.sh"

OUT=""
run() {
  # run <env> <payload-file> <command...>
  local e="$1" pl="$2"; shift 2
  OUT=$(cd "$FX" && env -i HOME="$HOME" LC_ALL=C PATH="$TMP/bin-$e" \
        CLAUDE_PROJECT_DIR="$FX" bash -c "$*" < "$TMP/$pl" 2>&1)
  return $?
}

echo "== baseline: every hook reaches a verdict with python3 + jq present =="
run full p-done.json "bash '$GUARD'"; expect_exit "completion-guard blocks a real violation" 2 "$?"
expect_says "  and names the crystal gate" "$OUT" "crystal-cut"
run full p-inprogress.json "bash '$GUARD'"; expect_exit "completion-guard silent on a non-terminal write" 0 "$?"
run full p-llm.json "bash '$ORPHAN'"; expect_exit "orphan-guard blocks a real orphan" 2 "$?"
run full p-commit.json "bash '$GITGUARD'"; expect_exit "git-guard blocks a commit" 2 "$?"
run full p-ls.json "bash '$GITGUARD'"; expect_exit "git-guard allows an ordinary command" 0 "$?"

for e in nopy crashpy; do
  echo ""
  echo "== RED: checker cannot run (env: $e) — in-scope calls must block =="

  run "$e" p-done.json "bash '$GUARD'"
  expect_exit "completion-guard: terminal write ⇒ exit 2" 2 "$?"
  expect_says "completion-guard: says NOT CHECKED" "$OUT" "NOT CHECKED"
  expect_says "completion-guard: names itself" "$OUT" "crystal-completion-guard"

  run "$e" p-workitem.json "bash '$LINT' --hook"
  expect_exit "crystal-lint: workitem write ⇒ exit 2" 2 "$?"
  expect_says "crystal-lint: says NOT CHECKED" "$OUT" "NOT CHECKED"

  run "$e" p-llm.json "bash '$ORPHAN'"
  expect_exit "orphan-guard: docs/llm write ⇒ exit 2 (blocked either way)" 2 "$?"

  run "$e" p-commit.json "bash '$GITGUARD'"
  expect_exit "git-guard: commit-shaped command ⇒ exit 2" 2 "$?"
  expect_says "git-guard: says NOT CHECKED" "$OUT" "NOT CHECKED"

  echo ""
  echo "== GREEN: same broken env, OUT-of-scope calls must stay silent (env: $e) =="

  run "$e" p-src.json "bash '$GUARD'"
  expect_exit "completion-guard: source-file write ⇒ exit 0" 0 "$?"

  run "$e" p-inprogress.json "bash '$GUARD'"
  expect_exit "completion-guard: no terminal status ⇒ exit 0" 0 "$?"

  run "$e" p-src.json "bash '$LINT' --hook"
  expect_exit "crystal-lint: source-file write ⇒ exit 0" 0 "$?"

  run "$e" p-readme.json "bash '$ORPHAN'"
  expect_exit "orphan-guard: ordinary markdown ⇒ exit 0" 0 "$?"

  run "$e" p-ls.json "bash '$GITGUARD'"
  expect_exit "git-guard: ordinary command ⇒ exit 0" 0 "$?"
done

echo ""
echo "== jq absent must change nothing: python3 answers for every hook =="
run nojq p-done.json "bash '$GUARD'"; expect_exit "completion-guard still blocks without jq" 2 "$?"
expect_says "  and it is the real verdict, not NOT CHECKED" "$OUT" "crystal-cut"
run nojq p-llm.json "bash '$ORPHAN'"; expect_exit "orphan-guard still blocks without jq" 2 "$?"
run nojq p-src.json "bash '$GUARD'"; expect_exit "completion-guard still silent without jq" 0 "$?"

printf '\nhook-fail-closed: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
