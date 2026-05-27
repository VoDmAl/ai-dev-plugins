#!/usr/bin/env python3
"""
crystal-completion-guard.py — simulator used by crystal-completion-guard.sh.

Reads the Claude Code PreToolUse JSON payload on stdin, decides whether the
edit would transition a crystal workitem to `status: done` while unchecked
`- [ ]` items remain, and — if so — prints the diagnostic to stderr and exits
with code 2 (which the bash wrapper re-emits to the hook harness).

All other paths exit 0 (no-op). Fail-open at every boundary.

Environment:
  CRYSTAL_ROOT  Absolute path to the resolved crystal storage root. Required.

Hook contract:
  Implements Decision Log #4 (`- [ ]` blocks done-transition) and #7
  (PreToolUse as the primary gate). The five resolution paths in the
  diagnostic come from Decision Log #9.
"""

from __future__ import annotations

import json
import os
import re
import sys


def _load_payload() -> dict | None:
    try:
        return json.loads(sys.stdin.read())
    except Exception:
        return None


def _build_post_edit_content(tool_name: str, tool_input: dict, abs_path: str) -> str | None:
    """Return what the file would look like after the tool runs, or None to skip."""
    if tool_name == "Write":
        return tool_input.get("content") or ""
    try:
        with open(abs_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except FileNotFoundError:
        return None
    except OSError:
        return None
    if tool_name == "Edit":
        old_s = tool_input.get("old_string") or ""
        new_s = tool_input.get("new_string") or ""
        if tool_input.get("replace_all"):
            content = content.replace(old_s, new_s)
        else:
            content = content.replace(old_s, new_s, 1)
        return content
    if tool_name == "MultiEdit":
        for edit in tool_input.get("edits") or []:
            old_s = edit.get("old_string") or ""
            new_s = edit.get("new_string") or ""
            if edit.get("replace_all"):
                content = content.replace(old_s, new_s)
            else:
                content = content.replace(old_s, new_s, 1)
        return content
    return None


def _frontmatter_status(content: str) -> str | None:
    fm = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not fm:
        return None
    body = fm.group(1)
    m = re.search(r"^status:\s*([^\s#]+)", body, re.MULTILINE)
    if not m:
        return None
    return m.group(1).strip().strip('"').strip("'")


def main() -> int:
    payload = _load_payload()
    if not payload:
        return 0

    tool_name = payload.get("tool_name") or ""
    if tool_name not in ("Write", "Edit", "MultiEdit"):
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path") or ""
    if not file_path:
        return 0

    crystal_root = os.environ.get("CRYSTAL_ROOT", "")
    if not crystal_root:
        return 0

    abs_path = os.path.abspath(file_path)
    abs_root = os.path.abspath(crystal_root)
    try:
        rel = os.path.relpath(abs_path, abs_root)
    except ValueError:
        return 0
    if rel.startswith(".."):
        return 0

    base = os.path.basename(abs_path)
    parts = rel.split(os.sep)
    is_folder_workitem = len(parts) >= 2 and base == "workitem.md"
    is_flat_workitem = len(parts) == 1 and base.endswith(".md")
    if not (is_folder_workitem or is_flat_workitem):
        return 0

    content = _build_post_edit_content(tool_name, tool_input, abs_path)
    if content is None:
        return 0

    status = _frontmatter_status(content)
    if status != "done":
        return 0

    unchecked = re.findall(r"(?m)^[ \t]*-[ \t]*\[ \](.*)$", content)
    if not unchecked:
        return 0

    sample = "\n".join("    " + line.strip() for line in unchecked[:5])
    extra = "" if len(unchecked) <= 5 else f"\n    ... and {len(unchecked) - 5} more"
    slug = parts[0] if is_folder_workitem else os.path.splitext(base)[0]

    sys.stderr.write(
        f"[crystal-cut] blocked: cannot transition `{slug}` to status:done "
        f"while {len(unchecked)} unchecked item(s) remain.\n\n"
        f"  Workitem: {abs_path}\n\n"
        f"  Unchecked:\n{sample}{extra}\n\n"
        f"  Resolve each unchecked item by one of the five paths "
        f"(see Decision Log #9):\n"
        f"    [x] resolved       — fixed in this workitem; check the box\n"
        f"    migrated -> <slug> — moved to another workitem; cross-link both sides\n"
        f"    cancelled (...)    — explicitly dropped with rationale (HITL)\n"
        f"    deferred (date)    — postponed with a target date\n"
        f"    promoted-to-stem   — promoted into a sibling workitem\n\n"
        f"  Once every `- [ ]` is addressed, re-run the edit that flips status:done.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
