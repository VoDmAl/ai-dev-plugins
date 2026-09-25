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
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true


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
# Field case, 2026-09-23 (t23b-program): `goal: |` — a block scalar — in 92
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
expect_not_says "…and never says 'cannot read line'" "$OUT" "cannot read line"

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
expect_not_says "GREEN: under --quiet (the hook) a skip prints nothing" "$OUT" "skipped"

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
echo "== a dated promise in a meeting record fires nowhere — when the summary is on =="
# Field case, global-auth-gap 2026-09-23: `- [ ] ⏰ **Пересмотр 17.09**` in a
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
# Field case, 2026-09-25 (space-hq): an email draft with no subject line and the
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
rm -f "$FX/.claude/vdm-plugins.json" "$LF"

echo ""
echo "== an outgoing draft declared outside comms/ =="
# Field case, 2026-09-25 (space-hq): a board post for two outside readers lived a
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

OUT=$(printf '%s' "$(payload Write "$FX/gaps/alpha/comms/attachments/letter.eml" "raw")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "RED: .eml into comms/ without python3 ⇒ NOT CHECKED, exit 2" 2 "$rc"
OUT=$(printf '%s' "$(bash_payload "cp '$TMP/letter.eml' tests/fixtures/")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, an .eml nowhere near comms/ ⇒ exit 0" 0 "$rc"
OUT=$(printf '%s' "$(bash_payload "ls -la")" | \
      env -i HOME="$HOME" LC_ALL=C PATH="$FARM" bash -c "cd '$FX' && bash '$EML_GUARD'" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a call with no .eml at all ⇒ exit 0" 0 "$rc"

printf '\ncomms: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
