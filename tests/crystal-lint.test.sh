#!/bin/bash
# crystal-lint.test.sh — RED TESTS for the workitem canon validator.
#
# A gate does not exist until you have watched it FAIL (docs/model/suite.md).
# Green on a clean tree proves nothing: `exit 0` is also green. So every check
# crystal-lint makes is exercised in BOTH directions, and the RED direction
# additionally asserts the message NAMES the thing that is wrong — a linter
# that fails without saying why gets ignored, which equals not existing.
#
# False-positive tests matter just as much here. This linter runs on every
# workitem write; if it fires on legitimate files, users switch it off. The
# scope rules (terminal tier out of scope, non-workitem artifacts out of scope,
# extra sections/keys legal) each get a test proving silence.
#
# Run: bash tests/crystal-lint.test.sh   (exit 0 = all pass)

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
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR \
      VDX_FOCUSED VDX_INTERCOM 2>/dev/null || true

# Nor the machine's git config: git 2.54 runs a hook declared there
# (`hook.<name>.command`) on every commit, a fixture's included — the case is
# in tests/gates.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$REPO_ROOT/plugins/vdm/scripts/crystal-lint.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_exit() {
  # expect_exit <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi
}
expect_says() {
  # expect_says <desc> <output> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "output did not mention: $3" ;;
  esac
}
expect_silent() {
  # expect_silent <desc> <output>
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi
}
expect_not_says() {
  # expect_not_says <desc> <output> <needle>
  # Needs output to look at: an empty haystack contains nothing, so the check
  # would pass whatever the code did — including when it never ran. Silence is
  # asserted with expect_silent.
  if [ -z "$2" ]; then bad "$1" "output is empty — its absence proves nothing; assert silence with expect_silent"; return; fi
  case "$2" in
    *"$3"*) bad "$1" "output should NOT mention: $3" ;;
    *)      ok "$1" ;;
  esac
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t crystallint)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

WI="$TMP/tasks/specimen"
mkdir -p "$WI"

# Canonical body used by the positive cases. Kept minimal on purpose: the point
# is that the SHAPE is complete, not that the content is good.
canon_body() {
  cat <<'EOF'

# Specimen

## Назначение
x

## Текущая модель
x

## Sidetracks
x

## Next actions
- [ ] x

## References
x
EOF
}

write_wi() {
  # write_wi <status> [extra-frontmatter-line]
  {
    printf -- '---\n'
    printf 'title: "Specimen"\nslug: specimen\nstatus: %s\n' "$1"
    printf 'session-type: prd-work\ncreated: 2026-08-22\nlast-updated: 2026-08-22\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf -- '---\n'
    canon_body
  } >"$WI/workitem.md"
}

run() { bash "$LINT" "$WI/workitem.md" 2>&1; }
run_rc() { bash "$LINT" "$WI/workitem.md" >/dev/null 2>&1; echo $?; }

# ---------------------------------------------------------------------------
printf '\ncanon derivation\n'
# ---------------------------------------------------------------------------
CANON=$(bash "$LINT" --print-canon 2>&1)
expect_says "canon lists a required section"      "$CANON" "section	Назначение"
expect_says "canon marks Decision Log optional"   "$CANON" "section-optional	Decision Log"
expect_says "canon lists required DL field Basis" "$CANON" "dl-field	Basis"
expect_says "canon carries the Basis enum"        "$CANON" "basis-value	observed"
# Supersedes is marked "(optional …)" in the template and must NOT be required.
case "$CANON" in
  *"dl-field	Supersedes"*) bad "optional DL field stays optional" "Supersedes was treated as required" ;;
  *)                        ok  "optional DL field stays optional" ;;
esac

# ---------------------------------------------------------------------------
printf '\nGREEN — legitimate files must stay silent\n'
# ---------------------------------------------------------------------------
write_wi "in-progress"
expect_exit "canonical workitem passes" 0 "$(run_rc)"

# Canon is a FLOOR (DL #4): host-repo keys and extra sections are legal.
write_wi "in-progress" "type: task"
printf '\n## Порядок разбора\nx\n' >>"$WI/workitem.md"
expect_exit "extra frontmatter key + extra section are legal" 0 "$(run_rc)"

write_wi "ready"
expect_exit "pre-work tier (parking) passes" 0 "$(run_rc)"

# ---------------------------------------------------------------------------
printf '\nRED — each broken invariant must fail AND name the problem\n'
# ---------------------------------------------------------------------------
# The field report's specimen: shape inferred from a neighbour.
cat >"$WI/workitem.md" <<'EOF'
---
title: "Specimen"
slug: specimen
status: ready
created: 2026-08-22
last-updated: 2026-08-22
---

# Specimen

## START HERE
x

## Что известно на 2026-08-22
**#1 (2026-08-22)** — проза вместо записи.

## Порядок разбора
1. x
EOF
OUT=$(run); RC=$(run_rc)
expect_exit "invented sections ⇒ red"            1 "$RC"
expect_says "names a missing section"            "$OUT" "## Назначение"
expect_says "names the live-model section"       "$OUT" "## Текущая модель"
expect_says "names the missing frontmatter key"  "$OUT" "session-type"

# Decision Log written as prose under a correct heading.
write_wi "in-progress"
printf '\n## Decision Log\n\n**#1 (2026-08-22)** — проза.\n' >>"$WI/workitem.md"
OUT=$(run)
expect_exit "prose Decision Log ⇒ red"    1 "$(run_rc)"
expect_says "explains no entries parsed"  "$OUT" "no \`### #N"

# Entry present, but the epistemic fields are gone — this is the loss the
# whole crystal exists to prevent (Basis forces "what did you NOT check?").
write_wi "in-progress"
cat >>"$WI/workitem.md" <<'EOF'

## Decision Log

### #1 / 2026-08-22 / имена врут

**Source:** assistant
**Context:** разбор
**Why:** хэши совпали
**Implication:** чистим
EOF
OUT=$(run)
expect_exit "DL entry missing Basis ⇒ red" 1 "$(run_rc)"
expect_says "names the missing Basis"      "$OUT" "Basis"
expect_says "names the missing detail"     "$OUT" "Basis-detail"

# Basis value outside the template's own enum.
write_wi "in-progress"
cat >>"$WI/workitem.md" <<'EOF'

## Decision Log

### #1 / 2026-08-22 / имена врут

**Source:** assistant
**Basis:** обосновано
**Basis-detail:** сравнивал хэши
**Context:** разбор
**Why:** хэши совпали
**Implication:** чистим
EOF
OUT=$(run)
expect_exit "Basis outside the enum ⇒ red" 1 "$(run_rc)"
expect_says "lists the allowed values"     "$OUT" "user-stated"

# DL heading in the wrong shape.
write_wi "in-progress"
printf '\n## Decision Log\n\n### Решение 1\n\n**Source:** assistant\n' >>"$WI/workitem.md"
OUT=$(run)
expect_exit "malformed DL heading ⇒ red" 1 "$(run_rc)"
expect_says "shows the required shape"   "$OUT" "YYYY-MM-DD"

# Non-canonical status.
write_wi "wip"
OUT=$(run)
expect_exit "non-canonical status ⇒ red" 1 "$(run_rc)"
expect_says "names the offending status" "$OUT" "wip"

# A file literally named workitem.md with no frontmatter is broken, period.
printf '# Specimen\n\nJust prose.\n' >"$WI/workitem.md"
OUT=$(run)
expect_exit "workitem.md without frontmatter ⇒ red" 1 "$(run_rc)"
expect_says "says frontmatter is absent"            "$OUT" "frontmatter"

# ---------------------------------------------------------------------------
printf '\nFALSE POSITIVES — scope rules must keep the linter quiet\n'
# ---------------------------------------------------------------------------
# Terminal tier is history; retro-fitting it to a newer canon would falsify the
# record (DL #3). Proven with a file that IS broken by current canon.
cat >"$WI/workitem.md" <<'EOF'
---
title: "Specimen"
slug: specimen
status: done
session-type: prd-work
created: 2026-05-27
last-updated: 2026-06-01
---

# Specimen

## Назначение
x
EOF
OUT=$(run)
expect_exit "terminal tier is out of scope" 0 "$(run_rc)"
expect_silent "terminal tier says nothing"  "$OUT"

# Same file, non-terminal ⇒ must go red. Without this pair the rule above could
# be passing because the linter is BLIND rather than because it is scoped.
sed -i.bak 's/^status: done$/status: in-progress/' "$WI/workitem.md" && rm -f "$WI/workitem.md.bak"
expect_exit "same file non-terminal ⇒ red (scope is not blindness)" 1 "$(run_rc)"

# A stray note in tasks/ is an artifact, not a broken workitem — matching
# lib/crystal-path.sh, which drops files without `status:` in filter_status().
printf '# Some notes\n\nNot a workitem.\n' >"$TMP/tasks/notes.md"
OUT=$(bash "$LINT" "$TMP/tasks/notes.md" 2>&1)
expect_silent "non-workitem artifact is ignored" "$OUT"

# Legacy import: informational one-liner, never a violation list.
cat >"$WI/workitem.md" <<'EOF'
---
title: "Specimen"
slug: specimen
status: ready
crystal-schema: legacy
created: 2026-01-05
last-updated: 2026-01-05
---

# Specimen

## Whatever shape it had
x
EOF
OUT=$(run)
expect_exit "legacy import is not a violation" 0 "$(run_rc)"
expect_says "legacy warns against copying it"  "$OUT" "never infer"

# ---------------------------------------------------------------------------
printf '\nmalformed dates — the lint and the lib read the same items\n'
# ---------------------------------------------------------------------------
# crystal-lint.py's `malformed_due` said it was "kept in step by the conformance
# test in tests/crystal-lint.test.sh". There was no such test until
# crystal-wake DL #1 (2026-09-25): two implementations of one rule that nothing
# compares are two rules. And that day they had to change together — an item
# is its checkbox line plus its continuation, so a broken date on a wrapped
# tail is broken, not invisible. Absolute value first, agreement second.
MDW="$TMP/tasks/malformed-due"
mkdir -p "$MDW"
{
  printf -- '---\ntitle: "Malformed due"\nslug: malformed-due\nstatus: in-progress\n'
  printf 'session-type: prd-work\ncreated: 2026-09-25\nlast-updated: 2026-09-25\n---\n\n# Malformed due\n\n'
  printf '## Назначение\nx\n\n## Текущая модель\nx\n\n## Sidetracks\nx\n\n## Next actions\n'
  printf -- '- [ ] on its own line, broken (due: 22-07-2026)\n'
  printf -- '- [ ] a wrapped item whose tail\n      carries a broken date (due: soon)\n'
  printf -- '- [ ] a wrapped item with a good date\n      (due: 2026-09-01)\n'
  printf -- '- [x] done, so its broken date owes nothing\n      (due: whenever)\n'
  printf '\n## References\nx\n'
} >"$MDW/workitem.md"
md_lib=$(bash -c ". '$REPO_ROOT/plugins/vdm/lib/crystal-path.sh' 2>/dev/null; audit_malformed_due '$MDW/workitem.md'" | grep -c .)
md_py=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cl', '$REPO_ROOT/plugins/vdm/scripts/crystal-lint.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(len(m.malformed_due(open('$MDW/workitem.md', encoding='utf-8').read().splitlines())))
" 2>&1)
expect_exit "lib: two broken dates — one on its line, one on the wrapped tail" 2 "$md_lib"
expect_exit "lint: the same two" 2 "$md_py"
expect_exit "lib and lint agree" "$md_lib" "$md_py"
OUT=$(bash "$LINT" "$MDW/workitem.md" 2>&1)
expect_says "the lint names the date on the wrapped tail" "$OUT" "(due: soon)"
expect_not_says "…and not the done item's" "$OUT" "whenever"

# The ledger's spellings (vdm-comms-commitment-form DL #4): `⏰ <date>` and
# `[due:: <date>]` are dates, `[due:: soon]` is broken like `(due: soon)`, and
# `⏰ after:` is an event. The lint and the lib must say the same.
MDL="$TMP/tasks/malformed-ledger"
mkdir -p "$MDL"
{
  printf -- '---\ntitle: "Malformed ledger"\nslug: malformed-ledger\nstatus: in-progress\n'
  printf 'session-type: prd-work\ncreated: 2026-10-15\nlast-updated: 2026-10-15\n---\n\n# Malformed ledger\n\n'
  printf '## Назначение\nx\n\n## Текущая модель\nx\n\n## Sidetracks\nx\n\n## Next actions\n'
  printf -- '- [ ] **Petrov** — the form ⏰ 2026-09-01 → followup\n'
  printf -- '- [ ] **Confirm the quota** [who:: ivan-petrov] [state:: sent] [due:: 2026-09-02]\n'
  printf -- '- [ ] an event ⏰ after: the transcript arrives\n'
  printf -- '- [ ] a broken full-form date [due:: soon]\n'
  printf '\n## References\nx\n'
} >"$MDL/workitem.md"
ml_lib=$(bash -c ". '$REPO_ROOT/plugins/vdm/lib/crystal-path.sh' 2>/dev/null; audit_malformed_due '$MDL/workitem.md'" | grep -c .)
ml_py=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cl', '$REPO_ROOT/plugins/vdm/scripts/crystal-lint.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(len(m.malformed_due(open('$MDL/workitem.md', encoding='utf-8').read().splitlines())))
" 2>&1)
expect_exit "lib: one broken date — \`[due:: soon]\`; \`⏰\` dates and events are not broken" 1 "$ml_lib"
expect_exit "lint: the same one" 1 "$ml_py"
OUT=$(bash "$LINT" "$MDL/workitem.md" 2>&1)
expect_says "the lint names it" "$OUT" "[due:: soon]"
expect_not_says "…and not the \`⏰\` date" "$OUT" "2026-09-01"

# ---------------------------------------------------------------------------
printf '\ngate (--pre-hook) — what an edit may not leave behind\n'
# ---------------------------------------------------------------------------
# The canon gate stops the edit on PreToolUse (canon-gate-scope). On
# PostToolUse it could only report an edit that had already landed: 87 Decision
# Log entries were written off canon after 2026-08-31 with the advisory lint
# running on every one of those writes (DL #5). Blocking everything instead
# would make every edit of an old workitem invent a Basis for entries months
# old — so the gate compares the file before and after the edit: structure is
# owed in full, an entry or a promise only where it is new (DL #2, #6, #7).
# Every RED below has a GREEN twin on the same text, so a gate that went blind
# cannot pass for a gate that scopes.
GR="$TMP/gaterepo"
mkdir -p "$GR/docs/tasks/w" "$GR/docs/tasks/sib"
GR=$(cd "$GR" && pwd -P)
( cd "$GR" && git init -q . ) >/dev/null 2>&1
# A sibling crystal, so the root is known before the file under test exists.
printf -- '---\nstatus: ready\n---\n' >"$GR/docs/tasks/sib/workitem.md"
GWI="$GR/docs/tasks/w/workitem.md"

gw_head() {
  printf -- '---\ntitle: "W"\nslug: w\nstatus: %s\nsession-type: prd-work\n' "$1"
  printf 'created: 2026-10-15\nlast-updated: 2026-10-15\n---\n\n# W\n'
}
GW_SECTIONS='
## Назначение
x

## Текущая модель
x

## Sidetracks
x

## Next actions
- [ ] x

## References
x
'
# An entry written before Basis entered the canon.
GW_OLD='
## Decision Log

### #1 / 2026-08-01 / old entry

**Source:** assistant
**Context:** c
**Why:** w
**Implication:** i
'
gw_entry() {
  # gw_entry <number> <title> <basis>
  printf '\n### #%s / 2026-10-15 / %s\n\n**Source:** assistant\n**Basis:** %s\n' "$1" "$2" "$3"
  printf '**Basis-detail:** d\n**Context:** c\n**Why:** w\n**Implication:** i\n'
}
gw_write() {
  # gw_write <path> — a Write payload carrying stdin as the content
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.stdin.read()}}))' "$1"
}
gw_edit() {
  # gw_edit <old> <new> — an Edit payload against $GWI
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$GWI" "$1" "$2"
}
gate() {
  # gate <payload> — runs the PreToolUse gate from the fixture
  OUT=$(cd "$GR" && printf '%s' "$1" | CLAUDE_PROJECT_DIR="$GR" bash "$LINT" --pre-hook 2>&1 >/dev/null)
  RC=$?
}

rm -f "$GWI"
gate "$( { gw_head in-progress; printf '%s' "$GW_SECTIONS$GW_OLD"; } | gw_write "$GWI")"
expect_exit "RED: a new file owes all of it — an entry without Basis ⇒ exit 2" 2 "$RC"
expect_says "…names the entry"                 "$OUT" "#1 / 2026-08-01"
expect_says "…and says the edit did not happen" "$OUT" "did not happen"

{ gw_head in-progress; printf '%s' "$GW_SECTIONS$GW_OLD"; } >"$GWI"
gate "$(gw_edit '- [ ] x' '- [x] x')"
expect_exit "GREEN: the same entry already in the file — an unrelated edit passes" 0 "$RC"

gate "$(gw_edit '**Implication:** i' "**Implication:** i
$(gw_entry 2 'new entry' measured)")"
expect_exit "RED: an entry the edit adds, Basis outside the taxonomy ⇒ exit 2" 2 "$RC"
expect_says     "…names the new entry"       "$OUT" "#2 / 2026-10-15"
expect_not_says "…and leaves the old one be" "$OUT" "#1 / 2026-08-01"

gate "$(gw_edit '**Implication:** i' "**Implication:** i
$(gw_entry 2 'new entry' observed)")"
expect_exit "GREEN: the same new entry on canon passes" 0 "$RC"

gate "$(gw_edit 'old entry' 'old entry, retitled')"
expect_exit "GREEN: retitling a past entry — the number is the entry (DL #6)" 0 "$RC"

gate "$(gw_edit '**Implication:** i' '**Implication:** i

### #1 / 2026-10-15 / a reused number

**Source:** assistant')"
expect_exit "RED: a second entry under a number already taken ⇒ exit 2" 2 "$RC"
expect_says     "…names the new one"   "$OUT" "a reused number"
expect_not_says "…not the one before" "$OUT" "old entry"

{ gw_head in-progress; printf '%s' "$GW_SECTIONS$GW_OLD" | sed '/^## Текущая модель$/,/^x$/d'; } >"$GWI"
gate "$(gw_edit '- [ ] x' '- [x] x')"
expect_exit "RED: a missing section is owed at any edit (DL #2) ⇒ exit 2" 2 "$RC"
expect_says "…names it" "$OUT" "## Текущая модель"
gate "$(gw_edit '## Sidetracks' '## Текущая модель

## Sidetracks')"
expect_exit "GREEN: the edit that adds it — empty — passes" 0 "$RC"

rm -f "$GWI"
gate "$( { gw_head done; printf '\n## Назначение\nx\n'; } | gw_write "$GWI")"
expect_exit "RED: born done — a new file has no record to protect (DL #7) ⇒ exit 2" 2 "$RC"
{ gw_head done; printf '\n## Назначение\nx\n'; } >"$GWI"
gate "$(gw_edit '## Назначение' '## Назначение ')"
expect_exit "GREEN: the same file already done is history" 0 "$RC"

{ gw_head in-progress; printf '%s' "$GW_SECTIONS"; printf '\n## Decision Log\n\n### D-1 / 2026-08-01 / theirs\n\n**Source:** user\n'; } >"$GWI"
gate "$(gw_edit '- [ ] x' '- [x] x')"
expect_exit "GREEN: a past entry under the host's own numbering is left as it is" 0 "$RC"
gate "$(gw_edit '**Source:** user' '**Source:** user

### D-2 / 2026-10-15 / new

**Source:** user')"
expect_exit "RED: a new entry under it is written by the canon ⇒ exit 2" 2 "$RC"
expect_says     "…names it"         "$OUT" "D-2"
expect_not_says "…not the past one" "$OUT" "D-1"

{ gw_head in-progress; printf '%s' "$GW_SECTIONS" | sed 's/^- \[ \] x$/- [ ] x (due: soon)/'; } >"$GWI"
gate "$(gw_edit '## References' '## References
')"
expect_exit "GREEN: a malformed date already there is not rewritten by force" 0 "$RC"
gate "$(gw_edit '(due: soon)' '(due: soon)
- [ ] y (due: later)')"
expect_exit "RED: a malformed date the edit adds ⇒ exit 2" 2 "$RC"
expect_says     "…names it"         "$OUT" "(due: later)"
expect_not_says "…not the old one" "$OUT" "(due: soon)"

gate "$(printf '%s' 'x' | gw_write "$GR/docs/tasks/w/references/brief.md")"
expect_exit "GREEN: a reference file in a crystal is not a workitem" 0 "$RC"
gate "$(printf '%s' 'x' | gw_write "$GR/README.md")"
expect_exit "GREEN: a markdown file outside the roots" 0 "$RC"

# The first workitem of a repository is written while no root exists: roots
# are found by their files. On PostToolUse the file was there by then.
FR="$TMP/firstrepo"
mkdir -p "$FR"
FR=$(cd "$FR" && pwd -P)
( cd "$FR" && git init -q . ) >/dev/null 2>&1
OUT=$( { gw_head in-progress; printf '\n## Назначение\nx\n'; } | gw_write "$FR/docs/tasks/first/workitem.md" \
       | (cd "$FR" && CLAUDE_PROJECT_DIR="$FR" bash "$LINT" --pre-hook 2>&1 >/dev/null) )
RC=$?
expect_exit "RED: the first workitem of a repository, before any tasks/ exists ⇒ exit 2" 2 "$RC"
expect_says "…names a missing section" "$OUT" "## Текущая модель"
OUT=$( { gw_head in-progress; printf '%s' "$GW_SECTIONS"; } | gw_write "$FR/docs/tasks/first/workitem.md" \
       | (cd "$FR" && CLAUDE_PROJECT_DIR="$FR" bash "$LINT" --pre-hook 2>&1 >/dev/null) )
RC=$?
expect_exit "GREEN: …and on canon it passes" 0 "$RC"

# ---------------------------------------------------------------------------
printf '\nhook — an open sidetrack this change introduced must carry a checkbox\n'
# ---------------------------------------------------------------------------
# The rule is old (crystal-multi-root DL #14) and it is enforced at ONE moment,
# the done-transition, by which time the reason is sessions old. Census of the
# machine this suite is developed on, 2026-09-25: 276 open sidetracks without a
# `- [ ] … Sidetrack #N` line, in 64 of 134 live workitems — 235 with no
# checkbox at all, the rest with a marker the parser cannot see (a wrapped
# continuation line, "Sidetracks #1 и #2", "побег #3"). Two of them were written
# in this repo the same day. So the hook names an orphan at the write — but
# only one this change introduced, measured against HEAD: the 276 are a
# backlog the done gate owns, and a hook that recited them on every edit would
# pull that backlog into unrelated sessions.
HR="$TMP/hookrepo"
mkdir -p "$HR/docs/tasks/orph"
HR=$(cd "$HR" && pwd -P)
HWI="$HR/docs/tasks/orph/workitem.md"
( cd "$HR" && git init -q . && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false ) >/dev/null 2>&1

wi_cards() {
  # wi_cards <next-actions (printf %b)> <N|status>... — a canonical workitem
  # whose Sidetracks section holds one card per argument.
  local next="$1" c; shift
  {
    printf -- '---\ntitle: "Orph"\nslug: orph\nstatus: in-progress\nsession-type: prd-work\n'
    printf 'created: 2026-09-25\nlast-updated: 2026-09-25\n---\n\n# Orph\n\n'
    printf '## Назначение\nx\n\n## Текущая модель\nx\n\n## Sidetracks\n\n'
    for c in "$@"; do
      printf '### #%s. Card %s\n\n**Status:** %s\n\n' "${c%%|*}" "${c%%|*}" "${c#*|}"
    done
    printf '## Next actions\n%b\n\n## References\nx\n' "$next"
  } >"$HWI"
}
hook_lint() {
  OUT=$(cd "$HR" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$HWI" \
          | CLAUDE_PROJECT_DIR="$HR" bash "$LINT" --hook 2>&1 >/dev/null)
  RC=$?
}
commit_wi() { ( cd "$HR" && git add -A && git commit -qm wi ) >/dev/null 2>&1; }

wi_cards '- [ ] x' '1|open'
hook_lint
expect_exit "RED: a new workitem with an open card and no checkbox ⇒ exit 2" 2 "$RC"
expect_says "…names the card"                  "$OUT" "#1. Card 1"
expect_says "…and gives the line that fixes it" "$OUT" "- [ ] Sidetrack #1"

wi_cards '- [ ] Sidetrack #1: close it' '1|open'
hook_lint
expect_exit "GREEN: the number on the checkbox line ⇒ exit 0" 0 "$RC"
expect_silent "…and nothing is said" "$OUT"

wi_cards '- [ ] Reply to the sender:\n  it covers Sidetrack #1' '1|open'
hook_lint
expect_exit "RED: the number on a wrapped continuation line is not seen ⇒ exit 2" 2 "$RC"
expect_says "…and the message says why" "$OUT" "continuation line"

wi_cards '- [ ] Sidetracks #1 и #2: reply' '1|open' '2|open'
hook_lint
expect_exit "RED: \"Sidetracks #1 и #2\" marks neither ⇒ exit 2" 2 "$RC"
expect_says "…names the first" "$OUT" "#1. Card 1"
expect_says "…and the second"  "$OUT" "#2. Card 2"

wi_cards '- [ ] x' '1|resolved — shipped'
hook_lint
expect_exit "GREEN: a card that is not open owes nothing ⇒ exit 0" 0 "$RC"

# The backlog stays with the done gate: an orphan already at HEAD is not
# re-reported by an edit elsewhere in the file…
wi_cards '- [ ] x' '1|open'
commit_wi
printf '\nan unrelated edit\n' >>"$HWI"
hook_lint
expect_exit "GREEN: an orphan committed before this change is not recited ⇒ exit 0" 0 "$RC"
expect_silent "…silently" "$OUT"

# …but a new one next to it is, and only the new one.
wi_cards '- [ ] x' '1|open' '2|open'
hook_lint
expect_exit "RED: a second open card added next to a committed orphan ⇒ exit 2" 2 "$RC"
expect_says     "…names the new card"            "$OUT" "#2. Card 2"
expect_not_says "…and leaves the committed one alone" "$OUT" "#1. Card 1"

# --staged makes the gate's comparison with HEAD in place of the disk (canon-gate-scope
# DL #7): a past entry at HEAD owes nothing, an entry this commit adds owes it all.
SWI="$HR/docs/tasks/staged/workitem.md"
mkdir -p "$HR/docs/tasks/staged"
{ gw_head in-progress; printf '%s' "$GW_SECTIONS$GW_OLD"; } >"$SWI"
commit_wi
printf '\nan unrelated line\n' >>"$SWI"
( cd "$HR" && git add -A ) >/dev/null 2>&1
OUT=$(cd "$HR" && bash "$LINT" --staged 2>&1); RC=$?
expect_exit "GREEN: --staged, a past entry off canon at HEAD, an unrelated change" 0 "$RC"
gw_entry 2 'new entry' measured >>"$SWI"
( cd "$HR" && git add -A ) >/dev/null 2>&1
OUT=$(cd "$HR" && bash "$LINT" --staged 2>&1); RC=$?
expect_exit "RED: --staged, an entry this commit adds off canon ⇒ exit 1" 1 "$RC"
expect_says     "…names it"                "$OUT" "#2 / 2026-10-15"
expect_not_says "…and not the one at HEAD" "$OUT" "#1 / 2026-08-01"

# ---------------------------------------------------------------------------
printf '\nSKILL.md ↔ template agreement\n'
# ---------------------------------------------------------------------------
# crystal-grow/SKILL.md inlines the skeleton so one read is enough. That inline
# copy is a SECOND copy of the canon, and second copies drift. This test is what
# makes the inlining safe: every canonical section and DL field derived from the
# template must literally appear in the skill text.
SKILL="$REPO_ROOT/plugins/vdm/skills/crystal-grow/SKILL.md"
if [ -f "$SKILL" ]; then
  SKILL_TEXT=$(cat "$SKILL")
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      section|section-optional)
        expect_says "SKILL.md inlines section '$value'" "$SKILL_TEXT" "## $value" ;;
      dl-field)
        expect_says "SKILL.md inlines DL field '$value'" "$SKILL_TEXT" "**$value:**" ;;
      basis-value)
        expect_says "SKILL.md inlines Basis value '$value'" "$SKILL_TEXT" "$value" ;;
    esac
  done < <(bash "$LINT" --print-canon | grep -v '^#')
else
  bad "crystal-grow/SKILL.md not found"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
