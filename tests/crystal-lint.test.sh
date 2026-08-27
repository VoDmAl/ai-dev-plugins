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
