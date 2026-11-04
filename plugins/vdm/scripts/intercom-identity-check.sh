#!/bin/bash
# intercom-identity-check.sh — SessionStart hook: "who am I in the agent
# directory, and can the user's words for me actually reach me?"
#
# The story it closes: a sender asks "what is that repo's name — the directory
# (cc-vdm-plugins), the remote slug (ai-dev-plugins), or what the user says
# ('vdm', 'the intercom agent')?" — and a brief addressed to the wrong one lands
# in a fresh, never-read inbox. The registry can derive identity and aliases by
# itself; it cannot derive what the USER calls the project. So every session
# starts by (1) doing the mechanical registration deterministically, and (2)
# telling the assistant, in context, whether the human part is still missing —
# names + description — until it is present. Once complete the hook prints one
# line: the agent's own name(s), so "what's your name?" has an answer.
#
# ON by default (intercom.identity-check = true). This is NOT the receiver-side
# inbox reminder (which stays OFF by default, DL #10): it fires once, at session
# start, and says nothing mid-session. Opt out per project:
#   /vdm:intercom identity-check off
#
# Fails open: without jq (registry is JSON) it exits silently. Skips $HOME and
# / — those are not projects, and their basename would register as an agent.
# Registers only an identity sturdier than the directory's own name (a git
# remote or toplevel, or `intercom.identity` in config). A directory that has
# nothing but its name and no entry gets no word at all: vdx, 2026-09-28 — two
# sessions in scratch directories became agents, and the incomplete-registration
# notice would have had the assistant finish the job. A non-git project says it
# is one with `/vdm:intercom register`; once registered, it is greeted here.
#
# Output: JSON hookSpecificOutput.additionalContext (same shape as
# crystal-hydrate.sh). Not mirrored to vdm-git — intercom ships in vdm only.

set -u

_IC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_IC_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$_IC_DIR/intercom-common.sh" 2>/dev/null || exit 0
# Best-effort: gives intercom_filed_but_pending the crystal roots. Absent (older
# install, crystal disabled) the notice below simply never fires.
# shellcheck disable=SC1091
. "$_IC_DIR/../lib/crystal-path.sh" 2>/dev/null || true

payload="$(cat 2>/dev/null || true)"   # only the session's id is needed from it

if command -v vdm_config_read >/dev/null 2>&1; then
  [ "$(vdm_config_read intercom identity-check true)" = "true" ] || exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
own_sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$own_sid" ] || own_sid="${CLAUDE_CODE_SESSION_ID:-}"
command -v intercom_register >/dev/null 2>&1 || exit 0

case "$PWD" in
  "$HOME"|"/") exit 0 ;;
esac

# (1) Mechanical registration — idempotent, deterministic, no LLM involved.
# Implicit, like `check` and `send`: this session was opened here, which says
# nothing about whether here is a project.
intercom_register --implicit >/dev/null 2>&1 || true

id="$(intercom_identity 2>/dev/null)"
[ -n "$id" ] || exit 0
if [ "$(intercom_identity_source)" = "cwd" ] && [ ! -f "$(intercom_registry_file "$id")" ]; then
  exit 0
fi

names="$(intercom_registry_get "$id" '(.names // []) | join(", ")')"

# The machine is named in the first line: the harness writes this output into
# the session's transcript, transcripts travel between the machines, and that
# is how a sender on the other one learns where this session runs
# (intercom_seen_elsewhere; docs/tasks/intercom-session-wake, DL #1).
machine="$(_intercom_machine_name)"

# A focused session (VDX_FOCUSED=1, `vdx ai --focused`) is deaf to mail: one
# line saying who it is, and nothing that calls it to the inbox — no count, no
# letters of its own waiting, no notice asking for work before other work. The
# registration above still runs: it is silent, and routing depends on it.
# @see intercom-common.sh → "Focused sessions"
#
# A focused session with a topic hears of the letters on it
# (intercom-focused-topic, DL #4): its start line names the topic, says such
# letters come here, and counts those already waiting. So does one with answers
# to letters it wrote: a restart keeps the session's id (intercom-hitl-via-initiator,
# DL #3), and an answer that came while it was down is named here, not on arrival.
#
# An ordinary session with a live HQ session of its project on this machine says
# the same and no more (hq-session-quiet, DL #2): the inbox and everything below
# are that session's, and the wakes go there. An answer to a letter of its own
# stays its own.
hq_quiet=""
if ! intercom_focused && command -v vdm_hq_quiet >/dev/null 2>&1 && vdm_hq_quiet; then hq_quiet=1; fi
if intercom_focused || [ -n "$hq_quiet" ]; then
  msg="[intercom] 🪪 You are \`${id}\` on \`${machine}\`"
  [ -n "$names" ] && msg="${msg} — aka: ${names}"
  topic="$(intercom_own_topic)"
  answers="$(_intercom_letters_where "$id" for-session "$own_sid" | grep -c .)"
  questions="$(intercom_questions_here "$id" "$own_sid" | grep -c .)"
  answers=$((answers - questions))
  if [ -n "$topic" ]; then
    on_topic="$(intercom_topic_letters "$id" "$topic" | grep -c .)"
    msg="${msg}. 🔇 Focused session on «${topic}»: mail is not shown here, except letters on this topic and answers to letters this session wrote — they are this session's, and a sender may wake it with one."
    [ "$on_topic" -eq 0 ] || msg="${msg} 📬 ${on_topic} on this topic in the inbox → /vdm:intercom check."
    [ "$answers" -eq 0 ] || msg="${msg} 📬 ${answers} answer(s) to this session's letters in the inbox → /vdm:intercom check."
    msg="${msg} A letter on it that is not: /vdm:intercom topic <slug> --miss \"<why>\". Read the rest of the inbox only when the user asks."
  elif [ -n "$hq_quiet" ]; then
    msg="${msg}. 🔕 A live HQ session of this project on this machine takes the sheet and what comes from outside: mail is not shown here and no other session wakes this one, except with an answer to a letter it wrote; read the rest of the inbox only when the user asks."
    [ "$answers" -eq 0 ] || msg="${msg} 📬 ${answers} answer(s) to this session's letters in the inbox → /vdm:intercom check."
  else
    msg="${msg}. 🔇 Focused session: mail is not shown here and no other session wakes this one, except with an answer to a letter it wrote; read the rest of the inbox only when the user asks."
    [ "$answers" -eq 0 ] || msg="${msg} 📬 ${answers} answer(s) to this session's letters in the inbox → /vdm:intercom check."
  fi
  [ "$questions" -eq 0 ] || msg="${msg} ❓ ${questions} question(s) for the user on this session's letters → /vdm:intercom check, and put them to the user first: another agent waits on them."
  jq -c -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
  exit 0
fi

aliases="$(intercom_registry_get "$id" '(.aliases // []) | join(", ")')"
missing="$(intercom_registration_missing "$id")"
mismatch="$(intercom_remote_mismatch "$id" 2>/dev/null || true)"
pending="$(intercom_inbox_count "$id" 2>/dev/null)"
case "$pending" in ''|*[!0-9]*) pending=0 ;; esac

# Defaults for the incomplete-registration notice (see the comment where they
# are used). Both are derived, never invented: the name is what this directory
# is actually called, the description is the README's own first heading.
default_name=""
default_desc=""
if [ -n "$missing" ]; then
  _proj_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _proj_root=""
  [ -n "$_proj_root" ] || _proj_root="$PWD"
  default_name="$(basename "$_proj_root")"
  # First ATX heading in the README, minus the hashes and any trailing
  # punctuation; falls back to the first non-empty, non-badge line. Quotes and
  # backslashes are stripped rather than escaped — this string is interpolated
  # into a shell command the agent will run, and a stray quote there breaks the
  # command silently, which is the failure this whole block exists to avoid.
  for _rd in README.md readme.md README; do
    [ -f "$_proj_root/$_rd" ] || continue
    default_desc="$(awk '
      /^#[[:space:]]+/ { sub(/^#+[[:space:]]*/, ""); print; exit }
    ' "$_proj_root/$_rd" 2>/dev/null)"
    [ -n "$default_desc" ] && break
  done
  [ -n "$default_desc" ] || default_desc="$default_name"
  default_desc="$(printf '%s' "$default_desc" | tr -d '"\\`$' | cut -c1-120)"
  default_name="$(printf '%s' "$default_name" | tr -d '"\\`$' | cut -c1-60)"
fi

msg=""
if [ -z "$missing" ]; then
  msg="[intercom] 🪪 You are \`${id}\` on \`${machine}\`"
  [ -n "$names" ] && msg="${msg} — aka: ${names}"
  [ -n "$aliases" ] && msg="${msg} (auto-aliases: ${aliases})"
  msg="${msg}. Other agents address you by any of these."
  if [ "$pending" -gt 0 ] && ! intercom_mail_session && ! intercom_hq_session; then
    msg="${msg} 📬 ${pending} pending message(s) in your inbox → /vdm:intercom check."
    # A question whose session is gone or is this one: the user is here (DL #5).
    questions="$(intercom_questions_here "$id" "$own_sid" | grep -c .)"
    [ "$questions" -eq 0 ] || msg="${msg} ❓ ${questions} of them: question(s) for the user — put them first: another agent waits on them."
  fi
  # Balls left here by letters picked up lately and written nowhere at home
  # (held-ball-after-pickup, DL #2): named until a crystal or a pending file says
  # them, or the letter says where they live. Not in an intercom session: the
  # owner's sessions keep the project's open items.
  if ! intercom_mail_session; then
    held="$(intercom_held_balls "$id" 2>/dev/null)"
    if [ -n "$held" ]; then
      msg="${msg}
↪ Balls you hold from letters picked up in the last ${INTERCOM_HELD_BALL_DAYS} days, written in no crystal or pending file here:
$(printf '%s\n' "$held" | awk -F '\t' '{ printf "  - [ ] %s (from %s)\n", $2, $1 }')
Write each where this project keeps its open items (/vdm:crystal-bud) before other work, or say where it lives: \`intercom ball-home <letter> \"<where>\"\`."
    fi
  fi
  msg="${msg} Directory of agents: /vdm:intercom directory · send a brief: /vdm:intercom send <name> <slug>."
else
  reach="\`${id}\`"
  [ -n "$aliases" ] && reach="${reach}, ${aliases}"
  msg="[intercom] ⚠ Agent registration INCOMPLETE for \`${id}\` on \`${machine}\` — missing: ${missing}."
  msg="${msg}
Right now other agents can reach this repo only as ${reach} — those are machine-derived names. A brief the user addresses to \"vdm\", \"the intercom agent\" or whatever they actually call this project will NOT land here."
  # A READY-TO-RUN line, not an instruction to derive one.
  #
  # Field report (executor, 2026-09-04): the notice used to say "infer the
  # names from the README / the directory name / how the user refers to it; if
  # unsure, ask once". The agent deferred it to the end of the session and then
  # asked the user — who replied «Странно, что он тебе не предложил дефолт по
  # названию папки». The directory was literally named after the project.
  #
  # The diagnosis is about the FORM of the notice, not the agent: a command an
  # agent can execute gets executed; a request to derive one, hedged with "if
  # you are confident", is exactly the shape that produces a question instead.
  # So derive the obvious default here — deterministically, in the hook — and
  # print it filled in. The agent's remaining job is to correct it, which is a
  # much cheaper judgement than inventing it.
  msg="${msg}
Before other work, register the names this project really goes by. A default derived from this repo — run it as-is if it is right, or edit the name / add --name for whatever else the user calls this project (do not invent names; ask ONCE if the default is clearly wrong):
  /vdm:intercom register --name \"${default_name}\" --describe \"${default_desc}\"
Verify with /vdm:intercom whoami. This notice repeats every session until the registration is complete (opt out: /vdm:intercom identity-check off)."
fi

# An intercom session (`vdx ai --intercom`) is told what it is for. For it the
# inbox is the work, not a reminder: nobody sits at it, and the wakes that would
# have gone to the owner's session come here. The owner accepted three
# conditions with the mode, and they are said where the session starts, which
# is the only moment this plugin has with it before the mail: a question for the
# owner goes to their list at HQ, not into a pane nobody looks at; work that
# changes the code is left for the owner's main session, which shares the
# working tree; a chain between intercom sessions stops (send enforces that one).
# Two more come with starting it from `send` (DL #12, #13): a note the project
# left for itself is not its mail, and the session ends itself with `close`.
# The 📮 line is also the mark a sender on the other machine reads in this
# session's transcript. @see intercom-common.sh → "Intercom sessions"
if intercom_mail_session; then
  if [ "$pending" -gt 0 ]; then inbox_now="${pending} letter(s) are waiting now."; else inbox_now="The inbox is empty now."; fi
  msg="${msg}
📮 Intercom session of \`${id}\`: the inbox is your work, not a reminder — nobody sits at this session, and the wakes for this project come here. ${inbox_now} Now and at every wake: /vdm:intercom check, then each letter in turn — take it, read it, act, and close it: reply for a brief, pickup for a note; one that waits for something outside the inbox goes back with release --note \"<what it waits for>\".
  • Here you answer, check and do small things. Work that changes the code is left for the owner's main session as a crystal (/vdm:crystal-grow, or /vdm:crystal-bud on an active one): the working tree is shared with it, and an edit here rides into its commit.
  • A question for the owner is not asked in this pane — nobody reads it. On a letter: /vdm:intercom ask <slug> --question \"<as the owner should read it>\" [--option \"<option>\"] puts it to the session that wrote the letter, and the letter waits with a note. When ask refuses, or the question is on no letter: Put one line on their list at HQ (the access layer's \`hq <project root> --obligations\` names it; the access layer: /vdm:intercom role access-layer). Either way take the next letter; do not wait for the answer.
  • A chain of letters between intercom sessions stops after ${INTERCOM_CHAIN_LIMIT} links in a row; send refuses the next one, and it goes to the owner the same way.
  • A letter from \`${id}\` itself is a note for the owner's next session, not mail: leave it untaken.
  • Inbox handled: say what was done, then end this session with /vdm:intercom close — it refuses while a letter nobody took is in the inbox, and runs \`vdx ai --close --waiting <n>\`, n being the letters you took and left for the owner. Your turn ends on its result."
fi

# An HQ session's count is its work, not a reason to call the owner
# (docs/tasks/hq-session-active): the owner sits at it, unlike at an intercom
# session, so a question goes to them here. Nothing is said while nothing waits: the
# access layer names its role, and a letter that comes says this again.
if intercom_hq_session; then
  hq_work="$(intercom_hq_work "$id" 2>/dev/null)"
  case "$hq_work" in ''|*[!0-9]*) hq_work=0 ;; esac
  if [ "$hq_work" -gt 0 ]; then
    msg="${msg}
👑 HQ session of \`${id}\`: letters are your work, not a reminder. ${hq_work} wait now. After the user's message, if there is one: /vdm:intercom check now, then each letter in turn — take it, read it, act, and close it: reply for a brief, pickup for a note.
  • The user sits here. Ask them only where the answer needs their decision: in this session, in words, with your recommendation, never a command for them to run. \`/vdm:intercom check\` in your answer to them means the work was not done.
  • A note this project left for its next working session is not yours: \`check\` says which; leave it untaken."
  fi
  questions="$(intercom_questions_here "$id" "$own_sid" | grep -c .)"
  [ "$questions" -eq 0 ] || msg="${msg}
❓ ${questions} question(s) for the user on letters here — put them first: another agent waits on them."
fi

# Mail piling up here, with no intercom session switched on: offered once per
# session start, to be put to the user in a line — unless the owner said no
# since the oldest of those letters came (see intercom_mail_candidate).
if ! intercom_mail_session; then
  backlog="$(intercom_mail_candidate "$id" 2>/dev/null)"
  b_n="${backlog%%$'\t'*}"; b_days="${backlog#*$'\t'}"
  if [ -n "$backlog" ] && ! intercom_mail_switched_on "$id"; then
    msg="${msg}
📨 ${b_n} letters from other agents wait in this inbox, the oldest ${b_days}d. An intercom session — a separate agent session that takes letters as they come — would answer them without waiting for a session here: offer it to the user once, in one line. It is switched on by this project's own commit, \`\"intercom\": {\"session\": true}\` in .claude/vdm-plugins.json, and costs a whole agent session per project and machine. The user says no: \`intercom mail-candidates decline ${id}\` — asked again only when mail piles up anew."
  fi
fi

# Delivery is not receipt, from the sender's side. A letter this agent wrote
# that has sat unpicked for three days is a promise nobody is keeping, and
# `check` shows only what came in. Three days, because that is how long the
# field case lay unseen (@see docs/tasks/intercom-live-delivery/workitem.md, DL #4);
# `/vdm:intercom sent` lists everything, without a threshold.
old_sent="$(intercom_sent_list "$id" 2>/dev/null | awk -F '\t' '$1 >= 3')"
if [ -n "$old_sent" ]; then
  n_old="$(printf '%s\n' "$old_sent" | wc -l | tr -d ' ')"
  oldest="$(printf '%s\n' "$old_sent" | head -1 | awk -F '\t' '{ printf "%sd, %s/%s", $1, $2, $3 }')"
  msg="${msg}
📤 ${n_old} of your letters lie unpicked for 3+ days (oldest: ${oldest}) — delivered is not received. See who can be woken now: /vdm:intercom sent"
fi

# A brief that was filed into a crystal but never archived reads as pending to
# every later session — indistinguishable from one nobody has looked at. The
# signal names the slug and the command, and it goes out the moment `pickup`
# runs, so it cannot become background the way a standing "don't forget" would.
stale="$(intercom_filed_but_pending "$id" 2>/dev/null || true)"
if [ -n "$stale" ]; then
  while IFS=$'\t' read -r sl where; do
    [ -n "$sl" ] || continue
    msg="${msg}
📂 \`${sl}\` is still in your inbox, but its brief is already filed under \`${where}\` — taken into a crystal and never archived. Close the loop: /vdm:intercom pickup ${sl}"
  done <<<"$stale"
fi

unclaimed="$(intercom_orphans_matching "$id" 2>/dev/null || true)"
if [ -n "$unclaimed" ]; then
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    n="$(intercom_inbox_count "$o" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
    msg="${msg}
📥 Unclaimed inbox \`${o}\` (${n} message(s)) matches one of your names — it was addressed to you under that name before you registered it. Bring it home: /vdm:intercom claim ${o}"
  done <<<"$unclaimed"
fi

if [ -n "$mismatch" ]; then
  msg="${msg}
⚠ Remote mismatch for \`${id}\`: registry has \`${mismatch}\`, this clone uses \`$(intercom_remote_url)\`. Same project under another remote (mirror / marketplace clone)? → /vdm:intercom register --same-project. A different project sharing the slug? → /vdm:intercom identity <distinct-name> in one of them."
fi

jq -c -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
