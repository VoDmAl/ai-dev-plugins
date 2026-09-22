#!/bin/bash
# Fail-closed helpers for BLOCKING hooks.
#
# The law they implement: **"the check failed" and "the check did not run" are
# different events, and for a gate the second one blocks too.**
#
# A reminder may fail open — the cost of a missed nudge is one missed nudge. A
# gate may not: a gate that cannot run returns "nothing wrong", which is
# indistinguishable from a clean tree. It then looks healthy forever while
# enforcing nothing. Measured in this suite on 2026-09-21: with `python3`
# absent, crystal-completion-guard exited 127, crystal-lint and orphan-guard
# exited 0, and git-guard exited 127 — and the harness blocks only on 2, so all
# four were silently off. The same defect arrived from three other repositories
# through the meetings relay (`docs/tasks/comms-plugin/references/`), where a
# `|| true` swallowed the linter's exit code.
#
# The shape every blocking hook follows:
#
#   1. Capture stdin once (a hook payload is consumed by the first reader).
#   2. Try to parse it — `vdm_json_field` tries python3, then jq.
#   3. Read a field that MUST be there (`tool_name`). Empty means the payload
#      was not read, which is not the same as "this call is out of scope".
#   4. On that, or on a checker that exits outside its documented codes, decide
#      with `vdm_payload_matches`: does the RAW payload look like something
#      this gate is responsible for? Only then block, via
#      `vdm_gate_unverified`, which names what went unchecked, why, and how to
#      proceed. A gate that fails without saying why is hostile.
#
# Step 3 is where the first version of this fix was itself wrong, which is why
# it is spelled out. Testing whether a parser is *installed* covers the machine
# that has none and misses the one whose python3 is present and broken — the
# parser returns nothing, the hook reads that as "not my business", and the
# gate is off again one level down. Measured: with a crashing python3, two of
# the four hooks still exited 0 after the first round of this patch. Ask what
# the answer means, not what the machine has.
#
# Step 4 is what keeps the rule from turning into "block everything": the
# prefilter needs no dependency at all, so its answer is available exactly when
# nothing else is. It is deliberately approximate — it errs toward blocking
# inside the gate's own scope and stays silent outside it.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/gate-guard.sh.
# The mirror is checked by scripts/check-lib-sync.sh in the dev repo; any change
# here MUST be applied to the vdm-git copy in the same commit.

# vdm_json_field <payload> <dotted.path>
#
# Prints the field's value, or nothing when it is absent OR when no parser
# could read the payload. Callers must not try to tell those apart by looking
# at VDM_JSON_PARSER afterwards: `$(vdm_json_field …)` runs in a subshell, so
# the assignment never reaches them. Ask a field that must exist instead — see
# step 3 above.
vdm_json_field() {
  local payload="$1" path="$2"

  if command -v python3 >/dev/null 2>&1; then
    VDM_JSON_PARSER="python3"
    FIELD_PATH="$path" python3 -c '
import json, os, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
cur = data
for part in os.environ.get("FIELD_PATH", "").split("."):
    cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None:
        break
if cur is not None:
    print(cur)
' <<<"$payload" 2>/dev/null
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    VDM_JSON_PARSER="jq"
    printf '%s' "$payload" \
      | jq -r --arg p "$path" 'getpath($p | split(".")) // empty' 2>/dev/null
    return 0
  fi

  VDM_JSON_PARSER=""
  return 0
}

# vdm_payload_matches <payload> <extended-regex>
#
# Dependency-free prefilter over the RAW payload text. True when the pattern
# occurs anywhere in it. Used to decide whether an unrunnable gate is
# responsible for this particular call.
vdm_payload_matches() {
  printf '%s' "$1" | grep -qE "$2" 2>/dev/null
}

# vdm_gate_missing_dep <dep>...
#
# Prints the first dependency that is absent; silent when all are present.
vdm_gate_missing_dep() {
  local dep
  for dep in "$@"; do
    command -v "$dep" >/dev/null 2>&1 || { printf '%s\n' "$dep"; return 0; }
  done
  return 0
}

# vdm_gate_unverified <label> <reason> <scope> [<remedy-line>...]
#
# Emits the standard "NOT CHECKED" diagnostic on stderr. The caller exits 2
# right after: `vdm_gate_unverified … ; exit 2`. Kept as a separate step so a
# caller can add its own lines first.
vdm_gate_unverified() {
  local label="$1" reason="$2" scope="$3"
  shift 3
  {
    printf '\n'
    printf '[%s] NOT CHECKED — %s\n' "$label" "$reason"
    printf '\n'
    printf '  This gate could not run. That is NOT the same as finding nothing\n'
    printf '  wrong, so it blocks instead of reporting success.\n'
    printf '\n'
    printf '  What went unchecked: %s\n' "$scope"
    if [ "$#" -gt 0 ]; then
      printf '\n'
      printf '  How to proceed:\n'
      local line
      for line in "$@"; do
        printf '    - %s\n' "$line"
      done
    fi
    printf '\n'
  } >&2
}
