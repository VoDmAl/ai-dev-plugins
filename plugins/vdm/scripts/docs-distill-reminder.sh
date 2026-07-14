#!/bin/bash
# docs-distill-reminder.sh — UserPromptSubmit hook. The synthesis-layer signal.
#
# Fragments accumulate on their own; synthesis has to be rebuilt, and nothing
# rebuilds it because nobody asks. At lime-analytics the forcing function was a
# HUMAN noticing ("wtf, why are there no results anywhere") — see DL #8 in
# docs/tasks/docs-distill/workitem.md. This hook is that human, mechanized.
#
# Signal: a synthesis document is older than the inputs it declares it covers
# (DL #4 — the same "sources newer than the artifact" comparison that
# crystal-capture-reminder already makes, aimed at a different pair of files).
#
# Why this and NOT "before completing a task": docs-sync already owns that
# instant, and it is the WRONG instant for synthesis — too late to distill
# on the fly (DL #10). Drift is a STATE, not a moment: it exists continuously
# from the edit that caused it until the rebuild that clears it. So the two
# skills never contend for the same second.
#
# Silent when the project has no synthesis tier at all. That is deliberate: the
# suite dictates the relation, not the artifact (DL #5), so we do not nag a
# project into a tier it never declared. The tier gets BORN through the
# crystal-cut handoff instead, which fires whether or not one exists.
#
# Modes (vdm-plugins.json → distill.mode):
#   silent     — never fires
#   smart      — fires on drift, throttled per session. Default.
#   proactive  — fires on drift every prompt, no throttle.
#
# Budget: <5s. Fails open everywhere — a broken hook must never block work.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$HERE/../lib/config-read.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$HERE/../lib/reminder-throttle.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "distill" || exit 0
fi

payload=""
payload=$(cat 2>/dev/null || true)

mode=$(vdm_config_read "distill" "mode" "smart")
[ "$mode" = "silent" ] && exit 0

# The scan is the single source of truth for what counts as drift — the hook
# must not re-derive the algorithm (same discipline as check-llm-orphans.sh).
drift=$(bash "$HERE/distill-scan.sh" --drift 2>/dev/null)
[ -z "$drift" ] && exit 0

if [ "$mode" = "smart" ] && command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
  sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
  throttle=$(vdm_config_read "distill" "throttle" "1800")
  if _vdm_reminder_throttle_check "docs-distill" "$throttle" "$sid"; then
    exit 0
  fi
  _vdm_reminder_throttle_touch "docs-distill" "$sid"
fi

# Render. Name the drifted documents and one example input each — a reminder
# that says "something is stale" without saying WHAT costs the assistant a
# re-scan and gets ignored by the third occurrence.
body=""
doc=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "  ← "*)
      [ -n "$doc" ] || continue
      body="${body}\\n    ${line#  }"
      ;;
    *)
      doc="$line"
      body="${body}\\n  • ${doc} — отстал от того, что покрывает:"
      ;;
  esac
done <<<"$drift"

[ -n "$body" ] || exit 0

ctx="[docs-distill] Слой синтеза отстал от входов."
ctx="${ctx}${body}"
ctx="${ctx}\\nСинтез не дописывают — его ПЕРЕСОБИРАЮТ. Фрагменты копятся сами; сводное «как оно устроено сейчас» — нет."
ctx="${ctx}\\n→ /vdm:docs-distill — пересобрать и обновить \`observed:\`. Упрётесь в незадокументированную фичу → сначала /vdm:docs-sync."

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$ctx"
exit 0
