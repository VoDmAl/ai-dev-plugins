#!/usr/bin/env python3
"""sc_usage.py — how the SuperClaude framework is actually used, counted from the harness transcripts.

Read-only; prints counts and nothing else, so its output names no project and
no person. Crystal `retire-superclaude`, Decision Log #5.

What it counts, over every transcript under ~/.claude/projects:

  * slash commands a person typed: every `/sc:*`, with `/vdm:wrap` and
    `/vdm:learn` as controls — a zero for `/sc:analyze` means something only
    beside a command known to be typed often;
  * `Skill` tool calls the assistant made for `sc:*`, `learn` and a grilling
    skill — a command can be reached without being typed;
  * `Agent`/`Task` calls per framework agent, beside the count of every
    subagent type, the denominator;
  * the owner's own turns (the harness marks them `turnOrigin: human`) that
    carry a framework flag (`--uc`, `--think`, …) or the words the owner uses
    for a brainstorm.

`projects/` is synced between the owner's machines, so one run covers both.
The harness deletes old transcripts: the dates printed are the window.

Usage: python3 -I sc_usage.py [--projects-dir DIR]
"""
import collections
import glob
import json
import os
import re
import sys

AGENTS = [
    "backend-architect", "business-panel-experts", "devops-architect",
    "frontend-architect", "learning-guide", "performance-engineer",
    "python-expert", "quality-engineer", "refactoring-expert",
    "requirements-analyst", "root-cause-analyst", "security-engineer",
    "socratic-mentor", "system-architect", "technical-writer",
]
CMD_RE = re.compile(r"<command-name>\s*/?(sc:[a-z-]+|vdm:wrap|vdm:learn)\s*</command-name>")
FLAGS = ("brainstorm|bs|introspect|introspection|task-manage|orchestrate|token-efficient|uc|"
         "ultracompressed|c7|context7|seq|sequential|magic|morph|morphllm|serena|play|playwright|"
         "all-mcp|no-mcp|think|think-hard|ultrathink|delegate|concurrency|iterations|safe-mode")
FLAG_RE = re.compile(r"(?<![\w-])--(" + FLAGS + r")(?![\w-])")
WORD_RE = re.compile(r"(?i)brainstorm|брейншторм|брейнсторм|grill|грил")


def text_of(content):
    """The text parts of a message `content`; tool results are not text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content
                         if isinstance(p, dict) and p.get("type") == "text")
    return ""


def has_tool_result(content):
    return isinstance(content, list) and any(
        isinstance(p, dict) and p.get("type") == "tool_result" for p in content)


def main():
    pd = os.path.expanduser("~/.claude/projects")
    if "--projects-dir" in sys.argv:
        pd = sys.argv[sys.argv.index("--projects-dir") + 1]
    files = sorted(glob.glob(os.path.join(pd, "**", "*.jsonl"), recursive=True))
    if not files:
        sys.stderr.write(f"sc_usage: no transcripts under {pd}\n")
        return 2

    typed = collections.Counter()
    typed_sessions = collections.defaultdict(set)
    skill_calls = collections.Counter()
    agent_calls = collections.Counter()
    agent_any = collections.Counter()
    flags = collections.Counter()
    words = collections.Counter()
    owner_turns = 0
    first, last = None, None

    for f in files:
        try:
            fh = open(f, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                m = re.search(r'"timestamp":"(\d{4}-\d{2}-\d{2})', line)
                if m:
                    d = m.group(1)
                    first = d if first is None or d < first else first
                    last = d if last is None or d > last else last
                is_user = '"type":"user"' in line
                is_tool = '"tool_use"' in line and ("subagent_type" in line or '"Skill"' in line)
                if not (is_user or is_tool):
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                content = (rec.get("message") or {}).get("content")

                if rec.get("type") == "user" and not has_tool_result(content):
                    t = text_of(content)
                    for m in CMD_RE.finditer(t):
                        typed[m.group(1)] += 1
                        typed_sessions[m.group(1)].add(f)
                    origin = rec.get("turnOrigin") or (rec.get("origin") or {}).get("kind")
                    if (origin == "human" and not rec.get("isMeta") and not rec.get("isCompactSummary")
                            and not rec.get("isSidechain") and not re.match(r"\s*<(bash-|local-command)", t)):
                        owner_turns += 1
                        for m in FLAG_RE.finditer(t):
                            flags[m.group(1)] += 1
                        for w in set(w.lower() for w in WORD_RE.findall(t)):
                            words[w] += 1

                if rec.get("type") == "assistant" and isinstance(content, list):
                    for p in content:
                        if not isinstance(p, dict) or p.get("type") != "tool_use":
                            continue
                        inp = p.get("input") or {}
                        if p.get("name") == "Skill":
                            s = str(inp.get("skill", "")).lstrip("/")
                            if s.startswith("sc:") or s in ("learn", "vdm:learn") or "grill" in s:
                                skill_calls[s] += 1
                        st = inp.get("subagent_type")
                        if st:
                            agent_any[st] += 1
                            if st in AGENTS:
                                agent_calls[st] += 1

    print(f"transcripts: {len(files)}, dated {first} .. {last}")
    print("typed by a person (uses / sessions):")
    for k, v in sorted(typed.items(), key=lambda kv: -kv[1]):
        print(f"  /{k}: {v} / {len(typed_sessions[k])}")
    print("Skill tool calls by the assistant:")
    for k, v in sorted(skill_calls.items(), key=lambda kv: -kv[1]):
        print(f"  {k}: {v}")
    print(f"framework agents, of {sum(agent_any.values())} subagent calls:")
    for a in AGENTS:
        print(f"  {a}: {agent_calls[a]}")
    print(f"owner turns read: {owner_turns}")
    print("  with a framework flag:", dict(flags) or 0)
    print("  with a brainstorm/grill word:", dict(words) or 0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
