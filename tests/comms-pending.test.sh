#!/bin/bash
# comms-pending.test.sh — RED TESTS for the pending-item detector.
#
# The fixture is built out of the shapes three live repositories actually
# contain, including every one that broke an earlier version of this detector:
#
#   * the owner inside the bold, together with the subject
#   * the owner NOT marked up at all, sitting after the date
#   * the bold being the DATE rather than the owner
#   * a known name appearing mid-sentence as the SUBJECT (61 misattributions)
#   * a people wikilink whose pipe is backslash-escaped
#   * the same person written three ways by declension
#   * a closed item left in the file struck through, whose date must not be
#     counted as overdue for ever (a bug that shipped in the field version)
#   * a version number (`8.19.1`) that is not a date
#
# Correlations are broken on purpose: the person-owned items and the
# team-owned ones are split across two tracks, and the section a shape appears
# in varies, so no assertion can pass by position alone.
#
# Both directions throughout. A detector that fires on legitimate lines gets
# switched off, which costs the real findings too.
#
# Run: bash tests/comms-pending.test.sh   (exit 0 = all pass)

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
PEND="${COMMS_PENDING_BIN:-$P/scripts/comms-pending.py}"
PENDSH="${COMMS_PENDING_SH:-$P/scripts/comms-pending.sh}"
CHECKSH="${COMMS_PENDING_CHECK_SH:-$P/scripts/comms-pending-check.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t pendtest)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/fx"
FX=$(cd "$TMP/fx" && pwd -P)
( cd "$FX" && git init -q . ) >/dev/null 2>&1

TODAY=2026-09-22

mkdir -p "$FX/.claude" "$FX/people" "$FX/tracks/alpha/comms" "$FX/tracks/beta" \
         "$FX/docs/tasks/KEY-1" "$FX/docs"

cat > "$FX/.claude/vdm-plugins.json" <<'JSON'
{
  "comms": {
    "pending-paths": ["tracks/*/index.md", "docs/tasks/*/*.md"],
    "pending-sections": {
      "waiting": ["Ожидаем"],
      "action": ["Наши действия"]
    },
    "owners": ["risk model", "limeflow", "Finance"],
    "people-dir": "people",
    "pending-draft-days": 3
  }
}
JSON

printf '# Ivan Petrov\n' > "$FX/people/ivan-petrov.md"
printf '# Olga Sidorova\n' > "$FX/people/olga-sidorova.md"

# --- track alpha: people owners, and every "looks like an owner but is not" ---
cat > "$FX/tracks/alpha/index.md" <<'EOF'
---
title: alpha
---

# alpha

## Ожидаем ответы

- [ ] 🔴 **[[../../people/ivan-petrov|Петров]] / Agent API — the number he promised.** ⏰ 2026-09-15
- [ ] **[[../../people/ivan-petrov\|Петрову]]** — second question, escaped pipe ⏰ 2026-09-30
- [ ] ⏰ 2026-09-15 — Finance — unloading of external purchases
- [ ] **Решить судьбу GA-5168** — a subject in bold, not an owner ⏰ 2026-09-30
- [ ] ~~**limeflow** — struck through, already settled ⏰ 2026-01-01~~
- [x] **limeflow** — closed, left in the file ⏰ 2026-01-02
  - [ ] a nested child of the closed item ⏰ 2026-01-03

## Наши действия

- [ ] Завершить миграцию пользователей ETNA → limeflow ⏰ 2026-09-30
- [ ] an action with no date at all
- ⏰ **limeflow** — a bullet hook with no date behind the clock

## Прочее

- [ ] a checkbox outside every declared section, carrying no marker
- [ ] an out-of-section obligation (due: 2026-09-10)
- [ ] an out-of-section one with a broken marker (due: soon)
EOF

# --- track beta: team owners, the dd.mm form, an event, a version number -----
cat > "$FX/tracks/beta/index.md" <<'EOF'
---
title: beta
---

# beta

## Ожидаем ответы

- [ ] **risk model** — details on REQ-579494 ⏰ 2026-09-24
- [ ] ⏰ 30.09 — **[[../../people/olga-sidorova|Сидоровой]]** — the dd.mm form
- [ ] **limeflow** — reply to the brief ⏰ after: the transcript arrives
- [ ] bump до 8.19.1 is what we are tracking ⏰ and no date behind it

## Наши действия

- [ ] 🔴 Send the letter [[comms/2026-09-20-answer-out]] to the platform team ⏰ 2026-09-30
EOF

# --- letters: one unsent and old, one already sent ---------------------------
cat > "$FX/tracks/alpha/comms/2026-09-01-old-out.md" <<'EOF'
---
type: letter
draft: true
---

# an old unsent letter
EOF

mkdir -p "$FX/tracks/beta/comms"
cat > "$FX/tracks/beta/comms/2026-09-20-answer-out.md" <<'EOF'
---
type: letter
draft: true
sent: 2026-09-20
---

# a letter that went out
EOF

# --- a ticket doc with no declared sections ---------------------------------
cat > "$FX/docs/tasks/KEY-1/spec.md" <<'EOF'
# KEY-1

## Blockers

- [ ] service account from the platform team (due: 2026-09-18)
- [ ] a plain checkbox with no marker at all
- [ ] one with a broken marker (due: soon)

## How to write one

```
- [ ] an example inside a fence ⏰ 2020-01-01
```
EOF

# --- a file the config never mentioned --------------------------------------
cat > "$FX/docs/notes.md" <<'EOF'
## Ожидаем ответы

- [ ] **limeflow** — this file is not in pending-paths ⏰ 2020-01-01
EOF

run() { # run <args...>  → OUT, returns rc
  OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" python3 "$PEND" --project-root "$FX" "$@" 2>&1)
  return $?
}

echo "== collection: what is an item, and what only looks like one =="

run --all
expect_says "the overdue person item is collected" "$OUT" "the number he promised"
expect_not_says "a struck-through item is not" "$OUT" "already settled"
expect_not_says "a closed [x] item is not — its date must not stay overdue for ever" "$OUT" "2026-01-02"
expect_not_says "a nested child of a closed item is not" "$OUT" "2026-01-03"
expect_not_says "an unmarked checkbox outside a declared section is not" "$OUT" "carrying no marker"
expect_says "a marked line outside a declared section IS" "$OUT" "an out-of-section obligation"
expect_not_says "an example inside a fence is not" "$OUT" "an example inside a fence"
expect_not_says "a file outside pending-paths is not read" "$OUT" "not in pending-paths"
expect_says "a bullet with a bare clock and no date IS an item" "$OUT" "a bullet hook with no date"

echo ""
echo "== dates: two markers, one detector =="

run
expect_says "an ISO clock date in the past is overdue" "$OUT" "2026-09-15 · Петров"
expect_says "a (due:) date in the past is overdue too" "$OUT" "an out-of-section obligation"
expect_says "a date inside the week is 'next 7 days'" "$OUT" "2026-09-24 · risk model"
expect_says "an event item is its own bucket" "$OUT" "on an event"
run --json
expect_says "dd.mm is read, and flagged as non-ISO later" "$OUT" '"date_kind": "dmy"'
expect_says "a broken (due:) is broken" "$OUT" '"date_kind": "broken"'
json_check() { # json_check <desc> <python-expr over `items`>
  if printf '%s' "$OUT" | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
sys.exit(0 if ($2) else 1)
"; then ok "$1"; else bad "$1"; fi
}
json_check "a version number is not read as a date" \
  "[i for i in items if '8.19.1' in i['text']][0]['date_kind'] == 'none'"

echo ""
echo "== owner: measured against the shapes, not against the documentation =="

run --json
expect_says "owner inside the bold, before the separator" "$OUT" '"owner": "Петров"'
expect_says "an escaped pipe in the wikilink still resolves" "$OUT" '"owner": "Петрову"'
expect_says "…and both fold onto one group key" "$OUT" '"owner_key": "person:ivan-petrov"'
expect_says "an unmarked owner at the head of the line is found" "$OUT" '"owner": "Finance"'
expect_says "a declared name in the emphasis is found" "$OUT" '"owner": "risk model"'
expect_says "a bold SUBJECT is not an owner" "$OUT" '"owner_kind": "missing"'

run --owner
expect_says "'us' is the first group" "$OUT" "## us ("
expect_says "a declared owner gets its own group" "$OUT" "## limeflow ("
expect_says "the two declensions land in one person group" "$OUT" "## Петров ("

run --json
json_check "a known name mid-sentence is the SUBJECT, not the owner" \
  "[i for i in items if 'ETNA' in i['text']][0]['owner'] == 'us'"
json_check "an action item with no owner written is ours by the section" \
  "[i for i in items if 'an action with no date' in i['text']][0]['owner_kind'] == 'us'"

echo ""
echo "== sections: the contract binds where it was declared, and only there =="

run --lint
expect_says "a waiting item with no owner is a violation" "$OUT" "no owner"
expect_says "a declared-section item with no date is a violation" "$OUT" "no \`⏰"
expect_says "dd.mm is asked to become ISO" "$OUT" "not in ISO form"
expect_says "a broken marker is a violation on its own" "$OUT" "broken date marker"
rc=0; run --lint || rc=$?
expect_exit "--lint exits 1 when it found something" 1 "$rc"

run --lint
expect_not_says "outside a declared section a missing owner is not a violation" "$OUT" "service account"

echo ""
echo "== drafts and letters already gone out =="

run --all
expect_says "an unsent letter older than the threshold is reported" "$OUT" "2026-09-01-old-out.md"
expect_says "a letter carrying sent: is not counted as a draft" "$OUT" "Written and never sent (1)"
expect_says "an item pointing at a sent letter is flagged as possibly done" "$OUT" "Possibly already done"

echo ""
echo "== brief: one line, and silence when there is nothing to say =="

rc=0; run --brief || rc=$?
expect_exit "--brief exits 1 when something is due" 1 "$rc"
expect_says "…and says what" "$OUT" "overdue"
OUT=$(cd "$FX" && COMMS_TODAY=2020-01-01 python3 "$PEND" --brief --project-root "$FX" 2>&1); rc=$?
expect_exit "--brief is silent when nothing is due yet" 0 "$rc"
expect_not_says "…and prints nothing at all" "$OUT" "pending"

echo ""
echo "== unconfigured: the whole half stays silent =="

mv "$FX/.claude/vdm-plugins.json" "$TMP/cfg.json"
rc=0; run || rc=$?
expect_exit "no pending-paths ⇒ exit 0" 0 "$rc"
expect_not_says "…and no output" "$OUT" "Pending on"
rc=0; run --lint || rc=$?
expect_exit "no pending-paths ⇒ --lint clean" 0 "$rc"
OUT=$(cd "$FX" && COMMS_TODAY="$TODAY" bash "$CHECKSH" </dev/null 2>&1); rc=$?
expect_exit "no pending-paths ⇒ the session-start hook is silent" 0 "$rc"
expect_not_says "…and says nothing" "$OUT" "pending"
mv "$TMP/cfg.json" "$FX/.claude/vdm-plugins.json"

echo ""
echo "== the hook: scope, verdict, and only NEW lines =="

payload() { # payload <tool> <path> <content>
  python3 - "$1" "$2" "$3" "$FX" <<'PY'
import json, sys
print(json.dumps({"tool_name": sys.argv[1],
                  "tool_input": {"file_path": sys.argv[2], "content": sys.argv[3]},
                  "cwd": sys.argv[4]}, ensure_ascii=False))
PY
}

hook() { # hook <payload>
  OUT=$(cd "$FX" && printf '%s' "$1" | CLAUDE_PROJECT_DIR="$FX" COMMS_TODAY="$TODAY" \
        bash "$PENDSH" --hook 2>&1)
  return $?
}

rc=0; hook "$(payload Write "$FX/tracks/alpha/index.md" "- [ ] x")" || rc=$?
expect_exit "an untracked pending file: every line is new ⇒ blocks" 2 "$rc"
expect_says "…and says what is wrong" "$OUT" "comms-pending"

rc=0; hook "$(payload Write "$FX/docs/notes.md" "- [ ] x ⏰ 2020-01-01")" || rc=$?
expect_exit "a markdown file outside pending-paths ⇒ silent" 0 "$rc"

rc=0; hook "$(payload Read "$FX/tracks/alpha/index.md" "")" || rc=$?
expect_exit "a Read is not our business" 0 "$rc"

rc=0; hook "$(payload Write "$FX/tracks/alpha/notes.txt" "- [ ] x")" || rc=$?
expect_exit "a non-markdown write ⇒ silent" 0 "$rc"

( cd "$FX" && git add -A >/dev/null 2>&1 &&
  git -c user.email=t@example.invalid -c user.name=t commit -q -m fixture >/dev/null 2>&1 )

rc=0; hook "$(payload Write "$FX/tracks/alpha/index.md" "unchanged")" || rc=$?
expect_exit "once the lines are in HEAD, the old tail is not re-reported" 0 "$rc"

printf '\n- [ ] a brand new item with neither owner nor date\n' >> "$FX/tracks/beta/index.md"
rc=0; hook "$(payload Edit "$FX/tracks/beta/index.md" "x")" || rc=$?
expect_exit "a NEW line outside the contract ⇒ blocks" 2 "$rc"
expect_says "…and names the new line" "$OUT" "brand new item"

echo ""
echo "== fail-closed: the blocking hook with python3 stripped from PATH =="

FARM="$TMP/bin-nopy"
mkdir -p "$FARM"
for t in bash sh grep sed awk cat tr mktemp date git printf head tail sort uniq wc find \
         dirname basename cut env mv rm mkdir readlink stat diff cp touch ls tee xargs \
         cmp true false test expr realpath id uname; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$FARM/$t"
done
JQ=$(command -v jq 2>/dev/null || true)
[ -n "$JQ" ] && ln -sf "$JQ" "$FARM/jq"

IN_SCOPE=$(payload Write "$FX/tracks/beta/index.md" "- [ ] a new promise")
OUT=$(printf '%s' "$IN_SCOPE" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      CLAUDE_PROJECT_DIR="$FX" bash -c "bash '$PENDSH' --hook" 2>&1); rc=$?
expect_exit "RED: a write carrying an open item, no python3 ⇒ exit 2" 2 "$rc"
expect_says "RED: it says NOT CHECKED" "$OUT" "NOT CHECKED"

OUT_OF_SCOPE=$(payload Write "$FX/docs/plain.md" "ordinary prose, no obligations")
OUT=$(printf '%s' "$OUT_OF_SCOPE" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      CLAUDE_PROJECT_DIR="$FX" bash -c "bash '$PENDSH' --hook" 2>&1); rc=$?
expect_exit "GREEN: same broken env, a write with nothing to guard ⇒ exit 0" 0 "$rc"

OUT=$(printf '%s' "$IN_SCOPE" | env -i HOME="$HOME" LC_ALL=C PATH="$FARM" \
      CLAUDE_PROJECT_DIR="$FX" bash -c "bash '$CHECKSH'" 2>&1); rc=$?
expect_exit "GREEN: the session-start reminder fails OPEN — exit 0" 0 "$rc"
expect_not_says "…and says nothing at all" "$OUT" "pending"

echo ""
echo "== the contract prints =="
OUT=$(python3 "$PEND" --print-contract 2>&1); rc=$?
expect_exit "--print-contract exits 0" 0 "$rc"
expect_says "…and names both markers" "$OUT" "(due: YYYY-MM-DD)"
expect_says "…and the section rule" "$OUT" "inside a declared section"

printf '\ncomms-pending: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
