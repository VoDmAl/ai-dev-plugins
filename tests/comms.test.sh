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

# Scrub git's per-invocation environment before anything else. A test harness
# run from inside a live `git commit` (which is what a pre-commit gate is)
# inherits GIT_INDEX_FILE / GIT_DIR pointing at THAT commit — and every `git`
# call against a throwaway fixture then writes into the user's real commit
# instead. Measured 2026-09-22 on this file's sibling: one `git add -A` in a
# fixture replaced all 158 entries of the pending commit's index with 9
# fixture paths. The commit survived only because the objects were missing.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$REPO_ROOT/plugins/vdm-comms"
# Overridable so a change can be proved red against the previous version.
LINT="${COMMS_LINT_BIN:-$P/scripts/comms-lint.py}"
LINTSH="$P/scripts/comms-lint.sh"
GUARD="$P/scripts/comms-draft-guard.sh"
INDEX="${COMMS_INDEX_BIN:-$P/scripts/comms-index.py}"
INDEXCHECK="${COMMS_INDEX_CHECK_SH:-$P/scripts/comms-index-check.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }
expect_silent() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

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
expect_silent "GREEN: and says nothing about it" "$OUT"

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

# The checklist arrives at the moment the draft is created (executor brief §1; owner
# 13.09: «Скил не лечит — его тоже надо не забыть вызвать»). It rides on the
# guard's own event, as additionalContext — never a block.
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-y-out.md" "$DRAFT" | bash "$GUARD" 2>/dev/null)
ctx=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["hookEventName"]); print(d["additionalContext"])' 2>/dev/null)
expect_says "RED: creating a draft brings the checklist, as PreToolUse context" "$ctx" "PreToolUse"
expect_says "…the checklist itself" "$ctx" "Before showing this draft"
expect_says "…with the decision-not-backstory line" "$ctx" "not the reader's own decisions retold"
# hq, 2026-09-29: «посмотрели… мы бы закрыли» — the owner's agent did it and
# would do it; the owner sent «посмотрел… я бы закрыл». The pronoun names the actor.
expect_says "…and the pronoun check: who really acts" "$ctx" "the pronoun names who really acts"
# hq, 2026-09-29 (letters-email-form-and-scope): the owner ended a request
# with «Дай знать, пожалуйста, как сделаешь, проверю…» and added «Спасибо!». Two
# checklist lines, compressed past the skill, forbade both: a bare "let me know"
# as an exit, and "courtesies" read as politeness rather than obliging extras.
expect_says "…an exit is putting it off, not a signal that it is done" "$ctx" "let me know when convenient"
expect_not_says "…a courtesy is an obliging extra, not a please or a thanks" "$ctx" "no courtesies"
expect_says "…and the channel sets the body's form" "$ctx" "a greeting on its own line"
# hq, 2026-09-30 (letters-connect-dont-relay): the owner's worker did one
# half of a request, a third person waited on the other half, and the session
# carried the news between them. Owner: connect them — a copy, a mention.
expect_says "…and whoever else waits on the subject is in copy, not us in the middle" "$ctx" "not us in the middle"
# program, 2026-10-04 (vdm-comms-bcc-earlier-witnesses), the owner: someone who
# saw the subject earlier but needs no part in what follows gets a blind copy
# of the first answer — they see it is not lost, and reply-all leaves them out.
expect_says "RED: …and whoever saw it earlier, needing no continuation, gets a blind copy of the first answer" "$ctx" "blind copy of this first answer"
# hq, 2026-10-05 (letters-write-from-their-artifact): a review point on someone
# else's epic was drafted from our own notes, and went out without an edit only
# after the epic was read live and the draft rebuilt from it — its place, terms,
# stages, the full key of our related task, the condition that lifts the
# restriction. A check for each of these was in place; none fired, since each
# reads the finished text and the error was in the material it was built from.
expect_says "RED: …writing into someone else's artifact: read it live first, and build the draft from it" "$ctx" "it was read live first, and the draft is built from it"
expect_says "RED: …and a ticket goes by its full key, never a bare number" "$ctx" "a ticket goes by its full key, never a bare number"
expect_not_says "…no register line when none is declared" "$ctx" "Register:"
printf '{\n  "comms": {\n    "register": "peer",\n    "language": "en"\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-y-out.md" "$DRAFT" | bash "$GUARD" 2>/dev/null)
expect_says "RED: the project's register is named" "$OUT" "Register: peer"
expect_says "…a peer doing a favour outside their queue gets a please and a thanks" "$OUT" "please"
expect_says "…and the language" "$OUT" "Language of the letter: en"
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-y-out.md" $'---\ndraft: true\nregister: volunteer\n---\n\nHi.\n' | bash "$GUARD" 2>/dev/null)
expect_says "RED: the letter's own register wins" "$OUT" "Register: volunteer"
rm -f "$FX/.claude/vdm-plugins.json"
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-x-out.md" "$SENT" | bash "$GUARD" 2>/dev/null); rc=$?
expect_exit "GREEN: a blocked letter is still blocked" 2 "$rc"
case "$OUT" in *"Before showing"*) bad "…and gets no checklist" "stdout: $OUT" ;; *) ok "…and gets no checklist" ;; esac

printf '%s' "$SENT" > "$FX/gaps/alpha/comms/2026-09-21-z-out.md"
OUT=$(payload Write "$FX/gaps/alpha/comms/2026-09-21-z-out.md" "$SENT" | bash "$GUARD" 2>&1); rc=$?
expect_exit "GREEN: editing an existing sent letter passes" 0 "$rc"
expect_silent "…and says nothing — the checklist is for a new draft" "$OUT"

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
echo "== wording of generated files is the project's, not the plugin's =="

# The generator writes into somebody else's repository, so the language of what
# it writes cannot be the language its authors happen to work in. Default is
# English; a project switches with one key, or renames individual columns.
POINTER="$FX/gaps/alpha/comms/$PAST-one-meeting.md"
rm -f "$FX/.claude/vdm-plugins.json" 2>/dev/null
sed -i.bak 's|  - incidents/one|  - gaps/alpha|' "$FX/meetings/$PAST-one/index.md"
rm -f "$FX/meetings/$PAST-one/index.md.bak"
rm -f "$POINTER"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1)
expect_says "GREEN: default wording is English" "$(cat "$POINTER")" "Topics on this track:"
expect_says "GREEN: and the registry header too" "$(cat "$FX/meetings/INDEX.md")" "| Date | Meeting |"

mkdir -p "$FX/.claude"
printf '{\n  "comms": {\n    "labels": "ru"\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1)
expect_says "GREEN: labels: ru switches the generated wording" "$(cat "$POINTER")" "Темы этого трека:"

printf '{\n  "comms": {\n    "labels": { "col-meeting": "Созвон" }\n  }\n}\n' \
  > "$FX/.claude/vdm-plugins.json"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1)
REG=$(cat "$FX/meetings/INDEX.md")
expect_says "GREEN: a map overrides one column" "$REG" "Созвон"
expect_says "GREEN: …and the rest stays English" "$REG" "| Date |"
rm -f "$FX/.claude/vdm-plugins.json"

echo ""
echo "== pointers: every link is computed from the pointer's own directory =="

# Field report 2026-09-23: `../../<meeting>` was written into every pointer.
# From a one-segment track that is right; from `<root>/<a>/<b>/comms/` it lands
# in `<root>/<a>/meetings/` — 87 of 87 pointers in one repository opened
# nothing. Tracks of depth 1, 2 and 3, each link resolved on disk.
mkdir -p "$FX/solo" "$FX/program/2026-2027/alpine-skills"
mk_meeting "$PAST-deep" "type: meeting
date: $PAST
tracks:
  - solo
  - gaps/alpha
  - program/2026-2027/alpine-skills" "index.md"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1)
resolves() { # resolves <pointer> — every markdown link target in it exists
  python3 - "$1" <<'PY'
import os, re, sys
p = sys.argv[1]; here = os.path.dirname(p)
links = re.findall(r"\]\(([^)]+)\)", open(p, encoding="utf-8").read())
sys.exit(0 if links and all(os.path.exists(os.path.normpath(os.path.join(here, l))) for l in links) else 1)
PY
}
for t in solo gaps/alpha program/2026-2027/alpine-skills; do
  if resolves "$FX/$t/comms/$PAST-deep-meeting.md"; then
    ok "the pointer in $t/comms/ opens the meeting"
  else
    bad "the pointer in $t/comms/ opens the meeting" "$(grep -o '](.*)' "$FX/$t/comms/$PAST-deep-meeting.md" | head -2)"
  fi
done

echo ""
echo "== wikilink mode, registry columns, materials and topic anchors =="

mkdir -p "$FX/people"
printf '# Ivan\n' > "$FX/people/ivan-petrov.md"
mkdir -p "$FX/.claude"
cat > "$FX/.claude/vdm-plugins.json" <<'JSON'
{
  "comms": {
    "link-style": "wikilink",
    "registry-columns": ["date", "meeting", "people", "tracks", "topics", "materials"],
    "series-columns": ["date", "meeting", "people"]
  }
}
JSON
mkdir -p "$FX/meetings/$PAST-rich"
cat > "$FX/meetings/$PAST-rich/index.md" <<EOF
---
type: meeting
date: $PAST
series: plc
people: [ivan-petrov, nobody-profiled]
tracks: [gaps/alpha]
topics:
  - name: "First: the question"
    track: gaps/alpha
  - name: "A tail"
    track: null
    tail: true
---

# A rich meeting

## Topic 1. First: the question

> Track: [[../../gaps/alpha/index|alpha]]

## Topic 2. A tail
EOF
printf 'agenda\n' > "$FX/meetings/$PAST-rich/agenda.md"
printf 'Speaker 1: …\n' > "$FX/meetings/$PAST-rich/transcript.txt"
printf '# alpha\n' > "$FX/gaps/alpha/index.md"
printf -- '---\ntype: meeting-series\nslug: plc\n---\n\n<!-- meetings:start -->\n<!-- meetings:end -->\n' \
  > "$FX/meetings/plc.md"
printf '# Registry\n\n<!-- registry:start -->\n<!-- registry:end -->\n' > "$FX/meetings/INDEX.md"
OUT=$(cd "$FX" && python3 "$INDEX" --write --project-root "$FX" 2>&1)
REG=$(cat "$FX/meetings/INDEX.md")
PTR=$(cat "$FX/gaps/alpha/comms/$PAST-rich-meeting.md")
expect_says "WIKI: the meeting is a wikilink, pipe escaped inside the table" "$REG" "[[$PAST-rich/index\\|A rich meeting]]"
expect_says "WIKI: a profiled person links to the profile" "$REG" "[[../people/ivan-petrov\\|ivan-petrov]]"
expect_says "WIKI: …an unprofiled one stays plain text" "$REG" ", nobody-profiled |"
expect_says "WIKI: a track links to its index" "$REG" "[[../gaps/alpha/index\\|alpha]]"
expect_says "WIKI: topics count their tails" "$REG" "| 2 (+1 tail) |"
expect_says "WIKI: materials list the agenda and the transcript" "$REG" "[[$PAST-rich/agenda\\|agenda]] · [[$PAST-rich/transcript.txt\\|transcript]]"
expect_says "WIKI: the header follows the configured columns" "$REG" "| Date | Meeting | Participants | Tracks | Topics | Materials |"
expect_says "WIKI: a series file takes its own columns" "$(cat "$FX/meetings/plc.md")" "| Date | Meeting | Participants |"
expect_says "WIKI: the pointer links back with a wikilink, three levels up" "$PTR" "[[../../../meetings/$PAST-rich/index|index.md]]"
expect_says "WIKI: the pointer lists the materials" "$PTR" "[[../../../meetings/$PAST-rich/transcript.txt|transcript]]"
expect_says "WIKI: a topic links to its own heading, exactly as written" "$PTR" "[[../../../meetings/$PAST-rich/index#Topic 1. First: the question|First: the question]]"
expect_not_says "WIKI: no markdown link is left in the pointer" "$PTR" "]("

printf '{\n  "comms": {\n    "registry-columns": ["date", "nonsense"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
OUT=$(cd "$FX" && python3 "$INDEX" --check --project-root "$FX" 2>&1)
expect_says "an unknown column is named, not silently dropped" "$OUT" "unknown column(s) nonsense"
rm -f "$FX/.claude/vdm-plugins.json"

echo ""
echo "== meeting-rules: a project's own conventions, off until named =="

# Field report 2026-09-23: a deliberately broken agenda and series file — the
# repository's own linter found nine errors, this one answered "ok". Every
# rule below is theirs, so every rule sits behind a key. First: with no key,
# the same broken files stay clean under the floor (the floor is not raised).
mkdir -p "$FX/meetings/$FUTURE-broken"
cat > "$FX/meetings/$FUTURE-broken/agenda.md" <<EOF
---
type: meeting
date: $FUTURE
gap: gaps/alpha
meeting_date: $FUTURE
people: [ivan-petrov, ghost-person]
tracks: [gaps/alpha]
topics:
  - name: "One"
    track: gaps/alpha
    must: true
    owner: ivan-petrov
  - name: "Two"
    track: gaps/alpha
    must: true
    owner: ghost-person
  - name: "Three"
    track: gaps/alpha
    must: true
  - name: "Tail"
    track: null
    tail: true
---

# A broken agenda

## Topic 1. One

> Track: [[../../gaps/alpha/index|alpha]]

## Topic 2. Two

plain prose where the track line should be

## Topic 3. Three

> Track: somewhere unnamed

## Topic 4. Tail

> Track: tail — nobody's yet
EOF
printf -- '---\ntype: meeting-series\nslug: board\n---\n\n# not the board\n' > "$FX/meetings/wrongslug.md"
printf -- '---\ntype: meeting-series\n---\n\n# no slug at all\n' > "$FX/meetings/noslug.md"

rm -f "$FX/.claude/vdm-plugins.json"
run_lint "$FX/meetings/$FUTURE-broken/agenda.md"; rc=$?
expect_exit "GREEN: without meeting-rules the broken agenda passes the floor" 0 "$rc"
run_lint "$FX/meetings/noslug.md"; rc=$?
expect_exit "GREEN: a series file without slug passes the floor" 0 "$rc"
run_lint "$FX/meetings/wrongslug.md"; rc=$?
expect_exit "RED (floor): a slug that disagrees with the file name ⇒ exit 1" 1 "$rc"
expect_says "RED (floor): …names both" "$OUT" "disagrees with the file name wrongslug.md"

cat > "$FX/.claude/vdm-plugins.json" <<'JSON'
{
  "comms": {
    "topic-sections": true,
    "people-dir": "people",
    "meeting-rules": {
      "forbidden-keys": ["gap", "gaps", "sent", "draft", "meeting_date"],
      "people-profiles": true,
      "topic-owner": ["agenda"],
      "tail-owner": true,
      "max-must": 2,
      "topic-track-line": "> Track:",
      "series-slug": true,
      "covered-bool": true,
      "unique-topics": true,
      "required-keys": ["series", "tracks"]
    }
  }
}
JSON
run_lint "$FX/meetings/$FUTURE-broken/agenda.md"; rc=$?
expect_exit "RED: the broken agenda fails once the rules are named" 1 "$rc"
expect_says "rule 1: a retired key" "$OUT" "\`gap:\` is a retired key"
expect_says "rule 1: …each of them" "$OUT" "\`meeting_date:\` is a retired key"
expect_says "rule 2: a person without a profile" "$OUT" "no profile people/ghost-person.md"
expect_says "rule 2: …a topic owner without one" "$OUT" "owner ghost-person has no profile"
expect_says "rule 3: an agenda topic without an owner" "$OUT" "topic 3 «Three» has no \`owner\`"
expect_says "rule 4: a tail without an owner" "$OUT" "topic 4 «Tail» is a tail (no track) with no \`owner\`"
expect_says "rule 5: three must-topics where two are allowed" "$OUT" "3 topics are \`must: true\` — at most 2"
expect_says "rule 6: a section that does not open with the track line" "$OUT" "under «## Topic 2. Two» the first line is not «> Track: …»"
expect_says "rule 6: a track line naming no track and no tail" "$OUT" "«## Topic 3. Three»: the «> Track:» line names neither"
expect_not_says "rule 6: a linked track line passes" "$OUT" "Topic 1. One»"
expect_not_says "rule 6: the word tail passes" "$OUT" "Topic 4. Tail»:"
expect_says "rule 9: a required key that is absent" "$OUT" "no \`series:\`"
expect_not_says "rule 9: a required key that is present is not reported" "$OUT" "no \`tracks:\`"
run_lint "$FX/meetings/noslug.md"; rc=$?
expect_exit "rule 7: series-slug asks every series file for a slug" 1 "$rc"

mkdir -p "$FX/meetings/$PAST-record"
cat > "$FX/meetings/$PAST-record/index.md" <<EOF
---
type: meeting
date: $PAST
series: null
tracks: [gaps/alpha]
topics:
  - name: "Same"
    track: gaps/alpha
    covered: partially
  - name: "Same"
    track: gaps/alpha
    covered: true
---

# A record

## Topic 1. Same

> Track: [[../../gaps/alpha/index|alpha]]

## Topic 2. Same

> Track: [[../../gaps/alpha/index|alpha]]
EOF
run_lint "$FX/meetings/$PAST-record/index.md"; rc=$?
expect_exit "rule 8: covered and repeated names are warnings — no block" 0 "$rc"
expect_says "rule 8: covered that is not a bool" "$OUT" "\`covered: partially\` is neither true nor false"
expect_says "rule 8: a repeated topic name" "$OUT" "topic name «Same» repeats"

mkdir -p "$FX/meetings/$FUTURE-imported"
cat > "$FX/meetings/$FUTURE-imported/agenda.md" <<EOF
---
type: meeting
date: $FUTURE
series: null
migrated_from: [gaps/alpha/comms/old-notes.md]
people: [ghost-person]
tracks: [gaps/alpha]
topics:
  - name: "Imported"
    track: null
    tail: true
    must: true
---

# imported as it was
EOF
run_lint "$FX/meetings/$FUTURE-imported/agenda.md"; rc=$?
expect_exit "migrated_from: an imported record is not failed for predating the rules" 0 "$rc"
expect_says "migrated_from: …the reference rules still say what is missing" "$OUT" "no profile people/ghost-person.md"
rm -f "$FX/.claude/vdm-plugins.json"

echo ""
echo "== outgoing letters: what to attach is a checklist the sender can click =="

# Field report 2026-09-23: a draft said "attached", listed the file in
# frontmatter and as a path in backticks in the header — and the person sending
# it by hand never saw either. The shape below is that draft's.
mkdir -p "$FX/gaps/alpha/comms/attachments"
LETTER="$FX/gaps/alpha/comms/2026-09-23-reply-out.md"
cat > "$LETTER" <<'EOF'
---
draft: true
attachments:
  - attachments/summary.pdf
---

> 📎 attach when sending: `attachments/summary.pdf`

The summary is attached.
EOF
run_lint "$LETTER"; rc=$?
expect_exit "RED: attachments in frontmatter and a path in backticks ⇒ exit 1" 1 "$rc"
expect_says "RED: …says where the sender actually looks" "$OUT" "reads the body, not the frontmatter"

cat > "$LETTER" <<'EOF'
---
draft: true
attachments:
  - attachments/summary.pdf
---

## 📎 Attach before sending

- [ ] [Summary of the survey.pdf](attachments/summary.pdf) — the numbers; the recipient is new to the thread, so earlier attachments do not carry over

The summary is attached.
EOF
run_lint "$LETTER"; rc=$?
expect_exit "RED: a checklist item linking a file that is not there ⇒ exit 1" 1 "$rc"
expect_says "RED: …names the missing file" "$OUT" "attachments/summary.pdf, which does not exist"
printf '%%PDF-1.7\n' > "$FX/gaps/alpha/comms/attachments/summary.pdf"
run_lint "$LETTER"; rc=$?
expect_exit "GREEN: one linked checkbox per existing file ⇒ exit 0" 0 "$rc"

sed -i.bak 's|^- \[ \] \[Summary of the survey.pdf\](attachments/summary.pdf)|- [ ] `attachments/summary.pdf`|' "$LETTER"
rm -f "$LETTER.bak"
run_lint "$LETTER"; rc=$?
expect_exit "RED: an item that is a path in backticks, not a link ⇒ exit 1" 1 "$rc"
expect_says "RED: …and says why" "$OUT" "is not a link to the file"

printf -- '---\nsent: 2026-09-20\nattachments:\n  - attachments/gone.pdf\n---\n\nSent long ago.\n' > "$LETTER"
run_lint "$LETTER"; rc=$?
expect_exit "GREEN: a letter that went out is history — not checked" 0 "$rc"
printf -- '---\ndraft: true\n---\n\nNothing attached here.\n' > "$LETTER"
run_lint "$LETTER"; rc=$?
expect_exit "GREEN: a draft that attaches nothing is never asked about attachments" 0 "$rc"

printf -- '---\ndraft: true\nattachments: [attachments/summary.pdf]\n---\n\nAttached.\n' > "$LETTER"
OUT=$(payload Write "$LETTER" "x" | (cd "$FX" && bash "$LINTSH" --hook) 2>&1); rc=$?
expect_exit "HOOK: a letter written without its checklist comes back as feedback (exit 2)" 2 "$rc"
expect_says "HOOK: …headed as a letter, not a meeting" "$OUT" "this outgoing letter does not meet the contract"
rm -f "$LETTER"

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

printf -- '---\ndraft: true\n---\n' > "$FX/gaps/alpha/comms/2026-09-23-farm-out.md"
letter_payload=$(payload Write "$FX/gaps/alpha/comms/2026-09-23-farm-out.md" "x")
OUT=$(printf '%s' "$letter_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
expect_exit "RED: an outgoing letter written without python3 ⇒ NOT CHECKED, exit 2" 2 "$rc"
rm -f "$FX/gaps/alpha/comms/2026-09-23-farm-out.md"

src_payload=$(payload Write "$FX/gaps/alpha/notes.md" "ordinary text")
OUT=$(printf '%s' "$src_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a file outside meetings/ ⇒ exit 0" 0 "$rc"

OUT=$(printf '%s' "$src_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a file outside comms/ ⇒ exit 0" 0 "$rc"

echo ""
echo "== frontmatter: valid YAML is read, not refused =="
# Field case, 2026-09-23 (program): `goal: |` — a block scalar — in 92
# files, because that repository's rule is that a goal has two halves on two
# lines. The reader stopped at the first continuation line; the hook turned
# that into a blocked write. 0.4.0 hid it for outgoing letters by reading them
# leniently, and the report stopped reproducing — while role files, series
# files and incoming letters kept failing. These cases are those survivors.

BS='goal: |
  На сейчас: первая половина.
  На будущее: вторая половина.'
mk_meeting "$FUTURE-bs" "type: meeting
date: $FUTURE
$BS
tracks: [gaps/alpha]" agenda.md
run_lint "$FX/meetings/$FUTURE-bs/agenda.md"; rc=$?
expect_exit "RED: a role file with a block-scalar goal is read ⇒ exit 0" 0 "$rc"
expect_silent "…and says nothing — no 'cannot read line'" "$OUT"

printf -- '---\ntype: meeting-series\n%s\n---\n\n# series\n' "$BS" > "$FX/meetings/bsseries.md"
run_lint "$FX/meetings/bsseries.md"; rc=$?
expect_exit "RED: a series file with a block scalar ⇒ exit 0" 0 "$rc"

mkdir -p "$FX/meetings/$FUTURE-bs/comms"
printf -- '---\ntype: comms\n%s\n---\n\n# incoming\n' "$BS" > "$FX/meetings/$FUTURE-bs/comms/$FUTURE-x-in.md"
run_lint "$FX/meetings/$FUTURE-bs/comms/$FUTURE-x-in.md"; rc=$?
expect_exit "RED: an incoming letter in a meeting dir with a block scalar ⇒ exit 0" 0 "$rc"

mk_meeting "$FUTURE-bstopic" "type: meeting
date: $FUTURE
tracks: [gaps/alpha]
topics:
  - name: Первая
    note: |
      строка один
      строка два
    track: gaps/alpha" agenda.md
run_lint "$FX/meetings/$FUTURE-bstopic/agenda.md"; rc=$?
expect_exit "RED: a block scalar INSIDE a topic item, siblings still read ⇒ exit 0" 0 "$rc"

mk_meeting "$FUTURE-plainml" "type: meeting
date: $FUTURE
goal: first half
  second half
tracks: [gaps/alpha]" agenda.md
run_lint "$FX/meetings/$FUTURE-plainml/agenda.md"; rc=$?
expect_exit "a value continued without a block header is still refused" 1 "$rc"
expect_says "…and the refusal names the shape and the fix" "$OUT" "needs a block scalar"

echo ""
echo "== frontmatter: a comment is never a value =="
# `sent: false  # not yet` used to come back as the string "false" — every caller
# reads a non-empty `sent` as SENT, so an unsent letter left the unsent list.

mkdir -p "$FX/gaps/alpha/comms"
cat > "$FX/gaps/alpha/comms/2026-09-20-cmt-out.md" <<'EOF'
---
sent: false   # not yet
attachments: [plan.pdf]
---

# a letter whose attachment was never listed in the body
EOF
OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$LINT" --project-root "$FX" "$FX/gaps/alpha/comms/2026-09-20-cmt-out.md" 2>&1); rc=$?
expect_exit "RED: 'sent: false  # comment' is NOT sent — the letter is checked ⇒ exit 1" 1 "$rc"
expect_says "…and its real defect is reported" "$OUT" "no \`## 📎"

mk_meeting "$FUTURE-cmt" "type: meeting
date: $FUTURE
tracks: [gaps/alpha]   # the one track
series: null           # not a series meeting" agenda.md
run_lint "$FX/meetings/$FUTURE-cmt/agenda.md"; rc=$?
expect_exit "RED: a flow list and a null followed by comments are read as such ⇒ exit 0" 0 "$rc"

echo ""
echo "== skipped is said, not implied =="
# Field case, 2026-09-23: a letter outside the contract gave empty output, and
# 88 files with a broken goal read as having passed.

run_skip() { OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$LINT" --project-root "$FX" "$@" 2>&1); return $?; }
printf '# notes\n' > "$FX/gaps/alpha/notes.md"
run_skip "$FX/gaps/alpha/notes.md"; rc=$?
expect_says "RED: a file outside the contract, named explicitly ⇒ 'skipped'" "$OUT" "skipped (not under the meetings contract"
expect_exit "…with exit 0 — skipping is not a failure" 0 "$rc"

printf -- '---\ndraft: true\n---\n\n# a letter that attaches nothing\n' > "$FX/gaps/alpha/comms/2026-09-20-plain-out.md"
run_skip "$FX/gaps/alpha/comms/2026-09-20-plain-out.md"
expect_says "RED: a letter with nothing to check ⇒ 'skipped', not 'ok'" "$OUT" "skipped (a letter that attaches nothing"
expect_not_says "…and never 'ok'" "$OUT" ": ok"

printf -- '---\nsent: 2026-09-20\n---\n\n# gone\n' > "$FX/gaps/alpha/comms/2026-09-20-gone-out.md"
run_skip "$FX/gaps/alpha/comms/2026-09-20-gone-out.md"
expect_says "a sent letter ⇒ 'skipped (… already sent …)'" "$OUT" "already sent"

run_skip "$FX/meetings/$FUTURE-bs/agenda.md"
expect_says "GREEN: a file that WAS checked still says ok" "$OUT" "agenda.md: ok"

OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$LINT" --quiet --project-root "$FX" "$FX/gaps/alpha/notes.md" 2>&1)
expect_silent "GREEN: under --quiet (the hook) a skip prints nothing" "$OUT"

echo ""
echo "== counterparts under people-profiles =="
mkdir -p "$FX/people"; printf '# known\n' > "$FX/people/known-person.md"
printf -- '---\ntype: meeting-series\ncounterparts: [known-person, nobody-yet]\n---\n\n# s\n' > "$FX/meetings/cpseries.md"
printf '{\n  "comms": {\n    "meeting-rules": {"people-profiles": true}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
run_skip "$FX/meetings/cpseries.md"; rc=$?
expect_says "RED: a counterpart with no profile is named" "$OUT" "\`counterparts\`: no profile people/nobody-yet.md"
expect_not_says "…the one with a profile is not" "$OUT" "known-person.md"
expect_exit "…as a warning — the verdict of the tool it replaced ⇒ exit 0" 0 "$rc"
rm -f "$FX/.claude/vdm-plugins.json"
run_skip "$FX/meetings/cpseries.md"
expect_not_says "GREEN: without the rule, nothing about profiles" "$OUT" "no profile"

echo ""
echo "== session start names what is behind =="
OUT=$(cd "$FX" && CLAUDE_PROJECT_DIR="$FX" COMMS_TODAY="$TODAY" bash "$INDEXCHECK" </dev/null 2>&1)
expect_says "RED: the signal lists a stale path, not only a count" "$OUT" "        update "

echo ""
echo "== comms.generate: an artefact the project writes itself is not ours to call stale =="
# Field case, hq 2026-09-25: its own linter writes meetings/INDEX.md and the
# series blocks, and every session start said "79 artefacts behind — rebuild",
# a rebuild that would cut their table to this plugin's format. The fixture's
# registry and series tables are hand-written, so without the key they ARE
# behind — the control below proves it, or the silence after it proves nothing.
GX="$TMP/gx"; mkdir -p "$GX/.claude" "$GX/meetings/2026-09-01-sync" "$GX/tracks/alpha/comms"
GX=$(cd "$GX" && pwd -P); ( cd "$GX" && git init -q . ) >/dev/null 2>&1
printf -- '---\ntype: meeting\ndate: 2026-09-01\nseries: sync\ntracks:\n  - tracks/alpha\n---\n\n# Sync\n' \
  > "$GX/meetings/2026-09-01-sync/index.md"
printf '# Registry\n\n<!-- registry:start -->\n| ours | seven | columns |\n<!-- registry:end -->\n' > "$GX/meetings/INDEX.md"
printf -- '---\ntype: meeting-series\n---\n\n# sync\n\n<!-- meetings:start -->\n| ours |\n<!-- meetings:end -->\n' > "$GX/meetings/sync.md"
cp "$GX/meetings/INDEX.md" "$TMP/gx-index.orig"; cp "$GX/meetings/sync.md" "$TMP/gx-sync.orig"
gx_cfg() { printf '{"comms": {"series": ["sync"]%s}}\n' "$1" > "$GX/.claude/vdm-plugins.json"; }
gx_check() { OUT=$(cd "$GX" && python3 "$INDEX" --check --project-root "$GX" 2>&1); }

gx_cfg ""
gx_check; rc=$?
expect_says "CONTROL: without the key the hand-written registry is behind" "$OUT" "update meetings/INDEX.md"
expect_says "CONTROL: …and so is the series table" "$OUT" "update meetings/sync.md"

gx_cfg ', "generate": ["pointers"]'
gx_check; rc=$?
expect_not_says "RED: a registry the project writes is not proposed" "$OUT" "meetings/INDEX.md"
expect_not_says "RED: nor are its series tables" "$OUT" "meetings/sync.md"
expect_says "GREEN: the artefact still named ours is checked" "$OUT" "tracks/alpha/comms/2026-09-01-sync-meeting.md"
OUT=$(cd "$GX" && python3 "$INDEX" --write --project-root "$GX" 2>&1)
cmp -s "$GX/meetings/INDEX.md" "$TMP/gx-index.orig" && ok "RED: --write leaves the project's registry byte for byte" \
  || bad "RED: --write leaves the project's registry byte for byte"
cmp -s "$GX/meetings/sync.md" "$TMP/gx-sync.orig" && ok "RED: …and its series file" \
  || bad "RED: …and its series file"
rm -f "$GX/meetings/INDEX.md"
gx_check
expect_silent "RED: no INDEX.md is no note when the registry is not ours (the pointer is in sync)" "$OUT"

gx_cfg ', "generate": []'
rm -f "$GX/tracks/alpha/comms/2026-09-01-sync-meeting.md"
gx_check; rc=$?
expect_exit "RED: nothing named ours ⇒ nothing behind, exit 0" 0 "$rc"
OUT=$(cd "$GX" && CLAUDE_PROJECT_DIR="$GX" bash "$INDEXCHECK" </dev/null 2>&1)
expect_silent "RED: …and session start says nothing" "$OUT"

gx_cfg ', "generate": ["registry", "indexes"]'
gx_check
expect_says "RED: an unknown artefact name is reported, not dropped" "$OUT" "\`indexes\`"

echo ""
echo "== a dated promise in a meeting record fires nowhere — when the summary is on =="
# Field case, command-center 2026-09-23: `- [ ] ⏰ **Пересмотр 17.09**` in a
# meeting record's «Our actions»; the summary reads tracks, nobody read the
# record, the promise to a lawyer surfaced by accident the evening before.

mk_meeting "$PAST-legal" "type: meeting
date: $PAST
series: legal
tracks: [gaps/alpha]" index.md
cat >> "$FX/meetings/$PAST-legal/index.md" <<'EOF'

## Наши действия

- [ ] ⏰ **Пересмотр 17.09**: созвон должен состояться в течение недели
- [x] ⏰ 2026-09-02 закрыто и оставлено в файле
- [ ] ~~⏰ 2026-09-03 снято~~
- обычный пункт без даты
EOF
run_lint "$FX/meetings/$PAST-legal/index.md"; rc=$?
expect_exit "GREEN: without the pending summary the record is left alone" 0 "$rc"

printf '{\n  "comms": {\n    "pending-paths": ["gaps/*/index.md"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
run_skip "$FX/meetings/$PAST-legal/index.md"; rc=$?
expect_exit "RED: summary on, record not read by it ⇒ exit 1" 1 "$rc"
expect_says "…names the line" "$OUT" "line 14: a dated promise in a meeting record"
expect_says "…and where it belongs: this meeting's track" "$OUT" "Move it to gaps/alpha/index.md"
n=$(printf '%s' "$OUT" | grep -c "dated promise")
expect_exit "…only the open one — closed, struck and undated lines are not promises" 1 "$n"

printf '{\n  "comms": {\n    "pending-paths": ["gaps/*/index.md", "meetings/*/index.md"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
run_skip "$FX/meetings/$PAST-legal/index.md"; rc=$?
expect_exit "GREEN: records added to pending-paths ⇒ the rule steps aside" 0 "$rc"

printf '{\n  "comms": {\n    "pending-paths": ["gaps/*/index.md"]\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
sed -i.bak 's/^series: legal$/series: legal\nmigrated_from: old-notes/' "$FX/meetings/$PAST-legal/index.md" && rm -f "$FX/meetings/$PAST-legal/index.md.bak"
run_skip "$FX/meetings/$PAST-legal/index.md"; rc=$?
expect_exit "an imported record (migrated_from) is warned, not failed" 0 "$rc"
expect_says "…but the promise is still named" "$OUT" "dated promise"
rm -f "$FX/.claude/vdm-plugins.json"

echo ""
echo "== a series names its next meeting =="
printf -- '---\ntype: meeting-series\nnext: soon\n---\n\n# s\n' > "$FX/meetings/nxbad.md"
run_lint "$FX/meetings/nxbad.md"; rc=$?
expect_exit "RED: a next: that is not a date ⇒ exit 1" 1 "$rc"
expect_says "…and says so" "$OUT" "is not a date"
printf -- '---\ntype: meeting-series\nnext: 2026-10-01\n---\n\n# s\n' > "$FX/meetings/nxgood.md"
run_lint "$FX/meetings/nxgood.md"; rc=$?
expect_exit "GREEN: a dated next: passes" 0 "$rc"

echo ""
echo "== the form of an outgoing draft, per channel (comms.letter-form) =="
# Field case, 2026-09-25 (hq): an email draft with no subject line and the
# channel "not chosen" passed the linter in silence. The form is a project's
# own, so it is configured; the one default is what every email has — a subject.
LF="$FX/gaps/alpha/comms/2026-09-25-form-out.md"

printf -- '---\ndraft: true\nchannel: email\n---\n\n# → Anna\n\n> service header\n\n---\n\nHello.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an email draft with no subject line ⇒ exit 1" 1 "$rc"
expect_says "…says what is missing" "$OUT" "no \`**Subject**:\` line"
printf -- '---\ndraft: true\nchannel: email\n---\n\n# → Anna\n\n> service header\n\n**Subject**: Access for the pilot\n\n---\n\nHello.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: the same draft with its subject line ⇒ exit 0 (the brief's acceptance)" 0 "$rc"
expect_says "…and reads as checked, not skipped" "$OUT" ": ok"

printf -- '---\ndraft: true\nchannel: email\n---\n\n> service header\n> **Subject**: hidden\n\n---\n\nHello.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a subject hidden inside the > header ⇒ exit 1" 1 "$rc"
expect_says "…named as hidden, not as missing" "$OUT" "inside the \`>\` header"

printf -- '---\ndraft: true\nchannel: "Email (to Anna, cc the team)"\n---\n\nHello.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: free-text channel is read by its first word — 'Email (…)' is email" 1 "$rc"

printf -- '---\ndraft: true\nchannel: telegram\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: a channel the default asks nothing of ⇒ exit 0" 0 "$rc"
expect_says "…and says it was skipped, not ok" "$OUT" "skipped (a letter that attaches nothing"

printf -- '---\nsent: 2026-09-20\nchannel: email\n---\n\nGone.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: a sent email without a subject is history, not refitted" 0 "$rc"

printf '{\n  "comms": {\n    "letter-form": {"*": ["channel", "separator"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\n---\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: '*' asks for a channel, the draft declares none ⇒ exit 1" 1 "$rc"
expect_says "…says so" "$OUT" "no \`channel:\`"
# Field report 2026-09-26 (program): an SMS draft marked `sent: false`, the
# project's way of saying "not gone yet", passed with exit 0 — the check looked
# for `draft: true` only, and a skip read as "nothing wrong".
printf -- '---\nsent: false\n---\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a draft marked sent: false owes the same form ⇒ exit 1" 1 "$rc"
expect_says "…says what is missing" "$OUT" "no \`channel:\`"
printf -- '---\ndraft: true\nchannel: telegram\n---\n\n> header\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: '*' asks for the separator, there is none ⇒ exit 1" 1 "$rc"
expect_says "…says so" "$OUT" "no \`---\` separator"
printf -- '---\ndraft: true\nchannel: telegram\n---\n\n> header\n\n---\n\n   \n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a separator with nothing after it ⇒ exit 1" 1 "$rc"
expect_says "…says so" "$OUT" "nothing after the \`---\` separator"
printf -- '---\ndraft: true\nchannel: telegram\n---\n\n> header\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: channel and separator present ⇒ exit 0" 0 "$rc"
printf -- '---\ndraft: true\nchannel: email\n---\n\n> header\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a project's '*' is merged over the default — email still owes a subject" 1 "$rc"

printf '{\n  "comms": {\n    "letter-form": {"email": ["subjekt"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\nchannel: email\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an unknown element in the config ⇒ exit 1, not ignored" 1 "$rc"
expect_says "…names it" "$OUT" "\`subjekt\`"

# The letter's goal lives in `goal:` (owner, 2026-09-28). Any YAML form: executor
# writes it as a block (`goal: |`) in 105 letters, and the reader takes that.
printf '{\n  "comms": {\n    "letter-form": {"*": ["goal"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: 'goal' asked for, the draft has none ⇒ exit 1" 1 "$rc"
expect_says "…says so" "$OUT" "no \`goal:\`"
printf -- '---\ndraft: true\ngoal:\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an empty goal: is no goal ⇒ exit 1" 1 "$rc"
expect_says "…for that reason, not another" "$OUT" "no \`goal:\`"
printf -- '---\ndraft: true\ngoal: |\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a block marker with nothing under it is no goal ⇒ exit 1" 1 "$rc"
expect_says "…for that reason, not another" "$OUT" "no \`goal:\`"
printf -- '---\ndraft: true\ngoal: know by Friday whether the room is ours\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: a one-line goal ⇒ exit 0" 0 "$rc"
printf -- '---\nsent: false\ngoal: |\n  know by Friday whether the room is ours,\n  and who asks the rector\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: a block goal, the form executor writes, ⇒ exit 0" 0 "$rc"

# «Знаем сами» before the questions (hq, 2026-09-26): a colleague was asked
# what the chats, tickets and meeting notes already held. A warning, not an
# error — a question mark is a loose sign, and hq asked for a warning.
printf '{\n  "comms": {\n    "letter-form": {"*": ["known"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\n---\n\n> service header\n\n---\n\nWhich Langfuse runs on prod? Where do the keys come from?\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: questions with no «What we know» line are a warning, not a failure ⇒ exit 0" 0 "$rc"
expect_says "…and the warning is there" "$OUT" "What we know"
printf -- '---\ndraft: true\n---\n\n> **Знаем сами** (разбор 26.09): prod runs the corporate Langfuse, per the ticket.\n\n---\n\nWhere do the keys come from?\n' > "$LF"
run_skip "$LF"; rc=$?
expect_not_says "GREEN: the header says what we know ⇒ no warning" "$OUT" "What we know"
printf -- '---\ndraft: true\n---\n\n> **What we know**: the ticket says corporate.\n\n---\n\nWhere do the keys come from?\n' > "$LF"
run_skip "$LF"; rc=$?
expect_not_says "GREEN: the English form counts too" "$OUT" "the text asks"
printf -- '---\ndraft: true\n---\n\n> Why write this? A header question is not the text.\n\n---\n\nThe keys are rotated on Friday. Details: https://example.invalid/page?id=4 .\n' > "$LF"
run_skip "$LF"; rc=$?
expect_not_says "GREEN: no question in the text — a URL query and a header question do not count" "$OUT" "the text asks"

# A warning is worth something only if the assistant reads it. PostToolUse shows
# stderr to the model only on exit 2; on exit 0 it went to the transcript and
# nowhere else — measured 2026-09-28: a Write the linter warned about reached the
# session as silence. Warnings now travel as additionalContext on stdout.
printf -- '---\ndraft: true\n---\n\n> service header\n\n---\n\nWhich Langfuse runs on prod?\n' > "$LF"
OUT=$(payload Write "$LF" "x" | (cd "$FX" && bash "$LINTSH" --hook) 2>/dev/null); rc=$?
expect_exit "HOOK: a warning does not block (exit 0)" 0 "$rc"
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; sys.exit(0 if d["hookEventName"]=="PostToolUse" and "What we know" in d["additionalContext"] else 1)' 2>/dev/null; then
  ok "HOOK: …and reaches the assistant as additionalContext on stdout"
else
  bad "HOOK: …and reaches the assistant as additionalContext on stdout" "stdout was: ${OUT:-<empty>}"
fi
printf -- '---\ndraft: true\n---\n\n> **What we know**: the ticket says corporate.\n\n---\n\nWhich Langfuse runs on prod?\n' > "$LF"
OUT=$(payload Write "$LF" "x" | (cd "$FX" && bash "$LINTSH" --hook) 2>&1); rc=$?
expect_silent "HOOK: nothing to say ⇒ nothing on either stream" "$OUT"

# The recipients line (program, 2026-10-04/06): whoever saw the subject earlier
# is in the blind copy of the first answer, and the header shows the blind copy
# was decided, not forgotten — `—` when nobody. The program's own line is
# `**Кому:** … · **копия:** … · **скрытая копия:** …`, colon inside the bold.
printf '{\n  "comms": {\n    "letter-form": {"email": ["recipients"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\nchannel: email\n---\n\n# → x\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an email draft with no recipients line ⇒ exit 1" 1 "$rc"
expect_says "…and the line is named" "$OUT" "recipients line"
printf -- '---\ndraft: true\nchannel: email\n---\n\n**To:** anna · **Cc:** boris\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: a recipients line with no blind-copy segment ⇒ exit 1" 1 "$rc"
expect_says "…and it asks for the blind copy to be decided" "$OUT" "Bcc"
printf -- '---\ndraft: true\nchannel: email\n---\n\n**Кому:** A · **копия:** B · **скрытая копия:** —\n\n---\n\nПривет.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: the program's form — Russian, colon inside the bold, the blind copy decided as — ⇒ exit 0" 0 "$rc"
printf -- '---\ndraft: true\nchannel: email\n---\n\n**To**: anna · **Bcc**: vera\n\n---\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: colon outside the bold, no Cc segment — a copy is optional ⇒ exit 0" 0 "$rc"
rm -f "$FX/.claude/vdm-plugins.json" "$LF"

echo ""
echo "== a draft starts from the scaffold, not from a neighbour's file =="
# Field report 2026-09-26 (program): with no scaffold, an SMS draft was made
# by copying a neighbouring letter's header — and the copy carried that letter's
# habits along. The scaffold writes the header the PROJECT's letter-form asks for.
NEW="${COMMS_NEW_BIN:-$P/scripts/comms-new.py}"
run_new() { OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$NEW" --project-root "$FX" "$@" 2>&1); return $?; }
SC="$FX/gaps/alpha/comms/$TODAY-anna-out.md"
rm -f "$SC"
run_new --channel email --to Anna --track gaps/alpha --subject "Access for the pilot"; rc=$?
expect_exit "RED: an email draft is scaffolded ⇒ exit 0" 0 "$rc"
expect_says "…and the path is printed" "$OUT" "gaps/alpha/comms/$TODAY-anna-out.md"
expect_says "RED: …and the checklist, since a scaffold is created by Bash where no Write hook fires" "$OUT" "Before showing this draft"
body="$(cat "$SC" 2>/dev/null)"
expect_says "…a draft by the plugin's own marker" "$body" "draft: true"
expect_says "…with its channel declared" "$body" "channel: email"
expect_says "…with the goal field waiting to be filled" "$body" "goal:"
expect_says "…and the subject line an email owes" "$body" "**Subject**: Access for the pilot"
run_skip "$SC"; rc=$?
expect_exit "GREEN: the scaffold meets the default letter-form ⇒ exit 0" 0 "$rc"
printf 'hand-written\n' > "$SC"
run_new --channel email --to anna --track gaps/alpha; rc=$?
expect_exit "RED: an existing letter is never overwritten ⇒ exit 1" 1 "$rc"
expect_says "…the file is untouched" "$(cat "$SC")" "hand-written"
rm -f "$SC"
run_new --channel sms --to anna --track org/roles; rc=$?
expect_exit "RED: a track that is a FILE has no comms/ ⇒ exit 1" 1 "$rc"
printf '{\n  "comms": {\n    "labels": "ru",\n    "letter-form": {"*": ["channel", "separator"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
SC="$FX/gaps/alpha/comms/$TODAY-boris-out.md"; rm -f "$SC"
run_new --channel telegram --to boris --track gaps/alpha; rc=$?
body="$(cat "$SC" 2>/dev/null)"
expect_exit "GREEN: a messenger draft ⇒ exit 0" 0 "$rc"
expect_not_says "…no subject line where the channel asks none" "$body" "Subject"
expect_says "…the separator the project asks for" "$body" $'\n---\n'
run_skip "$SC"; rc=$?
expect_exit "GREEN: …and it meets the project's letter-form ⇒ exit 0" 0 "$rc"
SC="$FX/gaps/alpha/comms/$TODAY-vera-out.md"; rm -f "$SC"
run_new --channel email --to vera --track gaps/alpha --subject "Доступ"
expect_says "RED: the project's wording — ru ⇒ **Тема**:" "$(cat "$SC" 2>/dev/null)" "**Тема**: Доступ"
printf '{\n  "comms": {\n    "labels": "ru",\n    "letter-form": {"email": ["subject", "recipients"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
SC="$FX/gaps/alpha/comms/$TODAY-gleb-out.md"; rm -f "$SC"
run_new --channel email --to gleb --track gaps/alpha --subject "Доступ"
expect_says "RED: a project that asks for recipients gets the line, the blind copy included" "$(cat "$SC" 2>/dev/null)" "**скрытая копия:** —"
run_skip "$SC"; rc=$?
expect_exit "GREEN: …and the scaffold meets that letter-form ⇒ exit 0" 0 "$rc"
rm -f "$SC"
printf '{\n  "comms": {\n    "labels": "ru",\n    "letter-form": {"*": ["channel", "separator"]}\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
# The file name is a latin slug, as in people/ — a Cyrillic name made a Cyrillic
# file name on the first field try (hq names its letters in latin).
run_new --channel email --to "Пётр Коваленко" --track gaps/alpha; rc=$?
expect_exit "RED: a non-latin --to is refused ⇒ exit 2" 2 "$rc"
expect_says "…and says how to write it" "$OUT" "--name"
SC="$FX/gaps/alpha/comms/$TODAY-kovalenko-out.md"; rm -f "$SC"
run_new --channel email --to kovalenko --name "Пётр Коваленко" --track gaps/alpha; rc=$?
expect_exit "GREEN: slug for the file, name for the heading ⇒ exit 0" 0 "$rc"
expect_says "…the heading carries the name" "$(cat "$SC" 2>/dev/null)" "# → Пётр Коваленко"
rm -f "$FX/.claude/vdm-plugins.json" "$FX"/gaps/alpha/comms/"$TODAY"-*-out.md

echo ""
echo "== register: the project's default, the letter's own when it differs =="
# Owner, 2026-09-28: three profiles (volunteer / executor / peer); the project
# declares its usual reader, a letter to someone else says so in `register:`.
printf '{\n  "comms": {\n    "register": "volunteer"\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
SC="$FX/gaps/alpha/comms/$TODAY-dana-out.md"; rm -f "$SC"
run_new --channel telegram --to dana --track gaps/alpha
expect_says "RED: the scaffold writes the project's register into the letter" "$(cat "$SC" 2>/dev/null)" "register: volunteer"
printf -- '---\ndraft: true\nchannel: email\nregister: friend\n---\n\n**Subject**: x\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an unknown register in a draft ⇒ exit 1" 1 "$rc"
expect_says "…and the known ones are named" "$OUT" "volunteer, executor, peer"
printf -- '---\ndraft: true\nchannel: email\nregister: peer\n---\n\n**Subject**: x\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "GREEN: a letter overriding the project's register ⇒ exit 0" 0 "$rc"
printf '{\n  "comms": {\n    "register": "boss"\n  }\n}\n' > "$FX/.claude/vdm-plugins.json"
printf -- '---\ndraft: true\nchannel: email\n---\n\n**Subject**: x\n\nHi.\n' > "$LF"
run_skip "$LF"; rc=$?
expect_exit "RED: an unknown comms.register is reported on the draft it governs ⇒ exit 1" 1 "$rc"
expect_says "…naming the key" "$OUT" "comms.register"
rm -f "$FX/.claude/vdm-plugins.json" "$LF" "$SC"

echo ""
echo "== an outgoing draft declared outside comms/ =="
# Field case, 2026-09-25 (hq): a board post for two outside readers lived a
# day in a working file of its track, and no tool saw it — every one of them
# recognised outgoing text by the folder. `channel:` makes it a letter by its own
# word; outside comms/ the draft guard and pending still cannot see it, so the
# linter says so at the one moment it costs nothing.
GR="$FX/gaps/alpha/grill.md"
printf -- '---\ndraft: true\nchannel: board\n---\n\n> for the security team\n\n---\n\nText.\n' > "$GR"
run_skip "$GR"; rc=$?
expect_exit "RED: channel + draft outside comms/ ⇒ exit 1" 1 "$rc"
expect_says "…names why it matters" "$OUT" "outside comms/"
OUT=$(payload Write "$GR" "x" | (cd "$FX" && bash "$LINTSH" --hook) 2>&1); rc=$?
expect_exit "HOOK: comes back as feedback at write time (exit 2)" 2 "$rc"
expect_says "HOOK: …headed as a letter" "$OUT" "this outgoing letter does not meet the contract"
printf -- '---\nsent: false\nchannel: board\n---\n\n> for the security team\n\n---\n\nText.\n' > "$GR"
run_skip "$GR"; rc=$?
expect_exit "RED: channel + sent: false outside comms/ ⇒ exit 1 — the same draft, marked the other way" 1 "$rc"
printf -- '---\nchannel: board\n---\n\nPublished notes.\n' > "$GR"
run_skip "$GR"; rc=$?
expect_exit "GREEN: a channel without draft: true outside comms/ ⇒ exit 0" 0 "$rc"
rm -f "$GR"

# PostToolUse runs after the write, so the file is on disk — as it is here.
printf -- '---\ndraft: true\nchannel: board\n---\n\nText.\n' > "$GR"
gr_payload=$(payload Write "$GR" "$(cat "$GR")")
OUT=$(printf '%s' "$gr_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
expect_exit "RED: a declared letter written without python3 ⇒ NOT CHECKED, exit 2" 2 "$rc"
expect_says "…it says NOT CHECKED" "$OUT" "NOT CHECKED"
EML_GUARD="$P/scripts/comms-eml-guard.sh"
# An Edit carries no frontmatter; the file on disk has to be the witness.
ed_payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"Text.","new_string":"More."}}))' "$GR")
OUT=$(printf '%s' "$ed_payload" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      bash -c "bash '$LINTSH' --hook" 2>&1); rc=$?
if [ -n "$JQ" ]; then
  expect_exit "RED: an Edit of a declared letter without python3 ⇒ exit 2 (the file is read)" 2 "$rc"
else
  ok "SKIP: an Edit without python3 needs jq to learn the path — none on this machine"
fi
rm -f "$GR"

echo ""
echo "== the raw .eml stays out of comms/ and meetings/ =="
# Owner's rule, 2026-09-25, for every project: the letter's text goes to
# comms/*-in.md, the attachments that matter to comms/attachments/, the raw .eml
# stays in the mail system. The files arrive by `cp` in Bash as often as by
# Write, so both are read. Territory only (workitem DL #5): a mail-parser repo's
# fixtures are legitimately .eml, and the plugin is installed everywhere.
bash_payload() { # bash_payload <command> [cwd]
  python3 - "$1" "${2:-$FX}" <<'PY'
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
PY
}
eml_run() { OUT=$(printf '%s' "$1" | (cd "$FX" && CLAUDE_PROJECT_DIR="$FX" bash "$EML_GUARD") 2>&1); return $?; }
mkdir -p "$FX/gaps/alpha/comms/attachments" "$FX/tests/fixtures" "$FX/meetings/$PAST-mail"
printf 'From: a\n\nbody\n' > "$TMP/letter.eml"

eml_run "$(payload Write "$FX/gaps/alpha/comms/attachments/letter.eml" "raw")"; rc=$?
expect_exit "RED: Write of an .eml into comms/attachments/ ⇒ exit 2" 2 "$rc"
expect_says "…says what goes where instead" "$OUT" "comms/<date>-<slug>-in.md"
eml_run "$(bash_payload "cp '$TMP/letter.eml' gaps/alpha/comms/attachments/")"; rc=$?
expect_exit "RED: cp of an .eml into a comms/ directory ⇒ exit 2" 2 "$rc"
expect_says "…names where it would have landed" "$OUT" "gaps/alpha/comms/attachments/letter.eml"
eml_run "$(bash_payload "mv \"$TMP/letter.eml\" \"meetings/$PAST-mail/\"")"; rc=$?
expect_exit "RED: mv of an .eml into the meetings tree ⇒ exit 2" 2 "$rc"
eml_run "$(bash_payload "cd gaps/alpha && cp '$TMP/letter.eml' comms/")"; rc=$?
expect_exit "RED: cd is followed along the chain ⇒ exit 2" 2 "$rc"
eml_run "$(bash_payload "cat '$TMP/letter.eml' > gaps/alpha/comms/copy.eml")"; rc=$?
expect_exit "RED: a > redirect into comms/ ⇒ exit 2" 2 "$rc"
eml_run "$(bash_payload "curl -sS -o gaps/alpha/comms/attachments/x.eml https://example.org/x.eml")"; rc=$?
expect_exit "RED: curl -o into comms/ ⇒ exit 2" 2 "$rc"
eml_run "$(bash_payload "cp -t gaps/alpha/comms/attachments '$TMP/letter.eml'")"; rc=$?
expect_exit "RED: cp -t <dir> form ⇒ exit 2" 2 "$rc"

eml_run "$(bash_payload "python3 -c 'import email,sys; print(email.message_from_file(open(sys.argv[1])))' '$TMP/letter.eml'")"; rc=$?
expect_exit "GREEN: reading an .eml where it lies ⇒ exit 0" 0 "$rc"
eml_run "$(bash_payload "cp '$TMP/letter.eml' /tmp/")"; rc=$?
expect_exit "GREEN: copying an .eml outside the project ⇒ exit 0" 0 "$rc"
eml_run "$(bash_payload "cp '$TMP/letter.eml' tests/fixtures/")"; rc=$?
expect_exit "GREEN: an .eml fixture outside comms/ and meetings/ ⇒ exit 0" 0 "$rc"
eml_run "$(payload Write "$FX/tests/fixtures/sample.eml" "raw")"; rc=$?
expect_exit "GREEN: Write of an .eml fixture ⇒ exit 0" 0 "$rc"
eml_run "$(bash_payload "git rm gaps/alpha/comms/attachments/old.eml")"; rc=$?
expect_exit "GREEN: removing an .eml — the cleanup — is never blocked" 0 "$rc"
eml_run "$(payload Write "$FX/gaps/alpha/comms/2026-09-25-x-in.md" "the text of the letter")"; rc=$?
expect_exit "GREEN: the letter's text as -in.md ⇒ exit 0" 0 "$rc"
eml_run "$(bash_payload "cp '$TMP/letter.eml' 'gaps/alpha/comms/attachments/letter.eml")"; rc=$?
expect_exit "RED: unbalanced quotes near comms/ ⇒ NOT CHECKED, exit 2" 2 "$rc"
expect_says "…and says so" "$OUT" "NOT CHECKED"
expect_says "RED: …naming what stopped it — the quotes" "$OUT" "quotes do not close"
expect_not_says "RED: …and not sending the reader to install the python3 that just ran" "$OUT" "install python3"

OUT=$(printf '%s' "$(payload Write "$FX/gaps/alpha/comms/attachments/letter.eml" "raw")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "RED: .eml into comms/ without python3 ⇒ NOT CHECKED, exit 2" 2 "$rc"
expect_says "…and here the way out is python3" "$OUT" "install python3"
BADPY="$TMP/bin-badpy"
mkdir -p "$BADPY"
for f in "$FARM"/*; do ln -sf "$(readlink "$f")" "$BADPY/${f##*/}"; done
printf '#!/bin/sh\necho "Traceback (most recent call last):" >&2\necho "ZeroDivisionError: boom" >&2\nexit 1\n' > "$BADPY/python3"
chmod +x "$BADPY/python3"
OUT=$(printf '%s' "$(payload Write "$FX/gaps/alpha/comms/attachments/letter.eml" "raw")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$BADPY" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "RED: the guard crashes ⇒ NOT CHECKED, exit 2" 2 "$rc"
expect_says "RED: …and it quotes the crash" "$OUT" "the guard failed (exit 1): ZeroDivisionError: boom"
expect_not_says "RED: …not a python3 that is plainly there" "$OUT" "install python3"
OUT=$(printf '%s' "$(bash_payload "cp '$TMP/letter.eml' tests/fixtures/")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, an .eml nowhere near comms/ ⇒ exit 0" 0 "$rc"
OUT=$(printf '%s' "$(bash_payload "ls -la")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a call with no .eml at all ⇒ exit 0" 0 "$rc"

echo ""
echo "== field report 2026-09-26 (program): a heredoc body and a comment are not shell =="
# The call that was blocked: `python3 - <<'PY' … PY`, reading an .eml where it
# lies and writing only the letter's text into comms/*-in.md — what the rule asks
# for. The body is python: an f-string whose subject line says "you're". Read as
# shell, its quotes never close; the guard gave up, said NOT CHECKED and sent the
# reader to install the python3 that had just run. The commands are written to
# files first: a heredoc inside $( ) is where bash 3.2's own parser trips over an
# apostrophe.
cp "$TMP/letter.eml" "$TMP/Court of Honor tomorrow — you're running it.eml"
cat > "$TMP/cmd-field.txt" <<EOF
cd "$FX" && python3 - <<'PY'
import email, pathlib
# 1. the reply, next to the letter of the 23rd
p = "$TMP/Court of Honor tomorrow — you're running it.eml"
m = email.message_from_file(open(p, encoding="utf-8"))
out = pathlib.Path("gaps/alpha/comms/2026-09-24-reply-in.md")
out.write_text(f"""---
subject: "Re: Court of Honor tomorrow — you're running it"
---

**Subject:** Re: Court of Honor tomorrow — you're running it

{m.get_payload()}
""", encoding="utf-8")
PY
ls -la gaps/alpha/comms/2026-09-24-reply-in.md | awk '{print \$5}'
EOF
eml_run "$(bash_payload "$(cat "$TMP/cmd-field.txt")")"; rc=$?
expect_exit "RED: the field call — the letter's text into comms/ from a python heredoc ⇒ exit 0" 0 "$rc"

cat > "$TMP/cmd-raw.txt" <<'EOF'
cat > gaps/alpha/comms/copy.eml <<'MAIL'
From: a

it's the raw letter, byte for byte
MAIL
EOF
eml_run "$(bash_payload "$(cat "$TMP/cmd-raw.txt")")"; rc=$?
expect_exit "…the line that opens a heredoc is still read: > comms/copy.eml ⇒ exit 2" 2 "$rc"
expect_says "RED: …as a verdict that names where it lands, not as NOT CHECKED" "$OUT" "gaps/alpha/comms/copy.eml"

printf 'cat <<-EOF > gaps/alpha/comms/2026-09-24-x-in.md\n\tit%ss only the text of %s\n\tEOF\n' "'" "$TMP/letter.eml" > "$TMP/cmd-dash.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-dash.txt")")"; rc=$?
expect_exit "RED: <<- ends at a tab-indented delimiter ⇒ exit 0" 0 "$rc"

# A `<<` that no line closes is not taken for a heredoc — or `$((1<<2))` would
# hide every line after it, and the copy on the next line would pass unread.
printf 'echo $((1<<2))\ncp %s gaps/alpha/comms/\n' "'$TMP/letter.eml'" > "$TMP/cmd-arith.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-arith.txt")")"; rc=$?
expect_exit "…a << that no line closes hides nothing after it ⇒ exit 2" 2 "$rc"

printf '# the letter%ss text only — the .eml stays where it lies\npython3 extract.py %s > gaps/alpha/comms/2026-09-24-x-in.md\n' "'" "'$TMP/letter.eml'" > "$TMP/cmd-comment.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-comment.txt")")"; rc=$?
expect_exit "RED: a comment with an apostrophe is not shell ⇒ exit 0" 0 "$rc"
eml_run "$(bash_payload "cp '$TMP/letter.eml' tests/fixtures/#1 gaps/alpha/comms/")"; rc=$?
expect_exit "…a # inside a word starts no comment: the copy still lands in comms/ ⇒ exit 2" 2 "$rc"
eml_run "$(bash_payload "cp '$TMP/letter #2.eml' gaps/alpha/comms/")"; rc=$?
expect_exit "…nor does a # inside quotes ⇒ exit 2" 2 "$rc"
expect_says "…as a verdict that names the file, not as NOT CHECKED" "$OUT" "gaps/alpha/comms/letter #2.eml"
# The reading is shared with git-guard since vdm-comms 0.6.4 (lib/shellwords.py),
# and with it came the line continuation: bash joins `co\⏎mms` into `comms`.
printf 'cp %s gaps/alpha/co\\\nmms/\n' "'$TMP/letter.eml'" > "$TMP/cmd-cont.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-cont.txt")")"; rc=$?
expect_exit "RED: a line continuation inside a word is joined, as bash joins it ⇒ exit 2" 2 "$rc"

echo ""
echo "== a newline ends a command, as it does for the shell (Sidetrack #19) =="
# The reader took a newline for a space. `cd gaps/alpha⏎cp x.eml comms/` was one
# command to it — `cd` with four arguments — and the copy was never looked at;
# in `cp x.eml gaps/alpha/comms/⏎echo done` the next line became the destination.
printf 'cd gaps/alpha\ncp %s comms/\n' "'$TMP/letter.eml'" > "$TMP/cmd-nl1.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-nl1.txt")")"; rc=$?
expect_exit "RED: cd on one line, the copy on the next ⇒ exit 2" 2 "$rc"
printf 'cp %s gaps/alpha/comms/\necho done\n' "'$TMP/letter.eml'" > "$TMP/cmd-nl2.txt"
eml_run "$(bash_payload "$(cat "$TMP/cmd-nl2.txt")")"; rc=$?
expect_exit "RED: the next line does not become the copy's destination ⇒ exit 2" 2 "$rc"

echo ""
echo "== people/: may this project write to a person, and from which address =="
# Owner with echelon, 2026-10-01 (echelon DL #75; vdm-comms-outward-checks DL #2):
# an HQ keeps people/, a hand reads its HQ's from disk and names it in comms.hq;
# `trust` in a profile says who may write, and anyone unmarked counts as careful.
PEOPLE="${COMMS_PEOPLE_BIN:-$P/scripts/comms-people.py}"
HQ="$TMP/hq"; HAND="$TMP/hand"; STORE="$TMP/store"
mkdir -p "$HQ/.git" "$HQ/.claude" "$HQ/crew" "$HAND/.git" "$HAND/.claude" "$STORE/_registry"
# The HQ keeps its people under a name of its own: the hand must take it from
# the HQ's config, not assume `people/`.
printf '{"comms": {"people-dir": "crew"}}\n' > "$HQ/.claude/vdm-plugins.json"
printf '{"identity": "hq-proj", "aliases": [], "names": ["the hq"], "paths": ["%s/gone", "%s"]}\n' "$TMP" "$HQ" > "$STORE/_registry/hq-proj.json"
printf -- '---\nslug: anna\ntrust: team\nidentity:\n  jira: anna_k\n---\n# Anna\n' > "$HQ/crew/anna.md"
printf -- '---\ntrust: Peer\nmail_from:\n  - to: boris@their.example\n    from: Owner <me@ours.example>\n---\n# Boris\n' > "$HQ/crew/boris.md"
printf -- '---\ntrust: carefull\n---\n# Vera — writes to anna_k often\n' > "$HQ/crew/vera.md"
printf -- '---\ntrust: exec\n---\n# Gleb\n' > "$HQ/crew/gleb.md"
printf -- '---\ntrust: top\nconfidential: true\n---\n# Legacy lead\n' > "$HQ/crew/legacy-lead.md"   # the former name of exec
printf '# Dina\n\n**Email**: dina@their.example\nWorks with Al on payments.\n' > "$HQ/crew/dina.md"   # no frontmatter at all
printf -- '---\ntrust: peer\nlinks:\n  blocks:\n    - x: 1\nmail_from:\n  - to: e@their.example\n    from: me@ours.example\n---\n# Egor\n' > "$HQ/crew/egor.md"
printf -- '---\ntrust: peer\n---\n# Another Anna\n' > "$HQ/crew/anna-k.md"
printf -- '---\nreports: [anna-k]\n---\n# Lead\n' > "$HQ/crew/lead.md"   # names anna-k in ITS frontmatter
run_people() { OUT=$(VDM_INTERCOM_ROOT="$STORE" python3 "$PEOPLE" "$@" 2>&1); return $?; }

printf '{"comms": {"hq": "hq-proj"}}\n' > "$HAND/.claude/vdm-plugins.json"
run_people where --project-root "$HAND"; rc=$?
expect_exit "RED: a hand finds its HQ's people through the intercom directory ⇒ exit 0" 0 "$rc"
expect_says "…the HQ's own people-dir, past a checkout that is gone" "$OUT" "$HQ/crew"
run_people show anna --project-root "$HAND"; rc=$?
expect_exit "RED: a profile by its file name ⇒ exit 0" 0 "$rc"
expect_says "…its level" "$OUT" "trust: team"
expect_says "…and the hand writes to team itself" "$OUT" "hand of \`hq-proj\`: write it yourself"
run_people show anna_k --project-root "$HAND"; rc=$?
expect_exit "RED: a profile by the login a hand meets in its ticket ⇒ exit 0" 0 "$rc"
expect_says "…the one whose frontmatter holds it, though another profile mentions it in prose" "$OUT" "profile: crew/anna.md"
run_people show ANNA_K --project-root "$HAND"; rc=$?
expect_exit "…case does not matter for a login ⇒ exit 0" 0 "$rc"
printf -- '---\nidentity:\n  jira: anna_k\n---\n# A namesake\n' > "$HQ/crew/anna-2.md"
run_people show anna_k --project-root "$HAND"; rc=$?
expect_exit "RED: one login in two profiles' frontmatter is ambiguous ⇒ exit 3" 3 "$rc"
expect_says "…and both files are named" "$OUT" "crew/anna-2.md"
rm -f "$HQ/crew/anna-2.md"
run_people show boris --project-root "$HAND"; rc=$?
expect_says "RED: a level is read case-blind" "$OUT" "trust: peer"
expect_says "RED: the owner's From pair is printed for the mail" "$OUT" "mail_from: to boris@their.example → from Owner <me@ours.example>"
run_people show vera --project-root "$HAND"; rc=$?
expect_says "RED: an unknown level reads as careful" "$OUT" "trust: careful"
expect_says "…and names the typo, not just the default" "$OUT" "unknown \`trust: carefull\`"
expect_says "…and a hand does not write to careful: it briefs the HQ" "$OUT" "do not write — brief the HQ"
run_people show gleb --project-root "$HAND"; rc=$?
expect_says "RED: exec goes through the HQ as well" "$OUT" "do not write — brief the HQ"
run_people show legacy-lead --project-root "$HAND"; rc=$?
expect_says "RED: the former \`trust: top\` reads as exec, not as an unknown value" "$OUT" "trust: exec (\`trust: top\` is the former name"
expect_says "…the note names what the profile becomes" "$OUT" "\`trust: exec\` plus \`confidential: true\`"
expect_says "…and a hand still briefs the HQ" "$OUT" "do not write — brief the HQ"
run_people show dina@their.example --project-root "$HAND"; rc=$?
expect_exit "RED: a profile with no frontmatter is found by the address in its body ⇒ exit 0" 0 "$rc"
expect_says "…and, with no trust field, it is careful" "$OUT" "careful (no \`trust:\` in the profile)"
run_people show egor --project-root "$HAND"; rc=$?
expect_says "RED: trust survives frontmatter the reader cannot parse" "$OUT" "trust: peer"
expect_says "…while mail_from there is reported, not guessed" "$OUT" "mail_from unreadable"
run_people show nobody-here --project-root "$HAND"; rc=$?
expect_exit "RED: not in people/ ⇒ exit 2" 2 "$rc"
expect_says "…and counts as careful" "$OUT" "trust: careful"
run_people show anna-k --project-root "$HAND"; rc=$?
expect_exit "GREEN: the file name wins over a token found in another profile ⇒ exit 0" 0 "$rc"
expect_says "…that file" "$OUT" "crew/anna-k.md"
run_people show al --project-root "$HAND"; rc=$?
expect_exit "GREEN: a two-letter search finds nobody rather than everybody ⇒ exit 2" 2 "$rc"

printf '{"comms": {"hq": "The HQ"}}\n' > "$HAND/.claude/vdm-plugins.json"
run_people where --project-root "$HAND"; rc=$?
expect_exit "RED: comms.hq may be a name the HQ goes by, folded as intercom folds ⇒ exit 0" 0 "$rc"
# Two machines editing one entry leave `<id>.sync-conflict-*.json` beside it
# (ten on the owner's store, 2026-10-03); read as an entry, the copy makes every
# name of the HQ "several agents".
cp "$STORE/_registry/hq-proj.json" "$STORE/_registry/hq-proj.sync-conflict-20261001-192610-ABCDEFG.json"
run_people where --project-root "$HAND"; rc=$?
expect_exit "RED: a sync-conflict copy of the HQ's entry is not a second agent ⇒ exit 0" 0 "$rc"
rm -f "$STORE/_registry/hq-proj.sync-conflict-20261001-192610-ABCDEFG.json"
printf '{"comms": {"hq": "no-such-hq"}}\n' > "$HAND/.claude/vdm-plugins.json"
run_people show anna --project-root "$HAND"; rc=$?
expect_exit "RED: an HQ nobody is registered as ⇒ exit 1" 1 "$rc"
expect_says "…says so, and that everyone counts as careful meanwhile" "$OUT" "everyone counts as careful"
printf '{"identity": "far-hq", "paths": ["%s/elsewhere"]}\n' "$TMP" > "$STORE/_registry/far-hq.json"
printf '{"comms": {"hq": "far-hq"}}\n' > "$HAND/.claude/vdm-plugins.json"
run_people where --project-root "$HAND"; rc=$?
expect_exit "RED: an HQ with no checkout on this machine ⇒ exit 1" 1 "$rc"
expect_says "…named as such" "$OUT" "none of its checkouts is on this machine"
rm -f "$HAND/.claude/vdm-plugins.json"
run_people where --project-root "$HAND"; rc=$?
expect_exit "RED: no people/ and no comms.hq ⇒ exit 1" 1 "$rc"
expect_says "…and the fix is named" "$OUT" "comms.hq"

run_people show gleb --project-root "$HQ"; rc=$?
expect_exit "GREEN: the HQ reads its own people/ ⇒ exit 0" 0 "$rc"
expect_says "…and for exec it asks the owner first" "$OUT" "ask the owner whether to write at all"
run_people show legacy-lead --project-root "$HQ"; rc=$?
expect_says "RED: the former top keeps the owner's question at the HQ — careful would drop it" "$OUT" "ask the owner whether to write at all"
run_people show vera --project-root "$HQ"; rc=$?
expect_says "…and careful is a draft the owner reads" "$OUT" "the owner reads it before it goes"

mkdir -p "$HAND/gaps/alpha"
printf '{"comms": {"hq": "hq-proj"}}\n' > "$HAND/.claude/vdm-plugins.json"
OUT=$(cd "$HAND" && COMMS_TODAY="$TODAY" VDM_INTERCOM_ROOT="$STORE" python3 "$NEW" --project-root "$HAND" --channel email --to gleb --track gaps/alpha 2>&1); rc=$?
expect_exit "RED: the scaffold still writes the draft ⇒ exit 0" 0 "$rc"
expect_says "RED: …and tells the hand who the recipient is, at the moment the letter is born" "$OUT" "Recipient \`gleb\`:"
expect_says "…with the next step" "$OUT" "do not write — brief the HQ"
rm -f "$HAND/.claude/vdm-plugins.json"
OUT=$(cd "$HAND" && COMMS_TODAY="$TODAY" VDM_INTERCOM_ROOT="$STORE" python3 "$NEW" --project-root "$HAND" --channel email --to boris --track gaps/alpha 2>&1); rc=$?
expect_exit "GREEN: a project with no people/ at all still gets its draft ⇒ exit 0" 0 "$rc"
expect_says "…and is told why the recipient counts as careful" "$OUT" "people: unresolved"

printf '\ncomms: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
