#!/usr/bin/env python3
"""
crystal-completion-guard.py — simulator used by crystal-completion-guard.sh.

Reads the Claude Code PreToolUse JSON payload on stdin, decides whether the
edit would transition a crystal workitem to a *terminal* status with unmet
preconditions, and — if so — prints the diagnostic to stderr and exits with
code 2 (which the bash wrapper re-emits to the hook harness).

Two gates fire here (both terminal-tier per DL #10):

1. ``done`` transition — blocked while any unchecked ``- [ ]`` items remain.
   Implements Decision Log #4 in crystal-design (completion discipline
   generalized to any unchecked checkbox in the workitem).

2. ``superseded`` transition — blocked unless ``superseded-by: <slug>`` is
   present in the frontmatter (DL #10 in crystal-multi-root). Forces the
   author to name the replacement workitem instead of letting the trail die.

``cancelled`` and other terminal statuses bypass the gate (the author has
explicitly dropped the work — unchecked items are no longer obligations).
All non-terminal statuses also bypass.

Environment:
  CRYSTAL_ROOTS              Colon-separated absolute crystal roots. Required.
                             (Falls back to CRYSTAL_ROOT for legacy compat.)
  CRYSTAL_GATE_DONE          Comma-separated status values that trigger the
                             done gate (canonical "done" + any status-aliases
                             mapping to "done"). Default: "done".
  CRYSTAL_GATE_SUPERSEDED    Same, for the superseded gate. Default: "superseded".

Hook contract:
  Fail-open at every boundary. Better to miss one edit than block on a
  hook bug. Exit 0 silently when payload is malformed, file isn't a workitem,
  config missing, etc.
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


def _frontmatter_field(content: str, field: str) -> str | None:
    fm = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not fm:
        return None
    body = fm.group(1)
    pattern = r"^" + re.escape(field) + r":\s*([^\s#]+)"
    m = re.search(pattern, body, re.MULTILINE)
    if not m:
        return None
    return m.group(1).strip().strip('"').strip("'")


def _is_workitem_path(abs_path: str, roots: list[str]) -> tuple[bool, bool, str]:
    """Return (is_workitem, is_folder_style, slug).

    Workitem files: <root>/<slug>/workitem.md (folder, canonical) or
    <root>/<slug>.md (flat, legacy). Anything else returns (False, False, "").
    """
    base = os.path.basename(abs_path)
    for root in roots:
        if not root:
            continue
        abs_root = os.path.abspath(root)
        try:
            rel = os.path.relpath(abs_path, abs_root)
        except ValueError:
            continue
        if rel.startswith(".."):
            continue
        parts = rel.split(os.sep)
        if len(parts) >= 2 and base == "workitem.md":
            return True, True, parts[0]
        if len(parts) == 1 and base.endswith(".md"):
            return True, False, os.path.splitext(base)[0]
    return False, False, ""


def _split_csv(value: str, default: str) -> set[str]:
    raw = value if value else default
    return {item.strip() for item in raw.split(",") if item.strip()}


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

    roots_env = os.environ.get("CRYSTAL_ROOTS") or os.environ.get("CRYSTAL_ROOT", "")
    if not roots_env:
        return 0
    roots = [r for r in roots_env.split(":") if r]
    if not roots:
        return 0

    abs_path = os.path.abspath(file_path)
    is_workitem, is_folder, slug = _is_workitem_path(abs_path, roots)
    if not is_workitem:
        return 0

    content = _build_post_edit_content(tool_name, tool_input, abs_path)
    if content is None:
        return 0

    status = _frontmatter_field(content, "status")
    if not status:
        return 0

    done_set = _split_csv(os.environ.get("CRYSTAL_GATE_DONE", ""), "done")
    superseded_set = _split_csv(os.environ.get("CRYSTAL_GATE_SUPERSEDED", ""), "superseded")

    if status in done_set:
        unchecked = re.findall(r"(?m)^[ \t]*-[ \t]*\[ \](.*)$", content)
        if not unchecked:
            return 0
        sample = "\n".join("    " + line.strip() for line in unchecked[:5])
        extra = "" if len(unchecked) <= 5 else f"\n    ... and {len(unchecked) - 5} more"
        sys.stderr.write(
            f"[crystal-cut] blocked: cannot transition `{slug}` to status:done "
            f"while {len(unchecked)} unchecked item(s) remain.\n\n"
            f"  Workitem: {abs_path}\n\n"
            f"  Unchecked:\n{sample}{extra}\n\n"
            f"  Resolve each unchecked item by one of the five paths "
            f"(see Decision Log #9 in crystal-design):\n"
            f"    [x] resolved       — fixed in this workitem; check the box\n"
            f"    migrated -> <slug> — moved to another workitem; cross-link both sides\n"
            f"    cancelled (...)    — explicitly dropped with rationale (HITL)\n"
            f"    deferred (date)    — postponed with a target date\n"
            f"    promoted-to-stem   — promoted into a sibling workitem\n\n"
            f"  Once every `- [ ]` is addressed, re-run the edit that flips status:done.\n"
        )
        return 2

    if status in superseded_set:
        superseded_by = _frontmatter_field(content, "superseded-by")
        if superseded_by:
            return 0
        sys.stderr.write(
            f"[crystal-cut] blocked: cannot transition `{slug}` to "
            f"status:superseded without a `superseded-by:` frontmatter field "
            f"naming the replacement workitem.\n\n"
            f"  Workitem: {abs_path}\n\n"
            f"  Add to frontmatter:\n"
            f"    superseded-by: <slug-of-replacement>\n\n"
            f"  Both this workitem and the replacement should cross-link to "
            f"the other (DL #10 in crystal-multi-root).\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
