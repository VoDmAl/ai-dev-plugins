#!/bin/bash
# git-guard-prepare-check.test.sh — `git-guard-prepare --check`: the checks a
# prep makes, run for a look only. Nothing is written, and a line still waiting
# stays as it was handed off.
#
# Field case (the machines agent, 2026-10-25): a line was handed to the owner; the agent
# then wanted to see again which documents the helper named under "documents
# this commit may leave behind", and ran `echo x | git-guard-prepare --supersede
# - -- <paths>`. That was no look: it prepared a new line with the message "x"
# and killed the one handed off. A third line followed, and the owner was told
# both earlier ones were void. Without --supersede the call refuses while a line
# waits, so there was no way to look at all. The same evening in this repository
# the list of documents ended in "+5 more", and nothing could show the rest
# without replacing the line.
#
# What this file holds:
#   - a line waiting: --check runs anyway, leaves its message file and every
#     sidecar as they were, and the next prep still refuses for that line;
#   - without paths it checks the waiting line's paths, with `-- <paths>` those;
#     the waiting line's paths are found from the cwd or from the top;
#   - the verdicts are a prep's: a refusal (U+FFFD) exits 1 with the prep's
#     words, a clean set exits 0; the documents left behind are listed in full;
#   - a message, when given, has its subject measured as a prep would.
#
# No commit anywhere: the HEAD is unborn, and a prep works there.
#
# Run: bash tests/git-guard-prepare-check.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm-git/bin/git-guard-prepare (--check)

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="${GIT_GUARD_PREPARE:-$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"${2:0:700}" ;; esac; }
says_not() {
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3"$'\n'"${2:0:700}" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ggpcheck)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"
export GIT_GUARD_SHORT_DIR="$TMP/short"
export GIT_GUARD_SYNC_CHECK=off
export CLAUDE_CODE_SESSION_ID=check-session

# run <dir> <args>... — prints "<exit>|<stdout>|<stderr>"
run() {
  local d="$1" out err rc; shift
  out=$( { cd "$d" && bash "$PREP" "$@" 2>"$TMP/err"; } ); rc=$?
  err=$(cat "$TMP/err" 2>/dev/null)
  printf '%s|%s|%s' "$rc" "$out" "$err"
}
rc_of()  { printf '%s' "${1%%|*}"; }
out_of() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }
err_of() { local r="${1#*|}"; printf '%s' "${r#*|}"; }
# sidecars — every file the helper keeps for this session, with its content's
# checksum: what a look must leave as it was.
sidecars() { ( cd "$TMPDIR" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done; ) ; ls "$GIT_GUARD_SHORT_DIR" 2>/dev/null; }

R="$TMP/repo"; mkdir -p "$R/docs" "$R/src"
git -C "$R" init -q
printf 'one\n' >"$R/src/a.txt"
printf 'two\n' >"$R/src/b.txt"
git -C "$R" add -- src/a.txt

echo "== a line waiting, and a look at it =="
out=$(run "$R" "[+] add a" -- src/a.txt)
eq "the canary: a prep hands off a line" "0" "$(rc_of "$out")"
line=$(out_of "$out")
msgfile=$(printf '%s' "$line" | sed -n "s/^\[ -f '\([^']*\)'.*/\1/p")
[ -f "$msgfile" ] && ok "…and its message file is there" || bad "…and its message file is there" "$line"
before=$(sidecars)

out=$(run "$R" --check)
eq "RED: --check while the line waits → exit 0, not the waiting refusal" "0" "$(rc_of "$out")"
says "…saying it checked the waiting line" "$(out_of "$out")" "[+] add a"
says "…and that nothing was written" "$(out_of "$out")" "Nothing written"
eq "RED: every sidecar exactly as before" "$before" "$(sidecars)"
[ -f "$msgfile" ] && ok "…the handed-off line still runs (its message file is there)" || bad "…the handed-off line still runs (its message file is there)"
out=$(run "$R" "[+] something else")
eq "the next prep still refuses: the line is still waiting" "1" "$(rc_of "$out")"
says "…for that line" "$(err_of "$out")" "still waiting"

echo "== whose paths =="
printf 'bad \xef\xbf\xbd byte\n' >"$R/src/b.txt"
git -C "$R" add -- src/b.txt
out=$(run "$R" --check)
eq "RED: without paths, the waiting line's paths — the broken file outside it is not checked" "0" "$(rc_of "$out")"
says "…and the paths are named" "$(out_of "$out")" "src/a.txt"
out=$(run "$R" --check -- src/b.txt)
eq "RED: with -- <paths>, those paths: the prep's refusal, as exit 1" "1" "$(rc_of "$out")"
says "…in the prep's words" "$(err_of "$out")" "U+FFFD"
eq "…and still nothing written" "$before" "$(sidecars)"
out=$(run "$R/src" --check)
eq "RED: from a subdirectory the waiting line's paths are found from the top" "0" "$(rc_of "$out")"

echo "== a message, when given =="
long="[+] $(printf 'x%.0s' $(seq 1 90))"
out=$(run "$R" --check "$long" -- src/a.txt)
eq "RED: an over-long subject → the prep's refusal, exit 1" "1" "$(rc_of "$out")"
says "…in its words" "$(err_of "$out")" "over this project's ceiling"

echo "== no line waiting =="
Q="$TMP/quiet"; mkdir -p "$Q"; git -C "$Q" init -q
printf 'q\n' >"$Q/q.txt"; git -C "$Q" add -- q.txt
before_q=$(sidecars)
out=$(run "$Q" --check)
eq "RED: no line waiting, no paths → the index, as a prep takes it" "0" "$(rc_of "$out")"
says "…named" "$(out_of "$out")" "q.txt"
eq "…and nothing written" "$before_q" "$(sidecars)"
out=$(run "$Q" --check --supersede "[+] x")
eq "RED: --check with --supersede is refused — a look never replaces a line" "1" "$(rc_of "$out")"
says "…by name, not as a stray argument" "$(err_of "$out")" "never replaces a line"
eq "…and writes nothing" "$before_q" "$(sidecars)"
W="$TMP/gone"; mkdir -p "$W"; git -C "$W" init -q
printf 'w\n' >"$W/w.txt"; git -C "$W" add -- w.txt
run "$W" "[+] add w" -- w.txt >/dev/null
rm -f "$W/w.txt"
out=$(run "$W" --check)
eq "a waiting path deleted from disk but still staged is placed by the index…" "1" "$(rc_of "$out")"
says "…and the prep's own check names it" "$(err_of "$out")" "working tree differs from the index"
git -C "$W" rm -q --cached -- w.txt
out=$(run "$W" --check)
eq "RED: a waiting path that is nowhere — not on disk, not in the index or HEAD → refused, not passed" "1" "$(rc_of "$out")"
says "…saying so" "$(err_of "$out")" "cannot be placed"
N="$TMP/nogit"; mkdir -p "$N"
eq "outside a repository → exit 1" "1" "$(rc_of "$(run "$N" --check)")"

printf '\ngit-guard-prepare-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
