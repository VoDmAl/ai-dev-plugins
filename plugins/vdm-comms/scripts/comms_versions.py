#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_versions — every text an outgoing letter had, kept as it is written.

The file in `comms/` is rewritten to what left once a letter is sent; git sees
only what was committed; the harness deletes its transcripts after about a
month. So the draft the owner saw, and each edit of it, used to survive only in
transcripts (crystal `letter-versions`: of 821 letters collected 2026-10-27, for
247 the transcript was the only trace — the file was gone). Here each version
is kept as it is written:

  * before a Write, Edit or MultiEdit of `*/comms/*-out.md` — the letter as it
    lies on disk; an edit made outside any tool call (the owner in an editor)
    becomes a version of its own  [comms_sent_proof.verdict, PreToolUse];
  * after such a write  [comms-versions.sh, PostToolUse];
  * before a Bash command, each letter it names by path — an editor edit just
    before it does not merge into the command's version  [comms-versions.sh,
    PreToolUse];
  * after a Bash command that names a letter — every `*/comms/*-out.md` that
    differs from HEAD or is not committed, and each letter the command names,
    in a git work tree or not  [comms_sent_proof.bash_verdict].

A version is a whole text with its moment, written once and never changed: a
fact about the past, which cannot go stale the way state does. The same text
twice is one version. Beside it goes the owner's last turn in the session, when
it is new: the versions show what changed, the turn shows which change the
owner asked for.

Store: $VDM_LETTER_VERSIONS_ROOT, else ~/.claude/vdm/letter-versions —
<project>/<letter path, `/` as `__`>/snap/<UTC moment>.md, and .json beside it.
One file per version, so two machines sharing the folder never write the same
file. It is the layout of the collection rescued from the transcripts, in the
same store (crystal `letter-versions`, DL #3, #5).

A letter renamed or moved — the date in its name is the day of the send —
starts a new folder; its first version names the previous one (`from`) when
the command named that letter or the text below the frontmatter is the same.
Two thirds of the letters gone from disk had moved (DL #5).

Never blocks. A version that could not be saved is said, as context.
"""
from __future__ import annotations

import datetime
import difflib
import hashlib
import json
import os
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_frontmatter as fmmod  # noqa: E402

ROOT_ENV = "VDM_LETTER_VERSIONS_ROOT"
LETTER = re.compile(r"/comms/[^/]*-out\.md$")
# A letter a shell command names: quoted (a path with a space), or bare.
NAMED = re.compile(r""""([^"\n]*comms/[^"\n]*-out\.md)"|'([^'\n]*comms/[^'\n]*-out\.md)'"""
                   r"""|([^\s'"`=<>|;&()]*comms/[^\s'"`=<>|;&()]*-out\.md)""")
CD = re.compile(r"""\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;)""")
WRITE_TOOLS = ("Write", "Edit", "MultiEdit")
# What is kept of the owner's turn and of a command: enough to read the request,
# not a pasted thread of a hundred letters.
TURN_LIMIT = 20000
COMMAND_LIMIT = 4000
# How far back a transcript is read for the owner's last turn. A long run of
# tool calls lies between the turn and the write; past this, there is no turn.
TRANSCRIPT_SCAN = 8 << 20
CHUNK = 256 << 10


def store_root():
    root = os.environ.get(ROOT_ENV) or os.path.join("~", ".claude", "vdm", "letter-versions")
    return os.path.expanduser(root)


def is_letter(path):
    return isinstance(path, str) and bool(LETTER.search(path.replace(os.sep, "/")))


def project_root(path):
    """The work tree a letter lives in: the nearest directory up holding `.git`."""
    d = os.path.dirname(path)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def letter_dir(path):
    """→ the folder that keeps the versions of the letter at `path`."""
    path = os.path.realpath(path)
    top = project_root(path)
    rel = os.path.relpath(path, top) if top else os.path.basename(path)
    project = os.path.basename(top) if top else "_unknown"
    return os.path.join(store_root(), project, rel.replace(os.sep, "__"))


def snapshots(folder):
    """→ the .json of each version in one letter folder, oldest first."""
    snap = os.path.join(folder, "snap")
    try:
        names = sorted(n for n in os.listdir(snap) if n.endswith(".json"))
    except OSError:
        return []
    return [os.path.join(snap, n) for n in names]


def read_meta(path):
    try:
        with open(path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        return None
    return meta if isinstance(meta, dict) else None


def last_meta(folder):
    for path in reversed(snapshots(folder)):
        meta = read_meta(path)
        if meta is not None:
            return meta
    return None


def text_of(meta_path):
    try:
        with open(meta_path[:-len(".json")] + ".md", "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return None


def split(text):
    """→ (frontmatter, body). A frontmatter never closed is all body."""
    try:
        return fmmod.split_frontmatter(text)
    except fmmod.FrontmatterError:
        return "", text


def is_sent(text):
    keys = fmmod.scalar_keys(split(text)[0])
    return keys.get("sent") not in (None, "", False)


# --- the owner's turn ---------------------------------------------------------

def _owner_text(line):
    """What the owner typed, from one transcript line; None for a turn the
    harness made — a tool result, a command and its output, a notice."""
    if b'"user"' not in line or b'toolUseResult' in line:
        return None
    try:
        record = json.loads(line)
    except ValueError:
        return None
    if (not isinstance(record, dict) or record.get("type") != "user"
            or record.get("isMeta") or record.get("isCompactSummary")):
        return None
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list):
        content = "\n".join(part.get("text", "") for part in content
                            if isinstance(part, dict) and part.get("type") == "text")
    if not isinstance(content, str):
        return None
    text = content.strip()
    if not text or text.startswith("<") or text.startswith("[Request interrupted"):
        return None
    return record.get("timestamp") or "", text[:TURN_LIMIT]


def owner_turn(transcript):
    """→ (at, text) of the owner's last turn in a session's transcript, or None.
    A subagent's transcript has none: its prompt came from the assistant."""
    if not isinstance(transcript, str) or not transcript or "/subagents/" in transcript:
        return None
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            pos, tail, scanned = fh.tell(), b"", 0
            while pos > 0 and scanned < TRANSCRIPT_SCAN:
                step = min(CHUNK, pos)
                pos -= step
                fh.seek(pos)
                lines = (fh.read(step) + tail).split(b"\n")
                scanned += step
                tail = lines.pop(0) if pos > 0 else b""
                for line in reversed(lines):
                    turn = _owner_text(line)
                    if turn:
                        return turn
    except OSError:
        return None
    return None


# --- a letter before a rename or a move --------------------------------------

def predecessor(folder, path, text, command):
    """→ the name of the folder, beside `folder`, of the letter this one was
    before it was renamed or moved — or None.

    A candidate is a letter whose last version names a path no longer on disk.
    The command that made this version names it — `git mv`, `mv` — or, failing
    that, the text below the frontmatter is the same. Two candidates where one
    is wanted is no answer."""
    project = os.path.dirname(folder)
    try:
        names = sorted(os.listdir(project))
    except OSError:
        return None
    gone = []
    for name in names:
        other = os.path.join(project, name)
        if name.startswith("_") or other == folder:
            continue
        metas = snapshots(other)
        meta = read_meta(metas[-1]) if metas else None
        old = meta.get("path") if meta else None
        if isinstance(old, str) and old and old != path and not os.path.exists(old):
            gone.append((name, old, metas[-1]))
    if not gone:
        return None
    if command:
        named = [g for g in gone if os.path.basename(g[1]) in command]
        if len(named) > 1:
            top = project_root(path) or "/"
            named = [g for g in named if os.path.relpath(g[1], top) in command]
        if len(named) == 1:
            return named[0][0]
    body = split(text)[1].strip()
    if not body:
        return None
    same = [g for g in gone if split(text_of(g[2]) or "")[1].strip() == body]
    return same[0][0] if len(same) == 1 else None


# --- keeping a version --------------------------------------------------------

def _now():
    return datetime.datetime.now(datetime.timezone.utc)


# The texts are the same letters and turns the harness keeps in transcripts,
# which it writes owner-only (0600); a copy must not be easier to read than its
# source on a machine whose ~/.claude sits in a home others can list.
FILE_MODE = 0o600
DIR_MODE = 0o700


def _mkdirs(path):
    """Create `path` and every missing folder above it, owner-only."""
    missing = []
    while not os.path.isdir(path):
        missing.append(path)
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    for d in reversed(missing):
        try:
            os.mkdir(d, DIR_MODE)
        except FileExistsError:
            pass


def _write_once(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, FILE_MODE)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)


def save(path, how, payload=None, command=None, data=None):
    """Keep the letter at `path` as a version, unless its last version is the
    same text. `how` says what made it ("after Edit", "before Write", …); the
    session, its transcript and the command come from the hook payload.
    → None when kept or when there was nothing new; a line saying why not."""
    path = os.path.realpath(path)
    try:
        if data is None:
            with open(path, "rb") as fh:
                data = fh.read()
    except FileNotFoundError:
        return None
    except OSError as err:
        return "%s: could not read it (%s)" % (path, err.strerror or err)
    digest = hashlib.sha256(data).hexdigest()
    folder = letter_dir(path)
    last = last_meta(folder)
    if last is not None and last.get("sha256") == digest:
        return None
    payload = payload if isinstance(payload, dict) else {}
    moment = _now()
    meta = {"at": moment.isoformat(timespec="seconds").replace("+00:00", "Z"),
            "machine": socket.gethostname().split(".")[0],
            "path": path, "how": how, "sha256": digest}
    if isinstance(payload.get("session_id"), str):
        meta["session"] = payload["session_id"]
    if command:
        meta["command"] = command[:COMMAND_LIMIT]
    turn = owner_turn(payload.get("transcript_path"))
    if turn:
        meta["owner_turn_at"] = turn[0]
        if last is None or last.get("owner_turn_at") != turn[0]:
            meta["owner_turn"] = turn[1]
    text = data.decode("utf-8", "replace")
    try:
        if last is None:
            before = predecessor(folder, path, text, command)
            if before:
                meta["from"] = before
        snap = os.path.join(folder, "snap")
        _mkdirs(snap)
        stem = moment.strftime("%Y%m%dT%H%M%S.%fZ")
        for n in range(10):
            name = os.path.join(snap, stem if n == 0 else "%s-%d" % (stem, n))
            try:
                _write_once(name + ".md", data)
                break
            except FileExistsError:
                continue
        else:
            return "%s: ten versions in the same microsecond" % path
        # The .json last, through a rename: a reader lists the .json, so the
        # text beside it is whole by the time it sees one.
        tmp = name + ".json.part"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, name + ".json")
    except OSError as err:
        return "%s: %s" % (folder, err.strerror or err)
    return None


def named_letters(command, cwd):
    """→ absolute paths of the outgoing letters a shell command names. A
    relative path is read from the `cd` that opens the command, else from the
    session's cwd; one with a glob or a variable in it is no single letter."""
    if not isinstance(command, str):
        return []
    base = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    m = CD.match(command)
    if m:
        d = os.path.expanduser((m.group(1) or m.group(2) or m.group(3)).replace("$HOME", "~"))
        base = d if os.path.isabs(d) else os.path.join(base, d)
    out = []
    for m in NAMED.finditer(command):
        p = m.group(1) or m.group(2) or m.group(3)
        if not p or "*" in p or "$" in p:
            continue
        p = os.path.normpath(os.path.join(base, os.path.expanduser(p)))
        if p not in out:
            out.append(p)
    return out


def save_named(command, cwd, payload, how):
    """Keep each letter the command names that is on disk. → the lines of what
    could not be kept."""
    failed = []
    for path in named_letters(command, cwd):
        if os.path.isfile(path):
            why = save(path, how, payload, command)
            if why:
                failed.append(why)
    return failed


def save_changed(top, rels, payload, command):
    """After a Bash command: keep each listed letter (relative to the work tree
    `top`) whose text is new. The command is kept with the letters it names;
    a letter it does not name changed some other way — an editor, a script the
    command ran — and says so. → the lines of what could not be kept."""
    failed = []
    for rel in rels:
        named = os.path.basename(rel) in (command or "")
        why = save(os.path.join(top, rel), "after Bash" if named else "found after Bash",
                   payload, command if named else None)
        if why:
            failed.append(why)
    return failed


UNSAVED = ("⚠️ comms-versions: a version of an outgoing letter was not saved — %s. "
           "Versions are what shows, after the send, what the owner changed (skill `letters` § 9); "
           "until this is fixed, the transcript is the only copy of this text.")


def unsaved_note(failed):
    return UNSAVED % "; ".join(failed) if failed else ""


def main():
    """PostToolUse on a Write, Edit or MultiEdit: keep the letter as written.
    PreToolUse on Bash: keep each letter the command names, as it lies before."""
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if tool == "Bash":
        event = "PreToolUse"
        failed = save_named(tool_input.get("command"), payload.get("cwd"), payload, "before Bash")
    elif tool in WRITE_TOOLS:
        event = "PostToolUse"
        path = tool_input.get("file_path")
        if not is_letter(path) or not os.path.isfile(path):
            return 0
        why = save(path, "after " + tool, payload)
        failed = [why] if why else []
    else:
        return 0
    if failed:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                                                 "additionalContext": unsaved_note(failed)}},
                         ensure_ascii=False))
    return 0


# --- reading ------------------------------------------------------------------

def chain(path):
    """→ [(folder, [meta path…])] of a letter, its oldest folder first: the
    folder of the letter at `path` and those it was renamed or moved from."""
    folder = letter_dir(path)
    out, seen = [], set()
    while folder and folder not in seen:
        seen.add(folder)
        metas = snapshots(folder)
        out.insert(0, (folder, metas))
        first = read_meta(metas[0]) if metas else None
        before = first.get("from") if first else None
        folder = os.path.join(os.path.dirname(folder), before) if isinstance(before, str) and before else None
    return out


TOKEN = re.compile(r"\s+|\S+")
CONTEXT = 8


def word_diff(old, new):
    """→ (text, words changed): `[-struck-]{+added+}`, unchanged runs longer
    than twice the context shortened to their ends."""
    a, b = TOKEN.findall(old), TOKEN.findall(new)
    out, changed = [], 0
    ops = difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
    for n, (op, i1, i2, j1, j2) in enumerate(ops):
        if op == "equal":
            run = a[i1:i2]
            words = [i for i, t in enumerate(run) if not t.isspace()]
            head = n > 0
            tail = n < len(ops) - 1
            if len(words) > CONTEXT * (head + tail):
                keep_head = run[:words[CONTEXT - 1] + 1] if head else []
                keep_tail = run[words[-CONTEXT]:] if tail else []
                joiner = " … " if head and tail else "… " if tail else " …"
                out.append("".join(keep_head) + joiner + "".join(keep_tail))
            else:
                out.append("".join(run))
            continue
        gone, came = "".join(a[i1:i2]), "".join(b[j1:j2])
        changed += sum(1 for t in a[i1:i2] if not t.isspace()) + sum(1 for t in b[j1:j2] if not t.isspace())
        if gone.strip():
            out.append("[-%s-]" % gone)
        if came.strip():
            out.append("{+%s+}" % came)
    return "".join(out), changed


def frontmatter_changes(old, new):
    """→ "key: a → b" for each top-level scalar that differs."""
    a = fmmod.scalar_keys(split(old)[0])
    b = fmmod.scalar_keys(split(new)[0])
    out = []
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            out.append("%s: %s → %s" % (key, "—" if a.get(key) in (None, "") else a.get(key),
                                        "—" if b.get(key) in (None, "") else b.get(key)))
    return out


if __name__ == "__main__":
    sys.exit(main())
