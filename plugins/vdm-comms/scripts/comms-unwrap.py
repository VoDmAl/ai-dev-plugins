#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-unwrap — join the hard-wrapped paragraphs of a draft's outgoing text.

    comms-unwrap.py <draft.md>...           report; exit 1 if a paragraph is wrapped
    comms-unwrap.py --show <draft.md>...    report and print each paragraph
    comms-unwrap.py --fix <draft.md>...     join each paragraph into one line

Only the text the draft sends is read: after the `---` separator, or the whole
body when there is none. That is the part `comms-lint` reports, so the command
it names fixes exactly what it found. The detection, the five classes it keeps
quiet about and the two invariants of `--fix` are in `comms_unwrap.py`.

Exit: 0 nothing wrapped, or all of it joined · 1 wrapped (report) · 2 a fix
refused by an invariant, or a file that cannot be read — that file is left as
it was.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_unwrap as unwrapmod  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser(prog="comms-unwrap", add_help=True)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--show", action="store_true")
    args = ap.parse_args(argv)

    rc = 0
    for path in args.files:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            print("%s: cannot read — %s" % (path, exc), file=sys.stderr)
            rc = 2
            continue
        lines = text.split("\n")
        start, end = unwrapmod.outgoing(lines)
        paras = unwrapmod.wrapped(lines, start, end)
        if not paras:
            continue
        where = ", ".join("L%d–%d" % (p[0][0] + 1, p[-1][0] + 1) for p in paras)
        if not args.fix:
            print("%s: %d wrapped paragraph(s): %s" % (path, len(paras), where))
            if args.show:
                for p in paras:
                    for i, raw in p:
                        print("    %4d │ %s" % (i + 1, raw))
            rc = max(rc, 1)
            continue
        try:
            new = unwrapmod.unwrap(lines, paras, start, end)
        except unwrapmod.Refused as exc:
            print("%s: not written — %s (%s); join these by hand" % (path, exc, where),
                  file=sys.stderr)
            rc = 2
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(new))
        print("%s: joined %d paragraph(s): %s" % (path, len(paras), where))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
