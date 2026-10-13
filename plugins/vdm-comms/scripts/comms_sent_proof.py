#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_sent_proof — does this write make an outgoing letter "sent" without proof?

Called by `comms-draft-guard.sh` on a Write, Edit or MultiEdit of
`*/comms/*-out.md`, with the hook payload on stdin:

    python3 comms_sent_proof.py < payload

Exit: 0 allow · 2 refuse (the reason on stderr) · 3 cannot tell.

The question is asked of the TRANSITION, not of the file. The letter as it is
on disk is compared with the letter as the write would leave it: not sent
before (or no file) and sent after → `sent-proof:` must be there. A letter that
was already sent is history — fixing a typo in it is legitimate, and it is
never asked for a proof it was written without. Measured 2026-10-13 on the
three projects that keep letters as files: of 616 sent letters about 520 carry
nothing that could serve as proof, and nothing can be added now — the tools'
answers are gone, and many were sent by the owner's hand.

What counts as proof is what shows the letter left, not the assistant's word
(the owner, 2026-10-09: only the hooks keep the agent from marking a template
as sent): an id or link from the sending tool's answer — a mail's message_id,
a ticket comment's link, a chat message's id — or `owner`, when the owner said
in the conversation that they sent it themselves (the owner's choice,
2026-10-13). The field cannot tell a real id from an invented one; it turns an
accidental mark into a deliberate claim. Crystal `outgoing-ladder`, DL #2–#5.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_frontmatter as fmmod  # noqa: E402

PROOF_KEY = "sent-proof"

REFUSAL = """\
🚫 comms-draft-guard: this write marks an outgoing letter as sent (`sent:`) without proof.

  A letter becomes "sent" by what shows it left, not by the assistant's word.
  Add to the frontmatter, next to `sent:`:
    sent-proof: <id or link from the sending tool's answer>
                 — a mail's message_id, the link to a ticket comment, a chat message's id
    sent-proof: owner
                 — the owner said, in this conversation, that they sent this letter themselves

  Neither in hand → the letter is still a draft: `draft: true`, and no `sent:`.
"""


def _keys(text):
    """Top-level scalar keys of a letter's frontmatter. A frontmatter opened and
    never closed is still read — line by line from the top — because a letter
    that claims `sent:` in a broken header claims it all the same."""
    try:
        fm_text, _ = fmmod.split_frontmatter(text)
    except fmmod.FrontmatterError:
        fm_text = "\n".join(text.split("\n")[1:40])
    return fmmod.scalar_keys(fm_text)


def is_sent(keys):
    return keys.get("sent") not in (None, "", False)


def has_proof(keys):
    value = keys.get(PROOF_KEY)
    return isinstance(value, str) and value.strip() != ""


def _apply(before, old, new, replace_all):
    """→ text after one replacement, or None when it would not apply (the
    harness refuses such an edit itself, and nothing is written)."""
    if not isinstance(old, str) or not isinstance(new, str) or old == "" or old not in before:
        return None
    return before.replace(old, new) if replace_all else before.replace(old, new, 1)


def after_text(tool, tool_input, before):
    """→ (text, ok). ok False = cannot tell; text None with ok True = nothing will be written."""
    if tool == "Write":
        content = tool_input.get("content")
        return (content, True) if isinstance(content, str) else (None, False)
    if before is None:
        return None, True
    if tool == "Edit":
        return _apply(before, tool_input.get("old_string"), tool_input.get("new_string"),
                      bool(tool_input.get("replace_all"))), True
    if tool == "MultiEdit":
        edits = tool_input.get("edits")
        if not isinstance(edits, list):
            return None, False
        text = before
        for e in edits:
            if not isinstance(e, dict):
                return None, False
            text = _apply(text, e.get("old_string"), e.get("new_string"), bool(e.get("replace_all")))
            if text is None:
                return None, True
        return text, True
    return None, True


def verdict(payload):
    """→ exit code for one hook payload (dict)."""
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 3
    path = tool_input.get("file_path")
    if not isinstance(path, str) or not path:
        return 3
    before = None
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                before = fh.read()
        except OSError:
            return 3
    after, ok = after_text(tool, tool_input, before)
    if not ok:
        return 3
    if after is None:
        return 0
    if before is not None and is_sent(_keys(before)):
        return 0
    keys = _keys(after)
    if is_sent(keys) and not has_proof(keys):
        sys.stderr.write(REFUSAL)
        return 2
    return 0


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, UnicodeDecodeError):
        return 3
    if not isinstance(payload, dict):
        return 3
    return verdict(payload)


if __name__ == "__main__":
    sys.exit(main())
