#!/usr/bin/env python3
"""retro-corpus.py — the owner's turns from every session on this machine, for a retrospective.

The shared rules layer (`~/.claude/vdm/rules.md`, delivered by shared-rules.sh)
grows one field case at a time, and nothing tells whether a rule works: no
session sees another. The harness keeps every session as a transcript, and a
transcript already holds the facts a retrospective needs, so this script only
reads them out (crystal `rules-retro`):

  * who typed a turn — `turnOrigin: human`, or `origin.kind: human` on records
    older than that field, so a tool result, a hook, a peer session or an SDK
    caller never passes for the owner. A record with neither cannot be
    attributed and is left out. Two records the marks get wrong: a
    compaction's summary carries `turnOrigin: human` and is the model's
    retelling, so it is dropped; a slash command is markup, but its arguments
    are the owner's (`/vdm:learn <the correction>`), so they are kept;
  * what the assistant said just before it — a correction makes no sense
    without what it corrects (a 500-char tail lost the cause in 3 of 83 cases);
  * where the session ran — the first `cwd` of the transcript, not of the turn:
    a session that `cd`s into a subdirectory is still one project;
  * which rules the session actually had — the SessionStart attachment carries
    the text the hook printed. A date in a rule's `Origin` line is not that:
    on 01–07.10 the layer reached sessions only as a harness preview, and a
    rule counted from its date would be charged with failures in sessions
    that never saw it.

Deciding whether a turn is a correction, and of which rule, is not done here:
that is judgment, and the skill hands it to the assistant chunk by chunk. A
keyword pre-filter was tried and caught about one known case in six. Reading
is in two passes because the assistant's text is three quarters of the bytes:
the first with `--assistant-cap 0` picks the corrections, the second reads
only those (`--only`) with the answer before each.

Each turn has an id, `<session>.<n>` — the first eight characters of the
session id and the turn's place in it — so a pick made on one run finds the
same turns on the next, while live sessions keep adding theirs.

The chunks hold people's names and other projects' text. They are written
outside any repository — by default into a fresh directory under the system
temp dir — readable by this user only, and are never committed.

Usage:
  retro-corpus.py [--projects-dir DIR] [--out DIR] [--since YYYY-MM-DD]
                  [--only FILE] [--chunk-bytes N] [--assistant-cap N] [--turn-cap N]

Writes <out>/layers.md (each distinct set of delivered rule headings, by id),
<out>/chunk-NNN.md (the turns), and prints a summary: per heading, how many
sessions received it and how many owner turns those sessions hold — the
denominator a count of corrections is read against.

Exit: 0 = written, 2 = usage error or nothing to read.
"""

import argparse
import collections
import glob
import json
import os
import re
import sys
import tempfile

LAYER_MARK = "Cross-project rules"
HEADING_RE = re.compile(r"(?m)^## (.+?)\s*$")
ID_RE = re.compile(r"\b[0-9A-Za-z-]{1,8}\.\d+\b")
# A turn that is only harness markup — a `!` command, a slash command, its
# output — was typed by the owner but says nothing about the assistant. A slash
# command's arguments are the exception: `/vdm:learn <the correction>` is the
# owner's own channel for a correction, and dropping the markup with them left
# 52 such turns in 10 projects out of the first full pass (2026-10-18).
MARKUP_RE = re.compile(r"^\s*<(bash-|command-|local-command)")
COMMAND_NAME_RE = re.compile(r"<command-name>\s*(.*?)\s*</command-name>", re.S)
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.S)


def text_of(content):
    """The text parts of a message `content`, joined; '' when there are none."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content
                         if isinstance(p, dict) and p.get("type") == "text")
    return ""


def layer_of(attachment):
    """(headings, hidden) for the shared rules layer a hook attachment
    delivered, or None when it is some other hook's. What counts is what the
    session saw: when the harness put a long output into a file, only the
    preview was in context, and only the headings inside it were delivered."""
    if not isinstance(attachment, dict):
        return None
    command = str(attachment.get("command") or "")
    body = attachment.get("content")
    if not isinstance(body, str) or not body:
        body = str(attachment.get("stdout") or "")
    if "shared-rules.sh" not in command and LAYER_MARK not in body:
        return None
    hidden = body.lstrip().startswith("<persisted-output>")
    return tuple(HEADING_RE.findall(body)), hidden


def private_dir(path):
    """The output directory, readable by this user only — the chunks hold
    people's names and other projects' words. None names a fresh one under the
    temp dir (random suffix, mode 0700). A given path is created 0700, or, if it
    exists, must be a real directory of this user; it is then closed to others.
    → the path, or None with the reason printed."""
    if path is None:
        return tempfile.mkdtemp(prefix="vdm-retro-")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
    except OSError as e:
        print("retro-corpus: cannot create --out: %s" % e, file=sys.stderr)
        return None
    if not os.path.isdir(path) or os.path.islink(path) or st.st_uid != os.getuid():
        print("retro-corpus: --out %s is not a directory of this user" % path, file=sys.stderr)
        return None
    os.chmod(path, 0o700)
    return path


def write_private(path, text):
    """Write a file only this user can read, never through a symlink."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


def owner_words(said):
    """What a turn says from the owner: the text itself, a slash command as
    `/name <arguments>`, '' for markup with nothing of theirs in it."""
    if not MARKUP_RE.match(said):
        return said
    args = COMMAND_ARGS_RE.search(said)
    if not args or not args.group(1).strip():
        return ""
    name = COMMAND_NAME_RE.search(said)
    return ("%s %s" % (name.group(1) if name else "", args.group(1).strip())).strip()


def typed_by_person(record):
    origin = record.get("turnOrigin")
    if origin is not None:
        return origin == "human"
    kind = record.get("origin")
    return isinstance(kind, dict) and kind.get("kind") == "human"


def read_session(path, since, assistant_cap, turn_cap):
    """→ [turn dict] for one transcript, in order."""
    turns, layer, last_assistant, project, n = [], None, "", None, 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return turns
    with fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or rec.get("isSidechain"):
                continue
            cwd = rec.get("cwd")
            if project is None and isinstance(cwd, str) and cwd.strip("/"):
                project = os.path.basename(cwd.rstrip("/"))
            kind = rec.get("type")
            if kind == "attachment":
                got = layer_of(rec.get("attachment"))
                if got is not None:
                    layer = got
                continue
            if kind == "assistant":
                said = text_of((rec.get("message") or {}).get("content")).strip()
                if said:
                    last_assistant = said
                continue
            if kind != "user" or not typed_by_person(rec) or rec.get("isMeta"):
                continue
            # The summary a compaction leaves is marked as typed by a human,
            # but the model wrote it, retelling the session's corrections.
            if rec.get("isCompactSummary"):
                continue
            said = owner_words(text_of((rec.get("message") or {}).get("content")).strip())
            if not said:
                continue
            n += 1
            stamp = str(rec.get("timestamp") or "")
            if since and stamp[:10] < since:
                continue
            if len(said) > turn_cap:
                said = said[:turn_cap] + " […cut at %d chars]" % turn_cap
            before = last_assistant
            if assistant_cap <= 0:
                before = ""
            elif len(before) > assistant_cap:
                before = "[…] " + before[-assistant_cap:]
            session = str(rec.get("sessionId") or os.path.splitext(os.path.basename(path))[0])
            turns.append({
                "id": "%s.%d" % (session[:8], n),
                "project": project or os.path.basename(os.path.dirname(path)),
                "session": session,
                "date": stamp[:10],
                "layer": layer,
                "assistant": before,
                "owner": said,
            })
    return turns


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--out")
    ap.add_argument("--since")
    ap.add_argument("--only", help="a file naming the turn ids to keep")
    ap.add_argument("--chunk-bytes", type=int, default=200000)
    ap.add_argument("--assistant-cap", type=int, default=1000)
    ap.add_argument("--turn-cap", type=int, default=4000)
    args = ap.parse_args(argv)
    if args.since and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.since):
        print("retro-corpus: --since wants YYYY-MM-DD", file=sys.stderr)
        return 2
    only = None
    if args.only:
        try:
            only = set(ID_RE.findall(open(args.only, encoding="utf-8").read()))
        except OSError as e:
            print("retro-corpus: cannot read --only: %s" % e, file=sys.stderr)
            return 2
        if not only:
            print("retro-corpus: no turn ids in %s" % args.only, file=sys.stderr)
            return 2
    files = sorted(glob.glob(os.path.join(args.projects_dir, "*", "*.jsonl")))
    if not files:
        print("retro-corpus: no transcripts under %s" % args.projects_dir, file=sys.stderr)
        return 2

    turns = []
    for path in files:
        turns.extend(read_session(path, args.since, args.assistant_cap, args.turn_cap))
    # The denominator is counted before --only narrows the turns: a pick is
    # read against every session that could have produced it.
    sessions = collections.defaultdict(set)
    turns_with = collections.Counter()
    for t in turns:
        if t["layer"] is not None:
            for h in t["layer"][0]:
                sessions[h].add(t["session"])
                turns_with[h] += 1
    total = turns
    if only is not None:
        turns = [t for t in turns if t["id"] in only]
    if not turns:
        print("retro-corpus: no turns typed by a person in %d transcript(s)%s"
              % (len(files), " match --only" if only is not None else ""), file=sys.stderr)
        return 2
    turns.sort(key=lambda t: (t["date"], t["project"], t["session"]))

    out = private_dir(args.out)
    if out is None:
        return 2

    # Layers by id, in order of first appearance. L0 is "no layer in this
    # session", a fact of its own (a harness or a project without the hook),
    # not a gap in the data.
    ids, layers = {}, []
    for t in total:
        if t["layer"] is not None and t["layer"] not in ids:
            ids[t["layer"]] = "L%d" % (len(layers) + 1)
            layers.append(t["layer"])
    doc = ["# Rule layers the sessions received\n\n", "L0 — no rules layer in the session.\n\n"]
    for layer in layers:
        heads, hidden = layer
        doc.append("## %s — %d rule(s)%s\n\n" % (
            ids[layer], len(heads), ", the harness showed only a preview" if hidden else ""))
        doc.append("".join("- %s\n" % h for h in heads) + "\n")
    files = [("layers.md", "".join(doc))]

    chunks, buf, n = [], [], 0
    for t in turns:
        # The owner's lines after the first are indented: a pasted `### ` must
        # not read as the next entry's heading.
        entry = "### %s · %s · %s · %s\n" % (t["id"], t["project"], t["date"],
                                             ids.get(t["layer"], "L0"))
        if args.assistant_cap > 0:
            entry += "ASSISTANT: %s\n" % (t["assistant"].replace("\n", " ") or "—")
        entry += "OWNER: %s\n\n" % t["owner"].replace("\n", "\n  ")
        size = len(entry.encode("utf-8"))
        if buf and n + size > args.chunk_bytes:
            chunks.append(buf)
            buf, n = [], 0
        buf.append(entry)
        n += size
    if buf:
        chunks.append(buf)
    files += [("chunk-%03d.md" % k, "".join(buf)) for k, buf in enumerate(chunks, 1)]
    for name, text in files:
        try:
            write_private(os.path.join(out, name), text)
        except OSError as e:
            # A symlink planted where a chunk goes ends here (O_NOFOLLOW).
            print("retro-corpus: cannot write %s: %s" % (os.path.join(out, name), e), file=sys.stderr)
            return 2

    print("retro-corpus: %d turn(s) by a person, %d session(s), %d project(s), %s → %s"
          % (len(total), len({t["session"] for t in total}), len({t["project"] for t in total}),
             min(t["date"] for t in total) or "?", max(t["date"] for t in total) or "?"))
    if only is not None:
        print("kept: %d of %d id(s) named in %s" % (len(turns), len(only), args.only))
    print("written: %s — layers.md and %d chunk(s)" % (out, len(chunks)))
    print("delivered\tsessions\tturns\trule")
    for h in sorted(sessions, key=lambda h: (-len(sessions[h]), h)):
        print("\t%d\t%d\t%s" % (len(sessions[h]), turns_with[h], h))
    none = sum(1 for t in total if t["layer"] is None)
    if none:
        print("\t—\t%d\t(no rules layer in the session)" % none)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
