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
# Works in non-git directories (basename identity) — some projects have no git.
#
# Output: JSON hookSpecificOutput.additionalContext (same shape as
# crystal-hydrate.sh). Not mirrored to vdm-git — intercom ships in vdm only.

set -u

_IC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_IC_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$_IC_DIR/intercom-common.sh" 2>/dev/null || exit 0

cat >/dev/null 2>&1 || true   # drain the hook payload; nothing in it is needed

if command -v vdm_config_read >/dev/null 2>&1; then
  [ "$(vdm_config_read intercom identity-check true)" = "true" ] || exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
command -v intercom_register >/dev/null 2>&1 || exit 0

case "$PWD" in
  "$HOME"|"/") exit 0 ;;
esac

# (1) Mechanical registration — idempotent, deterministic, no LLM involved.
intercom_register >/dev/null 2>&1 || true

id="$(intercom_identity 2>/dev/null)"
[ -n "$id" ] || exit 0

names="$(intercom_registry_get "$id" '(.names // []) | join(", ")')"
aliases="$(intercom_registry_get "$id" '(.aliases // []) | join(", ")')"
missing="$(intercom_registration_missing "$id")"
mismatch="$(intercom_remote_mismatch "$id" 2>/dev/null || true)"
pending="$(intercom_inbox_count "$id" 2>/dev/null)"
case "$pending" in ''|*[!0-9]*) pending=0 ;; esac

msg=""
if [ -z "$missing" ]; then
  msg="[intercom] 🪪 You are \`${id}\`"
  [ -n "$names" ] && msg="${msg} — aka: ${names}"
  [ -n "$aliases" ] && msg="${msg} (auto-aliases: ${aliases})"
  msg="${msg}. Other agents address you by any of these."
  if [ "$pending" -gt 0 ]; then
    msg="${msg} 📬 ${pending} pending message(s) in your inbox → /vdm:intercom check."
  fi
  msg="${msg} Directory of agents: /vdm:intercom directory · send a brief: /vdm:intercom send <name> <slug>."
else
  reach="\`${id}\`"
  [ -n "$aliases" ] && reach="${reach}, ${aliases}"
  msg="[intercom] ⚠ Agent registration INCOMPLETE for \`${id}\` — missing: ${missing}."
  msg="${msg}
Right now other agents can reach this repo only as ${reach} — those are machine-derived names. A brief the user addresses to \"vdm\", \"the intercom agent\" or whatever they actually call this project will NOT land here."
  msg="${msg}
Before other work, register the names this project really goes by: infer them from the README title, the product/plugin/skill names, the directory name, and how the user refers to it in chat; if you cannot infer them with confidence, ask the user ONCE — do not invent names. Then run:
  /vdm:intercom register --name \"<short name>\" --name \"<another name>\" --describe \"<one line: what this repo is / which agent lives here>\"
Verify with /vdm:intercom whoami. This notice repeats every session until the registration is complete (opt out: /vdm:intercom identity-check off)."
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
