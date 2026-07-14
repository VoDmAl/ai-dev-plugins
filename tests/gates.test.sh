#!/bin/bash
# gates.test.sh — RED TESTS for every deterministic gate in this repo.
#
# Why this file exists. On 2026-07-14 the orphan audit was found to have been
# blind since the day it shipped: `grep -rlF -- "$needle" --include=… .` puts
# `--` before the flags, which ends option parsing, so every --include /
# --exclude was handed to grep as a FILE OPERAND rather than a filter. The gate
# had been accepting a PROJECT_CHANGELOG.md mention as a discovery hook — the
# one thing its own documentation forbids — and passed every run anyway, because
# every audited file happened to also have a legitimate hook. It was green
# because it was BLIND, not because the tree was clean.
#
#   A gate does not exist until you have watched it FAIL.
#   Green on a clean tree proves nothing: `exit 0` is also green.
#
# So each gate here is exercised in BOTH directions:
#   - GREEN: clean tree ⇒ exit 0.
#   - RED:   invariant broken on purpose ⇒ non-zero, and the message names the
#            offending thing (a gate that fails without saying why is hostile).
# Several gates also get FALSE-POSITIVE tests: things that look like violations
# and must NOT be flagged. A gate that over-fires gets disabled by its users,
# which is the same as not existing.
#
# Everything runs inside a throwaway clone of HEAD, never the working tree.
#
# Run: bash tests/gates.test.sh   (exit 0 = all pass)
# See docs/llm/soft-guidance-vs-deterministic-gates.md → "The orphan gate that
# never ran" for the full post-mortem.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

expect_exit() {
  # expect_exit <desc> <expected-code> <actual-code>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi
}

expect_says() {
  # expect_says <desc> <output> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "output did not mention: $3" ;;
  esac
}

# ---------------------------------------------------------------------------
# Throwaway copy of the WORKING TREE (not of HEAD), turned into a fresh repo.
# The gates read the git index, so they need a real repo — but never this one.
#
# Working tree, emphatically NOT `git clone` of HEAD. `.githooks/pre-commit`
# executes the gate scripts as they exist on disk, so a harness that tested HEAD
# would be blind to the regression you just introduced and have not committed —
# i.e. blind at exactly the moment it is supposed to speak. Found by red-testing
# this harness: the grep bug was reintroduced on disk and the HEAD-cloning
# version reported all-green.
#
# The irony is the point. A red-test harness that is never itself red-tested is
# the same failure it exists to prevent, one level up.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gates)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CLONE="$TMP/clone"
mkdir -p "$CLONE"

# Copy every tracked and not-ignored file, exactly as it sits on disk right now.
( cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
    | tar -cf - --null -T - ) 2>/dev/null | ( cd "$CLONE" && tar -xf - ) 2>/dev/null || {
  echo "gates.test: could not materialise the working tree — aborting" >&2
  exit 1
}

cd "$CLONE" || exit 1

# The observer must not sit inside the observed tree. Defence in depth alongside
# the runtime-minted fixture names further down: the harness is not part of the
# system under test, and a copy of it in the tree is one more file that could
# accidentally satisfy an invariant the tests are trying to violate.
rm -rf tests

git init --quiet .
git config user.email test@example.com
git config user.name  Test
git add -A >/dev/null 2>&1
git commit --quiet -m 'baseline: working tree as of test start' >/dev/null 2>&1 || {
  echo "gates.test: could not create the baseline commit — aborting" >&2
  exit 1
}

# Every gate must be green on the pristine clone first. If this fails, the
# red tests below prove nothing — a gate that is already red cannot be shown
# to go red.
echo "== baseline: every gate green on a pristine tree =="
for g in check-lib-sync check-version-bump check-skill-paths check-crystal-completion; do
  out=$(bash "scripts/$g.sh" 2>&1); rc=$?
  expect_exit "$g green on clean tree" 0 "$rc"
done
out=$(bash plugins/vdm/scripts/check-doc-orphans.sh 2>&1); rc=$?
expect_exit "check-doc-orphans green on clean tree" 0 "$rc"

restore() { git -C "$CLONE" reset --quiet HEAD -- . 2>/dev/null; git -C "$CLONE" checkout --quiet -- . 2>/dev/null; git -C "$CLONE" clean --quiet -fd 2>/dev/null; }

# ---------------------------------------------------------------------------
echo ""
echo "== check-lib-sync =="
# RED 1: the two lib/ copies diverge.
printf '\n# injected drift\n' >> plugins/vdm-git/lib/config-read.sh
out=$(bash scripts/check-lib-sync.sh 2>&1); rc=$?
expect_exit "RED: divergent mirror ⇒ exit 1" 1 "$rc"
expect_says "RED: names the drifted file" "$out" "config-read.sh"
restore

# RED 2: a file exists in only one copy.
printf '#!/bin/bash\n' > plugins/vdm-git/lib/only-here.sh
out=$(bash scripts/check-lib-sync.sh 2>&1); rc=$?
expect_exit "RED: orphan file in vdm-git/lib ⇒ exit 1" 1 "$rc"
expect_says "RED: names the orphan" "$out" "only-here.sh"
restore

# FALSE-POSITIVE: the cross-reference comment naming the OTHER plugin is the
# one legal difference. It must not be reported as drift.
out=$(bash scripts/check-lib-sync.sh 2>&1); rc=$?
expect_exit "GREEN: legal cross-ref comment is not drift" 0 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "== check-version-bump =="
# RED 1: a plugin file staged with no version bump.
printf '\n# touched\n' >> plugins/vdm/scripts/distill-scan.sh
git add plugins/vdm/scripts/distill-scan.sh
out=$(bash scripts/check-version-bump.sh 2>&1); rc=$?
expect_exit "RED: staged plugin file without bump ⇒ exit 1" 1 "$rc"
expect_says "RED: names the plugin" "$out" "vdm has staged changes without a version bump"
restore

# RED 2: marketplace ↔ plugin.json parity broken — plugin.json bumped, catalog
# left behind. This is the round-2 bug from the meta-pattern doc: the first
# version of the gate saw plugin.json and ignored marketplace.json, so the
# catalog kept advertising the old version and downstream consumers never saw
# the update.
#
# The gate reads BOTH versions from the git INDEX (`git show :path`), not from
# disk — correct for a pre-commit gate, since an unstaged edit is not part of
# the commit it is guarding. So the injection must be staged to be visible.
# (Writing this test is how that semantic was learned; the first draft edited
# the file on disk only and the gate stayed green, correctly.)
sed -i.bak 's/"version": "[0-9][0-9.]*"/"version": "9.9.9"/' plugins/vdm/.claude-plugin/plugin.json && rm -f plugins/vdm/.claude-plugin/plugin.json.bak
git add plugins/vdm/.claude-plugin/plugin.json
out=$(bash scripts/check-version-bump.sh 2>&1); rc=$?
expect_exit "RED: staged parity drift ⇒ exit 1" 1 "$rc"
expect_says "RED: names the parity drift" "$out" "marketplace ↔ plugin.json drift"
restore

# RED 3: parity is checked UNCONDITIONALLY — a drift already present in HEAD
# fires on every commit, even one that touches nothing related. Committed drift
# must not become invisible just because nobody is touching the manifests.
sed -i.bak 's/"version": "[0-9][0-9.]*"/"version": "9.9.9"/' plugins/vdm/.claude-plugin/plugin.json && rm -f plugins/vdm/.claude-plugin/plugin.json.bak
git add plugins/vdm/.claude-plugin/plugin.json
git commit --quiet -m 'inject parity drift into HEAD' --no-verify
printf '\n' >> README.md          # an unrelated change, nothing to do with plugins
git add README.md
out=$(bash scripts/check-version-bump.sh 2>&1); rc=$?
expect_exit "RED: parity drift in HEAD fires on an unrelated commit" 1 "$rc"
git reset --quiet --hard HEAD~1

# GREEN: staged plugin file WITH a bump in both manifests.
printf '\n# touched\n' >> plugins/vdm/scripts/distill-scan.sh
sed -i.bak 's/"version": "[0-9][0-9.]*"/"version": "99.0.0"/' plugins/vdm/.claude-plugin/plugin.json && rm -f plugins/vdm/.claude-plugin/plugin.json.bak
python3 - <<'PY'
import json
p = ".claude-plugin/marketplace.json"
d = json.load(open(p))
for entry in d.get("plugins", []):
    if entry.get("name") == "vdm":
        entry["version"] = "99.0.0"
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
PY
git add plugins/vdm/scripts/distill-scan.sh plugins/vdm/.claude-plugin/plugin.json .claude-plugin/marketplace.json
out=$(bash scripts/check-version-bump.sh 2>&1); rc=$?
expect_exit "GREEN: bump present in both manifests ⇒ exit 0" 0 "$rc"
restore

# ---------------------------------------------------------------------------
echo ""
echo "== check-skill-paths =="
SKILL=plugins/vdm/skills/docs-distill/SKILL.md

# RED 1: a dev-tree path that does not resolve at user time.
printf '\nSee plugins/vdm/scripts/distill-scan.sh for details.\n' >> "$SKILL"
out=$(bash scripts/check-skill-paths.sh 2>&1); rc=$?
expect_exit "RED: dev-tree path leak ⇒ exit 1" 1 "$rc"
expect_says "RED: names the file" "$out" "docs-distill/SKILL.md"
restore

# RED 2: a bare reference to one of THIS repo's crystals — it ships nowhere.
printf '\nBackground: docs/tasks/docs-distill/workitem.md\n' >> "$SKILL"
out=$(bash scripts/check-skill-paths.sh 2>&1); rc=$?
expect_exit "RED: dangling repo-doc ref ⇒ exit 1" 1 "$rc"
expect_says "RED: calls it dangling" "$out" "dangling repo-doc reference"
restore

# FALSE-POSITIVE 1: the same crystal, written as an explicit cross-repo
# citation, is honest and must pass.
printf '\nBackground: cc-vdm-plugins → docs/tasks/docs-distill/workitem.md\n' >> "$SKILL"
out=$(bash scripts/check-skill-paths.sh 2>&1); rc=$?
expect_exit "GREEN: cross-repo citation is not flagged" 0 "$rc"
restore

# FALSE-POSITIVE 2: `docs/llm/{topic}.md` is a placeholder for the USER's tree —
# writing there is the plugin's entire job. Flagging it would be backwards.
printf '\nWrite the topic to docs/llm/{topic}.md and docs/features/{feature}.md.\n' >> "$SKILL"
out=$(bash scripts/check-skill-paths.sh 2>&1); rc=$?
expect_exit "GREEN: user-tree placeholders are not flagged" 0 "$rc"
restore

# FALSE-POSITIVE 3: ${CLAUDE_PLUGIN_ROOT} is the correct form and must pass.
printf '\nRun ${CLAUDE_PLUGIN_ROOT}/scripts/distill-scan.sh --drift\n' >> "$SKILL"
out=$(bash scripts/check-skill-paths.sh 2>&1); rc=$?
expect_exit "GREEN: \${CLAUDE_PLUGIN_ROOT} form is not flagged" 0 "$rc"
restore

# ---------------------------------------------------------------------------
echo ""
echo "== check-crystal-completion =="
mkdir -p docs/tasks/zz-gate-test

# RED: status:done staged while an unchecked obligation remains.
cat > docs/tasks/zz-gate-test/workitem.md <<'EOF'
---
title: "gate test"
slug: zz-gate-test
status: done
created: 2026-07-14
last-updated: 2026-07-14
---
# gate test
## Next actions
- [ ] an obligation nobody addressed
EOF
git add docs/tasks/zz-gate-test/workitem.md
out=$(bash scripts/check-crystal-completion.sh 2>&1); rc=$?
expect_exit "RED: status:done + unchecked ⇒ exit 1" 1 "$rc"
expect_says "RED: names the slug" "$out" "zz-gate-test"
restore

# GREEN: status:done with everything addressed.
mkdir -p docs/tasks/zz-gate-test
cat > docs/tasks/zz-gate-test/workitem.md <<'EOF'
---
title: "gate test"
slug: zz-gate-test
status: done
created: 2026-07-14
last-updated: 2026-07-14
---
# gate test
## Next actions
- [x] addressed
EOF
git add docs/tasks/zz-gate-test/workitem.md
out=$(bash scripts/check-crystal-completion.sh 2>&1); rc=$?
expect_exit "GREEN: status:done with zero unchecked ⇒ exit 0" 0 "$rc"
restore

# FALSE-POSITIVE: an unchecked box in an IN-PROGRESS crystal is normal work,
# not a violation. If this fired, no crystal could ever be committed.
mkdir -p docs/tasks/zz-gate-test
cat > docs/tasks/zz-gate-test/workitem.md <<'EOF'
---
title: "gate test"
slug: zz-gate-test
status: in-progress
created: 2026-07-14
last-updated: 2026-07-14
---
# gate test
## Next actions
- [ ] still working on it
EOF
git add docs/tasks/zz-gate-test/workitem.md
out=$(bash scripts/check-crystal-completion.sh 2>&1); rc=$?
expect_exit "GREEN: unchecked in status:in-progress is not a violation" 0 "$rc"
restore

# ---------------------------------------------------------------------------
echo ""
echo "== check-doc-orphans =="
ORPHANS=plugins/vdm/scripts/check-doc-orphans.sh

# Fixture paths are MINTED AT RUNTIME and never written literally anywhere.
#
# This is not fastidiousness — it is the fix for a trap this suite lays for its
# own tests, and which caught us twice. The audit counts a mention from a source
# file (`.sh`) or from a synthesis document as a legitimate discovery hook. So
# ANY static text in the repo that names a fixture path — the harness itself,
# a README paragraph, and (the one that actually bit) `docs/model/suite.md`
# explaining this very trap — becomes a real hook for that fixture, and the RED
# test quietly turns green. The gate would be right and the test wrong, which is
# the worst failure a test can have: it lies in the safe-looking direction.
#
# A name that exists only for the duration of this process cannot be referenced
# by any file on disk. Prose about the tests is then free to say anything.
UNIQ="zzgate$$x${RANDOM:-0}"
ORPHAN_DOC="docs/llm/${UNIQ}-frag.md"
SYNTH_DOC="docs/model/${UNIQ}-synth.md"

# RED 1: a docs/llm/ file nothing references.
printf '# Fragment\nNothing points here.\n' > "$ORPHAN_DOC"
out=$(bash "$ORPHANS" 2>&1); rc=$?
expect_exit "RED: unreferenced docs/llm/ file ⇒ exit 1" 1 "$rc"
expect_says "RED: names the orphan" "$out" "$ORPHAN_DOC"
restore

# RED 2: a SYNTHESIS document nothing references. This is the case the drift
# signal cannot catch — inputs never change ⇒ never drifts ⇒ never surfaces.
mkdir -p docs/model
cat > "$SYNTH_DOC" <<EOF
---
type: model
question: "does the orphan audit see a synthesis doc?"
covers:
  - docs/llm/*.md
observed: 2026-07-14
---
# Unreferenced synthesis
EOF
out=$(bash "$ORPHANS" 2>&1); rc=$?
expect_exit "RED: unreferenced synthesis doc ⇒ exit 1" 1 "$rc"
expect_says "RED: names the synthesis orphan" "$out" "$SYNTH_DOC"
restore

# RED 3 — THE REGRESSION THAT STARTED ALL THIS.
# A mention in PROJECT_CHANGELOG.md must NOT count as a discovery hook. The
# shipped gate accepted it for months because `--` before the grep flags turned
# every --exclude into a filename. If this test ever goes green, the bug is back.
printf '# Fragment\nOnly the changelog mentions this.\n' > "$ORPHAN_DOC"
printf '\n- see %s for details\n' "$ORPHAN_DOC" >> PROJECT_CHANGELOG.md
out=$(bash "$ORPHANS" 2>&1); rc=$?
expect_exit "RED: changelog mention is NOT a discovery hook ⇒ exit 1" 1 "$rc"
expect_says "RED: still names the orphan" "$out" "$ORPHAN_DOC"
restore

# GREEN 1: a CLAUDE.md back-reference is a valid hook.
printf '# Hooked\n' > "$ORPHAN_DOC"
printf '\nSee %s for the rule.\n' "$ORPHAN_DOC" >> CLAUDE.md
out=$(bash "$ORPHANS" 2>&1); rc=$?
expect_exit "GREEN: CLAUDE.md back-ref is a hook ⇒ exit 0" 0 "$rc"
restore

# GREEN 2: a reference from a SYNTHESIS document is a first-class hook — you
# reach the parts through the whole. This category did not exist before the
# suite grew a synthesis tier.
printf '# Hooked via synthesis\n' > "$ORPHAN_DOC"
mkdir -p docs/model
cat > "$SYNTH_DOC" <<EOF
---
type: model
question: "can a synthesis doc hook a fragment?"
covers:
  - docs/llm/*.md
observed: 2026-07-14
---
# Synthesis
It reassembles ${ORPHAN_DOC} among others.
EOF
printf '\nSee %s for the model.\n' "$SYNTH_DOC" >> CLAUDE.md
out=$(bash "$ORPHANS" 2>&1); rc=$?
expect_exit "GREEN: synthesis-doc reference is a hook ⇒ exit 0" 0 "$rc"
restore

# ---------------------------------------------------------------------------
echo ""
printf 'gates: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
