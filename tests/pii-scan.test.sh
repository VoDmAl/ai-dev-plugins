#!/bin/bash
# pii-scan.test.sh — RED TESTS for the PII gate (crystal public-repo-cleanup).
#
# The gate is scripts/pii-gate.sh: the pre-commit runs `index` (gate 13), the
# commit-msg hook `message <file>`; both run scripts/pii-scan.py --gate. A gate
# does not exist until you have watched it fail (tests/gates.test.sh), so each
# property is shown in both directions:
#   * a finding blocks the commit and says what, where and what to do;
#   * what the allowlist names passes — the allowlist STAGED with the commit,
#     not the file on disk;
#   * a disputed finding goes to Jev: once per value, at most five per run,
#     nothing but the candidate and its line, from the repository root, with the
#     commit's git session left behind. The answer picks the remedy and never
#     lets the commit through; after a failure no further question is asked;
#   * the gate reads the index git hands the hook, the message as git records
#     it, and the signature;
#   * without uv, or without address books, it blocks;
#   * its git launches do not grow with the staged files;
#   * both hooks call it.
#
# Fixtures only: a registry, an address book and an access layer of their own —
# never the owner's books, and never the real Jev, which would send text out.
# No commit is made anywhere: the fixture repository is `git init` and `git add`.
#
# Run: bash tests/pii-scan.test.sh   (exit 0 = all pass; needs uv on PATH)

set -u

# Scrub the inherited git session — see tests/gates.test.sh. The pre-commit runs
# this suite inside a live `git commit`, and this suite is the one that taught
# the block its second half: it reads the signature through `git var` and the
# editor to decide what the message is, and inherited, the live commit's author
# overrode the fixture's — three cases red in the hook, green by hand.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true
# The gate finds the address books, the private terms and the access layer
# through these. Each is pinned to the fixture below, never to the owner's.
unset VDM_INTERCOM_ROOT PII_SCAN_TERMS 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
expect_says() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "output did not mention: $3" ;;
  esac
}
expect_not_says() {
  # An empty haystack contains nothing, so absence there proves nothing
  # (tests/harness-asserts.test.sh). Silence is asserted as silence.
  [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }
  case "$2" in
    *"$3"*) bad "$1" "output should NOT mention: $3" ;;
    *)      ok "$1" ;;
  esac
}

if ! command -v uv >/dev/null 2>&1; then
  echo "pii-scan.test: uv is not on PATH — the gate runs through it (CLAUDE.md → Dev setup)" >&2
  exit 1
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t piiscan) || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"; HQ="$TMP/hq"; ACCESS="$TMP/access"; STORE="$TMP/store"; JEV_LOG="$TMP/jev"
mkdir -p "$REPO/scripts" "$REPO/.githooks" "$REPO/docs" "$HQ/people" "$ACCESS/bin" "$STORE/_registry"
cp "$REPO_ROOT/scripts/pii-scan.py" "$REPO_ROOT/scripts/pii-gate.sh" "$REPO/scripts/"
cp "$REPO_ROOT/.githooks/commit-msg" "$REPO/.githooks/"
: > "$TMP/terms.txt"

# One person in the address book. The name is one of the fictional ones this
# repository's own allowlist carries, so this file passes the real gate.
printf -- '---\nslug: ivan-sokolov\n---\n\n# Иван Соколов\n' > "$HQ/people/ivan-sokolov.md"

registry() {  # registry <identity> <path> — one entry of the fixture registry
  printf '{"identity": "%s", "paths": ["%s"]}\n' "$1" "$2" > "$STORE/_registry/$1.json"
}
registry fixture-repo "$REPO"
registry fixture-hq "$HQ"
registry echelon "$ACCESS"

# The access layer's `jev`, faked: it keeps what it was given and answers as the
# test says.
cat > "$ACCESS/bin/echelon" <<'EOF'
#!/bin/bash
[ "${1:-}" = jev ] || { echo "fake access layer: no command ${1:-}" >&2; exit 2; }
n=$(( $(cat "$JEV_LOG/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$JEV_LOG/n"
cat > "$JEV_LOG/in.$n"
pwd -P > "$JEV_LOG/cwd.$n"
env > "$JEV_LOG/env.$n"
case "${JEV_ANSWER:-term}" in
  down) echo "TypeSafe: no key" >&2; exit 1 ;;
  junk) echo "no json here" ;;
  *)    printf '{"choice": "%s", "confidence": 0.97, "model": "fake"}\n' "$JEV_ANSWER" ;;
esac
EOF
chmod +x "$ACCESS/bin/echelon"

allowlist() {  # allowlist [<line>…] — the fixture allowlist on disk
  { printf 'agent echelon\nemail example.com\nhost example.com\n'; printf '%s\n' "$@"; } \
    > "$REPO/scripts/pii-allow.txt"
}

cd "$REPO" || exit 1
git init -q .
git config user.name Test
git config user.email test@example.com

JEV_ANSWER=term
gate() {  # gate <mode> [<file>] — the gate as a hook runs it, from the repository root
  rm -rf "$JEV_LOG"; mkdir -p "$JEV_LOG"
  VDM_INTERCOM_ROOT="$STORE" PII_SCAN_TERMS="$TMP/terms.txt" JEV_LOG="$JEV_LOG" JEV_ANSWER="$JEV_ANSWER" \
    bash scripts/pii-gate.sh "$@" 2>&1
}
asked() { cat "$JEV_LOG/n" 2>/dev/null || echo 0; }
fresh() {  # fresh [<allowlist line>…] — an empty index holding only the allowlist
  git rm -rq --cached . >/dev/null 2>&1
  rm -rf docs; mkdir -p docs
  allowlist "$@"
  git add scripts/pii-allow.txt
}
stage() {  # stage <path> <text> — write a file and stage it
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  git add -- "$1"
}

# Built at run time: written out whole, this file would be a finding of the real
# gate itself.
KEY="ZQX""-42"
ADDRESS="build.bot@""corp-mail.net"

# ---------------------------------------------------------------------------
echo "== a clean change passes, and Jev is not asked =="
fresh
stage docs/clean.md "The gate reads only what a commit adds."
out=$(gate index); rc=$?
expect_exit "clean change: exit 0" 0 "$rc"
expect_says "clean change: says it looked" "$out" "nothing found"
expect_eq "clean change: no question to Jev" "$(asked)" 0

# ---------------------------------------------------------------------------
echo ""
echo "== the address book: a person blocks, in a line and in a path =="
fresh
stage docs/meeting.md "встреча с Соколовым прошла"
out=$(gate index); rc=$?
expect_exit "a person from the book: blocked" 1 "$rc"
expect_says "names the value" "$out" "Соколовым"
expect_says "names where" "$out" "docs/meeting.md:1"
expect_says "names the remedy" "$out" "a fictional name no address book holds"
expect_eq "a book finding is not disputed: Jev not asked" "$(asked)" 0

fresh
stage docs/sokolov-notes.md "Notes."
out=$(gate index); rc=$?
expect_exit "a person in a path: blocked" 1 "$rc"
expect_says "names the path" "$out" "docs/sokolov-notes.md (path)"

# ---------------------------------------------------------------------------
echo ""
echo "== a disputed name goes to Jev; the answer picks the remedy, the commit stays blocked =="
fresh
stage docs/call.md "на звонке был Котов"
# As a hook: git exports the commit's index to it.
out=$(GIT_INDEX_FILE="$REPO/.git/index" gate index); rc=$?
expect_exit "Jev says jargon: still blocked" 1 "$rc"
expect_says "says the answer came from Jev" "$out" "Jev: a technical term (0.97)"
expect_says "the remedy is the line for the allowlist" "$out" '`word Котов` in scripts/pii-allow.txt'
expect_eq "one question" "$(asked)" 1
sent=$(cat "$JEV_LOG/in.1" 2>/dev/null)
expect_says "the question carries the candidate" "$sent" "Котов"
expect_not_says "…and not the path of the file" "$sent" "docs/call.md"
state_len=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["state"]))' "$JEV_LOG/in.1" 2>/dev/null)
if [ -n "$state_len" ] && [ "$state_len" -le 400 ]; then
  ok "the state fits the access layer's 400 characters ($state_len)"
else
  bad "the state fits the access layer's 400 characters" "state length: ${state_len:-unreadable}"
fi
expect_eq "asked from the repository root" "$(cat "$JEV_LOG/cwd.1" 2>/dev/null)" "$REPO"
call_env=$(cat "$JEV_LOG/env.1" 2>/dev/null)
expect_says "the call's environment was recorded" "$call_env" "JEV_LOG="
expect_not_says "the commit's git session stays behind" "$call_env" "GIT_INDEX_FILE="

JEV_ANSWER=person
out=$(gate index); rc=$?
expect_exit "Jev says a person: blocked" 1 "$rc"
expect_says "the remedy is a fictional name" "$out" "Jev: a real person (0.97) — replace it with a fictional name"
JEV_ANSWER=term

# ---------------------------------------------------------------------------
echo ""
echo "== the allowlist that counts is the one staged with the commit =="
allowlist "word Котов"
out=$(gate index); rc=$?
expect_exit "allowed on disk, not staged: still blocked" 1 "$rc"
git add scripts/pii-allow.txt
out=$(gate index); rc=$?
expect_exit "allowed and staged: passes" 0 "$rc"
expect_eq "…with no question to Jev" "$(asked)" 0

# ---------------------------------------------------------------------------
echo ""
echo "== Jev that fails: no further question, still blocked =="
fresh
stage docs/two.md "были Котов и Морозов"
JEV_ANSWER=down
out=$(gate index); rc=$?
expect_exit "Jev down: blocked" 1 "$rc"
expect_says "says why" "$out" "TypeSafe is unavailable (exit 1: TypeSafe: no key)"
expect_eq "one question, not one per value" "$(asked)" 1
expect_says "the second value is still listed" "$out" "Морозов"

JEV_ANSWER=junk
out=$(gate index); rc=$?
expect_exit "an answer out of form: blocked" 1 "$rc"
expect_says "says so" "$out" "an answer outside the agreed form"

JEV_ANSWER=term
mv "$STORE/_registry/echelon.json" "$TMP/echelon.json.off"
out=$(gate index); rc=$?
expect_exit "no access layer in the registry: blocked" 1 "$rc"
expect_says "says Jev was not asked, and why" "$out" "not asked — the intercom registry has no echelon"
expect_eq "nothing was called" "$(asked)" 0
mv "$TMP/echelon.json.off" "$STORE/_registry/echelon.json"

# ---------------------------------------------------------------------------
echo ""
echo "== how much is asked: once per value, at most five per run =="
fresh
stage docs/twice.md "$(printf 'Котов пришёл\nКотов ушёл')"
out=$(gate index); rc=$?
expect_eq "one value on two lines: one question" "$(asked)" 1

fresh
stage docs/many.md "Бондаренко Волков Зайцев Козлов Котов Лебедев Морозов Смирнов"
out=$(gate index); rc=$?
expect_exit "eight disputed values: blocked" 1 "$rc"
expect_eq "eight values: five questions" "$(asked)" 5
expect_says "the rest say why" "$out" "not asked — at most 5 questions per run"

# ---------------------------------------------------------------------------
echo ""
echo "== the gate reads the index git hands the hook =="
# A pathspec commit (`git commit -- <paths>`, what git-guard hands out) builds a
# temporary index and names it in GIT_INDEX_FILE; that one is the commit.
fresh
stage docs/clean.md "Nothing to see."
cp .git/index "$TMP/next-index"
printf 'на звонке был Котов\n' > docs/call.md
GIT_INDEX_FILE="$TMP/next-index" git add docs/call.md
out=$(gate index); rc=$?
expect_exit "the repository's own index is clean" 0 "$rc"
out=$(GIT_INDEX_FILE="$TMP/next-index" gate index); rc=$?
expect_exit "the index handed to the hook holds a name: blocked" 1 "$rc"
expect_says "…and it is the one read" "$out" "docs/call.md:1"

# ---------------------------------------------------------------------------
echo ""
echo "== the message and the signature =="
printf '[*] fix %s\n' "$KEY" > "$TMP/msg"
out=$(GIT_EDITOR=: gate message "$TMP/msg"); rc=$?
expect_exit "a task key in the message: blocked" 1 "$rc"
expect_says "names the line of the message" "$out" "commit message:1"
expect_says "names the remedy" "$out" "write PROJ-123"

# Git drops comment lines and the diff below the scissors only when it opens an
# editor, and tells the hook so: GIT_EDITOR=: means none is opened.
printf '[*] a clean subject\n# %s\n# ------------------------ >8 ------------------------\n%s\n' "$KEY" "$KEY" > "$TMP/msg"
out=$(GIT_EDITOR=vi gate message "$TMP/msg"); rc=$?
expect_exit "under an editor, comments and the diff below the scissors are not the message" 0 "$rc"
out=$(GIT_EDITOR=: gate message "$TMP/msg"); rc=$?
expect_exit "under -F or -m, every line is the message" 1 "$rc"

printf '[*] a clean subject\n' > "$TMP/msg"
out=$(GIT_EDITOR=: gate message "$TMP/msg"); rc=$?
expect_exit "the clone's own identity passes" 0 "$rc"
expect_says "…and was looked at: message, author, committer" "$out" "3 lines, nothing found"
out=$(GIT_EDITOR=: GIT_AUTHOR_NAME=Build GIT_AUTHOR_EMAIL="$ADDRESS" gate message "$TMP/msg"); rc=$?
expect_exit "an author outside the public identity: blocked" 1 "$rc"
expect_says "names the remedy for a signature" "$out" "the commit's signature"

# ---------------------------------------------------------------------------
echo ""
echo "== both hooks call it =="
printf '[*] fix %s\n' "$KEY" > "$TMP/msg"
out=$(GIT_EDITOR=: VDM_INTERCOM_ROOT="$STORE" PII_SCAN_TERMS="$TMP/terms.txt" \
      bash .githooks/commit-msg "$TMP/msg" 2>&1); rc=$?
expect_exit "commit-msg blocks a key in the message" 1 "$rc"
expect_says "…through the gate" "$out" "the commit is blocked"
# The pre-commit runs every gate, its suites included, so it is read rather than
# run: gate 13 must be a line of its own at the top level, not inside a branch.
if grep -qx 'bash scripts/pii-gate.sh index' "$REPO_ROOT/.githooks/pre-commit"; then
  ok "the pre-commit runs the gate unconditionally"
else
  bad "the pre-commit runs the gate unconditionally" "no top-level 'bash scripts/pii-gate.sh index' in .githooks/pre-commit"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== a gate that cannot look blocks =="
mkdir -p "$TMP/no-uv"
out=$(PATH="$TMP/no-uv" /bin/bash scripts/pii-gate.sh index 2>&1); rc=$?
expect_exit "no uv on PATH: blocked" 1 "$rc"
expect_says "names the install" "$out" "brew install uv"

mkdir -p "$TMP/empty-store/_registry"
fresh
stage docs/clean.md "Nothing to see."
out=$(VDM_INTERCOM_ROOT="$TMP/empty-store" PII_SCAN_TERMS="$TMP/terms.txt" bash scripts/pii-gate.sh index 2>&1); rc=$?
expect_exit "no address books: blocked as a setup error" 2 "$rc"
expect_says "says so" "$out" "no people/ profiles"

# ---------------------------------------------------------------------------
echo ""
echo "== cost: git launches do not grow with the staged files =="
# Counted, not timed: a launch count is the same on a loaded machine and on an
# idle one (tests/gates.test.sh → "gate cost").
SHIM="$TMP/shim"
mkdir -p "$SHIM"
real_git=$(type -P git)
cat > "$SHIM/git" <<EOF
#!/bin/bash
printf x >> "\$COST_LOG"
exec "$real_git" "\$@"
EOF
chmod +x "$SHIM/git"
launches() {
  : > "$TMP/cost.log"
  COST_LOG="$TMP/cost.log" PATH="$SHIM:$PATH" gate index >/dev/null
  wc -c < "$TMP/cost.log" | tr -d ' '
}
fresh
stage docs/one.md "One file."
one=$(launches)
for i in $(seq 1 25); do stage "docs/more-$i.md" "File $i."; done
many=$(launches)
if [ "${one:-0}" -gt 0 ]; then
  ok "the counter sees the gate's git calls ($one)"
else
  bad "the counter sees the gate's git calls" "counted ${one:-nothing}"
fi
expect_eq "twenty-six staged files cost the launches of one" "$many" "$one"

printf '\npii-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
