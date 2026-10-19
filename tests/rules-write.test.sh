#!/bin/bash
# rules-write.test.sh — installing a rewritten shared rules layer (crystal rules-dream, DL #3, #5).
#
# A rewrite destroys the text it replaces, and the file is written by parallel
# sessions and by two machines through Syncthing. Each assertion below is one
# way a rewrite loses someone's lesson without a trace: written over a newer
# file, over a change still in transit, over a conflict copy, past the layer's
# budget, or with no copy of what it replaced.
#
# Run: bash tests/rules-write.test.sh   (exit 0 = all pass)
#
# @see plugins/vdm/scripts/rules-write.py

set -u

unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at a copy and watched go red.
WRITER="${RULES_WRITE_BIN:-$REPO_ROOT/plugins/vdm/scripts/rules-write.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ruleswrite)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/vdm"
RULES="$HOME/.claude/vdm/rules.md"
HIST="$HOME/.claude/vdm/history"
export VDM_RULES_SYNC_CHECK=off
w() { OUT=$(python3 "$WRITER" "$@" 2>&1); rc=$?; }

printf '## Rule one\n\nThe first rule.\n\n| a | b |\n|---|---|\n| row | x |\n\n## Rule two\n\nThe second rule.\n' > "$RULES"
chmod 640 "$RULES"
ORIG="$(cat "$RULES")"

echo "== the fingerprint =="
w --hash; H0="$OUT"
case "$H0" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ ${#H0} -eq 64 ] && ok "RED: --hash prints the file's sha256" || bad "RED: --hash prints the file's sha256" "got: $H0" ;; *) bad "RED: --hash prints the file's sha256" "got: $H0" ;; esac
HOME="$TMP/nohome" w --hash
eq "…and \`absent\` when there is no file" "$OUT" "absent"

echo "== what changes for a session =="
printf '## Rule one\n\nThe first rule.\n\n| a | b |\n|---|---|\n| another row | y |\n\n## Rule two\n\nThe second rule.\n' > "$TMP/table-only.md"
w --diff "$TMP/table-only.md"
eq "RED: a change below the first paragraph leaves the layer as it is ⇒ exit 0" "$rc" "0"
says "…and says so" "$OUT" "the layer is unchanged"
printf '## Rule one\n\nThe first rule, said more generally.\n\n## Rule two\n\nThe second rule.\n' > "$TMP/para.md"
w --diff "$TMP/para.md"
eq "RED: a changed first paragraph is a changed layer ⇒ exit 1" "$rc" "1"
says "…shown as a diff" "$OUT" "+The first rule, said more generally."
w --diff "$TMP/missing.md"
eq "a missing candidate ⇒ exit 2" "$rc" "2"

echo "== refusals leave the file as it was =="
w --base "0000" "$TMP/para.md"
eq "RED: a stale fingerprint ⇒ exit 3" "$rc" "3"
says "…naming why" "$OUT" "changed since it was read"
eq "…and the file is untouched" "$(cat "$RULES")" "$ORIG"
printf 'no rules here\n' > "$TMP/norules.md"
w --base "$H0" "$TMP/norules.md"
eq "RED: a candidate with no rule ⇒ exit 2" "$rc" "2"
eq "…untouched" "$(cat "$RULES")" "$ORIG"
python3 - "$TMP/huge.md" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    for i in range(40):
        fh.write("## Rule %d\n\n%s\n\n" % (i, "A long first paragraph that fills the layer. " * 6))
PY
w --base "$H0" "$TMP/huge.md"
eq "RED: a candidate that does not fit the layer ⇒ exit 5" "$rc" "5"
says "…with the hook's own words" "$OUT" "did not fit"
eq "…untouched" "$(cat "$RULES")" "$ORIG"
printf '#!/bin/sh\nexit 1\n' > "$TMP/coming"; chmod +x "$TMP/coming"
VDM_RULES_SYNC_CHECK="$TMP/coming" w --base "$H0" "$TMP/para.md"
eq "RED: Syncthing has changes on the way ⇒ exit 4" "$rc" "4"
eq "…untouched" "$(cat "$RULES")" "$ORIG"
printf '#!/bin/sh\nexit 3\n' > "$TMP/unknown"; chmod +x "$TMP/unknown"
cp "$RULES" "$HOME/.claude/vdm/rules.sync-conflict-20261019-120000-ABCDEFG.md"
w --base "$H0" "$TMP/para.md"
eq "RED: a conflict copy beside the file ⇒ exit 4" "$rc" "4"
says "…named" "$OUT" "rules.sync-conflict-20261019-120000-ABCDEFG.md"
eq "…untouched" "$(cat "$RULES")" "$ORIG"
rm -f "$HOME/.claude/vdm/rules.sync-conflict-"*
[ -d "$HIST" ] && bad "…and no refusal wrote history" "$(ls "$HIST")" || ok "…and no refusal wrote history"

echo "== a write keeps what it replaced =="
VDM_RULES_SYNC_CHECK="$TMP/unknown" w --base "$H0" "$TMP/para.md" --session abcdef1234
eq "RED: the right fingerprint ⇒ written, exit 0" "$rc" "0"
says "…Syncthing's \"cannot tell\" is said, not a refusal" "$OUT" "cannot tell"
eq "…the file is the candidate" "$(cat "$RULES")" "$(cat "$TMP/para.md")"
eq "RED: …its mode is kept" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$RULES")" "0o640"
n=$(ls "$HIST"/rules-*-abcdef12.md 2>/dev/null | wc -l | tr -d ' ')
eq "RED: …the replaced version is in history, under the session's tag" "$n" "1"
eq "…byte for byte" "$(cat "$HIST"/rules-*-abcdef12.md)" "$ORIG"
says "…and the report names it" "$OUT" "history/rules-"

echo "== history keeps the last N =="
for i in 1 2 3 4; do
  printf '## Rule one\n\nVersion %s.\n' "$i" > "$TMP/v$i.md"
  h=$(python3 "$WRITER" --hash)
  VDM_RULES_HISTORY_KEEP=3 python3 "$WRITER" --base "$h" "$TMP/v$i.md" --session s$i >/dev/null 2>&1
done
eq "RED: only the last 3 versions are kept" "$(ls "$HIST"/rules-*.md | wc -l | tr -d ' ')" "3"
newest=$(ls "$HIST"/rules-*.md | tail -1)
eq "…and the newest kept is the one just replaced" "$(cat "$newest")" "$(cat "$TMP/v3.md")"

echo "== a first write needs no history =="
rm -rf "$HOME/.claude/vdm"
w --base absent "$TMP/para.md"
eq "RED: no file yet and base \`absent\` ⇒ written" "$rc" "0"
eq "…the candidate is installed" "$(cat "$RULES")" "$(cat "$TMP/para.md")"

printf '\nrules-write: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
