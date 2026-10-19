#!/bin/bash
# shared-rules.sh — SessionStart hook: the cross-project rules layer.
#
# The file ~/.claude/vdm/rules.md holds rules about how the assistant works —
# sources, evidence, dealing with the user — that are true in every project on
# this machine. This hook loads it into every session, whatever the project.
#
# Why a layer at all (field request, hq, 2026-09-18): /vdm:learn knew only
# project addresses — CLAUDE.md, docs/llm/, session memory. A lesson about the
# assistant itself was learned in one project and learned again in the next;
# the owner, working in more than ten of them, called it "being shown the same
# failure in every area I work in". Copying the rule into each CLAUDE.md is N
# copies that drift at the first edit; auto-memory is tied to one directory.
#
# Why a hook and not an @import in the global CLAUDE.md (user's choice,
# 2026-09-24): an import is an install step, and an install step is the one
# shape of mechanism this suite has measured as not happening — the harness
# registers hooks by itself, there is nothing to set up. The cost of the choice
# is named here rather than hidden: a harness that runs no plugin hooks (Qwen
# Code loads only the skills) does not get the layer.
#
# Plain stdout: for SessionStart the harness adds it to the context as is, so
# no JSON and no jq — a dependency here would silently drop the rules on a
# machine without it, which is the failure this layer exists to prevent.
#
# What rides: the heading and the FIRST PARAGRAPH of every `## ` rule — the
# rule itself (owner's choice, crystal hq-lessons-up DL #1). Anything below it
# is close to unread: of 5 132 transcripts on this machine, 7 sessions opened
# the file to apply a rule (2026-10-19), so the paragraph has to work alone
# (crystal rules-dream, DL #4).
# Why: the harness puts a hook's text output longer than about 10 000
# characters into a file and hands the session a 2 KB preview. Measured on this
# machine's transcripts 2026-10-07: the longest output that reached a session
# whole was 9 793 characters, the shortest one put away 10 017; and this hook
# was put away at 1 034 session starts in a week — the layer reached sessions
# as its header and half a rule. The whole file no longer fitted; its rules do.
#
# The budget is counted in BYTES: never fewer than the characters the harness
# counts, so it holds in any locale with no locale to rely on. A rule that does
# not fit is not cut in the middle — it is named in a closing line, so the
# session knows it exists and where to read it. A file with no `## ` rules is
# delivered by whole lines, as before.
#
# `--measure [FILE]` prints what the layer would carry against the budget — for
# /vdm:learn before it writes a rule — and exits 1 when something does not fit.
# `--layer [FILE]` prints the rules as a session receives them, without the
# header, so a rewrite can be compared with the layer before it. FILE stands in
# for the live file — a candidate the rules writer has not installed yet — and
# is measured under the live file's header, since that is what will ride
# (crystal rules-dream, DL #3, #5).
#
# Never blocks. A file that exists but cannot be read is SAID, not skipped:
# "the rules did not load" and "there are no rules" must not look the same.
#
# @see plugins/vdm/skills/learn/SKILL.md — "→ Cross-project rules"
# @see docs/tasks/hq-lessons-up/workitem.md — DL #1

set -u

MODE="${1:-}"
case "$MODE" in
  --measure|--layer) ;;
  *) cat >/dev/null 2>&1 || true ;;   # drain the hook payload
esac

LIVE="$HOME/.claude/vdm/rules.md"
RULES="$LIVE"
case "$MODE" in --measure|--layer) [ -n "${2:-}" ] && RULES="$2" ;; esac
# Below the harness's ~10 000-character threshold with room for the header.
MAX_BYTES=9000

[ -e "$RULES" ] || { [ "$MODE" = "--measure" ] && echo "shared-rules: no rules file at $RULES"; exit 0; }
if [ ! -f "$RULES" ] || [ ! -r "$RULES" ]; then
  printf '[vdm] ⚠ Cross-project rules NOT loaded: %s exists but cannot be read.\n' "$RULES"
  exit 0
fi
grep -q '[^[:space:]]' "$RULES" 2>/dev/null || exit 0

header="$(printf '[vdm] Cross-project rules (%s). They hold in every project on this machine; follow them here as written, and do not copy them into a project'"'"'s CLAUDE.md.' "$LIVE")"
hbytes="$(printf '%s\n\n' "$header" | LC_ALL=C wc -c | tr -d ' ')"

# render <room> — the layer's body. Whole rules only; what does not fit is named.
render() {
  LC_ALL=C awk -v room="$1" -v path="$RULES" '
    function keep() { if (insec) { n++; T[n] = title; P[n] = para } }
    /^## / { keep(); title = substr($0, 4); insec = 1; got = 0; para = ""; next }
    insec {
      if (got) next
      if ($0 ~ /^[ \t]*$/) { if (para != "") got = 1; next }
      para = (para == "" ? $0 : para "\n" $0); next
    }
    { pre[++np] = $0 }
    END {
      keep()
      reserve = 1200; used = 0; cut = 0
      if (n == 0) {
        # No `## ` rules: the file is delivered by whole lines, as it always was.
        for (i = 1; i <= np; i++) {
          if (used + length(pre[i]) + 1 > room - 200) { cut = 1; break }
          print pre[i]; used += length(pre[i]) + 1
        }
        if (cut) printf "\n[vdm] ⚠ Truncated: the rules file has no `## ` rules and is longer than the layer carries (%d bytes). Read the rest in %s.\n", room, path
        exit (cut ? 3 : 0)
      }
      # The reserve is for the notice below, and the notice is printed only
      # when a rule is left out. A layer that fits whole uses the whole room:
      # held back every time, the reserve made `--measure` report 1 256 bytes
      # free in a layer with 70 left, and a rule written on that reading cut
      # three others (crystal rules-retro, 2026-10-15).
      all = 0
      for (i = 1; i <= n; i++) all += length("## " T[i] "\n" P[i] "\n\n")
      if (all <= room) {
        for (i = 1; i <= n; i++) printf "## %s\n%s\n\n", T[i], P[i]
        exit 0
      }
      for (i = 1; i <= n; i++) {
        block = "## " T[i] "\n" P[i] "\n\n"
        if (!cut && used + length(block) <= room - reserve) { printf "%s", block; used += length(block) }
        else { cut++; M[cut] = T[i] }
      }
      if (cut) {
        line = sprintf("[vdm] ⚠ %d rule(s) did not fit the layer (%d bytes) — read them in %s:", cut, room, path)
        for (i = 1; i <= cut; i++) {
          if (length(line) + length(M[i]) + 4 > reserve - 200) { line = line sprintf(" … and %d more.", cut - i + 1); break }
          line = line (i == 1 ? " " : "; ") M[i]
        }
        print line
        print "Shorten first paragraphs: the first paragraph of a rule is the rule; reasons and cases go below it."
        exit 3
      }
    }' "$RULES"
}

if [ "$MODE" = "--layer" ]; then
  render $((MAX_BYTES - hbytes))
  exit 0
fi

if [ "$MODE" = "--measure" ]; then
  body="$(render $((MAX_BYTES - hbytes)))"; rc=$?
  total=$(( hbytes + $(printf '%s\n' "$body" | LC_ALL=C wc -c | tr -d ' ') ))
  rules="$(grep -c '^## ' "$RULES")"
  printf 'shared-rules: the layer carries %s of %s bytes — %s rule(s), first paragraphs only; file %s bytes.\n' \
    "$total" "$MAX_BYTES" "$rules" "$(LC_ALL=C wc -c < "$RULES" | tr -d ' ')"
  [ "$rc" -eq 3 ] && { printf '%s\n' "$body" | grep '^\[vdm\] ⚠'; exit 1; }
  exit 0
fi

printf '%s\n\n' "$header"
render $((MAX_BYTES - hbytes))
exit 0
