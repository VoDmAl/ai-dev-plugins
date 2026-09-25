#!/bin/bash
# hook-commands.test.sh — RED TESTS for the hook command strings themselves:
# every `command` in every plugins/*/hooks/hooks.json, run the way the harness
# runs it, from a plugin root whose path contains a space.
#
# The incident (field report from echelon, 2026-09-25). The harness puts the
# plugin root into the command string and hands it to `/bin/sh -c`. Written
# unquoted, `${CLAUDE_PLUGIN_ROOT}/scripts/x.sh` is split by sh at the space,
# and the hook dies with `/bin/sh: /Users/…/AI: No such file or directory`,
# exit 127. Measured here the same day: all 15 commands of the three plugins,
# in both substitution modes below. Invisible from the marketplace, whose cache
# path has no space; live the moment a plugin is installed from a working
# clone under `~/AI Projects/`, which is how echelon found it.
#
# Worse than a noisy banner: the harness blocks only on exit 2, so a blocking
# hook that cannot START is simply off. git-guard, crystal-completion-guard and
# comms-draft-guard all went silently open. Nothing inside a script can help —
# gate-guard's fail-closed law applies to a script that runs, and this one
# never does — so the fix lives in the command string: the root is quoted.
#
# Why a real run and not a grep for quotes. A direct call of the script
# (`bash "$root/scripts/x.sh"`) bypasses exactly the shell parse that breaks,
# and a grep for `"\"${CLAUDE_PLUGIN_ROOT}` states a form, not the property.
# The property is: WHERE the plugin lives must not change what its hooks do.
# So each command is run from two roots — one plain, one with a space — and:
#
#   ABSOLUTE      the spaced run exits neither 126 nor 127 and its stderr holds
#                 no shell-level "not found" — the hook actually started;
#   DIFFERENTIAL  its exit code and output equal the plain run's, with the
#                 root path normalised out;
#   BEHAVIOUR     git-guard still BLOCKS (exit 2) a `git commit` from the
#                 spaced root. Agreement alone is not enough: two runs that
#                 both fail the same way agree perfectly.
#
# Two substitution modes, because which one the harness uses is its business,
# and a quoted command survives both:
#   text  the root is pasted into the command string
#   env   CLAUDE_PLUGIN_ROOT is exported and sh expands it
#
# The plugins are discovered, never enumerated — the lesson of pre-commit
# gate 7, whose list of plugins went on passing while a third plugin's hooks
# were covered by nothing.
#
# Run: bash tests/hook-commands.test.sh   (exit 0 = all pass)
#
# @see .githooks/pre-commit — gate 7, which runs this suite on any hook change

set -u

# Scrub git's per-invocation environment before anything else — see
# tests/gates.test.sh. This suite builds a git fixture and is run from inside a
# live `git commit` by gate 7.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

command -v jq >/dev/null 2>&1 || { echo "hook-commands: jq is required to read hooks.json" >&2; exit 1; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t hookcmds)
trap 'rm -rf "$TMP"' EXIT

PLAIN="$TMP/plain"
SPACED="$TMP/AI Projects"
PROJ="$TMP/proj"
mkdir -p "$PLAIN" "$SPACED" "$PROJ"

plugins=()
for hj in "$REPO_ROOT"/plugins/*/hooks/hooks.json; do
  [ -f "$hj" ] || continue
  p=$(basename "$(dirname "$(dirname "$hj")")")
  plugins+=("$p")
  cp -R "$REPO_ROOT/plugins/$p" "$PLAIN/$p"
  cp -R "$REPO_ROOT/plugins/$p" "$SPACED/$p"
done
[ "${#plugins[@]}" -gt 0 ] || { echo "hook-commands: no plugins/*/hooks/hooks.json found" >&2; exit 1; }

( cd "$PROJ" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

# payloads <event> — one payload per line. PreToolUse gets an out-of-scope call
# AND a commit, so a blocking hook is exercised on both sides of its scope.
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

# run_hook <root> <command> <mode> <payload> — sets RC, OUT, ERR, with the root
# normalised to <ROOT>. HOME and TMPDIR are fresh per run: a hook's throttle
# window or intercom registration from the previous run would otherwise make
# the second run differ for reasons that have nothing to do with the path.
run_hook() {
  local root=$1 cmd=$2 mode=$3 payload=$4 c
  if [ "$mode" = text ]; then c="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"; else c="$cmd"; fi
  rm -rf "$TMP/home" "$TMP/tmpdir"; mkdir -p "$TMP/home" "$TMP/tmpdir"
  ( cd "$PROJ" && printf '%s' "$payload" |
      HOME="$TMP/home" TMPDIR="$TMP/tmpdir" CLAUDE_PROJECT_DIR="$PROJ" \
      CLAUDE_CODE_SESSION_ID=t CLAUDE_PLUGIN_ROOT="$root" \
      /bin/sh -c "$c" >"$TMP/out" 2>"$TMP/err" )
  RC=$?
  OUT=$(sed "s#$root#<ROOT>#g" "$TMP/out")
  ERR=$(sed "s#$root#<ROOT>#g" "$TMP/err")
}

for p in "${plugins[@]}"; do
  echo "── $p"
  while IFS=$'\t' read -r ev cmd; do
    while IFS= read -r payload; do
      label="$p $ev: $cmd"
      case "$payload" in *'git commit'*) label="$label (git commit)" ;; esac

      run_hook "$PLAIN/$p" "$cmd" env "$payload"
      base_rc=$RC; base_out=$OUT; base_err=$ERR

      for mode in text env; do
        run_hook "$SPACED/$p" "$cmd" "$mode" "$payload"
        if [ "$RC" = 126 ] || [ "$RC" = 127 ] ||
           printf '%s' "$ERR" | grep -qE 'No such file or directory|is a directory|command not found'; then
          bad "$label [$mode] starts from a root with a space" \
              "exit $RC: $(printf '%s' "$ERR" | head -1)"
          continue
        fi
        if [ "$RC" = "$base_rc" ] && [ "$OUT" = "$base_out" ] && [ "$ERR" = "$base_err" ]; then
          ok "$label [$mode] behaves as from a plain root"
        else
          bad "$label [$mode] behaves as from a plain root" \
              "exit $RC vs $base_rc; stdout/stderr $( [ "$OUT$ERR" = "$base_out$base_err" ] && echo equal || echo differ)"
        fi
      done
    done < <(payloads "$ev")
  done < <(jq -r '.hooks | to_entries[] | .key as $ev | .value[] | .hooks[] | select(.type == "command") | [$ev, .command] | @tsv' \
             "$REPO_ROOT/plugins/$p/hooks/hooks.json")
done

# BEHAVIOUR — the absolute value behind the agreement above. Found by a
# jq query rather than by name of file, so a renamed guard is still found; the
# suite fails if it is not found at all.
echo "── blocking still blocks"
gg_cmd=$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | .command | select(test("git-guard-hook"))][0] // empty' \
           "$REPO_ROOT/plugins/vdm-git/hooks/hooks.json" 2>/dev/null)
if [ -z "$gg_cmd" ]; then
  bad "git-guard PreToolUse command is present in vdm-git/hooks/hooks.json"
else
  commit_payload=$(payloads PreToolUse | grep 'git commit')
  for mode in text env; do
    run_hook "$SPACED/vdm-git" "$gg_cmd" "$mode" "$commit_payload"
    if [ "$RC" = 2 ]; then
      ok "git-guard blocks \`git commit\` from a root with a space [$mode]"
    else
      bad "git-guard blocks \`git commit\` from a root with a space [$mode]" "exit $RC, expected 2"
    fi
  done
fi

echo
echo "hook-commands: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
