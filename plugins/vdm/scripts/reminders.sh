#!/bin/bash
# reminders.sh — the ONE UserPromptSubmit registration of the vdm plugin.
#
# Until 2.32.0 the six vdm reminders were six independent registrations. The
# harness runs matching hooks in parallel, so none of them could see the others,
# and measured over every local transcript (2026-09-22) they never spoke alone:
# learn, changelog and docs-sync appeared in company 100% of the time, crystal
# 99.9%. In interactive sessions 48% of the turns on which anything spoke carried
# four or five blocks at once (3.6–4.6 KB), all in the same tone and none saying
# which one mattered. "Five reminders of equal weight are zero priorities."
#
# Only something that sees all of them can rank them, so this script runs the
# six as children and composes one section:
#
#   * nobody spoke           → silence
#   * exactly one spoke      → its own text, unchanged — never longer than before
#   * two or more spoke      → a one-line header, then every reminder that
#                              MEASURED something this turn (tier 1), in a fixed
#                              order, then the standing habit prompts (tier 2)
#                              folded into a single line
#
# Each child keeps everything that was its own: its mode, its trigger, its
# throttle, its config keys, and its direct JSON output when run by hand. It
# only learns, through VDM_REMINDER_FRAGMENT, to leave its text in a file
# instead of printing it — see lib/reminder-emit.sh.
#
# THE PRICE, named rather than hidden. One registration is one point of
# failure: if this script dies, all six go quiet together. That is acceptable
# for reminders and would not be for gates — the suite's own rule is that a
# reminder may fail open and a gate may not (docs/model/suite.md, the fourth
# limit), and silence IS a reminder's failure mode. What is NOT acceptable is
# the slowest child taking the others down with it, so the children run in
# parallel under a deadline shorter than this hook's own timeout: a child that
# is still walking the tree when the deadline passes is killed and the rest are
# delivered. Before, a slow crystal-capture lost only itself; after, it still
# loses only itself.
#
# Silent inside a plugin cache. 9 587 of 9 652 headless sessions on this machine
# were a third-party plugin's backend running `claude` with its own cache
# directory as the working directory; each received changelog + learn on its
# only turn, ~5.8 MB in total into somebody else's model calls. A plugin cache
# is never a project — the same reasoning as "$HOME is not a project" in
# intercom — and the throttle cannot help there, because every such session is
# a fresh session on its first turn.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every text this script prints comes from a child, and one malformed text used
# to make the whole section unparseable — the harness then dropped every
# reminder of the turn, not only the broken one (command-center, 2026-09-25).
# The children check their texts as they hand them over; this checks them again
# as they arrive, because a child killed by the watchdog mid-write can leave a
# fragment cut inside an escape. Without the lib the texts pass unchecked, as
# before — a reminder may fail open.
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/reminder-emit.sh" 2>/dev/null || {
  _vdm_reminder_text_guard() { printf '%s' "$2"; }
  _vdm_json_text_ok() { return 0; }
  _vdm_json_escape() { printf '%s' "$1"; }
}
CHILD_DIR="${VDM_REMINDERS_DIR:-$SELF_DIR}"
DEADLINE="${VDM_REMINDERS_DEADLINE:-25}"
case "$DEADLINE" in ''|*[!0-9]*) DEADLINE=25 ;; esac

# Tier-1 order is the order of consequence: a workitem losing its capture before
# the next compaction is lost for good; a synthesis behind its inputs, docs
# behind the code and unread mail are all recoverable later.
TIER1_ORDER="crystal-capture docs-distill docs-sync intercom"
TIER2_ORDER="changelog learn"

payload=$(cat 2>/dev/null || true)

project="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$project/" in
  */.claude/plugins/cache/*) exit 0 ;;
esac

work=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"

# The payload goes to the children from a file rather than through a pipe: each
# child is then this script's own direct child, and the pid in hand is the one
# to stop — no subshell in between whose children have to be hunted down.
printf '%s' "$payload" > "$work/payload"

pids=""
for name in $TIER1_ORDER $TIER2_ORDER; do
  child="$CHILD_DIR/$name-reminder.sh"
  [ -f "$child" ] || continue
  VDM_REMINDER_FRAGMENT="$work/out" bash "$child" <"$work/payload" >/dev/null 2>&1 &
  pids="$pids $!"
done

# Wait for the children, not for the clock. This used to poll — `$(jobs -rp)`
# and a `sleep 0.1` every tick — so a slow child cost the dispatcher a process
# per 100 ms on top of its own, and the prompt waited up to 100 ms after the
# last child had already finished. `wait` returns the moment the last one does.
# The deadline is ONE sleep in a watchdog that speaks only if it runs out: it
# interrupts the `wait` with USR1, and the stragglers are stopped here, from
# this shell's own job table — the one place that knows which pids are still
# its children. When the children finish first, the watchdog is stopped and
# takes its sleep with it. No children, no wait: a bare `wait` would wait for
# the watchdog too.
if [ -n "$pids" ]; then
  timed_out=0
  trap 'timed_out=1' USR1
  (
    s=""
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$DEADLINE" & s=$!
    wait "$s" && kill -USR1 $$
  ) >/dev/null 2>&1 &
  watchdog=$!
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null
  kill "$watchdog" 2>/dev/null
  if [ "$timed_out" = 1 ]; then
    for pid in $(jobs -rp); do kill "$pid" 2>/dev/null; done
  fi
fi

# Compose.
n=0
tier1=""
tier2=""
only_full=""
for name in $TIER1_ORDER $TIER2_ORDER; do
  f="$work/out/$name"
  [ -s "$f" ] || continue
  tier=$(sed -n '1p' "$f")
  short=$(sed -n '2p' "$f")
  full=$(sed -n '3,$p' "$f")
  [ -n "$full" ] || continue
  full=$(_vdm_reminder_text_guard "$name" "$full")
  _vdm_json_text_ok "$short" || short=$(_vdm_json_escape "$short")
  n=$((n + 1))
  only_full="$full"
  if [ "$tier" = "1" ]; then
    if [ -z "$tier1" ]; then tier1="$full"; else tier1="${tier1}\\n\\n${full}"; fi
  else
    if [ -z "$tier2" ]; then tier2="$short"; else tier2="${tier2} · ${short}"; fi
  fi
done

[ "$n" -gt 0 ] || exit 0

if [ "$n" -eq 1 ]; then
  ctx="$only_full"
else
  ctx="[vdm] ${n} reminders this turn — the ones that measured something first."
  [ -n "$tier1" ] && ctx="${ctx}\\n\\n${tier1}"
  [ -n "$tier2" ] && ctx="${ctx}\\n\\n· Standing habits: ${tier2}"
fi

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$ctx"
exit 0
