#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_checklist — the checks an outgoing draft goes through before it is shown.

One text, two deliveries, because a draft is born two ways:

  * `comms-new.py` (the scaffold, run through Bash — no Write hook fires) prints
    it after the path;
  * `comms-draft-guard.sh` (PreToolUse on the Write that creates
    `*/comms/*-out.md`) hands it over as additionalContext:

      python3 comms_checklist.py --hook --file <path>   < content

The skill is `/vdm-comms:letters`; this is its short form at the moment of
writing. The owner, 2026-09-13: «Скил не лечит — его тоже надо не забыть
вызвать». Lines are checks, not a lecture, and carry no cluster numbers.

The register line comes from the letter's own `register:`, else from
`comms.register`; the language line from `comms.language`. Neither is printed
when undeclared — a line that says nothing specific is a line nobody reads.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fmmod  # noqa: E402

CHECKS = (
    "Goal: what changes once it is answered — in `goal:`, one sentence. A likely answer of \"yes\" or \"we'll see\" → do not write it.",
    "One subject: one request or one statement; every sentence carries it.",
    "The decision and the request — not the reader's own decisions retold, not our own corrections.",
    "No exit: nothing lets them close or park it in one line (\"if not, fine\", \"let me know when convenient\", \"send X, then\"); the request ends with what happens once it is done — our next step goes to the owner above the separator, as a proposal.",
    "Everything needed to start is inside the letter; procedural asks run in parallel, not as a condition.",
    "Every promise and date of ours was named by the owner (others go above the separator, as a proposal); the pronoun names who really acts: the owner's and their agent's work is \"I\", \"we\" only for what is truly shared.",
    "No obliging extras: no help nobody asked for, no \"happy to\", no \"while we're at it\" — \"please\" and \"thanks\" are the register's, not extras.",
    "Cut: what we already decided, our own status, what they already know.",
    "Questions only for the gap: a \"What we know\" line above the separator, with sources; not found = \"not seen in our sources\".",
    "Every fact about their system or a person has a source; \"always\" / \"any\" holds in every case.",
    "Their field is not explained to them; nothing is prescribed inside their zone.",
    "Recipients' profiles read and applied, and their `trust` lets this project write: a hand writes to team and peer only — careful, top and anyone not in people/ go through the HQ. No reproach for a past silence.",
    "The channel's form: an email has a subject (the same thread keeps `RE:`, a new matter a new one), a greeting on its own line, a paragraph per thought; a ticket addresses people by mention — `[~login]` in Jira, `@login` in GitLab.",
    "Attachments: the text says \"attached\", and the file has a 📎 section.",
    "After sending: who has the ball, and where the waiting item with a review date lives; whoever else waits on this subject is in copy — not us in the middle; whoever saw the subject earlier and needs no part in what follows (a copy of the letter we answer, someone the document was shared with) gets a blind copy of this first answer — they see it is not dropped, and reply-all leaves them out.",
)

REGISTER_LINES = {
    "volunteer": "ask, don't assign — what, by when, what counts as done, and what we take off them if the date is tight",
    "executor": "direct, no hedging about our own actions — the need and the outcome; where and how is theirs",
    "peer": "a request, not an order — no imperatives, no order of steps, no deadline for their answer; a favour outside their queue gets a please and a thanks",
}


def render(cfg, register=None):
    reg = register if register in cfgmod.REGISTERS else cfg.get("register")
    lines = ["Before showing this draft (skill /vdm-comms:letters):"]
    lines += ["%d. %s" % (i, text) for i, text in enumerate(CHECKS, 1)]
    if reg in REGISTER_LINES:
        lines.append("Register: %s — %s." % (reg, REGISTER_LINES[reg]))
    lang = cfg.get("language")
    if isinstance(lang, str) and lang.strip():
        lines.append("Language of the letter: %s — the recipient's, without calques." % lang.strip())
    return "\n".join(lines)


def _register_of(content):
    try:
        fm_text, _ = fmmod.split_frontmatter(content)
    except fmmod.FrontmatterError:
        return None
    value = fmmod.scalar_keys(fm_text).get("register")
    return str(value) if value not in (None, "") else None


def main(argv):
    ap = argparse.ArgumentParser(prog="comms_checklist", add_help=True)
    ap.add_argument("--hook", action="store_true")
    ap.add_argument("--file", default=None)
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args(argv)

    anchor = args.file or os.getcwd()
    root = os.path.abspath(args.project_root or cfgmod.project_root_of(anchor))
    cfg, cfg_err = cfgmod.load(root)
    if cfg_err or cfg.get("enabled") is False:
        return 0
    register = _register_of(sys.stdin.read()) if args.hook else None
    text = render(cfg, register)
    if args.hook:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "additionalContext": text}},
                         ensure_ascii=False))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
