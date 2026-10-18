#!/bin/bash
# retro-corpus.test.sh — the corpus a rules retrospective reads (crystal rules-retro).
#
# The script reads three facts out of the harness's transcripts, and each is a
# way the retrospective lies if it is read wrong: a turn the owner did not type
# taken for a correction; the assistant's words AFTER a turn shown as what it
# corrected; a rule charged with a failure in a session that never received it.
# The fixture is built from the record shapes the transcripts on this machine
# hold (2026-10-15), including the two that broke the first draft: turns older
# than `turnOrigin` carry only `origin.kind`, and a session that `cd`s away is
# still the project it started in.
#
# Run: bash tests/retro-corpus.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/retro-corpus.py

set -u

# Scrub git's per-invocation environment (see gates-harness-isolation.test.sh):
# run from inside a pre-commit gate, a harness inherits the commit's index.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

# Nor the machine's git config: git 2.54 runs a hook declared there
# (`hook.<name>.command`) on every commit, a fixture's included — the case is
# in tests/gates.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at a copy and watched go red.
CORPUS="${RETRO_CORPUS_BIN:-$REPO_ROOT/plugins/vdm/scripts/retro-corpus.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there"; return; }; case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t retrocorpus)
trap 'rm -rf "$TMP"' EXIT
P="$TMP/projects"

# Three sessions in two project directories. Every line is a record shape the
# harness writes; the comments say which way each one could mislead.
python3 - "$P" <<'PY'
import json, os, sys
root = sys.argv[1]
def w(proj, sid, recs):
    d = os.path.join(root, proj); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".jsonl"), "w", encoding="utf-8") as fh:
        for r in recs:
            r.setdefault("sessionId", sid)
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
def layer(heads, preview=False):
    body = "[vdm] Cross-project rules — each rule as its first paragraph.\n\n" + \
           "".join("## %s\nThe rule.\n\n" % h for h in heads)
    if preview:
        body = "<persisted-output>\nOutput too large (12KB). Full output saved to: /x/hook.txt\n\nPreview (first 2KB):\n" + body
    return {"type": "attachment", "attachment": {"type": "hook_success", "hookName": "SessionStart:startup",
            "hookEvent": "SessionStart", "content": body, "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/shared-rules.sh\""}}
def other_hook():
    return {"type": "attachment", "attachment": {"type": "hook_success", "hookEvent": "SessionStart",
            "content": "## Not a rule\nanother hook's heading", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/other.sh\""}}
def a(text, cwd="/home/u/alpha"):
    return {"type": "assistant", "cwd": cwd, "message": {"content": [{"type": "text", "text": text}]}}
def h(text, ts, cwd="/home/u/alpha", **kw):
    r = {"type": "user", "cwd": cwd, "timestamp": ts, "turnOrigin": "human",
         "message": {"content": text}}
    r.update(kw); return r

A = "aaaaaaaa-1111-0000-0000-000000000000"
w("-home-u-alpha", A, [
    layer(["Rule one", "Rule two"]),
    other_hook(),
    a("I wrote the letter and sent it."),
    h("You did not send it, you drafted it.", "2026-10-01T10:00:00Z"),
    # Not the owner: an SDK caller, a peer session, a tool result, a meta line.
    {"type": "user", "cwd": "/home/u/alpha", "timestamp": "2026-10-01T10:01:00Z", "turnOrigin": "sdk",
     "message": {"content": "SDK PROMPT"}},
    {"type": "user", "cwd": "/home/u/alpha", "timestamp": "2026-10-01T10:02:00Z", "turnOrigin": "peer",
     "message": {"content": "PEER MESSAGE"}},
    {"type": "user", "cwd": "/home/u/alpha", "timestamp": "2026-10-01T10:03:00Z", "turnOrigin": "human",
     "message": {"content": [{"type": "tool_result", "content": "TOOL OUTPUT"}]}},
    h("META LINE", "2026-10-01T10:04:00Z", isMeta=True),
    # Typed by the owner, but harness markup: a `!` command.
    h("<bash-input>git push</bash-input>", "2026-10-01T10:05:00Z"),
    # A subagent's turn lives in the same file and is not the owner's.
    {"type": "user", "cwd": "/home/u/alpha", "timestamp": "2026-10-01T10:06:00Z", "turnOrigin": "human",
     "isSidechain": True, "message": {"content": "SIDECHAIN"}},
    # The session moved into a subdirectory; it is still alpha.
    a("Checked one file of five; nothing there.", cwd="/home/u/alpha/sub"),
    h("One of five is not \"nowhere\".\n### pasted heading", "2026-10-02T09:00:00Z", cwd="/home/u/alpha/sub"),
    a("LATER WORDS, said after the turn above"),
    # A compaction delivers the layer again, now with a third rule.
    layer(["Rule one", "Rule two", "Rule three"]),
    a("Here is the plan."),
    h("Fine.", "2026-10-03T09:00:00Z"),
])

B = "bbbbbbbb-2222-0000-0000-000000000000"
w("-home-u-beta", B, [
    # The harness put the layer into a file; the session saw the preview only.
    layer(["Rule one"], preview=True),
    {"type": "user", "cwd": "/home/u/beta", "timestamp": "2026-09-20T08:00:00Z",
     "origin": {"kind": "human"}, "message": {"content": [{"type": "text", "text": "Older turn, origin.kind only."}]}},
    # Neither field: cannot be attributed.
    {"type": "user", "cwd": "/home/u/beta", "timestamp": "2026-09-20T08:01:00Z",
     "message": {"content": "UNATTRIBUTED"}},
])

C = "cccccccc-3333-0000-0000-000000000000"
w("-home-u-beta", C, [
    a("Done.", cwd="/home/u/beta"),
    h("Why did you ask me that?", "2026-10-05T12:00:00Z", cwd="/home/u/beta"),
    # A compaction summary: the model wrote it, the harness marks it typed by a
    # human, and it retells the session's corrections — read, each would count
    # twice (58 such records on this machine, 2026-10-18).
    h("This session is being continued from a previous conversation. SUMMARY RETELLS "
      "\"Why did you ask me that?\"", "2026-10-05T12:30:00Z", cwd="/home/u/beta",
      isCompactSummary=True, isVisibleInTranscriptOnly=True),
    a("Here is the commit line again.", cwd="/home/u/beta"),
    # A slash command is markup, but its arguments are the owner's words:
    # `/vdm:learn <the correction>` (52 such turns in 10 projects, 2026-10-18).
    h("<command-message>vdm:learn</command-message>\n<command-name>/vdm:learn</command-name>\n"
      "<command-args>stop handing me the commit line</command-args>", "2026-10-05T13:00:00Z",
      cwd="/home/u/beta"),
    h("<command-name>/doctor</command-name>\n<command-message>doctor</command-message>\n"
      "<command-args></command-args>", "2026-10-05T13:01:00Z", cwd="/home/u/beta"),
])
PY

run() { OUT=$(python3 "$CORPUS" --projects-dir "$P" "$@" 2>&1); rc=$?; }
all() { cat "$1"/chunk-*.md 2>/dev/null; }

echo "== who typed it =="
run --out "$TMP/o1"; expect_exit "the corpus is written" 0 "$rc"
C1=$(all "$TMP/o1")
expect_says "RED: the owner's turn is read" "$C1" "OWNER: You did not send it, you drafted it."
expect_says "RED: a turn older than turnOrigin, with origin.kind: human, is the owner's" "$C1" "Older turn, origin.kind only."
expect_says "…and the summary counts six turns" "$OUT" "6 turn(s) by a person, 3 session(s), 2 project(s)"
for w in "SDK PROMPT" "PEER MESSAGE" "TOOL OUTPUT" "META LINE" "git push" "SIDECHAIN" "UNATTRIBUTED" "SUMMARY RETELLS" "/doctor"; do
  expect_not_says "RED: not the owner's words: $w" "$C1" "$w"
done
expect_says "RED: a slash command's arguments are the owner's words" "$C1" "OWNER: /vdm:learn stop handing me the commit line"
expect_says "…with the answer before them" "$C1" "ASSISTANT: Here is the commit line again."
expect_says "…and a compaction summary takes no number" "$C1" $'### cccccccc.2 · beta · 2026-10-05 · L0\nASSISTANT: Here is the commit line again.'

echo "== what it answered =="
expect_says "RED: a turn carries the assistant's words before it" "$C1" "ASSISTANT: Checked one file of five; nothing there."
expect_not_says "RED: …never the words after it" "$C1" "ASSISTANT: LATER WORDS"
expect_says "RED: a session that cd's away is still the project it started in" "$C1" "### aaaaaaaa.2 · alpha · 2026-10-02"
expect_not_says "…not the subdirectory" "$C1" "· sub ·"
expect_says "a pasted heading is indented, not the next entry" "$C1" "  ### pasted heading"

echo "== which rules the session had =="
L1=$(cat "$TMP/o1/layers.md")
# Layers are numbered as they first appear in date order: beta's preview
# (2026-09-20) is L1, alpha's first layer L2, its compaction L3.
expect_says "RED: the layer is read from the session's own attachment" "$L1" "## L2 — 2 rule(s)"
expect_not_says "RED: another hook's heading is not a rule" "$L1" "Not a rule"
expect_says "RED: a compaction's layer applies to the turns after it" "$C1" "### aaaaaaaa.3 · alpha · 2026-10-03 · L3"
expect_says "…and the turns before it keep the first" "$C1" "### aaaaaaaa.1 · alpha · 2026-10-01 · L2"
expect_says "RED: a preview delivered only the headings inside it, and says so" "$L1" "## L1 — 1 rule(s), the harness showed only a preview"
expect_says "RED: a session with no layer is L0" "$C1" "### cccccccc.1 · beta · 2026-10-05 · L0"
# Rule one reached alpha (three turns) and beta's preview (one); the third
# session had no layer.
expect_says "RED: the denominator counts each session once per rule" "$OUT" "$(printf '\t2\t4\tRule one')"
expect_says "…and a rule that reached one session only" "$OUT" "$(printf '\t1\t1\tRule three')"
expect_says "…and names the turns that had no layer" "$OUT" "(no rules layer in the session)"

echo "== two passes =="
run --out "$TMP/o2" --assistant-cap 0
C2=$(all "$TMP/o2")
expect_not_says "RED: --assistant-cap 0 leaves the answers out" "$C2" "ASSISTANT:"
expect_says "…and keeps the owner's turns" "$C2" "OWNER: Fine."
printf 'picked: cccccccc.1 and aaaaaaaa.2\n' > "$TMP/ids"
run --out "$TMP/o3" --only "$TMP/ids"
C3=$(all "$TMP/o3")
expect_says "RED: --only keeps the named turns" "$C3" "### cccccccc.1"
expect_not_says "RED: …and only them" "$C3" "aaaaaaaa.1 "
expect_says "RED: the denominator is still the whole corpus" "$OUT" "$(printf '\t2\t4\tRule one')"
expect_says "…and the pick is counted" "$OUT" "kept: 2 of 2 id(s)"
run --out "$TMP/o4" --since 2026-10-02
C4=$(all "$TMP/o4")
expect_not_says "--since drops earlier turns" "$C4" "You did not send it"
expect_says "RED: …and an id does not shift when a window drops turns before it" "$C4" "### aaaaaaaa.2 · alpha · 2026-10-02"

echo "== chunks and refusals =="
run --out "$TMP/o5" --chunk-bytes 1
n=$(ls "$TMP/o5"/chunk-*.md | wc -l | tr -d ' ')
expect_exit "RED: a chunk smaller than an entry still holds one whole entry" 6 "$n"
expect_says "…and no entry is split" "$(cat "$TMP/o5/chunk-002.md")" "OWNER:"
run --projects-dir "$TMP/none" --out "$TMP/o6"
expect_exit "no transcripts ⇒ exit 2" 2 "$rc"
run --out "$TMP/o7" --since 2026-13
expect_exit "a malformed --since ⇒ exit 2" 2 "$rc"
echo "== the chunks are the owner's only =="
# They hold people's names and other projects' words (crystal rules-retro).
mode() { python3 -c 'import os, sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
expect_exit "RED: a chunk is readable by this user only" 600 "$(mode "$TMP/o1/chunk-001.md")"
expect_exit "RED: …and so is layers.md" 600 "$(mode "$TMP/o1/layers.md")"
expect_exit "RED: --out is closed to others" 700 "$(mode "$TMP/o1")"
mkdir -p "$TMP/tmpd"
OUT=$(TMPDIR="$TMP/tmpd" python3 "$CORPUS" --projects-dir "$P" 2>&1); rc=$?
d=$(printf '%s\n' "$OUT" | sed -n 's/^written: \(.*\) — layers.md.*/\1/p')
case "$d" in "$TMP/tmpd/vdm-retro-"?*) ok "RED: with no --out, a fresh directory under the temp dir" ;; *) bad "RED: with no --out, a fresh directory under the temp dir" "got: $d" ;; esac
expect_exit "RED: …created 0700" 700 "$(mode "$d")"
mkdir -p "$TMP/real"; ln -s "$TMP/real" "$TMP/link"
run --out "$TMP/link"
expect_exit "RED: an --out that is a symlink is refused" 2 "$rc"
mkdir -p "$TMP/o9"; printf 'keep\n' > "$TMP/victim"; ln -s "$TMP/victim" "$TMP/o9/chunk-001.md"
run --out "$TMP/o9"
expect_exit "RED: a symlink planted where a chunk goes is not followed" 2 "$rc"
expect_says "…and its target is untouched" "$(cat "$TMP/victim")" "keep"

printf 'nothing here\n' > "$TMP/noids"
run --out "$TMP/o8" --only "$TMP/noids"
expect_exit "an --only file with no ids ⇒ exit 2" 2 "$rc"

printf '\nretro-corpus: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
