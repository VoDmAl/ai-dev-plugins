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

What the shell does not read as words is not read here either: the body of a
heredoc — data on the command's stdin, very often python — and a comment. Field
report, program, 2026-09-26: `python3 - <<'PY' … PY` wrote only the
letter's text into comms/, as the rule asks, and its body — an f-string with
"you're" in it — was read as shell. The quotes never closed, and the call was
blocked as NOT CHECKED with a hint to install the python3 that had just run.

Reads the hook payload on stdin. Exit 0 allow, 2 block (message on stdout),
3 could not decide — the reason on stderr's first line, the way out on its
second; the wrapper puts both into NOT CHECKED.
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


def heredoc_word(command, j):
    """The delimiter that follows `<<` at `j`: (index past it, word, tabs
    stripped?). Quotes and backslashes come off, as the shell takes them off."""
    n = len(command)
    strip = command.startswith("-", j)
    if strip:
        j += 1
    while j < n and command[j] in " \t":
        j += 1
    word, quote = [], None
    while j < n:
        c = command[j]
        if quote:
            if c == quote:
                quote = None
            else:
                word.append(c)
        elif c in "'\"":
            quote = c
        elif c == "\\" and j + 1 < n:
            j += 1
            word.append(command[j])
        elif c in " \t\n;&|()<>":
            break
        else:
            word.append(c)
        j += 1
    return j, "".join(word), strip


def past_bodies(command, i, heredocs):
    """Where the bodies of `heredocs` end, read one after another from `i`, as
    the shell reads them. A body that no line closes cuts nothing: `$((1<<2))`
    looks like a heredoc, and taking the rest of the command for its body would
    hide every command after it."""
    n, j = len(command), i
    for word, strip in heredocs:
        while True:
            if j >= n:
                return i
            k = command.find("\n", j)
            line = command[j:] if k < 0 else command[j:k]
            j = n if k < 0 else k + 1
            if (line.lstrip("\t") if strip else line) == word:
                break
    return j


def shell_text(command):
    """`command` without what the shell does not read as words: heredoc bodies
    and comments. Quoting is followed, so a `<<` or a `#` inside quotes stays
    text, and a `#` starts a comment only where a word would start."""
    out, heredocs = [], []
    i, n = 0, len(command)
    quote, word_start = None, True
    while i < n:
        c = command[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i:i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(command[i:i + 2])
            i += 2
            word_start = False
            continue
        if c == "#" and word_start:
            k = command.find("\n", i)
            i = n if k < 0 else k
            continue
        if command.startswith("<<", i):
            j, word, strip = heredoc_word(command, i + 2)
            if word:
                heredocs.append((word, strip))
            out.append(command[i:j])
            i, word_start = j, False
            continue
        if c in "'\"":
            quote = c
        out.append(c)
        i += 1
        if c == "\n" and heredocs:
            i = past_bodies(command, i, heredocs)
            heredocs = []
        word_start = quote is None and c in " \t\n;&|()<>"
    return "".join(out)


def split_commands(command):
    lex = shlex.shlex(shell_text(command), posix=True, punctuation_chars=";&|()<>")
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


def undecided(why, how=""):
    """No verdict (exit 3): the reason on the first line of stderr, the way out
    on the second. Without them the wrapper could only guess, and it guessed
    "install python3" for a python3 that had just run."""
    sys.stderr.write("%s\n%s\n" % (why, how))
    return 3


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return undecided("the hook payload is not JSON")
    tool = payload.get("tool_name")
    if not tool:
        return undecided("the hook payload names no tool")
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    root = os.environ.get("CLAUDE_PROJECT_DIR") or cfgmod.project_root_of(cwd)
    cfg, err = cfgmod.load(root)
    if err:
        return undecided(err, "fix that file and try again, or")
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
        except ValueError as exc:
            return undecided(
                "the command's quotes do not close as the shell reads them (%s), "
                "so where anything lands cannot be told" % exc,
                "if the shell runs it as written, the guard misread it: give the "
                "part that names the .eml a call of its own, or")
    if not found:
        return 0
    where = "\n  ".join("→ %s" % os.path.relpath(os.path.realpath(p), territory.root)
                        for p in found)
    print(MESSAGE.format(where=where))
    return 2


if __name__ == "__main__":
    sys.exit(main())
