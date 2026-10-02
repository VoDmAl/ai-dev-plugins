#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-people — may this project write to a person, and from which address.

    comms-people.py where            [--project-root DIR]
    comms-people.py show <who>       [--project-root DIR]

`where` prints the people directory this project reads: its own, or its HQ's
(`comms.hq`, looked up in the intercom directory). `show` finds the person,
by profile file name or by any token written in a profile (a login, an
address, a handle), and prints `trust`, the From pairs and the next step for
this project: a hand writes to `team` and `peer` itself and sends everyone else
through the HQ.

The rules and the field formats are in `comms_people.py`; the skill is
`/vdm-comms:letters` § 5.

Exit: 0 found · 2 not in people/ (counts as careful) · 3 in several profiles ·
1 the people directory could not be found, or the config is unreadable.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_config as cfgmod  # noqa: E402
import comms_people as people  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser(prog="comms-people", add_help=True)
    ap.add_argument("command", choices=("where", "show"))
    ap.add_argument("who", nargs="?", default=None)
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args(argv)

    root = os.path.abspath(args.project_root or cfgmod.project_root_of(os.getcwd()))
    cfg, cfg_err = cfgmod.load(root)
    if cfg_err:
        print("✖ %s" % cfg_err, file=sys.stderr)
        return 1

    if args.command == "where":
        try:
            where = people.locate(root, cfg)
        except people.Unresolved as exc:
            print("✖ %s" % exc)
            return 1
        origin = "hq `%s` (%s)" % (where["hq"], where["hq_root"]) if where["hq"] else "this project's own"
        print("%s\t%s" % (where["dir"], origin))
        return 0

    if not args.who:
        print("✖ show needs a person: a profile file name, a login, an address", file=sys.stderr)
        return 2
    code, lines = people.describe(root, cfg, args.who)
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
