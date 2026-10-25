#!/bin/bash
# crystal-stop-reminder.test.sh — the Stop hook's status line: the active
# crystals with open items, written for the user, and nothing it has to walk.
#
# Field case (late-grow DL #5, Sidetrack #2): the hook's output is a
# systemMessage, which reaches the user only — 15 of 15 never reached the model
# in one session. Its text was written to the assistant all the same: "finish
# or migrate before declaring done", and a 📌 line asking whether source edits
# made it into the workitem. To ask that, it walked the whole tree every turn,
# and that walk had already hit the hook's ceiling on a note vault
# (hook-timeout-fail-open, DL #9). The question reaches the assistant through
# crystal-capture-reminder at every user prompt; here it is gone, walk and all
# (late-grow DL #7).
#
# What this file holds:
#   - the status line: each active crystal with open items, its count, its path;
#   - no 📌 line and no instruction to the assistant, whatever is newer;
#   - no tree walk at all (the find shim journals every call);
#   - silence without open items; the non-canonical audit line stays.
#
# No commit anywhere: crystal roots are found through `git ls-files`, and
# `git add` is enough for that.
#
# Run: bash tests/crystal-stop-reminder.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: as a child of a live `git
# commit` the inherited GIT_INDEX_FILE would point the fixture's `git add` at
# that commit's index (tests/gates.test.sh, 2026-09-03), and the session's
# author and editor are not this file's either.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

# Nor the machine's git config: git 2.54 runs a hook declared there
# (`hook.<name>.command`) on every commit, a fixture's included — the case is
# in tests/gates.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${CRYSTAL_STOP_REMINDER:-$REPO_ROOT/plugins/vdm/scripts/crystal-stop-reminder.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"$2" ;; esac; }
says_not() {
  # An empty haystack contains nothing, so absence there proves nothing
  # (tests/harness-asserts.test.sh). Silence is asserted as silence.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3"$'\n'"$2" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t stopreminder)
TMP=$(cd "$TMP" && pwd -P)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The find journal sits outside every project.
STATE="$TMP/state"; SHIM="$TMP/shim"
mkdir -p "$STATE" "$SHIM"
REAL_FIND=$(type -P find)
cat >"$SHIM/find" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$STATE/find.log"
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM/find"

# project <dir> <slug>... — a git work tree with one in-progress crystal with
# an open item per slug and a src/ file. Every file starts in 2019.
project() {
  local dir="$1" slug; shift
  mkdir -p "$dir/.claude" "$dir/src"
  for slug in "$@"; do
    mkdir -p "$dir/tasks/$slug"
    printf -- '---\nslug: %s\nstatus: in-progress\n---\n# %s\n\n- [ ] open\n' "$slug" "$slug" \
      >"$dir/tasks/$slug/workitem.md"
  done
  printf 'echo hi\n' >"$dir/src/main.sh"
  ( cd "$dir" && git init -q . && git add -A >/dev/null 2>&1 )
  "$REAL_FIND" "$dir" -path "$dir/.git" -prune -o -type f -exec touch -t 201901010000 {} +
}

# run <cwd> — the way the harness calls a Stop hook: cwd = the project, the
# event JSON on stdin, the find shim first on PATH. Prints the message text.
run() {
  rm -f "$STATE/find.log"
  ( cd "$1" && printf '{"session_id":"t"}' \
      | PATH="$SHIM:$PATH" TMPDIR="$STATE" bash "$HOOK" 2>/dev/null ) \
    | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('systemMessage',''))
except ValueError: pass"
}
walks() { grep -c -- '-newer' "$STATE/find.log" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
printf '\nthe status line\n'
# ---------------------------------------------------------------------------
P="$TMP/proj"; project "$P" alpha beta
# A source file newer than both workitems: the case in which the 📌 line spoke.
touch -t 202501010000 "$P/src/main.sh"
out=$(run "$P")
says "each active crystal, its count" "$out" "alpha: 1 open  ("
# The fixture's crystals live in tasks/, with no crystal.path set; the path
# was built as the setting's default (docs/tasks) plus the path under the root.
says "RED: …and its own path from the project root, not one under docs/tasks/" "$out" "alpha: 1 open  (tasks/alpha/workitem.md)"
says "…the second one too" "$out" "beta: 1 open"
says_not "RED: no 📌 line, though a source file is newer than every workitem" "$out" "📌"
says_not "RED: no instruction to the assistant, who never sees this text" "$out" "before declaring done"
eq "RED: no tree walk at all" "0" "$(walks)"

# ---------------------------------------------------------------------------
printf '\nsilence and the audit line\n'
# ---------------------------------------------------------------------------
Q="$TMP/closed"; project "$Q" gamma
printf -- '---\nslug: gamma\nstatus: in-progress\n---\n# gamma\n\n- [x] done\n' >"$Q/tasks/gamma/workitem.md"
eq "an active crystal with nothing open → silence" "" "$(run "$Q")"

A="$TMP/audit"; project "$A" delta
printf -- '---\nslug: delta\nstatus: someday-maybe\n---\n# delta\n\n- [ ] open\n' >"$A/tasks/delta/workitem.md"
out=$(run "$A")
says "a non-canonical status is still named" "$out" "Non-canonical statuses: 1"

printf '\ncrystal-stop-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
