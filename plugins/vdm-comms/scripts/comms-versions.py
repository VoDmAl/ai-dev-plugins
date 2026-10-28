#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-versions — the versions an outgoing letter had, as they were written.

    comms-versions.py list <letter.md>          every version, oldest first, across renames
    comms-versions.py diff <letter.md>          what each version changed, with the owner's turn before it
    comms-versions.py diff <letter.md> A [B]    between two versions: numbers from `list`, or `now`
                                                for the file as it is (B defaults to `now`)
    comms-versions.py where <letter.md>         the folders that keep its versions

The versions are kept by the plugin's hooks as the letter is written
(`comms_versions.py`). A letter the owner sent by hand, once its copy says what
left (`letters` § 9): the last step of `diff` is what the owner changed in the
mail client, and the steps before it, each after its turn, what they asked for
in the conversation — the lines of the project's journal of cuts.

Exit: 0 · 1 no versions kept for this letter · 2 bad arguments.
"""
from __future__ import annotations

import argparse
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_versions as vermod  # noqa: E402

RESCUED = "index.md"


def _local(at):
    try:
        moment = datetime.datetime.fromisoformat(at.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return at or "?"
    return moment.astimezone().strftime("%Y-%m-%d %H:%M")


def _one_line(text, width=90):
    line = " ".join((text or "").split())
    return line if len(line) <= width else line[:width - 1] + "…"


def versions(path):
    """→ [(number, meta, text)], oldest first, and the folders they came from."""
    found, folders = [], []
    for folder, metas in vermod.chain(path):
        folders.append(folder)
        for meta_path in metas:
            meta = vermod.read_meta(meta_path)
            text = vermod.text_of(meta_path)
            if meta is not None and text is not None:
                found.append((len(found) + 1, meta, text))
    return found, folders


def _state(text):
    return "sent" if vermod.is_sent(text) else "draft"


def cmd_where(path):
    _, folders = versions(path)
    for folder in folders:
        print(folder)
    return 0


def cmd_list(path):
    found, folders = versions(path)
    if not found:
        print("no versions kept for %s (looked in %s)" % (path, folders[-1]), file=sys.stderr)
        return 1
    prev, where = None, None
    for number, meta, text in found:
        if meta.get("path") != where:
            where = meta.get("path")
            print("%s" % where)
        _, changed = vermod.word_diff(vermod.split(prev)[1], vermod.split(text)[1]) if prev is not None else ("", 0)
        print("  %2d  %s  %-6s %-17s %-5s %s" % (
            number, _local(meta.get("at")), meta.get("machine", "?"), meta.get("how", "?"),
            _state(text), ("±%d words" % changed) if prev is not None else "first"))
        if meta.get("owner_turn"):
            print("        owner: %s" % _one_line(meta["owner_turn"]))
        prev = text
    for folder in folders:
        rescued = os.path.join(folder, RESCUED)
        if os.path.isfile(rescued):
            print("rescued from transcripts: %s" % rescued)
    return 0


def _step(label, old, new):
    print("── %s" % label)
    for line in vermod.frontmatter_changes(old, new):
        print("   frontmatter  %s" % line)
    text, changed = vermod.word_diff(vermod.split(old)[1], vermod.split(new)[1])
    print(text if changed else "   (the text below the frontmatter is the same)")
    print()


def cmd_diff(path, a, b):
    found, _ = versions(path)
    if not found:
        print("no versions kept for %s" % path, file=sys.stderr)
        return 1
    by_number = {number: (meta, text) for number, meta, text in found}

    def pick(token):
        if token == "now":
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    return "the file now", fh.read()
            except OSError:
                return None
        try:
            meta, text = by_number[int(token)]
        except (ValueError, KeyError):
            return None
        return "%s (%s, %s)" % (token, _local(meta.get("at")), meta.get("how", "?")), text

    if a is not None:
        old, new = pick(a), pick(b or "now")
        if old is None or new is None:
            print("no version %s — numbers are those of `list`, or `now`" % (a if old is None else b),
                  file=sys.stderr)
            return 2
        _step("%s → %s" % (old[0], new[0]), old[1], new[1])
        return 0
    prev = None
    for number, meta, text in found:
        if meta.get("owner_turn"):
            print("👤 %s: %s\n" % (_local(meta.get("owner_turn_at")), meta["owner_turn"].strip()))
        if prev is not None:
            _step("%d → %d  %s  %s, %s" % (number - 1, number, _local(meta.get("at")),
                                          meta.get("how", "?"), _state(text)), prev, text)
        prev = text
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="comms-versions")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("list", "where"):
        sub.add_parser(name).add_argument("letter")
    d = sub.add_parser("diff")
    d.add_argument("letter")
    d.add_argument("a", nargs="?")
    d.add_argument("b", nargs="?")
    args = ap.parse_args(argv)
    path = os.path.abspath(args.letter)
    if args.cmd == "where":
        return cmd_where(path)
    if args.cmd == "list":
        return cmd_list(path)
    return cmd_diff(path, args.a, args.b)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
