#!/bin/bash
# shared-rules.sh — SessionStart hook: the cross-project rules layer.
#
# The file ~/.claude/vdm/rules.md holds rules about how the assistant works —
# sources, evidence, dealing with the user — that are true in every project on
# this machine. This hook loads it into every session, whatever the project.
#
# Why a layer at all (field request, space-hq, 2026-09-18): /vdm:learn knew only
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
# Never blocks. A file that exists but cannot be read is SAID, not skipped:
# "the rules did not load" and "there are no rules" must not look the same.
#
# @see plugins/vdm/skills/learn/SKILL.md — "→ Cross-project rules"

set -u

cat >/dev/null 2>&1 || true   # drain the hook payload; nothing in it is needed

RULES="$HOME/.claude/vdm/rules.md"
# The layer rides in every session's context, so it has a ceiling. A rules file
# that outgrows it has stopped being a list of rules.
MAX_BYTES=8192

[ -e "$RULES" ] || exit 0
if [ ! -f "$RULES" ] || [ ! -r "$RULES" ]; then
  printf '[vdm] ⚠ Cross-project rules NOT loaded: %s exists but cannot be read.\n' "$RULES"
  exit 0
fi
grep -q '[^[:space:]]' "$RULES" 2>/dev/null || exit 0

size="$(wc -c < "$RULES" | tr -d ' ')"
printf '[vdm] Cross-project rules (%s). They hold in every project on this machine; follow them here as written, and do not copy them into a project'"'"'s CLAUDE.md.\n\n' "$RULES"
if [ "$size" -gt "$MAX_BYTES" ]; then
  # Whole lines only, counted in bytes: cutting at a byte offset can split a
  # multi-byte letter, and half a Cyrillic letter reaches the context as U+FFFD.
  LC_ALL=C awk -v max="$MAX_BYTES" '{ n += length($0) + 1; if (n > max) exit; print }' "$RULES"
  printf '\n\n[vdm] ⚠ Truncated: the rules file is %s bytes, the layer carries %s. Prune it — a rule that no longer earns its place in every session belongs in a project, or nowhere.\n' "$size" "$MAX_BYTES"
else
  cat "$RULES"
fi
exit 0
