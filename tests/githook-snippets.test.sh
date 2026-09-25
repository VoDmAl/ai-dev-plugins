#!/bin/bash
# githook-snippets.test.sh — RED TESTS for the git-hook snippets that
# plugins/vdm-git/skills/guard/SKILL.md hands to a user's `.githooks/pre-commit`.
#
# The snippets run in a plain shell outside the harness, where
# ${CLAUDE_PLUGIN_ROOT} is undefined, so they find the plugin's install path
# themselves — and that finding is what is tested here. The incident this file
# exists for (2026-09-25): ~/.claude/plugins/marketplaces/ held two clones of one
# marketplace, the live `vodmal/` and an abandoned
# `vodmal-claude-code-marketplace/` six months stale. The snippet took the first
# match of a glob, and the live clone happened to sort first. Where the names
# sort the other way, every commit would have been checked by a months-old copy
# of the gate, and nothing would have said so.
#
# The snippets are read from SKILL.md itself, never copied here, so what runs is
# exactly what a user pastes. To prove a change red against the previous text:
#   GUARD_SKILL=<old SKILL.md> bash tests/githook-snippets.test.sh
#
# @see plugins/vdm-git/skills/guard/SKILL.md § Crystal pre-commit backup, § U+FFFD

# A harness that runs inside a hook inherits the caller's git session. Nothing
# here calls git today; the scrub is here so that nothing added later can write
# into the commit that is running this file.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="${GUARD_SKILL:-$REPO_ROOT/plugins/vdm-git/skills/guard/SKILL.md}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t githook-snippets)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# block <prefix> — the fenced ```bash block of SKILL.md whose first line starts
# with <prefix>. Empty when there is no such block, which is how the previous
# SKILL.md (no shared resolver) still assembles into a runnable hook.
block() {
  awk -v want="$1" '
    /^```bash$/        { inb = 1; first = 1; keep = 0; buf = ""; next }
    /^```$/ && inb     { if (keep) printf "%s", buf; inb = 0; next }
    inb                { if (first) { keep = (index($0, want) == 1); first = 0 }
                         buf = buf $0 "\n" }
  ' "$SKILL"
}

# make_hook <file> <gate-prefix> <shell-options> — a pre-commit the way the
# SKILL tells a user to write one: the shared resolver, then the gate.
make_hook() {
  { printf '#!/bin/sh\nset %s\n' "$3"
    block '# vdm-git gate resolver'
    block "$2"
  } > "$1"
  chmod +x "$1"
}

# stub <dir> <script> — a stand-in for the real gate that says which copy ran.
stub() {
  mkdir -p "$1"
  printf '#!/bin/sh\necho "RAN %s"\nexit "${STUB_RC:-0}"\n' "$1/$2" > "$1/$2"
  chmod +x "$1/$2"
}

# registry <home> <location>... — a known_marketplaces.json in the harness's own
# shape (pretty-printed, one object per marketplace) listing those checkouts.
registry() {
  local h="$1"; shift
  local n=$# i=0 loc
  mkdir -p "$h/.claude/plugins"
  {
    echo "{"
    for loc in "$@"; do
      i=$((i + 1))
      printf '  "market-%d": {\n    "source": {\n      "source": "github",\n      "repo": "owner/repo-%d"\n    },\n    "installLocation": "%s",\n    "lastUpdated": "2026-09-25T00:00:00.000Z"\n  }%s\n' \
        "$i" "$i" "$loc" "$([ "$i" -lt "$n" ] && echo ,)"
    done
    echo "}"
  } > "$h/.claude/plugins/known_marketplaces.json"
}

# run_hook <hook> <shell> <home> [VAR=value...] — run it with a clean environment:
# the developer's own CRYSTAL_PRECOMMIT_CHECK must not leak into a scenario.
run_hook() {
  local hook="$1" sh="$2" home="$3"; shift 3
  OUT=$(env -i PATH="$PATH" HOME="$home" "$@" "$sh" "$hook" 2>&1); RC=$?
}

[ -f "$SKILL" ] || { echo "githook-snippets: no SKILL.md at $SKILL" >&2; exit 1; }

for gate in crystal fffd; do
  case "$gate" in
    crystal) prefix='# Crystal completion-discipline backup gate'
             script=crystal-precommit-check.sh; override=CRYSTAL_PRECOMMIT_CHECK ;;
    fffd)    prefix='# U+FFFD guard'
             script=fffd-precommit-check.sh;    override=FFFD_PRECOMMIT_CHECK ;;
  esac
  rel="plugins/vdm-git/scripts"

  echo "== $gate: the snippet finds the live copy of $script =="

  if [ -z "$(block "$prefix")" ]; then
    bad "$gate: SKILL.md has a bash block starting with '$prefix'"
    continue
  fi

  HOOK="$TMP/$gate.pre-commit"
  make_hook "$HOOK" "$prefix" -eu

  # 1. The incident itself: an abandoned clone that sorts BEFORE the live one.
  H="$TMP/$gate/h1"; M="$H/.claude/plugins/marketplaces"
  stub "$M/aaa-abandoned/$rel" "$script"
  stub "$M/vodmal/$rel" "$script"
  mkdir -p "$M/other"
  registry "$H" "$M/other" "$M/vodmal"
  run_hook "$HOOK" sh "$H"
  expect_exit "RED: registered clone wins over an abandoned one that sorts first — commit passes" 0 "$RC"
  expect_says "RED: … and it is the registered clone that ran" "$OUT" "RAN $M/vodmal/$rel/$script"
  expect_not_says "RED: … and the abandoned clone never ran" "$OUT" "aaa-abandoned"

  # 2. No registry to ask: two copies are refused by name, not guessed between.
  H="$TMP/$gate/h2"; M="$H/.claude/plugins/marketplaces"
  stub "$M/aaa-abandoned/$rel" "$script"
  stub "$M/vodmal/$rel" "$script"
  run_hook "$HOOK" sh "$H"
  expect_exit "RED: without a registry, two copies do not block the commit" 0 "$RC"
  expect_not_says "RED: … neither copy is run on a guess" "$OUT" "RAN "
  expect_says "RED: … it says it refuses to guess" "$OUT" "several copies"
  expect_says "RED: … the refusal names the first copy" "$OUT" "$M/aaa-abandoned/$rel/$script"
  expect_says "RED: … and the second" "$OUT" "$M/vodmal/$rel/$script"

  # 3. A readable registry is the whole truth: a clone it does not list is not
  #    picked up behind its back, even when it is the only copy on disk.
  H="$TMP/$gate/h3"; M="$H/.claude/plugins/marketplaces"
  stub "$M/unregistered/$rel" "$script"
  mkdir -p "$M/other"
  registry "$H" "$M/other"
  run_hook "$HOOK" sh "$H"
  expect_not_says "RED: an unregistered clone is not used while the registry is readable" "$OUT" "RAN "
  expect_says "RED: … and the snippet says it found nothing" "$OUT" "not found"

  # 4. Without a registry, a single copy is simply used (Qwen Code, or a harness
  #    that keeps no registry). Both roots are covered.
  H="$TMP/$gate/h4"
  stub "$H/.qwen/plugins/marketplaces/some/$rel" "$script"
  run_hook "$HOOK" sh "$H"
  expect_says "GREEN: without a registry, the one copy there is gets run" "$OUT" "RAN $H/.qwen/plugins/marketplaces/some/$rel/$script"

  # 5. Nothing installed: loud, and the commit is not blocked by the absence.
  H="$TMP/$gate/h5"; mkdir -p "$H"
  run_hook "$HOOK" sh "$H"
  expect_exit "GREEN: nothing installed does not block the commit" 0 "$RC"
  expect_says "GREEN: … but says so" "$OUT" "not found"

  # 6. The gate's own verdict still blocks.
  H="$TMP/$gate/h6"; M="$H/.claude/plugins/marketplaces"
  stub "$M/vodmal/$rel" "$script"
  registry "$H" "$M/vodmal"
  run_hook "$HOOK" sh "$H" STUB_RC=1
  expect_exit "GREEN: a failing gate blocks the commit" 1 "$RC"

  # 7. The override wins and the resolver is not consulted.
  H="$TMP/$gate/h7"; M="$H/.claude/plugins/marketplaces"
  stub "$M/vodmal/$rel" "$script"
  registry "$H" "$M/vodmal"
  stub "$TMP/$gate/custom" "$script"
  run_hook "$HOOK" sh "$H" "$override=$TMP/$gate/custom/$script"
  expect_says "GREEN: $override overrides the resolver" "$OUT" "RAN $TMP/$gate/custom/$script"
  expect_not_says "GREEN: … and the registered copy is not run as well" "$OUT" "RAN $M/vodmal"

  # 8. A registered checkout whose path has a space in it (echelon's lives under
  #    "AI Projects" on the machine this was written on).
  H="$TMP/$gate/h8"; M="$H/.claude/plugins/marketplaces"
  stub "$M/my market/$rel" "$script"
  registry "$H" "$M/my market"
  run_hook "$HOOK" sh "$H"
  expect_says "GREEN: a registered path with a space resolves" "$OUT" "RAN $M/my market/$rel/$script"

  # 9. A hook written as strictly as this repo's own — bash, -euo pipefail —
  #    must survive the paths where grep matches nothing.
  STRICT="$TMP/$gate.strict.pre-commit"
  make_hook "$STRICT" "$prefix" '-euo pipefail'
  H="$TMP/$gate/h9"; M="$H/.claude/plugins/marketplaces"
  mkdir -p "$M/other"
  registry "$H" "$M/other"
  run_hook "$STRICT" bash "$H"
  expect_exit "GREEN: under set -euo pipefail, nothing found still lets the commit through" 0 "$RC"
  expect_says "GREEN: … and still says so" "$OUT" "not found"
done

echo
echo "githook-snippets: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
