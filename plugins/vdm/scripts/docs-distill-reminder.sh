#!/bin/bash
# docs-distill-reminder.sh — UserPromptSubmit hook. The synthesis-layer signal.
#
# Fragments accumulate on their own; synthesis has to be rebuilt, and nothing
# rebuilds it because nobody asks. At executor the forcing function was a
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
# The text below carries file names, and without the escaper there is no safe
# way to put a name into JSON — so no escaper, no reminder. Silence is this
# hook's legal failure; an unparseable text would take the turn's other
# reminders down with it.
# shellcheck disable=SC1091
. "$HERE/../lib/reminder-emit.sh" 2>/dev/null || exit 0

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "distill" || exit 0
fi

payload=""
payload=$(cat 2>/dev/null || true)

mode=$(vdm_config_read "distill" "mode" "smart")
[ "$mode" = "silent" ] && exit 0

# The window is asked BEFORE the scan. A closed window mutes whatever the scan
# would find, so scanning first only paid for an answer nobody would hear — on
# every prompt of the half hour after each reminder. Asking first changes no
# outcome: closed ⇒ silent either way; open ⇒ scan, and touch only on an emit,
# exactly as before. (The window is NOT touched on a quiet scan: drift that
# appears mid-session has to surface on the next prompt, not half an hour on.)
throttled=0
if [ "$mode" = "smart" ] && command -v _vdm_reminder_throttle_check >/dev/null 2>&1; then
  throttled=1
  sid=$(printf '%s' "$payload" | _vdm_reminder_session_id 2>/dev/null || printf 'default')
  throttle=$(vdm_config_read "distill" "throttle" "1800")
  if _vdm_reminder_throttle_check "docs-distill" "$throttle" "$sid"; then
    exit 0
  fi
fi

# The scan is the single source of truth for what counts as drift — the hook
# must not re-derive the algorithm (same discipline as check-doc-orphans.sh).
drift=$(bash "$HERE/distill-scan.sh" --drift 2>/dev/null)
[ -z "$drift" ] && exit 0

[ "$throttled" = 1 ] && _vdm_reminder_throttle_touch "docs-distill" "$sid"

# Render. Name the drifted documents and one example input each — a reminder
# that says "something is stale" without saying WHAT costs the assistant a
# re-scan and gets ignored by the third occurrence.
#
# Built as plain text with real line breaks and escaped once, as a whole. The
# names are real paths — the scanner reads git with -z — and a real name can
# hold a quote or a backslash; pasted raw, one such name broke the JSON, and the
# emitter's safety net then delivered the whole text escaped, under a notice
# that this reminder is defective. Escaping the finished text also leaves no
# second place where a line break has to be spelled `\n` by hand.
body=""
doc=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "  ← "*)
      [ -n "$doc" ] || continue
      body="${body}"$'\n'"    ${line#  }"
      ;;
    *)
      doc="$line"
      body="${body}"$'\n'"  • ${doc} — отстал от того, что покрывает:"
      ;;
  esac
done <<<"$drift"

[ -n "$body" ] || exit 0

ctx="[docs-distill] Слой синтеза отстал от входов.${body}"
ctx="${ctx}"$'\n'"Синтез не дописывают — его ПЕРЕСОБИРАЮТ. Фрагменты копятся сами; сводное «как оно устроено сейчас» — нет."
ctx="${ctx}"$'\n'"→ /vdm:docs-distill — пересобрать и обновить \`observed:\`. Упрётесь в незадокументированную фичу → сначала /vdm:docs-sync."

_vdm_reminder_emit docs-distill 1 \
  "docs-distill: a synthesis is behind its inputs → /vdm:docs-distill" "$(_vdm_json_escape "$ctx")"
exit 0
