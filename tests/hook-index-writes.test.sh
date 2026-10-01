#!/bin/bash
# hook-index-writes.test.sh — no shipped hook rewrites .git/index.
#
# The finding (vdx, 2026-09-30, brief `hooks-no-optional-locks`). `git status`
# refreshes the stat data it keeps in the index and WRITES the index back when
# it can take the lock (git-status(1), BACKGROUND REFRESH). Three reminders ran
# it on every prompt, and git-guard's PreToolUse ran it on every blocked commit.
# The owner's repositories travel between machines with Syncthing, `.git`
# included, and he works in one repo from two machines at once: a hook that
# writes the index while the other machine commits leaves an
# `index.sync-conflict-*` copy and a live index that lost an update. vdx saw
# exactly that twice on 30.09 — indirectly: the writes matched the owner's
# prompts in time, the hooks were suspected, not caught.
#
# What a hook may use, measured on git 2.54.0 against a stat-dirty file:
#
#   git status                         writes
#   git --no-optional-locks status     no write      GIT_OPTIONAL_LOCKS=0 — same
#   git diff        (index ↔ worktree) writes, EVEN with GIT_OPTIONAL_LOCKS=0
#   git describe --dirty               writes, EVEN with GIT_OPTIONAL_LOCKS=0
#   git diff <rev>, git diff --cached, diff-files, ls-files, rev-parse, log
#                                      no write
#
# So the guard is `export GIT_OPTIONAL_LOCKS=0` in each script that reads git
# (for python, in the env handed to the subprocess) — and it does NOT cover
# `git diff` without a revision. Written where the call is, not in the
# dispatcher that happens to run it today: a script run standalone, or moved to
# another caller, keeps its guard.
#
# GREEN: every registered hook of every plugin, with the payloads
#   tests/hook-commands.test.sh uses (a PreToolUse `git commit` among them), is
#   run in a fixture whose tracked file has just had its mtime changed. The
#   index checksum must not change. Rule, not list: a new hook is covered the
#   day it is registered.
# CONTROL: on the same step a plain `git status` does change it — otherwise the
#   fixture could not see a write and GREEN would prove nothing.
# RED: for each script that carries the guard, a copy with the guard line cut
#   out must make at least one hook of its plugin write. A guard no hook reaches
#   is a guard this file cannot vouch for — that is the red it reports.
#
# Run: bash tests/hook-index-writes.test.sh   (exit 0 = all pass)

set -u

# Scrub the inherited git session — see tests/gates.test.sh. The fixture below
# runs `git add`, and as a child of a live `git commit` it would land in THAT
# commit's index. GIT_OPTIONAL_LOCKS too: inherited, it would hide every write.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_OPTIONAL_LOCKS 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

command -v jq >/dev/null 2>&1 || { echo "hook-index-writes: jq is required to read hooks.json" >&2; exit 1; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t hookindex)
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
mkdir -p "$PROJ"
# No commit: git-guard's hook refuses `git commit` in any repository, this
# fixture's included, and an index is all a refresh needs.
( cd "$PROJ" && git init -q && printf 'a\n' > f && git add f ) >/dev/null 2>&1

# Each step gives f a new mtime, so the index entry is stale again and a
# refreshing read has something to write. Checksums, not mtimes: no sleeps, and
# no dependence on the filesystem's timestamp granularity.
STEP=0
dirty() {
  STEP=$((STEP+1))
  touch -t "$(printf '2020010100%02d.%02d' $((STEP / 60 % 60)) $((STEP % 60)))" "$PROJ/f"
}
sum() { cksum < "$PROJ/.git/index"; }

payloads() {
  case "$1" in
    SessionStart)
      printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"t","cwd":"%s"}\n' "$PROJ" ;;
    UserPromptSubmit)
      printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"t","cwd":"%s"}\n' "$PROJ" ;;
    PreToolUse)
      printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"t","cwd":"%s"}\n' "$PROJ"
      printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"t","cwd":"%s"}\n' "$PROJ" ;;
    PostToolUse)
      printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s/notes.md","content":"x"},"session_id":"t","cwd":"%s"}\n' "$PROJ" "$PROJ" ;;
    *)
      printf '{"hook_event_name":"%s","session_id":"t","cwd":"%s"}\n' "$1" "$PROJ" ;;
  esac
}

# run_hook <plugin-root> <command-string> <payload> → WROTE=1 when the index changed.
run_hook() {
  local root=$1 cmd=$2 payload=$3 before
  rm -rf "$TMP/home" "$TMP/tmpdir"; mkdir -p "$TMP/home" "$TMP/tmpdir"
  dirty
  before=$(sum)
  ( cd "$PROJ" && printf '%s' "$payload" |
      HOME="$TMP/home" TMPDIR="$TMP/tmpdir" CLAUDE_PROJECT_DIR="$PROJ" \
      CLAUDE_CODE_SESSION_ID=t CLAUDE_PLUGIN_ROOT="$root" \
      /bin/sh -c "$cmd" >/dev/null 2>&1 )
  if [ "$(sum)" = "$before" ]; then WROTE=0; else WROTE=1; fi
}

# for_each_hook <plugin> <callback> — callback gets: event, command, payload.
for_each_hook() {
  local p=$1 cb=$2 ev cmd payload
  while IFS=$'\t' read -r ev cmd; do
    while IFS= read -r payload; do
      "$cb" "$ev" "$cmd" "$payload" || return 0
    done < <(payloads "$ev")
  done < <(jq -r '.hooks | to_entries[] | .key as $ev | .value[].hooks[] | [$ev, .command] | @tsv' \
             "$REPO_ROOT/plugins/$p/hooks/hooks.json")
}

plugins=()
for hj in "$REPO_ROOT"/plugins/*/hooks/hooks.json; do
  [ -f "$hj" ] || continue
  plugins+=("$(basename "$(dirname "$(dirname "$hj")")")")
done
[ "${#plugins[@]}" -gt 0 ] || { echo "hook-index-writes: no plugins/*/hooks/hooks.json found" >&2; exit 1; }

# ---------------------------------------------------------------------------
printf '\ncontrol: the fixture sees a write\n'
# ---------------------------------------------------------------------------
dirty; b=$(sum); ( cd "$PROJ" && git status --porcelain >/dev/null 2>&1 )
if [ "$(sum)" != "$b" ]; then ok "a plain git status rewrites the index here"
else bad "a plain git status rewrites the index here" "it did not — nothing below can see a write"; fi
dirty; b=$(sum); ( cd "$PROJ" && git --no-optional-locks status --porcelain >/dev/null 2>&1 )
if [ "$(sum)" = "$b" ]; then ok "…and git --no-optional-locks status does not"
else bad "…and git --no-optional-locks status does not"; fi

# ---------------------------------------------------------------------------
printf '\nGREEN: no registered hook writes the index\n'
# ---------------------------------------------------------------------------
# Plugins are copied so that nothing a hook drops next to itself (a python
# bytecode cache) lands in the working tree.
mkdir -p "$TMP/plugins"
for p in "${plugins[@]}"; do cp -R "$REPO_ROOT/plugins/$p" "$TMP/plugins/$p"; done

green_one() {
  local label="$CUR $1: $2"
  case "$3" in *'git commit'*) label="$label (git commit)" ;; esac
  run_hook "$TMP/plugins/$CUR" "$2" "$3"
  if [ "$WROTE" = 0 ]; then ok "$label"; else bad "$label" "the index changed"; fi
}
for p in "${plugins[@]}"; do
  echo "── $p"
  CUR=$p
  for_each_hook "$p" green_one
done

# ---------------------------------------------------------------------------
printf '\nRED: each guard is one some hook depends on\n'
# ---------------------------------------------------------------------------
red_one() {
  run_hook "$TMP/red/$CUR" "$2" "$3"
  [ "$WROTE" = 1 ] && { RED_HIT="$1: $2"; return 1; }
  return 0
}
for p in "${plugins[@]}"; do
  while IFS= read -r f; do
    rel=${f#"$REPO_ROOT/plugins/$p/"}
    rm -rf "$TMP/red"; mkdir -p "$TMP/red"; cp -R "$REPO_ROOT/plugins/$p" "$TMP/red/$p"
    grep -v 'GIT_OPTIONAL_LOCKS' "$f" > "$TMP/red/$p/$rel"
    CUR=$p; RED_HIT=""
    for_each_hook "$p" red_one
    if [ -n "$RED_HIT" ]; then ok "$p/$rel without its guard → a hook writes ($RED_HIT)"
    else bad "$p/$rel without its guard → a hook writes" "no hook of $p wrote — the guard is unreached or the fixture misses it"; fi
  # Text files only: a neighbouring suite that runs a python hook in place
  # leaves a bytecode cache holding the same name (found 2026-09-30 in the
  # pre-commit, where suites run side by side).
  done < <(grep -rlI --exclude-dir=__pycache__ 'GIT_OPTIONAL_LOCKS' \
             "$REPO_ROOT/plugins/$p/scripts" "$REPO_ROOT/plugins/$p/lib" 2>/dev/null | sort)
done

echo
echo "hook-index-writes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
