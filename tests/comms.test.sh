#!/bin/bash
# comms.test.sh — RED TESTS for the vdm-comms plugin.
#
# The contract this linter enforces is a FLOOR distilled from three live
# repositories, so the tests are built out of the shapes those repositories
# actually contain — including the ones that broke the first implementation:
#
#   * a block sequence at indent 0 (`people:` then `- name` in column 1)
#   * a track that resolves to `<path>.md` rather than a directory
#   * a track path three segments deep, and one containing capitals
#   * a meeting in the FUTURE, which legitimately has no index.md yet
#   * raw transcripts with no frontmatter sitting beside the contract files
#   * a project's own `type` vocabulary on role files and handouts
#
# Both directions are tested throughout. A linter that fires on legitimate
# files gets switched off, which costs the real violations too — so every rule
# has a green case proving silence as well as a red one proving noise.
#
# Run: bash tests/comms.test.sh   (exit 0 = all pass)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$REPO_ROOT/plugins/vdm-comms"
LINT="$P/scripts/comms-lint.py"
LINTSH="$P/scripts/comms-lint.sh"
GUARD="$P/scripts/comms-draft-guard.sh"
INDEX="$P/scripts/comms-index.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t commstest)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Canonicalised: on macOS mktemp hands back a path under the /var symlink while
# git and the tools resolve the real one, and a mismatch would take files out of
# scope for reasons that have nothing to do with what is under test.
mkdir -p "$TMP/fx"
FX=$(cd "$TMP/fx" && pwd -P)
( cd "$FX" && git init -q . ) >/dev/null 2>&1

mkdir -p "$FX/meetings" "$FX/gaps/alpha" "$FX/org" "$FX/incidents/one" \
         "$FX/areas/advancement-records" "$FX/program/2026-2027/alpine-skills"
printf '# org file track\n' > "$FX/org/roles.md"          # a track that is a FILE
printf '# caps\n'          > "$FX/areas/INDEX.md"          # a track with capitals

TODAY=2026-09-21
PAST=2026-09-01
FUTURE=2026-12-01

mk_meeting() { # mk_meeting <dir> <leaf> <frontmatter-body>
  mkdir -p "$FX/meetings/$1"
  printf -- '---\n%s\n---\n\n# Заголовок встречи\n\nтекст\n' "$2" > "$FX/meetings/$1/$3"
}

run_lint() { # run_lint <path...>
  OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$LINT" --quiet --project-root "$FX" "$@" 2>&1)
  return $?
}

echo "== contract: the shapes the field repositories actually contain =="

mk_meeting "$FUTURE-planning" "type: meeting
date: $FUTURE
series: null
tracks:
- gaps/alpha" "agenda.md"
run_lint "$FX/meetings/$FUTURE-planning/agenda.md"; rc=$?
expect_exit "GREEN: future meeting without index.md is clean" 0 "$rc"
expect_exit "GREEN: block sequence at indent 0 parses" 0 "$rc"

mk_meeting "$PAST-gone" "type: meeting
date: $PAST
tracks: [gaps/alpha]" "agenda.md"
run_lint "$FX/meetings/$PAST-gone/agenda.md"; rc=$?
expect_exit "RED: past meeting without index.md ⇒ exit 1" 1 "$rc"
expect_says "RED: says the meeting is in the past" "$OUT" "in the past"

printf -- '---\ntype: meeting\ndate: %s\ntracks: [gaps/alpha]\n---\n\n# x\n' "$PAST" \
  > "$FX/meetings/$PAST-gone/index.md"
run_lint "$FX/meetings/$PAST-gone/index.md"; rc=$?
expect_exit "GREEN: past meeting WITH index.md is clean" 0 "$rc"

mk_meeting "$FUTURE-wrongdate" "type: meeting
date: 2026-11-30
tracks: [gaps/alpha]" "agenda.md"
run_lint "$FX/meetings/$FUTURE-wrongdate/agenda.md"; rc=$?
expect_exit "RED: date disagrees with the directory ⇒ exit 1" 1 "$rc"
expect_says "RED: names both dates" "$OUT" "disagrees with the directory date"

mk_meeting "$FUTURE-notrack" "type: meeting
date: $FUTURE
tracks: [gaps/does-not-exist]" "agenda.md"
run_lint "$FX/meetings/$FUTURE-notrack/agenda.md"; rc=$?
expect_exit "RED: track resolves to nothing ⇒ exit 1" 1 "$rc"
expect_says "RED: shows both forms it tried" "$OUT" "neither"

mk_meeting "$FUTURE-filetrack" "type: meeting
date: $FUTURE
tracks:
  - org/roles
  - areas/INDEX
  - program/2026-2027/alpine-skills" "agenda.md"
run_lint "$FX/meetings/$FUTURE-filetrack/agenda.md"; rc=$?
expect_exit "GREEN: file track, capitals and depth-3 all resolve" 0 "$rc"

mk_meeting "$FUTURE-topics" "type: meeting
date: $FUTURE
tracks: [gaps/alpha]
topics:
  - name: \"тема\"
    track: incidents/one" "agenda.md"
run_lint "$FX/meetings/$FUTURE-topics/agenda.md"; rc=$?
expect_exit "RED: topic track outside the meeting's tracks ⇒ exit 1" 1 "$rc"
expect_says "RED: names the offending track" "$OUT" "incidents/one"

echo ""
echo "== scope: what is NOT under contract must stay silent =="

printf '*Speaker 1:* …\n' > "$FX/meetings/$FUTURE-planning/transcript.md"
run_lint "$FX/meetings/$FUTURE-planning/transcript.md"; rc=$?
expect_exit "GREEN: raw transcript without frontmatter ⇒ exit 0" 0 "$rc"
expect_not_says "GREEN: and says nothing about it" "$OUT" "frontmatter"

printf -- '---\ntype: meeting-handout\n---\n\n# раздатка\n' \
  > "$FX/meetings/$FUTURE-planning/handout.md"
run_lint "$FX/meetings/$FUTURE-planning/handout.md"; rc=$?
expect_exit "GREEN: a project's own type on a non-role file ⇒ exit 0" 0 "$rc"

printf -- '---\ntype: meeting-agenda\ndate: %s\ntracks: [gaps/alpha]\n---\n\n# x\n' "$FUTURE" \
  > "$FX/meetings/$FUTURE-planning/agenda.md"
run_lint "$FX/meetings/$FUTURE-planning/agenda.md"; rc=$?
expect_exit "GREEN: role file with a divergent type still passes" 0 "$rc"
expect_says "GREEN: but the divergence is named" "$OUT" "role file"

printf -- '---\ntype: meeting-series\n---\n\n## Очередь тем\n\n| что-то | своё |\n' \
  > "$FX/meetings/troop.md"
run_lint "$FX/meetings/troop.md"; rc=$?
expect_exit "GREEN: a series file body is never checked" 0 "$rc"

OUT=$(cd "$TMP" && python3 "$LINT" --all --quiet --project-root "$TMP" 2>&1); rc=$?
expect_exit "GREEN: a project with no meetings dir ⇒ exit 0" 0 "$rc"

echo ""
echo "== config: series membership is the invariant, the file is a note =="

mkdir -p "$FX/.claude"
printf '{\n  "comms": {\n    "series": ["plc"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
mk_meeting "$FUTURE-series" "type: meeting
date: $FUTURE
series: troop
tracks: [gaps/alpha]" "agenda.md"
run_lint "$FX/meetings/$FUTURE-series/agenda.md"; rc=$?
expect_exit "RED: series outside the declared list ⇒ exit 1" 1 "$rc"
expect_says "RED: names the declared list" "$OUT" "declared list"

printf '{\n  "comms": {\n    "series": ["plc", "troop"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
run_lint "$FX/meetings/$FUTURE-series/agenda.md"; rc=$?
expect_exit "GREEN: declared series passes" 0 "$rc"

printf '{\n  "comms": {\n    "series": ["plc", "committee"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
mk_meeting "$FUTURE-nofile" "type: meeting
date: $FUTURE
series: committee
tracks: [gaps/alpha]" "agenda.md"
run_lint "$FX/meetings/$FUTURE-nofile/agenda.md"; rc=$?
expect_exit "GREEN: declared series with no file is a warning, not an error" 0 "$rc"
expect_says "GREEN: and the note names the missing file" "$OUT" "committee.md"

printf '{\n  "comms": {\n    "track-roots": ["gaps"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
run_lint "$FX/meetings/$FUTURE-filetrack/agenda.md"; rc=$?
expect_exit "RED: track root outside the configured list ⇒ exit 1" 1 "$rc"
expect_says "RED: names the root it rejected" "$OUT" "track root"
rm -f "$FX/.claude/vdm-plugins.json"

echo ""
echo "== draft guard: the path shape, not a list of prefixes =="

payload() { # payload <tool> <path> <content>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
print(json.dumps({"tool_name": sys.argv[1],
                  "tool_input": {"file_path": sys.argv[2], "content": sys.argv[3]},
                  "cwd": "."}))
PY
}

SENT=$'---\nsent: 2026-09-21\n---\n\nтекст письма\n'
DRAFT=$'---\ndraft: true\n---\n\nтекст письма\n'

for track in gaps/alpha org incidents/one; do
  mkdir -p "$FX/$track/comms"
  OUT=$(payload Write "$FX/$track/comms/2026-09-21-x-out.md" "$SENT" | bash "$GUARD" 2>&1); rc=$?
  expect_exit "RED: new -out.md claiming sent: under $track ⇒ exit 2" 2 "$rc"
done
expect_says "RED: the message says what to write instead" "$OUT" "draft: true"

OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-y-out.md" "$DRAFT" | bash "$GUARD" 2>&1); rc=$?
expect_exit "GREEN: a real draft passes" 0 "$rc"

printf '%s' "$SENT" > "$FX/gaps/alpha/comms/2026-09-21-z-out.md"
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-z-out.md" "$SENT" | bash "$GUARD" 2>&1); rc=$?
expect_exit "GREEN: editing an existing sent letter passes" 0 "$rc"

OUT=$(payload Write "$FX/gaps/alpha/notes.md" "$SENT" | bash "$GUARD" 2>&1); rc=$?
expect_exit "GREEN: a file outside comms/ passes" 0 "$rc"

echo ""
echo "== index: generated layer is proposed, never written behind your back =="

rm -rf "$FX/meetings" && mkdir -p "$FX/meetings"
mk_meeting "$PAST-one" "type: meeting
date: $PAST
series: plc
tracks:
  - gaps/alpha
  - org/roles
topics:
  - name: \"важное\"
    track: gaps/alpha" "index.md"

OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1); rc=$?
expect_exit "RED: missing pointers ⇒ exit 1" 1 "$rc"
expect_says "RED: names the pointer it would write" "$OUT" "gaps/alpha/comms/$PAST-one-meeting.md"
expect_says "RED: a FILE track gets a note, not a pointer" "$OUT" "resolves to a FILE"
expect_says "RED: INDEX.md without markers is reported, not rewritten" "$OUT" "INDEX.md does not exist"

OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1); rc=$?
expect_exit "WRITE: applying changes reports exit 1 (something changed)" 1 "$rc"
[ -f "$FX/gaps/alpha/comms/$PAST-one-meeting.md" ] \
  && ok "WRITE: the pointer exists" || bad "WRITE: the pointer exists"
expect_says "WRITE: the pointer body carries this meeting's topic" \
  "$(cat "$FX/gaps/alpha/comms/$PAST-one-meeting.md")" "важное"

OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1); rc=$?
# Exit 0 although INDEX.md is still missing, and that is the intended split: a
# NOTE is not drift. Whether this project wants a registry file at all is its
# own call, and creating one unasked is exactly the "plugin writes into your
# tree" move the field repositories objected to. The note stays visible in
# `--check`; only real staleness sets the exit code and wakes the signal.
expect_exit "GREEN: a second check finds the pointers in sync (a note is not drift)" 0 "$rc"
expect_says "GREEN: the missing registry is still reported as a note" "$OUT" "INDEX.md does not exist"
expect_not_says "GREEN: and no longer proposes the pointer" "$OUT" "update gaps/alpha/comms"

printf '# Реестр\n\n<!-- registry:start -->\n<!-- registry:end -->\n' > "$FX/meetings/INDEX.md"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1); rc=$?
expect_says "WRITE: the registry table lands between the markers" \
  "$(cat "$FX/meetings/INDEX.md")" "$PAST"
OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1); rc=$?
expect_exit "GREEN: everything in sync ⇒ exit 0" 0 "$rc"

# A pointer whose meeting stopped naming that track is ours to remove.
sed -i.bak 's|  - gaps/alpha|  - incidents/one|' "$FX/meetings/$PAST-one/index.md"
rm -f "$FX/meetings/$PAST-one/index.md.bak"
OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1); rc=$?
expect_says "RED: a pointer for a dropped track is proposed for removal" "$OUT" "remove gaps/alpha/comms"

# A file we did not generate is never touched.
printf -- '---\ntype: meeting-link\n---\n\nнаписано человеком\n' \
  > "$FX/incidents/one/comms/$PAST-one-meeting.md"
OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1); rc=$?
expect_says "GREEN: a hand-written pointer is left alone, with a note" "$OUT" "was not generated"

echo ""
echo "== fail-closed: the two blocking hooks with python3 stripped from PATH =="

FARM="$TMP/bin-nopy"
mkdir -p "$FARM"
for t in bash sh grep sed awk cat tr mktemp date git printf head tail sort uniq wc find \
         dirname basename cut env mv rm mkdir readlink stat diff cp touch ls tee xargs \
         cmp true false test expr realpath id uname; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$FARM/$t"
done
JQ=$(command -v jq 2>/dev/null || true)
[ -n "$JQ" ] && ln -sf "$JQ" "$FARM/jq"

hook_payload=$(payload Write "$FX/meetings/$PAST-one/index.md" "x")
OUT=$(printf '%s' "$hook_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
expect_exit "RED: comms-lint hook without python3 ⇒ exit 2" 2 "$rc"
expect_says "RED: it says NOT CHECKED" "$OUT" "NOT CHECKED"

out_payload=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-new-out.md" "$SENT")
OUT=$(printf '%s' "$out_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$GUARD'" 2>&1); rc=$?
expect_exit "RED: draft guard without python3 ⇒ exit 2" 2 "$rc"

src_payload=$(payload Write "$FX/gaps/alpha/notes.md" "ordinary text")
OUT=$(printf '%s' "$src_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a file outside meetings/ ⇒ exit 0" 0 "$rc"

OUT=$(printf '%s' "$src_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a file outside comms/ ⇒ exit 0" 0 "$rc"

printf '\ncomms: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
