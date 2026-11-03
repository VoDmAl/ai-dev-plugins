#!/bin/bash
# hq-session.test.sh — is a live HQ session of this project on this machine?
#
# The promise (crystal hq-session-quiet, DL #1): an ordinary session goes quiet
# only for a session that is really alive, really started with the flag and really
# of its project; a mode of its own keeps its own rules; and the question is cheap
# enough to ask at every hook. What each hook does with the answer is tested in that
# hook's own suite: crystal-hydrate, memory-scope, comms, intercom.
#
# No commit anywhere: the fixtures are `git init` and plain files under an isolated
# HOME.
#
# Run: bash tests/hq-session.test.sh   (exit 0 = all pass)

set -u

# The session running this suite must not reach the fixtures (the canonical block:
# tests/gates-harness-isolation.test.sh says why each name is here).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM VDX_HQ CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR 2>/dev/null || true

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${HQ_SESSION_LIB:-$REPO_ROOT/plugins/vdm/lib/hq-session.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t hqsession)
TMP="$(cd "$TMP" && pwd -P)"
# Unix socket paths are capped near 104 bytes on macOS — keep them short.
SOCKS="$(mktemp -d /tmp/hqsock.XXXXXX)"
PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$TMP" "$SOCKS"' EXIT
export HOME="$TMP/home"
SESS="$HOME/.claude/sessions"

# sleeper [VAR=1]… — a process with that environment, in SLEEPER; python, because
# macOS hides a platform binary's environment (`sleep`). Waits until it has exec'd.
sleeper() {
  env "$@" python3 -c 'import time; time.sleep(300)' & SLEEPER=$!
  disown "$SLEEPER" 2>/dev/null || true
  PIDS="$PIDS $SLEEPER"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    { [ -r "/proc/$SLEEPER/environ" ] || ps -wwE -p "$SLEEPER" -o command= 2>/dev/null | grep -q 'time.sleep'; } && break
    python3 -c 'import time; time.sleep(0.2)'
  done
}
mksock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
# mksess <file> <pid> <cwd> [<sessionId>] — the session file, as the harness writes it
mksess() {
  mkdir -p "$SESS"
  [ -S "$SOCKS/$1.sock" ] || mksock "$SOCKS/$1.sock"
  jq -n --argjson pid "$2" --arg cwd "$3" --arg sock "$SOCKS/$1.sock" --arg sid "${4:-sid-$1}" \
    '{pid:$pid, sessionId:$sid, cwd:$cwd, name:"n", kind:"interactive", status:"idle",
      messagingSocketPath:$sock, peerProtocol:1}' > "$SESS/$1.json"
}
clear_sessions() { rm -f "$SESS"/*.json; }
live_in()  { ( cd "$1" && vdm_hq_live ) && echo live || echo none; }
quiet_in() { ( cd "$1" && vdm_hq_quiet ) && echo quiet || echo loud; }

R="$TMP/proj"; mkdir -p "$R/sub"; git -C "$R" init -q
sleeper VDX_HQ=1; HQ="$SLEEPER"
sleeper; PLAIN="$SLEEPER"

echo "== nothing to find =="
eq "no session files at all" "$(live_in "$R")" none
mkdir -p "$SESS"
eq "an empty directory of them" "$(live_in "$R")" none
mksess plain "$PLAIN" "$R"
eq "RED: an ordinary session of the project is not an HQ session" "$(live_in "$R")" none

echo "== found =="
mksess hq "$HQ" "$R"
eq "RED: a session started with the flag, in the project" "$(live_in "$R")" live
eq "…from a subdirectory of the project too" "$(live_in "$R/sub")" live
eq "…and when the hook is told the project by CLAUDE_PROJECT_DIR" "$(cd "$TMP" && CLAUDE_PROJECT_DIR="$R/sub" vdm_hq_live && echo live || echo none)" live
mksess hq "$HQ" "$R/sub"
eq "…and with the HQ session itself in a subdirectory" "$(live_in "$R")" live

echo "== the mode of this session decides who goes quiet =="
mksess hq "$HQ" "$R"
eq "RED: an ordinary session goes quiet" "$(quiet_in "$R")" quiet
eq "RED: an HQ session gets everything" "$(VDX_HQ=1 quiet_in "$R")" loud
eq "RED: a focused one too (DL #6)" "$(VDX_FOCUSED=1 quiet_in "$R")" quiet
eq "…started focused and with the HQ flag, it is a focused one" "$(VDX_FOCUSED=1 VDX_HQ=1 quiet_in "$R")" quiet
eq "…and an intercom one" "$(VDX_INTERCOM=1 quiet_in "$R")" loud

echo "== not of this project =="
O="$TMP/other"; mkdir -p "$O"; git -C "$O" init -q
clear_sessions; mksess hq "$HQ" "$O"
eq "RED: another project's HQ session" "$(live_in "$R")" none
eq "…is that project's" "$(live_in "$O")" live
P="${R}-2"; mkdir -p "$P"; git -C "$P" init -q
clear_sessions; mksess hq "$HQ" "$P"
eq "RED: a project whose name only starts like this one" "$(live_in "$R")" none
N="$R/nested"; mkdir -p "$N"; git -C "$N" init -q
clear_sessions; mksess hq "$HQ" "$N"
eq "RED: a repository of its own nested in this one" "$(live_in "$R")" none
clear_sessions; mksess hq "$HQ" "$HOME"
eq "RED: \$HOME is not a project" "$(cd "$HOME" && vdm_hq_live && echo live || echo none)" none

echo "== not alive, or not the flag =="
clear_sessions; mksess hq "$HQ" "$R"
mv "$SESS/hq.json" "$SESS/hq.sync-conflict-20261103-120000-abcdefg.json"
eq "RED: Syncthing's copy of a session file is no session" "$(live_in "$R")" none
clear_sessions; mksess hq "$HQ" "$R"
rm -f "$SOCKS/hq.sock"
eq "RED: no socket, no session" "$(live_in "$R")" none
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null
clear_sessions; mksess gone "$DEAD" "$R"
eq "a pid that answers nothing" "$(live_in "$R")" none
sleeper VDX_HQ=1 VDX_FOCUSED=1; BOTH="$SLEEPER"
clear_sessions; mksess both "$BOTH" "$R"
eq "RED: started with the flag and focused — it is a focused one" "$(live_in "$R")" none
sleeper VDX_HQ=1 VDX_INTERCOM=1; BOTH="$SLEEPER"
clear_sessions; mksess both2 "$BOTH" "$R"
eq "…and with the flag and intercom — an intercom one" "$(live_in "$R")" none
sleeper VDX_HQ=0; ZERO="$SLEEPER"
clear_sessions; mksess zero "$ZERO" "$R"
eq "…the flag set to anything but 1 is not the flag" "$(live_in "$R")" none
clear_sessions; mksess hq "$HQ" "$R" sid-of-this-one
eq "RED: this session is not its own HQ session" "$(CLAUDE_CODE_SESSION_ID=sid-of-this-one live_in "$R")" none

echo "== it may close in the middle of a working session =="
sleeper VDX_HQ=1; SHORT="$SLEEPER"
clear_sessions; mksess short "$SHORT" "$R"
eq "alive: quiet" "$(quiet_in "$R")" quiet
kill "$SHORT" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SHORT" 2>/dev/null || break; python3 -c 'import time; time.sleep(0.2)'; done
eq "RED: closed: the very next question says so, with nothing to clean up" "$(quiet_in "$R")" loud
eq "RED: …a focused session too: with no HQ session it is the only reader left" "$(VDX_FOCUSED=1 quiet_in "$R")" loud

echo "== it fails open =="
FARM="$TMP/farm"; mkdir -p "$FARM"
for t in git grep awk ps tr cat dirname; do ln -s "$(type -P "$t")" "$FARM/$t"; done
clear_sessions; mksess hq "$HQ" "$R"
eq "without jq nothing says quiet" "$(cd "$R" && PATH="$FARM" vdm_hq_quiet && echo quiet || echo loud)" loud

echo "== the cost: launches, not wall-clock (the machine runs at load 40–70) =="
SHIM="$TMP/shim"; COUNT="$TMP/count"; mkdir -p "$SHIM"
for t in ps jq git grep; do
  printf '#!/bin/bash\necho %s >> "%s"\nexec "%s" "$@"\n' "$t" "$COUNT" "$(type -P "$t")" > "$SHIM/$t"
  chmod +x "$SHIM/$t"
done
launches() { : > "$COUNT"; ( cd "$R" && PATH="$SHIM:$PATH" CLAUDE_CODE_SESSION_ID="${2:-}" vdm_hq_live ) >/dev/null 2>&1; grep -c "^$1\$" "$COUNT"; }
clear_sessions
sleeper; FAR="$SLEEPER"
for i in 1 2 3 4 5; do mksess "far$i" "$FAR" "$O"; done
eq "RED: sessions of other projects cost no jq" "$(launches jq)" 0
eq "…and no ps" "$(launches ps)" 0
mksess me "$PLAIN" "$R" sid-me
eq "RED: this session alone in its project: no ps at all (5–8 ms each, 0.7 s for all)" "$(launches ps sid-me)" 0
eq "…one jq, for its own file" "$(launches jq sid-me)" 1
eq "…one git, one grep" "$(launches git sid-me)$(launches grep sid-me)" 11
mksess gone "$DEAD" "$R"
eq "RED: a session file left by a closed session costs no ps either" "$(launches ps sid-me)" 0
rm -f "$SESS/gone.json"
mksess other1 "$PLAIN" "$R"; mksess other2 "$FAR" "$R"
eq "RED: two other sessions of the project: one ps, not two" "$(launches ps sid-me)" 1

printf '\nhq-session: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
