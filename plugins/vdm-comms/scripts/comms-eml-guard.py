#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-eml-guard — does this tool call put a raw `.eml` into comms/ or the
meetings tree?

Owner's rule, 2026-09-25, for every one of their projects: the raw mail file is
not kept in the repository. The text of the letter goes to `comms/*-in.md`, the
attachments that matter are extracted into `comms/attachments/`, and the `.eml`
stays where the mail system keeps it. Measured the same day: 27 files, 22 MB in
one repository, travelling to three devices through Syncthing, CRLF noise after
every machine switch, and phone numbers from signatures that the `.md` never
carried.

Territory, not the whole project (workitem vdm-comms-letter-form DL #5): the
plugin is installed for every project on the machine, and a mail-parser repo
keeps `.eml` fixtures legitimately. The rule was born of `comms/attachments/`,
and every case of 2026-09-25 lay there — so the guard watches `*/comms/*` and
`<meetings-dir>/`, and nothing else.

A Bash command is read by name, not by effect: `cp`, `mv`, `rsync`, `ditto`,
`install`, `ln`, `scp`, `tee`, `curl -o`, `wget -O`, and `>` / `>>`, with `cd`
followed along the chain. A python one-liner that writes the file is not seen —
that is the known limit of a hook (crystal-grow → "Why this isn't a hook").

Reads the hook payload on stdin. Exit 0 allow, 2 block (message on stdout),
3 could not decide (the wrapper turns that into NOT CHECKED).
"""
from __future__ import annotations

import json
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import comms_config as cfgmod  # noqa: E402

COPY_VERBS = {"cp", "mv", "rsync", "ditto", "install", "ln", "scp"}
PREFIXES = {"sudo", "command", "env", "nice", "nohup", "time"}
SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")"}


def is_eml(p):
    return p.lower().endswith(".eml")


class Territory:
    def __init__(self, root, meetings_dir):
        self.root = os.path.realpath(root)
        self.meetings = meetings_dir.strip("/") or "meetings"

    def owns(self, path):
        real = os.path.realpath(path)
        if real != self.root and not real.startswith(self.root + os.sep):
            return False
        parts = os.path.relpath(real, self.root).split(os.sep)
        return "comms" in parts[:-1] or parts[0] == self.meetings


def landing(dest, source, cwd):
    """Where a copy of `source` ends up when `dest` is its destination."""
    dest = os.path.expanduser(dest)
    full = dest if os.path.isabs(dest) else os.path.join(cwd, dest)
    if dest.endswith("/") or os.path.isdir(full):
        return os.path.join(full, os.path.basename(source))
    return full


def split_commands(command):
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    cmds, cur = [], []
    for tok in lex:
        if tok in SEPARATORS or set(tok) <= set(";&|()") and tok:
            if cur:
                cmds.append(cur)
            cur = []
            continue
        cur.append(tok)
    if cur:
        cmds.append(cur)
    return cmds


def offences_in_bash(command, cwd, territory):
    found = []
    for argv in split_commands(command):
        # redirections anywhere in the simple command: `> x.eml`, `>> x.eml`
        for i, tok in enumerate(argv[:-1]):
            if tok in (">", ">>", ">|") and is_eml(argv[i + 1]):
                target = landing(argv[i + 1], argv[i + 1], cwd)
                if territory.owns(target):
                    found.append(target)
        words = [t for t in argv if t not in (">", ">>", ">|", "<")]
        while words and ("=" in words[0] and not words[0].startswith("-")
                         or words[0] in PREFIXES):
            words = words[1:]
        if not words:
            continue
        verb, args = os.path.basename(words[0]), words[1:]
        if verb == "cd":
            target = args[0] if args else os.path.expanduser("~")
            nxt = os.path.expanduser(target)
            cwd = nxt if os.path.isabs(nxt) else os.path.normpath(os.path.join(cwd, nxt))
            continue
        if verb in COPY_VERBS:
            target_dir = None
            paths = []
            it = iter(range(len(args)))
            for i in it:
                a = args[i]
                if a in ("-t", "--target-directory") and i + 1 < len(args):
                    target_dir = args[i + 1]
                    next(it, None)
                elif a.startswith("--target-directory="):
                    target_dir = a.split("=", 1)[1]
                elif not a.startswith("-"):
                    paths.append(a)
            if target_dir is not None:
                sources, dest = paths, target_dir + "/"
            elif len(paths) >= 2:
                sources, dest = paths[:-1], paths[-1]
            else:
                continue
            for src in sources:
                if is_eml(src) or is_eml(dest):
                    target = landing(dest, src, cwd)
                    if territory.owns(target):
                        found.append(target)
        elif verb == "tee":
            for a in args:
                if not a.startswith("-") and is_eml(a):
                    target = landing(a, a, cwd)
                    if territory.owns(target):
                        found.append(target)
        elif verb in ("curl", "wget"):
            for i, a in enumerate(args):
                out = None
                if a in ("-o", "--output", "-O", "--output-document") and i + 1 < len(args):
                    out = args[i + 1]
                elif a.startswith("--output=") or a.startswith("--output-document="):
                    out = a.split("=", 1)[1]
                if out and is_eml(out):
                    target = landing(out, out, cwd)
                    if territory.owns(target):
                        found.append(target)
    return found


MESSAGE = """🚫 comms-eml-guard: the raw .eml does not go into the repository.

  {where}

  The mail system keeps the letter; the repository keeps what was read and
  decided:
    - the text of the letter or the thread  → comms/<date>-<slug>-in.md
    - the attachments that matter            → extract them from the .eml into
      comms/attachments/ — the documents and screenshots under discussion, not
      the logos from signatures
  Read the .eml where it lies (~/Downloads, a temp dir) — python's `email`
  module parses it — and write only those two things. Why: the text is already
  in the .md; the .eml is a duplicate in size, in CRLF noise, and in personal
  data from signatures the .md never carried.
"""


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 3
    tool = payload.get("tool_name")
    if not tool:
        return 3
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    root = os.environ.get("CLAUDE_PROJECT_DIR") or cfgmod.project_root_of(cwd)
    cfg, err = cfgmod.load(root)
    if err:
        return 3
    if cfg.get("enabled") is False:
        return 0
    territory = Territory(root, str(cfg.get("meetings-dir") or "meetings"))

    found = []
    if tool in ("Write", "Edit", "MultiEdit"):
        path = tool_input.get("file_path") or ""
        if is_eml(path):
            full = path if os.path.isabs(path) else os.path.join(cwd, path)
            if territory.owns(full):
                found.append(full)
    elif tool == "Bash":
        command = tool_input.get("command") or ""
        if ".eml" not in command.lower():
            return 0
        try:
            found = offences_in_bash(command, cwd, territory)
        except ValueError:
            return 3  # unbalanced quotes — cannot tell where anything lands
    if not found:
        return 0
    where = "\n  ".join("→ %s" % os.path.relpath(os.path.realpath(p), territory.root)
                        for p in found)
    print(MESSAGE.format(where=where))
    return 2


if __name__ == "__main__":
    sys.exit(main())
