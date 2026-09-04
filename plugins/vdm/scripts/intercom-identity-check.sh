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
  # A READY-TO-RUN line, not an instruction to derive one.
  #
  # Field report (obsidianvault, 2026-09-04): the notice used to say "infer the
  # names from the README / the directory name / how the user refers to it; if
  # unsure, ask once". The agent deferred it to the end of the session and then
  # asked the user — who replied «Странно, что он тебе не предложил дефолт по
  # названию папки». The directory was literally called `ObsidianVault`.
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
