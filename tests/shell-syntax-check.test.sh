#!/bin/bash
# shell-syntax-check.test.sh — RED TESTS for the parse check that runs after
# every write of a shell file (PostToolUse). Its staged mode is the tenth
# pre-commit gate and is red-tested with the other gates, in tests/gates.test.sh.
#
# The incident (2026-09-25, this repo). docs-sync-reminder.sh gained
#     case "${entry:0:2}" in R*|C*|?R|?C) … ;; esac
# inside `$( )`. bash 3.2 — /bin/bash on every Mac — reads the `)` that closes a
# bare case pattern as the end of the substitution, so the script no longer
# parsed; bash 4+ accepts it. Nothing said so at the write. The error surfaced
# only when a test ran the script, and in a session the reminder composer would
# simply have gone on without docs-sync: a hook that does not parse fails
# without a word. `bash -n` answers in milliseconds, and nothing asked it.
#
# What is asserted:
#   RED    a file that does not parse ⇒ exit 2 from the hook (1 in file mode),
#          and the message names the file, the line and the interpreter that
#          refused it;
#   GREEN  anything that is not a shell file, and every shell file that parses,
#          ⇒ exit 0 and silence — including the false positive a plain `bash -n`
#          has: a script that turns extglob on for itself;
#   WHICH  the interpreter is the one the file will meet, not the newest one
#          around — a permissive stub `bash` first on PATH decides for
#          `#!/usr/bin/env bash`, and does not save a `#!/bin/bash` script.
#
# Run: bash tests/shell-syntax-check.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment before anything else — see
# tests/gates.test.sh. This suite builds a git fixture and runs inside a live
# `git commit` when gate 7 fires.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/plugins/vdm/scripts/shell-syntax-check.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_silent() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t shellsyntax)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Canonicalised: on macOS mktemp hands back /var/… while tools resolve
# /private/var/…, and a path mismatch is not what is under test.
mkdir -p "$TMP/fx"
FX=$(cd "$TMP/fx" && pwd -P)
( cd "$FX" && git init -q . ) >/dev/null 2>&1

put() { # put <relpath> <content> — printf-interpreted, so \n is a newline
  mkdir -p "$(dirname "$FX/$1")"
  printf "$2" > "$FX/$1"
}

payload() { # payload <tool> <abs-path>
  printf '{"hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"},"session_id":"t","cwd":"%s"}' \
    "$1" "$2" "$FX"
}

# hook <tool> <relpath> [env-assignment...] — sets RC and ERR (stderr). A
# PostToolUse hook speaks on stderr; anything on stdout is a defect of its own.
hook() {
  local tool="$1" rel="$2"; shift 2
  ( cd "$FX" && payload "$tool" "$FX/$rel" | env "$@" bash "$CHECK" --hook ) >"$TMP/out" 2>"$TMP/err"
  RC=$?
  ERR=$(cat "$TMP/err")
  if [ -s "$TMP/out" ]; then bad "stdout stays empty for $rel" "got: $(cat "$TMP/out")"; fi
}

if [ ! -f "$CHECK" ]; then
  bad "the checker exists at plugins/vdm/scripts/shell-syntax-check.sh" "missing: $CHECK"
  printf '\nshell-syntax-check: %s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

echo "== a file that parses is left alone =="
put ok.sh '#!/bin/bash\nset -u\nx=$(printf "%%s" hi)\necho "$x"\n'
hook Write ok.sh
expect_exit "GREEN: a script that parses ⇒ exit 0" 0 "$RC"
expect_silent "…and says nothing" "$ERR"

echo "== a file that does not parse is named, with its line and interpreter =="
put broken.sh '#!/bin/bash\nif true; then\n  echo hi\n'
hook Write broken.sh
expect_exit "RED: an unterminated if ⇒ exit 2" 2 "$RC"
expect_says "…names the file" "$ERR" "broken.sh"
expect_says "…says it does not parse" "$ERR" "does not parse"
expect_says "…names the interpreter that refused it" "$ERR" "/bin/bash"
expect_says "…and carries the interpreter's own line number" "$ERR" "line "
hook Edit broken.sh
expect_exit "RED: an Edit is checked the same way" 2 "$RC"
hook MultiEdit broken.sh
expect_exit "RED: so is a MultiEdit" 2 "$RC"

echo "== the incident: bash 3.2 and a bare case pattern inside \$( ) =="
put case-bare.sh '#!/bin/bash\nx=$(case a in a) echo 1 ;; esac)\necho "$x"\n'
put case-paren.sh '#!/bin/bash\nx=$(case a in (a) echo 1 ;; esac)\necho "$x"\n'
bash_major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)
if [ "$bash_major" = "3" ]; then
  hook Write case-bare.sh
  expect_exit "RED: \`a)\` inside \$( ) under /bin/bash 3.2 ⇒ exit 2" 2 "$RC"
  expect_says "…and the message names the fix for it" "$ERR" "(pat)"
else
  ok "RED: bare case pattern — skipped, /bin/bash here is ${bash_major:-?}.x and accepts it"
fi
hook Write case-paren.sh
expect_exit "GREEN: the \`(a)\` form parses under every bash ⇒ exit 0" 0 "$RC"

echo "== extglob: a script that turns it on for itself is not a syntax error =="
put glob-on.sh '#!/bin/bash\nshopt -s extglob\ncase "$1" in +(a|b)) echo ab ;; esac\n'
put glob-off.sh '#!/bin/bash\ncase "$1" in +(a|b)) echo ab ;; esac\n'
hook Write glob-on.sh
expect_exit "GREEN: \`shopt -s extglob\` then +(a|b) ⇒ exit 0 (plain \`bash -n\` says syntax error)" 0 "$RC"
expect_silent "…and says nothing" "$ERR"
hook Write glob-off.sh
expect_exit "RED: +(a|b) with extglob never enabled fails at run time too ⇒ exit 2" 2 "$RC"

echo "== what counts as a shell file =="
put notes.md 'if then fi ( ( (\n'
hook Write notes.md
expect_exit "GREEN: markdown is not parsed ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$ERR"
put tool.py '#!/usr/bin/env python3\nif True:\n    print("x")\n'
hook Write tool.py
expect_exit "GREEN: a python script is not parsed as shell ⇒ exit 0" 0 "$RC"
put pyshim.sh '#!/usr/bin/env python3\nprint("a .sh name does not outrank the shebang")\n'
hook Write pyshim.sh
expect_exit "GREEN: .sh with a python shebang — the shebang wins ⇒ exit 0" 0 "$RC"
put bin/runner '#!/bin/sh\nif true; then\n  echo hi\n'
hook Write bin/runner
expect_exit "RED: no extension, a #!/bin/sh shebang — checked ⇒ exit 2" 2 "$RC"
expect_says "…under /bin/sh" "$ERR" "/bin/sh"
put lib/helpers.sh 'helper() {\n  echo hi\n'
hook Write lib/helpers.sh
expect_exit "RED: a sourced .sh with no shebang is checked with bash ⇒ exit 2" 2 "$RC"
put "dir with space/broken.sh" '#!/bin/bash\nfor x in a b; do\n'
hook Write "dir with space/broken.sh"
expect_exit "RED: a path with a space ⇒ exit 2" 2 "$RC"
expect_says "…and the whole path is named" "$ERR" "dir with space/broken.sh"

if command -v zsh >/dev/null 2>&1; then
  put ok.zsh '#!/usr/bin/env zsh\nparts=(${(s:,:)1})\nprint -l $parts\n'
  hook Write ok.zsh
  expect_exit "GREEN: zsh-only syntax under a zsh shebang is checked by zsh ⇒ exit 0" 0 "$RC"
  put broken.zsh '#!/usr/bin/env zsh\nif true; then\n  print hi\n'
  hook Write broken.zsh
  expect_exit "RED: a zsh script that does not parse ⇒ exit 2" 2 "$RC"
  expect_says "…and zsh is the one that refused it" "$ERR" "(zsh "
else
  ok "zsh cases — skipped, no zsh on this machine"
fi

echo "== which interpreter: the one the file will meet =="
# A stub `bash` first on PATH. With -n it logs the file and accepts anything;
# otherwise it hands over to the real bash, so the checker itself still runs.
STUB="$TMP/stub"; mkdir -p "$STUB"
REAL_BASH=$(command -v bash)
cat > "$STUB/bash" <<EOF
#!$REAL_BASH
case " \$* " in *" -n "*) printf '%s\n' "\$*" >> "$TMP/stub.log"; exit 0 ;; esac
exec "$REAL_BASH" "\$@"
EOF
chmod +x "$STUB/bash"
put env-broken.sh '#!/usr/bin/env bash\nif true; then\n'
: > "$TMP/stub.log"
hook Write env-broken.sh PATH="$STUB:$PATH"
expect_exit "WHICH: #!/usr/bin/env bash is judged by the PATH bash (the stub accepts) ⇒ exit 0" 0 "$RC"
expect_says "…and the stub was asked" "$(cat "$TMP/stub.log")" "env-broken.sh"
: > "$TMP/stub.log"
hook Write broken.sh PATH="$STUB:$PATH"
expect_exit "WHICH: #!/bin/bash is judged by /bin/bash even when PATH's bash accepts ⇒ exit 2" 2 "$RC"
expect_says "…while the PATH bash is asked too: \`bash x.sh\` would meet it" "$(cat "$TMP/stub.log")" "broken.sh"

echo "== what is out of scope stays silent =="
hook Read broken.sh
expect_exit "GREEN: a Read is not a write ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$ERR"
hook Write gone.sh
expect_exit "GREEN: a path that does not exist ⇒ exit 0" 0 "$RC"
mkdir -p "$FX/.claude"
printf '{"shell-syntax":{"enabled":false}}\n' > "$FX/.claude/vdm-plugins.json"
hook Write broken.sh CLAUDE_PROJECT_DIR="$FX"
expect_exit "GREEN: shell-syntax.enabled=false ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$ERR"
rm -f "$FX/.claude/vdm-plugins.json"

echo "== a payload it cannot read: block in scope, silence out of it =="
ERR=$(cd "$FX" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/broken.sh"' "$FX" \
        | bash "$CHECK" --hook 2>&1 >/dev/null); RC=$?
expect_exit "RED: a truncated payload about a .sh ⇒ exit 2" 2 "$RC"
expect_says "…and it says the file was NOT CHECKED" "$ERR" "NOT CHECKED"
ERR=$(cd "$FX" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/notes.md"' "$FX" \
        | bash "$CHECK" --hook 2>&1 >/dev/null); RC=$?
expect_exit "GREEN: a truncated payload about markdown ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$ERR"

echo "== file mode: the same verdicts, exit 1 =="
OUT=$(cd "$FX" && bash "$CHECK" ok.sh broken.sh notes.md 2>&1); RC=$?
expect_exit "RED: one broken file among three ⇒ exit 1" 1 "$RC"
expect_says "…names it" "$OUT" "broken.sh"
OUT=$(cd "$FX" && bash "$CHECK" ok.sh glob-on.sh case-paren.sh notes.md 2>&1); RC=$?
expect_exit "GREEN: nothing broken ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$OUT"

printf '\nshell-syntax-check: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
