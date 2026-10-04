#!/bin/bash
# shellwords.test.sh — RED TESTS for the reader two guards share,
# plugins/{vdm-git,vdm-comms}/lib/shellwords.py (Sidetrack #18,
# docs/tasks/crystal-wake/workitem.md).
#
# The reader promises the shell's own reading of a command, as far as a guard
# needs it:
#   * text the shell does not read as words is cut — a heredoc body, a comment;
#   * a heredoc is cut only when a line closes it, or `$((1<<2))` would hide
#     everything after it;
#   * `<<` and `#` inside quotes stay text, and a `#` inside a word is no comment;
#   * a line continuation is joined, as the shell joins it;
#   * a newline outside quotes ends a simple command, as `;` does;
#   * the command splits into simple commands with the quotes removed, and
#     redirections stay where a guard can read them;
#   * a command whose quotes do not close is not guessed at: ValueError.
#
# The cases run against every copy of the file. check-lib-sync keeps the copies
# byte-identical; this suite says what the bytes must do. It also runs
# git-guard's case table, the reader's heaviest user: a change to the reader
# alone runs this suite and not git-guard's.
#
# Run: bash tests/shellwords.test.sh   (exit 0 = all pass)
set -u

# No git in here, but the isolation suite requires the scrub of every harness
# (tests/gates-harness-isolation.test.sh) — a rule with an exception is a rule
# someone has to remember.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t shellwords)
trap 'rm -rf "$TMP"' EXIT

# Written to a file, not run from $( ): a heredoc inside $( ) is where bash
# 3.2's own parser trips over an apostrophe.
cat > "$TMP/cases.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from shellwords import shell_text, simple_commands

TEXT = [  # (what, command, what the shell reads as words)
    ("a heredoc body is cut",
     "cat <<'PY'\nx = \"it's\"\nPY\necho done", "cat <<'PY'\necho done"),
    ("<<- ends at a tab-indented delimiter",
     "cat <<-EOF\n\tit's\n\tEOF\necho done", "cat <<-EOF\necho done"),
    ("a << that no line closes cuts nothing",
     "echo $((1<<2))\ncp a b", "echo $((1<<2))\ncp a b"),
    ("two heredocs on one line are read in turn",
     "cat <<A <<B\na\nA\nb\nB\nnext", "cat <<A <<B\nnext"),
    ("a here-string is no heredoc",
     "cat <<<\"it's\" > f\nnext", "cat <<<\"it's\" > f\nnext"),
    ("<< inside quotes is text, even with a line that would close it",
     "echo \"a <<b\"\nb\nnext", "echo \"a <<b\"\nb\nnext"),
    ("a comment is cut to the end of its line",
     "ls # it's\nnext", "ls \nnext"),
    ("# inside a word is no comment", "curl http://x/#frag", "curl http://x/#frag"),
    ("# inside quotes is no comment", "echo \"step #1\"", "echo \"step #1\""),
    ("$# is no comment", "echo $#", "echo $#"),
    ("a line continuation is joined", "git \\\ncommit", "git commit"),
    ("…inside double quotes too", "echo \"a\\\nb\"", "echo \"ab\""),
    ("…but not inside single quotes", "echo 'a\\\nb'", "echo 'a\\\nb'"),
]
CMDS = [  # (what, command, the simple commands)
    ("separators end a simple command",
     "a; b && c | d || e & f", [["a"], ["b"], ["c"], ["d"], ["e"], ["f"]]),
    ("( ) and $( ) open commands of their own",
     "echo $(git status) (cd x)", [["echo", "$"], ["git", "status"], ["cd", "x"]]),
    ("backticks open a command of their own",
     "x=`git status`", [["x="], ["git", "status"]]),
    ("redirections stay in the argv",
     "cat > f 2>&1", [["cat", ">", "f", "2", ">&", "1"]]),
    ("quotes come off",
     "'git' \"commit\" -m 'a b'", [["git", "commit", "-m", "a b"]]),
    ("a newline outside quotes ends a simple command",
     "a\nb", [["a"], ["b"]]),
    ("…inside quotes it is text",
     "echo 'a\nb'", [["echo", "a\nb"]]),
    ("…a continuation joins lines, it does not end a command",
     "cp a \\\nb", [["cp", "a", "b"]]),
    ("…after a heredoc body the next line is a command of its own",
     "cat <<'E'\nx\nE\nnext", [["cat", "<<", "E"], ["next"]]),
    ("…and a newline after | or && belongs to the operator",
     "a |\nb &&\nc", [["a"], ["b"], ["c"]]),
]

for what, cmd, want in TEXT:
    got = shell_text(cmd)
    print("ok\t" + what if got == want else "bad\t%s\tgot %r" % (what, got))
for what, cmd, want in CMDS:
    got = simple_commands(cmd)
    print("ok\t" + what if got == want else "bad\t%s\tgot %r" % (what, got))
try:
    simple_commands("echo \"unclosed")
    print("bad\tquotes that never close raise ValueError\tnothing raised")
except ValueError:
    print("ok\tquotes that never close raise ValueError")
PY

copies=0
for lib in "$REPO_ROOT"/plugins/*/lib; do
  [ -f "$lib/shellwords.py" ] || continue
  copies=$((copies + 1))
  plugin=${lib%/lib}; plugin=${plugin##*/}
  echo "== $plugin/lib/shellwords.py =="
  ran=0
  while IFS=$'\t' read -r verdict what detail; do
    ran=$((ran + 1))
    if [ "$verdict" = ok ]; then ok "$what"; else bad "$verdict $what" "${detail:-}"; fi
  done < <(python3 "$TMP/cases.py" "$lib" 2>&1)
  if [ "$ran" -ge 24 ]; then ok "canary: all $ran cases ran"
  else bad "canary: all cases ran" "only $ran — the cases were cut or the reader did not load"; fi
done
if [ "$copies" = 2 ]; then ok "canary: both copies were read (vdm-git, vdm-comms)"
else bad "canary: both copies were read" "found $copies"; fi

echo ""
echo "== git-guard's case table, the reader's heaviest user =="
CASES_OUT=$(python3 "$REPO_ROOT/scripts/test-git-guard-hook.py" 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok "every case holds ($(printf '%s\n' "$CASES_OUT" | tail -1))"
else bad "every case holds" "$(printf '%s\n' "$CASES_OUT" | grep -A1 '✗' | head -20)"; fi

printf '\nshellwords: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
