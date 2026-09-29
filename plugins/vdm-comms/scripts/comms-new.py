#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-new — scaffold an outgoing draft for a channel.

    comms-new.py --channel <channel> --to <slug> --track <track path>
                 [--name <how the heading names them>] [--subject <text>]
                 [--project-root <dir>]

Writes `<track>/comms/<today>-<to>-out.md` and prints its path. The header is
the one the PROJECT's `comms.letter-form` asks of that channel — the same
reader the linter uses, so the scaffold and the check cannot disagree:

  * `draft: true` — the plugin's own draft marker;
  * `channel:` — declared at the one moment it is known;
  * `register:` — the project's `comms.register`, when declared; a letter to a
    different kind of reader changes it (skill `letters` § 6);
  * `goal:` — present and EMPTY. The goal is not something a scaffold can know;
    a project that switched on the `goal` element gets a reminder from the
    linter at the first edit, until the goal is written;
  * a subject line, when the channel owes one (`--subject` fills it);
  * the separator, when the project asks for one.

Why it exists (field report, program, 2026-09-26): with no scaffold, an
SMS draft was made by copying a neighbouring letter's header, and the copy
carried that letter's habits along. A neighbour is evidence of what someone
once wrote, not of what the project asks for.

`--to` is the file-name slug, in latin letters as in `people/`; `--name` is how
the heading addresses them (`--to kovalenko --name "Пётр Коваленко"`). The first
field try passed a Cyrillic name to `--to` and got a Cyrillic file name — a
repository that names its letters in latin now has one that sorts, greps and
lists differently from the rest.

An existing file is never overwritten, and a track that is a FILE (it has no
`comms/`) is refused. Exit: 0 written, 1 refused, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_config as cfgmod  # noqa: E402

SLUG_RE = re.compile(r"[^0-9a-z]+")


def slug_of(text):
    """`Anna Petrova` → `anna-petrova`; the file name, not the address. None when
    the text holds letters outside latin — those are a name, not a slug."""
    text = str(text).strip()
    if any(ch.isalpha() and not ch.isascii() for ch in text):
        return None
    return SLUG_RE.sub("-", text.lower()).strip("-")


def render(cfg, channel, to, subject):
    lab = cfgmod.labels(cfg)
    need = cfgmod.form_need(cfg, channel) or []
    lines = ["---", "draft: true", "channel: %s" % channel]
    if cfg.get("register") in cfgmod.REGISTERS:
        lines.append("register: %s" % cfg["register"])   # the project's; edit it for a different reader
    lines += ["goal:", "---", "", "# → %s" % to, ""]
    if "subject" in need:
        lines += ["**%s**: %s" % (lab["letter-subject"], subject or ""), ""]
    if "separator" in need:
        lines += ["---", "", lab["letter-text"], ""]
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(prog="comms-new", add_help=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--track", required=True)
    ap.add_argument("--name", default="")
    ap.add_argument("--subject", default="")
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args(argv)

    root = os.path.abspath(args.project_root or cfgmod.project_root_of(os.getcwd()))
    cfg, cfg_err = cfgmod.load(root)
    if cfg_err:
        print("✖ %s" % cfg_err, file=sys.stderr)
        return 1

    channel = cfgmod.channel_of(args.channel)
    to = slug_of(args.to)
    if to is None:
        print("✖ --to is the file-name slug, in latin letters as in people/; put the "
              "name for the heading in --name: --to <slug> --name \"%s\"" % args.to.strip(),
              file=sys.stderr)
        return 2
    if not channel or not to:
        print("✖ --channel and --to need a word each", file=sys.stderr)
        return 2
    track = args.track.strip().strip("/")
    track_dir = os.path.join(root, track)
    if not os.path.isdir(track_dir):
        why = ("is a file track — it has no comms/ to hold a letter"
               if os.path.isfile(track_dir + ".md") else "does not exist")
        print("✖ track `%s` %s" % (track, why), file=sys.stderr)
        return 1

    name = "%s-%s-out.md" % (cfgmod.today().isoformat(), to)
    path = os.path.join(track_dir, "comms", name)
    if os.path.exists(path):
        print("✖ %s already exists — a letter is never overwritten; open it, or pick "
              "another --to" % os.path.relpath(path, root), file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(render(cfg, channel, args.name.strip() or args.to.strip(),
                        args.subject.strip()))
    print(os.path.relpath(path, root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
