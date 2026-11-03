#!/bin/bash
# git-guard-line-lifetime.test.sh — a prepared commit line lives until it is run
# or replaced, and when it dies it says why (docs/tasks/git-guard-line-lifetime).
#
# Field case (a project's agent, 2026-10-31): a line the owner held for five days
# died overnight. Its files lay under $TMPDIR and /tmp, which macOS cleans by
# itself after three days; the short call was gone, and the full line said
# "void", which reads as "replaced". So the files moved to the state directory
# (DL #1), every death the helper causes leaves its reason (DL #2), the helper
# does the cleaning the OS did (DL #3), and a line lost outside git-guard is
# named by --pending (DL #4).
#
# Nothing here commits: every fixture is a repository with an unborn HEAD, where
# the helper prepares lines from the index alone. A dead line is checked by
# running only its opening check, cut off before `git commit`.
#
# Run: bash tests/git-guard-line-lifetime.test.sh   (exit 0 = all pass)

set -u
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      CLAUDE_CODE_SESSION_ID XDG_STATE_HOME GIT_GUARD_STATE_DIR GIT_GUARD_SHORT_DIR \
      GIT_GUARD_EXPIRE_DAYS VDX_FOCUSED VDX_INTERCOM VDX_HQ CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_GUARD_SYNC_CHECK=off

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="${GIT_GUARD_PREPARE:-$REPO_ROOT/plugins/vdm-git/bin/git-guard-prepare}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"      got: ${2:0:300}" ;; esac; }
says_not() {
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gglife)
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR"
STATE="$HOME/.local/state/vdm-git"

# repo <dir> — a fresh repository with one staged file and no commit.
repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'x\n' > "$1/a.txt"
  git -C "$1" add a.txt
}
# prep <dir> <session> <args…> — the printed line, stderr discarded.
prep() { local d="$1" s="$2"; shift 2; ( cd "$d" && CLAUDE_CODE_SESSION_ID="$s" "$PREP" "$@" 2>/dev/null ); }
# opening <line> — the line's opening check alone, cut before the rest; run, it
# prints what a dead line prints and fails, or succeeds for a live one.
opening() {
  local l="$1" cut="${1%%false; \} &&*}"
  # A line the pattern does not cut would run whole, `git commit` included.
  [ "$cut" != "$l" ] && [ -n "$cut" ] || { echo "opening: the check was not cut off — nothing run"; return 99; }
  sh -c "${cut}false; }" 2>&1
}
# backdate <days> <file>… — move mtime and atime into the past.
backdate() { local d="$1"; shift; python3 -c 'import os,sys,time
t = time.time() - int(sys.argv[1]) * 86400
for f in sys.argv[2:]: os.utime(f, (t, t))' "$d" "$@"; }
mode_of() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }

echo "== where the files live (DL #1) =="
R="$TMP/r1"; repo "$R"
line="$(prep "$R" s1 "[*] first")"
says "a prep still prints its line" "$line" "git commit -F"
eq "RED: the message file is under the state directory, in the session's scope" \
  "$(ls "$STATE/s1/"*.txt 2>/dev/null | grep -c .)" "1"
says "RED: …and the line points there" "$line" "$STATE/s1/"
eq "RED: nothing goes to TMPDIR" "$(find "$TMPDIR" -type f | grep -c .)" "0"
eq "RED: the state directory is the user's alone (700)" "$(mode_of "$STATE")" "700"
eq "…and so is the session's scope" "$(mode_of "$STATE/s1")" "700"
short="$(cd "$R" && CLAUDE_CODE_SESSION_ID=s1 "$PREP" --pending 2>/dev/null | head -n 1)"
says "RED: the short call lives beside the scopes" "$short" "sh $STATE/sh/"
out="$(opening "$line")"; rc=$?
eq "a live line's opening check passes" "$rc" "0"

R2="$TMP/r2"; repo "$R2"
line2="$( cd "$R2" && XDG_STATE_HOME="$TMP/xdg" CLAUDE_CODE_SESSION_ID=s9 "$PREP" "[*] xdg" 2>/dev/null )"
says "XDG_STATE_HOME moves it" "$line2" "$TMP/xdg/vdm-git/s9/"
line3="$( cd "$R2" && GIT_GUARD_STATE_DIR="$TMP/own" CLAUDE_CODE_SESSION_ID=s9 "$PREP" "[*] own" 2>/dev/null )"
says "GIT_GUARD_STATE_DIR moves it" "$line3" "$TMP/own/s9/"
line4="$( cd "$R2" && GIT_GUARD_STATE_DIR="$TMP/nosess" "$PREP" "[*] no session" 2>/dev/null )"
says "without a session id the scope is the state directory itself" "$line4" "-F '$TMP/nosess/r2-"

echo "== a line that dies says why (DL #2) =="
old_short="${short#sh }"
new="$(prep "$R" s1 --supersede "[*] second")"
says "a superseding prep prints the new line" "$new" "git commit -F"
out="$(opening "$line")"; rc=$?
eq "the replaced line fails at its opening check" "$rc" "1"
says "RED: …saying it was replaced" "$out" "this line is void — replaced by a newer line"
out="$(sh "$old_short" 2>&1)"; rc=$?
eq "RED: its short call fails too, not with 'No such file'" "$rc" "1"
says "RED: …with the same reason" "$out" "replaced by a newer line"
eq "…and runs nothing else: no git command, no cd in the stub" "$(grep -cE 'git (commit|diff)|^cd ' "$old_short")" "0"
out="$(opening "$new")"; rc=$?
eq "the new line is live" "$rc" "0"

echo "== deleted outside git-guard (DL #2, #4) =="
rm -f "$STATE/s1/"*.txt
out="$(opening "$new")"; rc=$?
eq "a line whose message file someone deleted fails" "$rc" "1"
says "RED: …and says the file went outside git-guard" "$out" "its message file was deleted outside git-guard"
out="$(cd "$R" && CLAUDE_CODE_SESSION_ID=s1 "$PREP" --pending 2>/dev/null)"; rc=$?
eq "RED: --pending names the lost line with exit 4" "$rc" "4"
says "…and why it is lost" "$out" "deleted outside git-guard"
third="$(prep "$R" s1 "[*] third")"; rc=$?
says "RED: a new prep needs no --supersede over a lost line" "$third" "git commit -F"
out="$(opening "$new")"
says "…and the lost line keeps saying why" "$out" "deleted outside git-guard"
out="$(cd "$R" && CLAUDE_CODE_SESSION_ID=s1 "$PREP" --pending 2>/dev/null)"; rc=$?
eq "…while --pending is back to the waiting line" "$rc" "0"

echo "== the helper cleans what the OS cleaned (DL #3) =="
RO="$TMP/r-old"; repo "$RO"
oline="$(prep "$RO" s-old "[*] long forgotten")"
oshort="$(cd "$RO" && CLAUDE_CODE_SESSION_ID=s-old "$PREP" --pending 2>/dev/null | head -n 1)"; oshort="${oshort#sh }"
backdate 40 "$STATE/s-old/"* "$oshort"
mkdir -p "$STATE/s-gone"; printf 'old\n' > "$STATE/s-gone/r-commit-1-2.gone"; backdate 40 "$STATE/s-gone/r-commit-1-2.gone"
RF="$TMP/r-fresh"; repo "$RF"
fline="$(prep "$RF" s-fresh "[*] fresh, another session")"
prep "$R" s1 --supersede "[*] fourth" >/dev/null
out="$(opening "$oline")"; rc=$?
eq "RED: another session's line unused for 40 days is retired" "$rc" "1"
says "RED: …and says it expired" "$out" "expired: unused for 30 days"
says "…its short call says the same" "$(sh "$oshort" 2>&1)" "expired"
out="$(opening "$fline")"; rc=$?
eq "RED: another session's fresh line is not touched" "$rc" "0"
[ -d "$STATE/s-gone" ] && bad "RED: an old record of a death goes, and its empty scope with it" "$(ls "$STATE/s-gone")" \
  || ok "RED: an old record of a death goes, and its empty scope with it"
backdate 40 "$STATE/s1/"*.meta "$STATE/s1/"*.txt
( cd "$RF" && CLAUDE_CODE_SESSION_ID=s-fresh "$PREP" --supersede "[*] fresh again" >/dev/null 2>&1 )
out="$(cd "$R" && CLAUDE_CODE_SESSION_ID=s1 "$PREP" --pending 2>/dev/null)"; rc=$?
eq "…a session's own old line is retired only by another session's prep" "$rc" "1"

printf '\ngit-guard-line-lifetime: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
