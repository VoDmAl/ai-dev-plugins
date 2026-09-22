#!/bin/bash
# crystal-completion-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Implements the primary gate from docs/tasks/crystal-design Decision Log #4
# and #7 (done-transition completion discipline) plus the superseded-by
# requirement from crystal-multi-root DL #10.
#
# Hook protocol (Claude Code):
#   stdin   JSON {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
#   exit 0  no-op (transition is safe, or this edit doesn't touch a workitem)
#   exit 2  stderr surfaces as feedback to the assistant — used to block the
#           done-transition with the five-path diagnostic from Decision Log #9
#
# Fail-open for everything it CAN evaluate: parse errors, missing config,
# exotic edits — all exit 0. Better to miss one edit than to block on a hook bug.
#
# Fail-CLOSED for the one case that is not an evaluation at all: when the
# checker could not run, the gate blocks instead of returning silence. "The
# check failed" and "the check did not run" are different events, and only the
# first one is what `exit 0` means. Measured 2026-09-21: without `python3` this
# hook exited 127, which the harness treats as non-blocking — the gate was off
# and looked healthy. See lib/gate-guard.sh for the shape and the field report.
#
# The wrapper resolves all crystal roots and the active status-alias sets
# (canonical "done"/"superseded" plus any aliases that map to them), passing
# them via env to the Python simulator. Keeping Python pure-stdlib and
# env-driven avoids quoting hell inside a $(...) heredoc.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/crystal-path.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gate-guard.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0

# Warm the root cache in THIS shell before anything fans out into subshells.
# The memo inside resolve_crystal_roots is process-scoped, and every use of it
# below sits inside `$(...)`, `< <(...)` or a pipeline — a subshell inherits the
# cache but cannot fill it. Without this line the tree is rescanned once per
# call site (measured: 7× per hook run on an 11-root vault).
if command -v vdm_prime_crystal_roots >/dev/null 2>&1; then
  vdm_prime_crystal_roots
fi
fi

if ! command -v resolve_crystal_roots >/dev/null 2>&1; then
  exit 0
fi

# Collect roots as colon-separated. Empty = nothing to guard.
roots_colon=$(resolve_crystal_roots | tr '\n' ':' | sed 's/:$//')
[ -z "$roots_colon" ] && exit 0

# Build gate value sets — canonical terminal status + any status-aliases that
# resolve to it. Status-aliases let projects use their own vocab while still
# tripping the gate. Default to bare canonical when jq/config unavailable.
gate_values_for() {
  local target="$1"
  printf '%s' "$target"
  command -v jq >/dev/null 2>&1 || return 0
  local cfg
  cfg=$(resolve_config_path 2>/dev/null) || return 0
  [ -f "$cfg" ] || return 0
  local aliases
  aliases=$(jq -r --arg t "$target" '
    .crystal["status-aliases"] // {} | to_entries[] | select(.value == $t) | .key
  ' "$cfg" 2>/dev/null)
  if [ -n "$aliases" ]; then
    printf ',%s' $(printf '%s' "$aliases" | tr '\n' ' ')
  fi
}

done_csv=$(gate_values_for "done")
superseded_csv=$(gate_values_for "superseded")

simulator="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crystal-completion-guard.py"

# The payload is consumed by whoever reads stdin first, so capture it here and
# hand a copy to the checker. The copy is also what the prefilter below reads.
payload=$(cat)

# Dependency-free scope prefilter. Answers "is this call one this gate is
# responsible for?" using nothing but grep, so the answer is available exactly
# when the checker is not. Deliberately approximate and narrow: all three
# conditions must hold, which keeps a machine without python3 from having every
# write blocked while still covering the one shape the gate exists to catch —
# a workitem going terminal.
guard_in_scope() {
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE 'workitem\.md|/tasks/' 2>/dev/null || return 1
  printf '%s' "$payload" | grep -qE 'status:[[:space:]]*"?(done|superseded)' 2>/dev/null || return 1
  return 0
}

guard_unverified() {
  guard_in_scope || exit 0
  if command -v vdm_gate_unverified >/dev/null 2>&1; then
    vdm_gate_unverified "crystal-completion-guard" "$1" \
      "a workitem is being written with a terminal status — whether open \`- [ ]\` obligations remain was never checked" \
      "install python3 — the checker is a python script — and write again, or" \
      "sweep the file by hand: every \`- [ ]\` must be resolved via one of the five paths (crystal-cut DL #9) before status:done"
  else
    printf '\n[crystal-completion-guard] NOT CHECKED — %s\n  A workitem is going terminal and the gate could not run. Blocking.\n\n' "$1" >&2
  fi
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  guard_unverified "python3 is not on PATH"
fi
[ -f "$simulator" ] || guard_unverified "checker not found at $simulator"

printf '%s' "$payload" \
  | CRYSTAL_ROOTS="$roots_colon" \
    CRYSTAL_GATE_DONE="$done_csv" \
    CRYSTAL_GATE_SUPERSEDED="$superseded_csv" \
    python3 "$simulator"
rc=$?

# The checker returns 0 (allow) or 2 (block) and nothing else. Any other code
# means it did not reach a verdict — a crash, an import error, a killed process.
case "$rc" in
  0|2) exit "$rc" ;;
  *)   guard_unverified "the checker exited $rc without reaching a verdict" ;;
esac
