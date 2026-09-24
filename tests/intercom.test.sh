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

# Scrub git's per-invocation environment before anything else. A test harness
# run from inside a live `git commit` (which is what a pre-commit gate is)
# inherits GIT_INDEX_FILE / GIT_DIR pointing at THAT commit — and every `git`
# call against a throwaway fixture then writes into the user's real commit
# instead. Measured 2026-09-22 on this file's sibling: one `git add -A` in a
# fixture replaced all 158 entries of the pending commit's index with 9
# fixture paths. The commit survived only because the objects were missing.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at a PRE-CHANGE copy of the plugin and
# watched go red — a test that has never failed is the defect it was written
# against. The script resolves its library and its template relative to itself,
# so one variable swaps the whole implementation.
IC="${INTERCOM_BIN:-$REPO_ROOT/plugins/vdm/scripts/intercom.sh}"
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
# A suggestion list that names everyone suggests nothing. The assertions above
# passed while the matcher returned the ENTIRE directory for every miss: a jq
# pipe rebound `.`, so one clause asked whether the input contains itself and
# was always true. Checking that the right agent APPEARS can never catch that.
# This input resembles nothing, so the only correct answer is silence.
out="$(bash "$IC" resolve "zzqq" 2>&1)"
says_not "a miss with nothing similar suggests nobody" "$out" "• widget"

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
# The flag must mean what the legend under the listing says it means: no human
# NAME. It also fired on a missing description, and nobody noticed while both
# fields were empty together — the wrong condition kept giving the right answer.
# Naming an agent without describing it is what separates them.
bash "$IC" names add --for gadget "gizmo-named" >/dev/null 2>&1
out="$(bash "$IC" directory)"
line="$(printf '%s\n' "$out" | grep '• gadget')"
says "a named-but-undescribed agent still shows (no description)" "$line" "(no description)"
says_not "a named-but-undescribed agent is not called unnamed" "$line" "⚠ unnamed"
bash "$IC" names rm --for gadget "gizmo-named" >/dev/null 2>&1
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

printf '\n[$HOME is not a project — and its basename is somebody'"'"'s name]\n'
# Field report (vodmal-work-imac, 2026-09-10): the SessionStart hook has always
# skipped $HOME and /, but `send` / `check` / `claim` register from wherever the
# shell sits and had no such guard. On the reporting machine `basename $HOME` is
# `vdm` — a registered NAME of ai-dev-plugins — so one send from the home
# directory would have created a second entry claiming it and made routing to
# the plugin repo ambiguous. Fixture mirrors that exactly: a home directory
# whose basename is `wgt`, already a name of `widget`.
FAKEHOME="$TMP/wgt"; mkdir -p "$FAKEHOME"
machine="$( { scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo localhost; } \
  | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -e 's|[^a-z0-9._-]|-|g' -e 's|-\{2,\}|-|g' -e 's|^-||' -e 's|-$||')"
# Whoever owns `wgt` by now — earlier assertions move it between agents on
# purpose. The claim under test is that it does not MOVE here, not who holds it.
WGT_OWNER="$(bash "$IC" resolve wgt)"

out="$(cd "$FAKEHOME" && HOME="$FAKEHOME" bash "$IC" identity)"
eq "identity from \$HOME is the machine, not the home basename" "$out" "$machine"
says_not "identity from \$HOME is not the colliding basename" "$out" "wgt"

( cd "$FAKEHOME" && HOME="$FAKEHOME" bash "$IC" send widget probe-from-home --title t ) >/dev/null 2>&1
[ -f "$VDM_INTERCOM_ROOT/_registry/wgt.json" ] \
  && bad "send from \$HOME does not register the home basename" "wgt.json was created" \
  || ok "send from \$HOME does not register the home basename"
eq "the name it would have hijacked still routes" "$(bash "$IC" resolve wgt)" "$WGT_OWNER"
eq "the machine entry carries no basename alias" \
  "$(jq -r '[.aliases[] | select(. == "wgt")] | length' "$VDM_INTERCOM_ROOT/_registry/$machine.json" 2>/dev/null)" "0"

printf '\n[implicit registration needs more than a cwd basename]\n'
# `check` and `send` ride along on registration — the natural "I exist" moment —
# but they run from whatever directory the shell is in. That is how a directory
# named after a version, or a browser profile, becomes an agent.
GHOSTDIR="$TMP/0.2.42"; mkdir -p "$GHOSTDIR"
( cd "$GHOSTDIR" && bash "$IC" check ) >/dev/null 2>&1
[ -f "$VDM_INTERCOM_ROOT/_registry/0.2.42.json" ] \
  && bad "check from a non-project cwd registers nothing" "0.2.42.json was created" \
  || ok "check from a non-project cwd registers nothing"

# The escape hatch has to stay open: a real non-git project says so explicitly.
out="$(cd "$TMP/notes-vault" && bash "$IC" register 2>&1)"
says "explicit register still works for a non-git project" "$out" "registered: notes-vault →"

printf '\n[an identity that is already a name is refused]\n'
# Worse than a name clash, because intercom_resolve_target answers from
# <registry>/<input>.json before it looks at names: the new entry does not tie,
# it WINS, and silently takes over routing that used to work.
COLLIDE="$TMP/wgt-project/wgt"; mkdir -p "$COLLIDE"
out="$(cd "$COLLIDE" && bash "$IC" register 2>&1)"; rc=$?
eq "register refuses when the identity is another agent's name" "$rc" "1"
says "the refusal names the agent that owns it" "$out" "already a NAME of \`$WGT_OWNER\`"
says "the refusal says what would break" "$out" "would hijack"
[ -f "$VDM_INTERCOM_ROOT/_registry/wgt.json" ] \
  && bad "the refused registration wrote nothing" "wgt.json was created" \
  || ok "the refused registration wrote nothing"
eq "routing survives the refusal" "$(bash "$IC" resolve wgt)" "$WGT_OWNER"

printf '\n[suggestions stay narrow once there is more than one agent]\n'
# Repeated here rather than beside the first resolve block on purpose: up there
# only one agent existed, so "the list excludes the others" was true whatever
# the matcher did. An assertion that cannot fail is worse than none — it reports
# coverage that is not there.
nagents=$(ls -1 "$VDM_INTERCOM_ROOT/_registry/"*.json 2>/dev/null | grep -c .)
[ "$nagents" -ge 2 ] \
  && ok "fixture: at least two agents registered ($nagents)" \
  || bad "fixture: at least two agents registered" "only $nagents — the assertions below cannot fail"
out="$(bash "$IC" resolve "widg" 2>&1)"
says "near miss still finds the right agent" "$out" "• widget"
says_not "near miss does not list the unrelated one" "$out" "• gadget"
out="$(bash "$IC" resolve "qqzz" 2>&1)"
says_not "a total miss lists nobody (1/2)" "$out" "• widget"
says_not "a total miss lists nobody (2/2)" "$out" "• gadget"

printf '\n[describe --for]\n'
# A description is normally what an agent says about itself. But a directory of a
# dozen agents cannot be completed that way without opening a session in each of
# a dozen repositories, and until it is completed the listing cannot tell an
# unfinished onboarding from an accidental entry.
out="$(bash "$IC" describe --for gadget "The gadget service" 2>&1)"; rc=$?
eq "describe --for succeeds" "$rc" "0"
eq "description landed on the named agent" \
  "$(jq -r '.description' "$VDM_INTERCOM_ROOT/_registry/gadget.json")" "The gadget service"
out="$(bash "$IC" directory)"
says "the described agent shows its description" "$out" "— The gadget service"
out="$(bash "$IC" describe --for nosuchagent "x" 2>&1)"; rc=$?
eq "describe refuses an unknown agent" "$rc" "1"
says "the refusal names the agent" "$out" 'no registered agent `nosuchagent`'
out="$(bash "$IC" describe --for gadget "" 2>&1)"; rc=$?
eq "describe refuses empty text" "$rc" "1"
eq "the refused describe left the old text" \
  "$(jq -r '.description' "$VDM_INTERCOM_ROOT/_registry/gadget.json")" "The gadget service"

printf '\n[unregister — one entry, never a sweep]\n'
# Removing an entry that turns out to be real is not recoverable from the listing
# it vanished from: the next sender gets "no agent is registered as …", which
# reads as their own typo rather than as a deletion. A human name is the strong
# signal of alive — names exist only because somebody said them.
mkdir -p "$TMP/junkdir"
( cd "$TMP/junkdir" && bash "$IC" register ) >/dev/null 2>&1
[ -f "$VDM_INTERCOM_ROOT/_registry/junkdir.json" ] \
  && ok "fixture: an unnamed entry exists to remove" \
  || bad "fixture: an unnamed entry exists to remove" "junkdir.json missing"

out="$(bash "$IC" unregister widget 2>&1)"; rc=$?
eq "unregister refuses an agent that has names" "$rc" "1"
says "the refusal lists the names in use" "$out" "addressed by name"
[ -f "$VDM_INTERCOM_ROOT/_registry/widget.json" ] \
  && ok "the refused unregister removed nothing" \
  || bad "the refused unregister removed nothing" "widget.json is gone"
eq "routing to the refused agent is intact" "$(bash "$IC" resolve "widget app")" "widget"

out="$(bash "$IC" unregister junkdir 2>&1)"; rc=$?
eq "unregister removes an unnamed entry" "$rc" "0"
says "removal is reported" "$out" "removed \`junkdir\`"
[ -f "$VDM_INTERCOM_ROOT/_registry/junkdir.json" ] \
  && bad "the entry is gone from the registry" "junkdir.json survived" \
  || ok "the entry is gone from the registry"
out="$(bash "$IC" unregister junkdir 2>&1)"; rc=$?
eq "unregistering twice is an error, not a silent no-op" "$rc" "1"
says "the second attempt says there is nothing to remove" "$out" "nothing to remove"

# --force is for the case the user named something by mistake themselves.
bash "$IC" names add --for gadget "throwaway-name" >/dev/null 2>&1
out="$(bash "$IC" unregister gadget --force 2>&1)"; rc=$?
eq "--force removes a named entry" "$rc" "0"
[ -f "$VDM_INTERCOM_ROOT/_registry/gadget.json" ] \
  && bad "--force actually removed it" "gadget.json survived" \
  || ok "--force actually removed it"

printf '\n[a brief filed into a crystal but never archived]\n'
# Archiving a consumed brief is a separate gesture with nothing comparing it to
# anything, so a brief can be worked to completion — code shipped, reply sent —
# and still read as pending to every later session. Observed 2026-09-11 on
# `intercom-home-guard-missing`, found only by a manual sweep at the end.
#
# The join key is the envelope `slug:`, NOT the filename: a brief is routinely
# renamed on its way into references/ (this repo holds two different briefs both
# called intercom-brief-obsidianvault.md). The fixture renames on purpose.
cd "$TMP/widget-clone" || exit 1
mkdir -p docs/tasks/probe-crystal/references
{ printf -- '---\nintercom: v1\nfrom: someone\nto: widget\nslug: hello\nstatus: pending\n---\n\n# filed copy\n'; } \
  > docs/tasks/probe-crystal/references/renamed-on-the-way-in.md
out="$(printf '{"session_id":"t","source":"startup"}' | bash "$HOOK")"
says "a filed-but-pending brief is named" "$out" "hello\` is still in your inbox"
says "the notice points at where it is filed" "$out" "renamed-on-the-way-in.md"
says "the notice gives the command that closes it" "$out" "pickup hello"

# A reference that is not an intercom brief must not be scanned for slugs — the
# tree is full of other references, and a stray `slug:` line in one of them
# would accuse a message nobody filed.
mkdir -p docs/tasks/probe-crystal2/references
printf -- '---\nslug: hello\n---\n\nnot an intercom brief\n' \
  > docs/tasks/probe-crystal2/references/plain-note.md
rm -f docs/tasks/probe-crystal/references/renamed-on-the-way-in.md
out="$(printf '{"session_id":"t","source":"startup"}' | bash "$HOOK")"
says_not "a non-brief reference does not trigger the notice" "$out" "still in your inbox"

# And the signal must extinguish itself: once the message is gone, so is the line.
printf -- '---\nintercom: v1\nslug: hello\n---\n' > docs/tasks/probe-crystal/references/again.md
mv "$VDM_INTERCOM_ROOT/widget/hello.md" "$VDM_INTERCOM_ROOT/widget/_done/hello.md" 2>/dev/null \
  || { mkdir -p "$VDM_INTERCOM_ROOT/widget/_done"; mv "$VDM_INTERCOM_ROOT/widget/hello.md" "$VDM_INTERCOM_ROOT/widget/_done/"; }
out="$(printf '{"session_id":"t","source":"startup"}' | bash "$HOOK")"
says_not "archiving the message silences the notice" "$out" "still in your inbox"
rm -rf docs/tasks/probe-crystal docs/tasks/probe-crystal2

echo ""
echo "== relay form: a letter references the previous one, never contains it =="
# The specimen: one relay in 318 letters (measured 2026-09-22) arrived as 64 KB
# with two levels of `>` quoting, 288 of 550 lines being re-transmitted text.
# Nothing forced that — every inbox is a sibling directory in one store, so the
# previous letter was readable by path all along. What was missing was a form
# for naming it.

mkrepo "$TMP/hop-a" "git@example.com:acme/hop-a.git"
mkrepo "$TMP/hop-b" "git@example.com:acme/hop-b.git"
mkrepo "$TMP/hop-c" "git@example.com:acme/hop-c.git"
( cd "$TMP/hop-a" && bash "$IC" register --name "hop-a" --describe "first hop"  >/dev/null 2>&1 )
( cd "$TMP/hop-b" && bash "$IC" register --name "hop-b" --describe "second hop" >/dev/null 2>&1 )
( cd "$TMP/hop-c" && bash "$IC" register --name "hop-c" --describe "third hop"  >/dev/null 2>&1 )

( cd "$TMP/hop-a" && bash "$IC" send hop-b relay-one --title "Facts from A" >/dev/null 2>&1 )
eq "an ordinary letter carries no reply-to field" \
   "$(grep -c '^reply-to:' "$VDM_INTERCOM_ROOT/hop-b/relay-one.md")" "0"
eq "…and no blank line where the token was" \
   "$(sed -n '9p' "$VDM_INTERCOM_ROOT/hop-b/relay-one.md")" "status: pending"
says_not "…and no CONTINUES banner" "$(cat "$VDM_INTERCOM_ROOT/hop-b/relay-one.md")" "CONTINUES"

( cd "$TMP/hop-b" && bash "$IC" send hop-c relay-two --title "What B adds" --reply-to relay-one >/dev/null 2>&1 )
eq "a relay letter records the reference, qualified by identity" \
   "$(grep '^reply-to:' "$VDM_INTERCOM_ROOT/hop-c/relay-two.md")" "reply-to: hop-b/relay-one"
says "the banner names the previous letter and its title" \
   "$(cat "$VDM_INTERCOM_ROOT/hop-c/relay-two.md")" "**CONTINUES:** \`hop-b/relay-one\` — Facts from A"
says_not "the previous letter is NOT inlined" \
   "$(cat "$VDM_INTERCOM_ROOT/hop-c/relay-two.md")" "📤 **FROM:** \`hop-a\`"

out="$( cd "$TMP/hop-c" && bash "$IC" check 2>&1 )"
says "check shows what the letter continues" "$out" "hop-b/relay-one — Facts from A"

out="$( cd "$TMP/hop-c" && bash "$IC" chain relay-two 2>&1 )"
says "chain walks back one hop" "$out" "hop-b/relay-one"
says "chain prints where the link lives now" "$out" "$VDM_INTERCOM_ROOT/hop-b/relay-one.md"

# The reason the envelope stores a REFERENCE and not a path: picking a letter up
# moves it, and a stored path would quietly start lying.
( cd "$TMP/hop-b" && bash "$IC" pickup relay-one >/dev/null 2>&1 )
out="$( cd "$TMP/hop-c" && bash "$IC" chain relay-two 2>&1 )"
says "an archived link still resolves — _done/ is searched too" "$out" "hop-b/_done/relay-one.md"

( cd "$TMP/hop-c" && bash "$IC" send hop-a relay-three --title "What C adds" --reply-to relay-two >/dev/null 2>&1 )
out="$( cd "$TMP/hop-a" && bash "$IC" chain relay-three 2>&1 )"
says "three hops: the chain reaches the second link" "$out" "hop-c/relay-two"
says "three hops: …and the first" "$out" "hop-b/relay-one"
eq "the chain is derived, not stored — each letter names only its predecessor" \
   "$(grep -c '^reply-to:' "$VDM_INTERCOM_ROOT/hop-a/relay-three.md")" "1"

out="$( cd "$TMP/hop-c" && bash "$IC" send hop-a relay-ghost --reply-to no-such-letter 2>&1 )"; rc=$?
eq "a reference that matches nothing refuses" "$rc" "2"
says "…and says what a reference looks like" "$out" "<identity>/<slug>"
[ ! -f "$VDM_INTERCOM_ROOT/hop-a/relay-ghost.md" ] \
  && ok "…and writes no letter: a letter naming one that is not is worse than none" \
  || bad "relay-ghost.md was written despite the bad reference"

cp "$VDM_INTERCOM_ROOT/hop-c/relay-two.md" "$VDM_INTERCOM_ROOT/hop-a/relay-two.md"
out="$( cd "$TMP/hop-c" && bash "$IC" send hop-a relay-amb --reply-to relay-two 2>&1 )"; rc=$?
eq "an ambiguous bare slug refuses" "$rc" "3"
says "…and names every candidate" "$out" "hop-c/relay-two"
says "…and says how to qualify it" "$out" "--reply-to <identity>/<slug>"
[ ! -f "$VDM_INTERCOM_ROOT/hop-a/relay-amb.md" ] \
  && ok "…and writes no letter" || bad "relay-amb.md was written despite ambiguity"

out="$( cd "$TMP/hop-c" && bash "$IC" send hop-a relay-qual --reply-to hop-c/relay-two 2>&1 )"; rc=$?
eq "the qualified form resolves what the bare one could not" "$rc" "0"
eq "…and records exactly what was asked for" \
   "$(grep '^reply-to:' "$VDM_INTERCOM_ROOT/hop-a/relay-qual.md")" "reply-to: hop-c/relay-two"
rm -f "$VDM_INTERCOM_ROOT/hop-a/relay-two.md"

# A link that is deleted after the fact must be REPORTED, not silently skipped:
# a chain that stops early looks exactly like a chain that was complete.
mv "$VDM_INTERCOM_ROOT/hop-b/_done/relay-one.md" "$TMP/relay-one.parked"
out="$( cd "$TMP/hop-a" && bash "$IC" chain relay-three 2>&1 )"
says "a missing link is named, not skipped" "$out" "(missing"
says "…and the reference that could not be resolved is shown" "$out" "hop-b/relay-one"
mv "$TMP/relay-one.parked" "$VDM_INTERCOM_ROOT/hop-b/_done/relay-one.md"

out="$( cd "$TMP/hop-a" && bash "$IC" chain relay-one 2>&1 )"
says "a letter that starts a chain says so" "$out" "starts the chain"

out="$( cd "$TMP/hop-a" && bash "$IC" chain no-such-letter 2>&1 )"; rc=$?
eq "chain on an unknown slug refuses" "$rc" "2"

echo ""
echo "== body from a file: what was sent is byte-for-byte what was kept =="
# Field request (global-auth-risk-model, 2026-09-24): a sender keeps a copy of
# every outgoing letter in its repo, and its owner audits conclusions against
# that copy. With no way to hand `send` a body, the copy was spliced in by a
# script that had to know where the template's placeholder begins and ends —
# two manual steps, and an error in either is a divergence nobody sees, because
# the recipient never reads the copy and the sender never rereads the letter.

B="$TMP/bodies"; mkdir -p "$B"
# Characters that a substitution pass would eat, and tokens the template uses.
printf '## What we need\n\n- keep `&`, `\\` and `$HOME` as written\n- {{TITLE}} and {{SLUG}} stay literal\n\nLast line, no newline at the end' > "$B/plain.md"

out="$( cd "$TMP/hop-a" && bash "$IC" send hop-b body-plain --title "From a file" --body "$B/plain.md" 2>&1 )"; rc=$?
eq "--body sends" "$rc" "0"
L="$VDM_INTERCOM_ROOT/hop-b/body-plain.md"
if tail -c "$(wc -c < "$B/plain.md")" "$L" | cmp -s - "$B/plain.md"; then
  ok "the letter ends with the file's bytes, exactly — no newline added, nothing substituted"
else
  bad "the letter ends with the file's bytes, exactly" "$(tail -c 200 "$L")"
fi
says_not "no placeholder is left behind" "$(cat "$L")" "Write the brief below"
eq "the envelope is still the template's" "$(sed -n '2p' "$L")" "intercom: v1"
says "the title is still the letter's heading" "$(cat "$L")" "# From a file"
says "the sender is told the body was checked" "$out" "identical"
says_not "…and is not told to go and write it" "$out" "now write the brief body"

( cd "$TMP/hop-a" && bash "$IC" send hop-b body-eq --body="$B/plain.md" >/dev/null 2>&1 )
[ -f "$VDM_INTERCOM_ROOT/hop-b/body-eq.md" ] && ok "--body=<file> works too" || bad "--body=<file> sent nothing"

out="$( cd "$TMP/hop-c" && bash "$IC" send hop-a body-reply --reply-to hop-c/relay-two --body "$B/plain.md" 2>&1 )"; rc=$?
eq "--body works together with --reply-to" "$rc" "0"
eq "…the reference is in the envelope" \
   "$(grep '^reply-to:' "$VDM_INTERCOM_ROOT/hop-a/body-reply.md")" "reply-to: hop-c/relay-two"
if tail -c "$(wc -c < "$B/plain.md")" "$VDM_INTERCOM_ROOT/hop-a/body-reply.md" | cmp -s - "$B/plain.md"; then
  ok "…and the body is the file"
else
  bad "…and the body is the file"
fi

# Every refusal must leave NO letter: a letter with a placeholder for a body
# looks sent, and that is the failure the request exists to remove.
refuses() {  # refuses <desc> <slug> <expect-in-output> <send args…>
  local desc="$1" slug="$2" want="$3"; shift 3
  local o r
  o="$( cd "$TMP/hop-a" && bash "$IC" send hop-b "$slug" "$@" 2>&1 )"; r=$?
  if [ "$r" -ne 0 ] && [ ! -e "$VDM_INTERCOM_ROOT/hop-b/$slug.md" ]; then
    ok "$desc — refused, no letter written"
  else
    bad "$desc — refused, no letter written" "rc=$r, letter exists: $([ -e "$VDM_INTERCOM_ROOT/hop-b/$slug.md" ] && echo yes || echo no)"
  fi
  says "$desc — says why" "$o" "$want"
}
: > "$B/empty.md"
printf '  \n\n\t\n' > "$B/blank.md"
printf '# Draft\n\n<!-- Write the brief below. Replace this comment -->\n' > "$B/unfilled.md"
refuses "a missing file"                  body-missing  "cannot read"  --body "$B/nope.md"
refuses "an empty file"                   body-empty    "empty"        --body "$B/empty.md"
refuses "a whitespace-only file"          body-blank    "empty"        --body "$B/blank.md"
refuses "a file still holding the placeholder" body-unfilled "placeholder" --body "$B/unfilled.md"
refuses "--body with no path"             body-nopath   "--body"       --body
refuses "a directory"                     body-dir      "cannot read"  --body "$B"

# A relative path is the sender's, read from where the sender stands.
mkdir -p "$TMP/hop-a/docs/comms"
cp "$B/plain.md" "$TMP/hop-a/docs/comms/out.md"
( cd "$TMP/hop-a" && bash "$IC" send hop-b body-rel --body docs/comms/out.md >/dev/null 2>&1 )
if [ -f "$VDM_INTERCOM_ROOT/hop-b/body-rel.md" ] && \
   tail -c "$(wc -c < "$B/plain.md")" "$VDM_INTERCOM_ROOT/hop-b/body-rel.md" | cmp -s - "$B/plain.md"; then
  ok "a relative --body path is read from the sender's directory"
else
  bad "a relative --body path is read from the sender's directory"
fi
ls -a "$VDM_INTERCOM_ROOT/hop-b" | grep -q '\.render\.' \
  && bad "no half-rendered file is left in the inbox" "$(ls -a "$VDM_INTERCOM_ROOT/hop-b")" \
  || ok "no half-rendered file is left in the inbox"

echo ""
echo "== a value flag at the end of the line refuses instead of hanging =="
# `--x) v="${2:-}"; shift 2` with the flag as the last argument shifts nothing,
# and the loop sees the same flag forever. Found 2026-09-24 while adding --body:
# `send <to> <slug> --title` hung until killed. Each call runs under an alarm;
# exit 142 is the alarm, i.e. the hang.
bounded() { perl -e 'alarm 10; exec @ARGV' "$@"; }
for flag in --title --from-agent --reply-to --to --body; do
  out="$( cd "$TMP/hop-a" && bounded bash "$IC" send hop-b dangling "$flag" 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 142 ]; then ok "send … $flag (no value) refuses"; else bad "send … $flag (no value) refuses" "rc=$rc"; fi
  says "…and names $flag" "$out" "$flag needs a value"
done
[ ! -e "$VDM_INTERCOM_ROOT/hop-b/dangling.md" ] && ok "…and none of them wrote a letter" || bad "a dangling flag wrote a letter"
out="$( cd "$TMP/hop-a" && bounded bash "$IC" register --name 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 142 ]; then ok "register --name (no value) refuses"; else bad "register --name (no value) refuses" "rc=$rc"; fi
out="$( cd "$TMP/hop-a" && bounded bash "$IC" names add --for 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 142 ]; then ok "names add --for (no value) refuses"; else bad "names add --for (no value) refuses" "rc=$rc"; fi
out="$( cd "$TMP/hop-a" && bounded bash "$IC" describe --for 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 142 ]; then ok "describe --for (no value) refuses"; else bad "describe --for (no value) refuses" "rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
