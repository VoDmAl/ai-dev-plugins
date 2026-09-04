#!/bin/bash
# intercom.test.sh — tests for the agent directory + identity resolution.
#
# Why this file exists. The one failure that matters in a mailbox is silent:
# a brief addressed to the wrong name creates a fresh inbox nobody reads, and
# the sender sees "staged" exactly as if it had landed. Every assertion here is
# about routing — does the name the user SAYS reach the agent they MEAN — plus
# the session-start hook that makes each repo declare those names.
#
# Everything runs against a scratch store (VDM_INTERCOM_ROOT) and scratch git
# repos with fake remotes; the real ~/.claude/vdm/intercom is never touched.
#
# Run: bash tests/intercom.test.sh   (exit 0 = all pass)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC="$REPO_ROOT/plugins/vdm/scripts/intercom.sh"
HOOK="$REPO_ROOT/plugins/vdm/scripts/intercom-identity-check.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
says() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3"$'\n'"      got: $2" ;; esac
}
says_not() {
  case "$2" in *"$3"*) bad "$1" "output should not mention: $3" ;; *) ok "$1" ;; esac
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'intercom tests need jq — skipping (0 assertions).\n'
  exit 0
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t intercom)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export VDM_INTERCOM_ROOT="$TMP/store"
export HOME="$TMP/home"          # so ~/.claude/vdm-plugins.json cannot leak in
mkdir -p "$HOME"

mkrepo() {  # mkrepo <dir> <remote-url>
  mkdir -p "$1"
  git -C "$1" init -q .
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  [ -n "${2:-}" ] && git -C "$1" remote add origin "$2"
}

mkrepo "$TMP/widget-clone" "git@example.com:acme/Widget.git"
mkrepo "$TMP/gadget"       "https://example.com/acme/gadget.git"
mkrepo "$TMP/widget-mirror" "https://github.com/acme/widget.git"   # same project, 2nd remote
mkdir -p "$TMP/notes-vault"                                         # non-git project

printf '\n[identity]\n'
cd "$TMP/widget-clone"
eq "identity = remote slug, lowercased, not the directory basename" "$(bash "$IC" identity)" "widget"
cd "$TMP/notes-vault"
eq "non-git dir falls back to basename identity" "$(bash "$IC" identity)" "notes-vault"

printf '\n[register — mechanical part]\n'
cd "$TMP/widget-clone"
out="$(bash "$IC" register 2>&1)"
says "register reports identity → inbox" "$out" "registered: widget →"
reg="$VDM_INTERCOM_ROOT/_registry/widget.json"
[ -f "$reg" ] && ok "registry entry written" || bad "registry entry missing at $reg"
eq "auto-alias: directory basename" "$(jq -r '.aliases | index("widget-clone") != null' "$reg")" "true"
eq "auto-alias: owner/repo" "$(jq -r '.aliases | index("acme/widget") != null' "$reg")" "true"
eq "remotes[] seeded with the primary" "$(jq -r '.remotes[0]' "$reg")" "git@example.com:acme/Widget.git"
eq "names empty before the human part" "$(jq -r '.names | length' "$reg")" "0"
out="$(bash "$IC" whoami)"
says "whoami flags INCOMPLETE" "$out" "INCOMPLETE"
says "whoami names what is missing" "$out" "missing: names, description"

printf '\n[session-start hook — incomplete]\n'
out="$(printf '{"session_id":"t","source":"startup"}' | bash "$HOOK")"
says "hook emits SessionStart context" "$out" '"hookEventName":"SessionStart"'
says "hook says registration is incomplete" "$out" "registration INCOMPLETE for \`widget\`"
says "hook names the reachable machine names" "$out" "widget-clone, acme/widget"
says "hook tells the assistant the register command" "$out" "/vdm:intercom register --name"
says "hook says ask once, never invent" "$out" "do not invent names"

printf '\n[register — human part]\n'
out="$(bash "$IC" register --name "Widget App" --name "wgt" --describe "The widget service (billing)" 2>&1)"
says "register accepts names + description" "$out" "names:       widget app, wgt"
eq "names stored lowercased, spaces kept" "$(jq -r '.names | join("|")' "$reg")" "widget app|wgt"
eq "description stored" "$(jq -r '.description' "$reg")" "The widget service (billing)"
eq "registration now complete" "$(bash "$IC" whoami | grep -c 'registration: ✓ complete')" "1"
out="$(bash "$IC" register 2>&1)"
eq "plain re-register keeps names" "$(jq -r '.names | length' "$reg")" "2"
eq "plain re-register keeps description" "$(jq -r '.description' "$reg")" "The widget service (billing)"

printf '\n[session-start hook — complete]\n'
out="$(printf '{"session_id":"t","source":"startup"}' | bash "$HOOK")"
says "hook states who you are" "$out" "You are \`widget\`"
says "hook lists the human names" "$out" "aka: widget app, wgt"
says_not "hook no longer nags" "$out" "INCOMPLETE"
cd "$HOME"
out="$(printf '{}' | bash "$HOOK")"
eq "hook is silent in \$HOME (not a project)" "$out" ""
cd "$TMP/widget-clone"
mkdir -p .claude && printf '{"intercom":{"identity-check":false}}\n' > .claude/vdm-plugins.json
out="$(printf '{}' | bash "$HOOK")"
eq "hook honours intercom.identity-check=false" "$out" ""
rm -rf .claude

printf '\n[resolve — every name the user might say]\n'
cd "$TMP/gadget"
for n in "widget" "Widget" "WIDGET-CLONE" "acme/widget" "Widget App" "widget-app" "widget_app" "  wgt  "; do
  eq "resolve '$n' → widget" "$(bash "$IC" resolve "$n" 2>/dev/null)" "widget"
done
bash "$IC" resolve "nonexistent" >/dev/null 2>&1; rc=$?
eq "unknown name → exit 2" "$rc" "2"
out="$(bash "$IC" resolve "widg" 2>&1)"
says "partial match suggests the agent" "$out" "Did you mean:"
says "suggestion line carries the identity" "$out" "• widget"
out="$(bash "$IC" resolve "billing" 2>&1)"
says "description words are searchable too" "$out" "• widget"

printf '\n[send — routing by human name]\n'
out="$(bash "$IC" send "Widget App" hello --title "Hi" 2>&1)"; rc=$?
eq "send by human name succeeds" "$rc" "0"
[ -f "$VDM_INTERCOM_ROOT/widget/hello.md" ] && ok "message landed in the CANONICAL inbox" || bad "message not in widget/ inbox"
says "send reports the resolution" "$out" 'to: widget (resolved from "Widget App")'
eq "envelope to: is canonical" "$(grep '^to:' "$VDM_INTERCOM_ROOT/widget/hello.md")" "to: widget"
eq "envelope keeps what the user typed" "$(grep '^to_input:' "$VDM_INTERCOM_ROOT/widget/hello.md")" 'to_input: "Widget App"'
eq "sender auto-registered (gadget)" "$(test -f "$VDM_INTERCOM_ROOT/_registry/gadget.json" && echo yes)" "yes"

printf '\n[send — unknown target is a hard stop]\n'
out="$(bash "$IC" send "wdiget" typo 2>&1)"; rc=$?
eq "unknown target → exit 2" "$rc" "2"
says "refusal names the problem" "$out" 'no agent is registered as "wdiget"'
[ ! -d "$VDM_INTERCOM_ROOT/wdiget" ] && ok "no stray inbox created" || bad "stray inbox wdiget/ was created"
out="$(bash "$IC" send "widg" typo2 2>&1)"; rc=$?
says "refusal suggests the near match" "$out" "• widget"
out="$(bash "$IC" send "newcomer" first --first-contact 2>&1)"; rc=$?
eq "--first-contact creates the inbox" "$rc" "0"
[ -f "$VDM_INTERCOM_ROOT/newcomer/first.md" ] && ok "first-contact message staged" || bad "first-contact message missing"
says "first-contact is announced" "$out" "first contact"

printf '\n[names — one name routes to one agent]\n'
cd "$TMP/gadget"
out="$(bash "$IC" register --name wgt --describe "Gadget" 2>&1)"; rc=$?
eq "register refuses a name that routes elsewhere" "$rc" "1"
says "refusal says where it routes" "$out" 'already routes to `widget`'
eq "refused registration wrote nothing" "$(jq -r '.description // ""' "$VDM_INTERCOM_ROOT/_registry/gadget.json")" ""
out="$(bash "$IC" names add wgt 2>&1)"; rc=$?
eq "names add refuses too" "$rc" "1"
out="$(bash "$IC" names rm --for widget wgt 2>&1)"
says "names rm --for edits another agent" "$out" "names of widget: widget app"
out="$(bash "$IC" names add wgt gizmo 2>&1)"
says "name freed → add succeeds (insertion order kept)" "$out" "names of gadget: wgt, gizmo"
eq "resolve 'wgt' now → gadget" "$(bash "$IC" resolve wgt 2>/dev/null)" "gadget"
out="$(bash "$IC" names add --for nope x 2>&1)"; rc=$?
eq "names add --for unknown agent fails" "$rc" "1"

printf '\n[ambiguity — hand-crafted duplicate]\n'
jq '.names += ["gizmo"]' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
bash "$IC" resolve gizmo >/dev/null 2>&1; rc=$?
eq "two agents claiming a name → exit 3" "$rc" "3"
out="$(bash "$IC" send gizmo dup 2>&1)"; rc=$?
eq "send to ambiguous name refused (exit 3)" "$rc" "3"
says "ambiguity lists both" "$out" "• gadget"
says "ambiguity lists both (2)" "$out" "• widget"
bash "$IC" names rm --for widget gizmo >/dev/null 2>&1
eq "after cleanup gizmo → gadget" "$(bash "$IC" resolve gizmo 2>/dev/null)" "gadget"

printf '\n[directory]\n'
out="$(bash "$IC" directory)"
says "directory counts registered agents" "$out" "2 agent(s)"
says "directory shows names + aliases" "$out" "• widget   aka: widget app, widget-clone, acme/widget"
says "directory shows description" "$out" "— The widget service (billing)"
says "directory flags pending mail" "$out" "[📬 1 pending]"
says "directory flags unnamed agents" "$out" "⚠ unnamed"
out="$(bash "$IC" who)"
says "who is an alias of directory" "$out" "intercom directory"
says "directory lists orphan first-contact inboxes" "$out" "NO registered agent"
says "orphan inbox named with its pending count" "$out" "• newcomer   [1 pending]"

printf '\n[second remote — mirror vs collision]\n'
cd "$TMP/widget-mirror"
out="$(bash "$IC" register 2>&1)"
says "unconfirmed second remote warns" "$out" "registered under a different remote"
eq "primary remote is NOT overwritten" "$(jq -r '.remote' "$reg")" "git@example.com:acme/Widget.git"
eq "unconfirmed remote not added to remotes[]" "$(jq -r '.remotes | length' "$reg")" "1"
out="$(printf '{}' | bash "$HOOK")"
says "hook surfaces the mismatch" "$out" "Remote mismatch"
says "hook offers --same-project" "$out" "register --same-project"
out="$(bash "$IC" register --same-project 2>&1)"
says_not "--same-project silences the warning" "$out" "different remote"
eq "confirmed remote added to remotes[]" "$(jq -r '.remotes | index("https://github.com/acme/widget.git") != null' "$reg")" "true"
out="$(bash "$IC" register 2>&1)"
says_not "subsequent registers stay quiet" "$out" "different remote"
out="$(printf '{}' | bash "$HOOK")"
says_not "hook no longer reports a mismatch" "$out" "Remote mismatch"

printf '\n[non-git project]\n'
cd "$TMP/notes-vault"
out="$(bash "$IC" register --name "vault" --describe "Notes" 2>&1)"
eq "non-git project registers under its basename" "$(jq -r '.identity' "$VDM_INTERCOM_ROOT/_registry/notes-vault.json")" "notes-vault"
eq "non-git remote is null, no remotes[]" "$(jq -r '.remotes | length' "$VDM_INTERCOM_ROOT/_registry/notes-vault.json")" "0"
out="$(printf '{}' | bash "$HOOK")"
says "hook works without git" "$out" "You are \`notes-vault\`"

printf '\n[send --to — the negative scenario, closed at the moment of confirmation]\n'
cd "$TMP/gadget"
out="$(bash "$IC" send "the widget people" howdy --title "Hi" 2>&1)"; rc=$?
eq "unknown hint is still refused" "$rc" "2"
says "refusal names the exact next command" "$out" 'intercom send "the widget people" howdy --to <identity>'
says "refusal says the hint will be recorded" "$out" 'records "the widget people" as that agent'
says "refusal says never guess" "$out" "never guess a recipient"
out="$(bash "$IC" send "the widget people" howdy --to widget 2>&1)"; rc=$?
eq "--to delivers" "$rc" "0"
[ -f "$VDM_INTERCOM_ROOT/widget/howdy.md" ] && ok "message landed in the chosen agent's inbox" || bad "howdy.md not in widget/"
eq "envelope to: is the chosen identity" "$(grep '^to:' "$VDM_INTERCOM_ROOT/widget/howdy.md")" "to: widget"
eq "envelope to_input: keeps the hint" "$(grep '^to_input:' "$VDM_INTERCOM_ROOT/widget/howdy.md")" 'to_input: "the widget people"'
says "hint recorded as the agent's name" "$out" 'recorded "the widget people" as a name of `widget`'
eq "next time the hint resolves directly" "$(bash "$IC" resolve "The Widget People" 2>/dev/null)" "widget"
out="$(bash "$IC" send gizmo hey2 --to widget 2>&1)"; rc=$?
eq "--to overrides a hint that routes elsewhere" "$rc" "0"
says "…but warns and does not touch the directory" "$out" 'currently routes to `gadget`, not `widget` — delivered as told, name NOT recorded'
eq "gizmo still routes to gadget" "$(bash "$IC" resolve gizmo 2>/dev/null)" "gadget"
out="$(bash "$IC" send foo bar --to nobody 2>&1)"; rc=$?
eq "--to must itself resolve" "$rc" "1"
[ ! -f "$VDM_INTERCOM_ROOT/nobody/bar.md" ] && ok "nothing sent when --to is unknown" || bad "stray message for unknown --to"
out="$(bash "$IC" send "widget app" hey3 --to widget 2>&1)"
says_not "hint that already routes there is not re-recorded" "$out" "recorded"

printf '\n[claim — an unclaimed inbox addressed to one of my names]\n'
cd "$TMP/widget-clone"
out="$(printf '{}' | bash "$HOOK")"
says_not "hook is silent about orphans that match none of my names" "$out" "Unclaimed inbox"
bash "$IC" names add newcomer >/dev/null 2>&1
out="$(printf '{}' | bash "$HOOK")"
says "hook flags the unclaimed inbox once the name matches" "$out" "Unclaimed inbox \`newcomer\` (1 message(s))"
says "hook offers claim" "$out" "/vdm:intercom claim newcomer"
out="$(bash "$IC" check)"
says "check flags it too" "$out" "unclaimed inbox \`newcomer\`"
out="$(bash "$IC" whoami)"
says "whoami flags it too" "$out" "unclaimed inbox \`newcomer\`"
out="$(bash "$IC" claim newcomer 2>&1)"; rc=$?
eq "claim succeeds" "$rc" "0"
says "claim reports the move" "$out" "claimed inbox \`newcomer\` → \`widget\` (1 message(s) moved"
[ -f "$VDM_INTERCOM_ROOT/widget/first.md" ] && ok "message moved home" || bad "first.md not in widget/"
[ ! -d "$VDM_INTERCOM_ROOT/newcomer" ] && ok "orphan directory removed" || bad "newcomer/ still exists"
eq "envelope to: rewritten to the canonical identity" "$(grep '^to:' "$VDM_INTERCOM_ROOT/widget/first.md")" "to: widget"
eq "to_input kept as the trace" "$(grep '^to_input:' "$VDM_INTERCOM_ROOT/widget/first.md")" 'to_input: "newcomer"'
out="$(bash "$IC" directory)"
says_not "directory no longer lists the orphan" "$out" "NO registered agent"
out="$(printf '{}' | bash "$HOOK")"
says_not "hook is quiet again" "$out" "Unclaimed inbox"
out="$(bash "$IC" claim gadget 2>&1)"; rc=$?
eq "claiming a registered agent's inbox is refused" "$rc" "1"
says "…and says why" "$out" "belongs to a registered agent"
bash "$IC" send stranger s1 --first-contact >/dev/null 2>&1
out="$(bash "$IC" claim stranger 2>&1)"; rc=$?
eq "orphan matching none of my names is refused" "$rc" "1"
says "…with the --force hint" "$out" "intercom claim stranger --force"
out="$(bash "$IC" claim stranger --force 2>&1)"; rc=$?
eq "--force claims it anyway" "$rc" "0"
eq "forced claim records the name" "$(bash "$IC" resolve stranger 2>/dev/null)" "widget"

printf '\n[check still registers]\n'
cd "$TMP/widget-clone"
out="$(bash "$IC" check)"
says "check lists the pending briefs" "$out" "pending message(s) for \`widget\`"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
