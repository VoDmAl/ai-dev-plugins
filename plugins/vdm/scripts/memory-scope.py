#!/usr/bin/env python3
"""memory-scope.py — the class of a memory record: whose lesson is it.

A memory record is one file in a project's `.claude/memory/` or in the
harness's `~/.claude/projects/<project>/memory/`. Each carries, next to its
`type`, a `scope`:

    project   the lesson is about this project's subject — it lives here
    hq        how an HQ works: letters, meetings, the ball, questions to the owner
    conduct   how the assistant works, in any project

and, once an `hq` or `conduct` lesson has a home outside the project, a
`shared: <address>` — the rule in `~/.claude/vdm/rules.md`, a skill section, a
README section. With `shared` set the local record is a pointer.

Why (owner, 2026-10-07, to an HQ that kept a procedural lesson in its own
memory): «Твоя память по процедурным вещам которые полезны другим HQ не может
быть твой только.» The access layer collects `hq` and `conduct` records from
every project; this module only names what is missing, in the act of writing
and at session start. The contract — names, values, both places — was agreed
with the access layer (crystal hq-lessons-up, DL #3, DL #4).

"Next to `type`" means wherever `type` is: at the top of the frontmatter, or
under `metadata:` as the harness writes it. Measured 2026-10-07 on this
machine: 463 records with `type` on top, 782 under `metadata:`. Both are read.

Modes:
    memory-scope.py hook             PostToolUse payload on stdin → one reminder
                                     (JSON additionalContext) for a record
                                     written without a valid `scope`; else nothing
    memory-scope.py check <project>  one session-start line naming `hq` and
                                     `conduct` records not lifted yet; else nothing

A reminder fails open: any error is silence, never a blocked write.

@see plugins/vdm/skills/learn/SKILL.md — "Memory records name their scope"
@see docs/tasks/hq-lessons-up/workitem.md
"""
import json
import os
import re
import sys

SCOPES = ("project", "hq", "conduct")
FRONTMATTER = re.compile(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", re.S)
READ_LIMIT = 16384


def field(fm, name):
    """`name:` at the top of the frontmatter or indented under a mapping such
    as `metadata:`. None when absent; "" when present and empty."""
    m = re.search(r"(?m)^[ \t]*%s:[ \t]*(.*?)[ \t]*$" % re.escape(name), fm)
    if not m:
        return None
    value = m.group(1)
    if value.startswith("#"):
        return ""
    return value.strip("\"'").strip()


def frontmatter(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read(READ_LIMIT)
    m = FRONTMATTER.match(text)
    return m.group(1) if m else None


def is_record(path):
    """A memory record: an `.md` directly in `.claude/memory/` or in
    `~/.claude/projects/<p>/memory/` — not the `MEMORY.md` index."""
    if not path.endswith(".md") or os.path.basename(path) == "MEMORY.md":
        return False
    parent = os.path.dirname(path)
    if parent.endswith(os.sep + os.path.join(".claude", "memory")):
        return True
    home = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    return (os.path.basename(parent) == "memory"
            and os.path.dirname(os.path.dirname(parent)) == home)


def hook():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    if payload.get("tool_name") not in ("Write", "Edit", "MultiEdit"):
        return 0
    path = (payload.get("tool_input") or {}).get("file_path") or ""
    if not path or not is_record(path) or not os.path.isfile(path):
        return 0
    fm = frontmatter(path)
    if fm is None:
        return 0  # no frontmatter at all: not the shape this contract is about
    scope = field(fm, "scope")
    if scope in SCOPES:
        return 0
    name = os.path.basename(path)
    if scope:
        what = "`scope: %s` is not one of project | hq | conduct" % scope
    else:
        what = "no `scope:`"
    msg = (
        "[memory-scope] %s: %s. Say whose lesson this is, next to `type:` (at the top, or under "
        "`metadata:` where `type` is): project — about this project's subject; hq — how an HQ works "
        "(letters, meetings, the ball, questions to the owner); conduct — how the assistant works in any "
        "project. An hq or conduct lesson is collected for every project by the access layer; once it has "
        "a home, add `shared: <address>` (a rule in ~/.claude/vdm/rules.md, a skill section) and keep this "
        "record as a pointer." % (name, what))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                             "additionalContext": msg}}, ensure_ascii=False))
    return 0


def memory_dirs(project):
    project = os.path.abspath(project)
    yield os.path.join(project, ".claude", "memory")
    # The harness names a project's directory after its path, every character
    # outside [A-Za-z0-9] turned into '-' (measured on this machine's 51 entries).
    encoded = re.sub(r"[^A-Za-z0-9]", "-", project)
    yield os.path.join(os.path.expanduser("~"), ".claude", "projects", encoded, "memory")


def check(project):
    waiting = []
    for d in memory_dirs(project):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if not is_record(path) or not os.path.isfile(path):
                continue
            try:
                fm = frontmatter(path)
            except OSError:
                continue
            if fm is None or field(fm, "scope") not in ("hq", "conduct"):
                continue
            if field(fm, "shared"):
                continue
            waiting.append(name[:-3])
    if not waiting:
        return 0
    shown = ", ".join(waiting[:3]) + (" and %d more" % (len(waiting) - 3) if len(waiting) > 3 else "")
    print("[vdm] memory: %d lesson(s) marked hq or conduct are not lifted yet (no `shared:`): %s. The "
          "access layer collects them for every project; once a lesson has its home, set "
          "`shared: <address>` and keep the record as a pointer." % (len(waiting), shown))
    return 0


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            return hook()
        if argv[:1] == ["check"] and len(argv) > 1:
            return check(argv[1])
    except Exception:  # a reminder fails open
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
