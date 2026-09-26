#!/bin/bash
# docs-distill-reminder.test.sh — the UserPromptSubmit hook that says a
# synthesis document has fallen behind the inputs it covers.
#
# The assertion this file exists for: a closed window costs nothing. Until vdm
# 2.36.2 the hook ran the whole drift scan first and only then asked the
# throttle whether it may speak — so for the half hour after every reminder,
# every prompt paid for a scan whose answer was muted anyway. No outcome was
# ever wrong, which is exactly why nothing noticed: a wasted cost has no
# symptom except the bill. Found while counting what one prompt costs in any
# project (Sidetrack #5, docs/tasks/crystal-wake/workitem.md).
#
#   Ask the question that can end the work before doing the work it would end.
#
# Counted in scanner runs, not seconds. The hook runs from a copy of the
# plugin tree in which distill-scan.sh is a wrapper: one line to a log, then
# the real scanner. The hook finds the scanner and its libraries relative to
# its own path, so the copy behaves as the original does.
#
# Run: bash tests/docs-distill-reminder.test.sh   (exit 0 = all pass)
# Another hook in the same seat: DISTILL_REMINDER_BIN=<path> bash tests/…

set -u

# Scrub git's per-invocation environment first: the fixture below runs
# `git init` / `git add`, and as a child of a live `git commit` the inherited
# GIT_INDEX_FILE would point them at that commit's index (tests/gates.test.sh,
# 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_INDEX_VERSION 2>/dev/null || true
# Under the dispatcher a reminder writes a fragment instead of printing; this
# suite reads what the hook prints.
unset VDM_REMINDER_FRAGMENT 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SRC="${DISTILL_REMINDER_BIN:-$REPO_ROOT/plugins/vdm/scripts/docs-distill-reminder.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac
}
silent() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $(printf '%s' "$2" | head -c 160)"; fi
}
count_is() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t distillreminder)
trap 'rm -rf "$TMP"' EXIT

PLUG="$TMP/plugin"
mkdir -p "$PLUG"
cp -R "$REPO_ROOT/plugins/vdm/scripts" "$REPO_ROOT/plugins/vdm/lib" "$PLUG/"
cp "$HOOK_SRC" "$PLUG/scripts/docs-distill-reminder.sh"
mv "$PLUG/scripts/distill-scan.sh" "$PLUG/scripts/distill-scan.real.sh"
cat >"$PLUG/scripts/distill-scan.sh" <<'EOF'
#!/bin/bash
printf 'scan\n' >>"$DISTILL_SCAN_LOG"
exec bash "$(dirname "${BASH_SOURCE[0]}")/distill-scan.real.sh" "$@"
EOF
HOOK="$PLUG/scripts/docs-distill-reminder.sh"
SCANS="$TMP/scans.log"
STATE="$TMP/state"
mkdir -p "$STATE"

REPO="$TMP/repo"
mkdir -p "$REPO/docs/model" "$REPO/src"
cd "$REPO" || exit 1
git init -q . 2>/dev/null
cat >docs/model/m.md <<'EOF'
---
type: model
question: "how the parts fit"
covers:
  - src/
observed: 2020-01-01
---
# M
EOF
printf 'x\n' >src/a.txt
git add -A >/dev/null 2>&1

# Nothing is committed, so the scanner compares mtimes only — the content
# confirmation needs a commit that wrote the synthesis. Fixed stamps rather than
# "now": two writes in one second must not decide a case.
drifted() { touch -t 202001010000 docs/model/m.md; touch -t 202201010000 src/a.txt; }
current() { touch -t 202201010000 docs/model/m.md; touch -t 202001010000 src/a.txt; }

prompt() {  # prompt <session-id> — one UserPromptSubmit, prints what the hook said
  printf '{"session_id":"%s","prompt":"x"}' "$1" \
    | TMPDIR="$STATE" DISTILL_SCAN_LOG="$SCANS" bash "$HOOK" 2>/dev/null
}
scans() {
  if [ -f "$SCANS" ]; then wc -l <"$SCANS" | tr -d ' '; else printf '0'; fi
}

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# ---------------------------------------------------------------------------
printf '\na closed window runs no scan\n'
# ---------------------------------------------------------------------------
drifted
OUT=$(prompt s1)
says "the first prompt of a session reports the drift" "$OUT" "[docs-distill]"
says "…naming the document that fell behind" "$OUT" "docs/model/m.md"
# The canary: without it, a wrapper the hook never reaches would read as
# "zero scans" below and pass for the wrong reason.
count_is "canary: that prompt ran the scanner once" 1 "$(scans)"

OUT=$(prompt s1)
silent "the next prompt in the same window is silent" "$OUT"
count_is "RED: …and runs no scan — a muted answer is not paid for" 1 "$(scans)"

if [ "$have_jq" = 1 ]; then
  before=$(scans)
  OUT=$(prompt s2)
  says "another session's window is its own" "$OUT" "[docs-distill]"
  count_is "…and that session scans" $((before + 1)) "$(scans)"
else
  printf '  – SKIP per-session windows: no jq, every session is "default"\n'
fi

# ---------------------------------------------------------------------------
printf '\na quiet scan leaves the window open\n'
# ---------------------------------------------------------------------------
# Asking first must not turn into claiming first: drift that appears in the
# middle of a session has to surface on the next prompt, not a window later.
current
before=$(scans)
OUT=$(prompt s3)
silent "nothing behind → nothing said" "$OUT"
count_is "…after a scan" $((before + 1)) "$(scans)"
drifted
OUT=$(prompt s3)
says "drift that appears mid-session surfaces on the next prompt" "$OUT" "[docs-distill]"

# ---------------------------------------------------------------------------
printf '\nthe modes\n'
# ---------------------------------------------------------------------------
if [ "$have_jq" = 1 ]; then
  mkdir -p .claude
  printf '{"distill":{"mode":"proactive"}}\n' >.claude/vdm-plugins.json
  drifted
  OUT=$(prompt s4)
  says "proactive: the first prompt reports" "$OUT" "[docs-distill]"
  OUT=$(prompt s4)
  says "proactive: so does the next — no window" "$OUT" "[docs-distill]"

  printf '{"distill":{"mode":"silent"}}\n' >.claude/vdm-plugins.json
  before=$(scans)
  OUT=$(prompt s5)
  silent "silent: says nothing" "$OUT"
  count_is "silent: …and scans nothing" "$before" "$(scans)"
  rm -f .claude/vdm-plugins.json
else
  printf '  – SKIP modes: no jq, the config is not read\n'
fi

# ---------------------------------------------------------------------------
printf '\na name is text inside JSON\n'
# ---------------------------------------------------------------------------
# The scanner hands over real names since it reads git with -z, and a real name
# can hold a quote or a backslash. The hook pastes names into a JSON string;
# one unescaped name makes the whole text unparseable — the failure that took
# down every reminder of a turn at command-center, 2026-09-25.
printf 'x\n' > 'src/quote"d.txt'
printf 'x\n' > 'src/back\slash.txt'
printf 'x\n' > 'src/Документ.txt'
touch -t 202001010000 docs/model/m.md src/a.txt
touch -t 202201010000 'src/quote"d.txt' 'src/back\slash.txt' 'src/Документ.txt'
OUT=$(prompt s6)
CTX=$(printf '%s' "$OUT" | python3 -c '
import json, sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)
if [ -n "$CTX" ]; then ok "RED: with a quote and a backslash in names the reminder is still valid JSON"
else bad "RED: with a quote and a backslash in names the reminder is still valid JSON" "$(printf '%s' "$OUT" | head -c 200)"; fi
says "…the quoted name reads as itself" "$CTX" 'src/quote"d.txt'
says "…so does the backslash" "$CTX" 'src/back\slash.txt'
says "…and the Cyrillic one" "$CTX" 'src/Документ.txt'
# Valid JSON alone is not the property: lib/reminder-emit.sh re-escapes a text
# that breaks the contract and marks it as a defect of the reminder, so a hook
# that pastes names raw still comes out parseable — under that notice, with its
# own line breaks turned into literal "\n". The hook escapes its names itself.
case "$CTX" in
  *"not valid JSON"*) bad "RED: …because the hook escaped the names itself, not the safety net" "$(printf '%s' "$CTX" | head -c 160)" ;;
  "")                 bad "RED: …because the hook escaped the names itself, not the safety net" "no text to look at" ;;
  *)                  ok  "RED: …because the hook escaped the names itself, not the safety net" ;;
esac

printf '\ndocs-distill-reminder: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
