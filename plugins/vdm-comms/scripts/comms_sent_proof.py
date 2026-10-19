#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_sent_proof — does this write make an outgoing letter "sent" without proof?

Called with a hook payload on stdin, by two hooks:

    python3 comms_sent_proof.py < payload

  * `comms-draft-guard.sh`, PreToolUse on a Write, Edit or MultiEdit of
    `*/comms/*-out.md` — the letter on disk against the letter as the write
    would leave it;
  * `comms-sent-check.sh`, PostToolUse on Bash — the letters as the command
    left them against HEAD (`unproven_since_head`).

Exit: 0 allow · 2 refuse, or report after the fact (the reason on stderr) ·
3 cannot tell.

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

The shell is the main road, not a side door (DL #6). Measured 2026-10-13 on
this machine's transcripts, September–October: of the tool calls that wrote
`sent:` into a letter under `comms/`, 322 were Bash (`sed -i`, a python
`replace`, `cat >` a new file) against 163 Write and Edit. A command's effect
cannot be read off its text before it runs, so the check comes after it:
whatever the command did, a letter that is sent without proof now and was not
sent in HEAD — or is not committed yet — is named.

The field is checked, not only seen (vdm-comms 0.27.0, DL #7). The access layer
writes every send it makes into its journal and answers for an id from it:
`<its command> sent <directory of the letter> <id>` — 0 a send with this id
from this project is there, 1 it is not (invented, or another project's), 2
cannot tell (an id of a kind the journal does not keep, such as a link to a
ticket comment). Only 1 refuses; 2 must not — a "no" about what the journal
never kept would throw out a real send. No access layer on this machine, or no
answer: the presence of the field is all that is checked, as before. `owner`
is the owner's word and is never asked about.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_frontmatter as fmmod  # noqa: E402

PROOF_KEY = "sent-proof"
OWNER = "owner"

HOWTO = """\
  A letter becomes "sent" by what shows it left, not by the assistant's word.
  Add to the frontmatter, next to `sent:`:
    sent-proof: <id from the sending tool's answer>
                 — a mail's message_id, a chat message's id or link, a ticket write's `audit` id;
                   where the access layer is on this machine, it is checked against its journal of sends
    sent-proof: owner
                 — the owner said, in this conversation, that they sent this letter themselves
"""

NOT_IN_JOURNAL = (
    "🚫 comms-draft-guard: the proof in `sent-proof:` is not in the access layer's journal of sends:\n"
    "    %s\n\n"
    "  An id the journal does not have for this project is invented or another project's.\n"
    + HOWTO
    + "\n  Sent from the other machine a moment ago: its journal may not have arrived yet — write again in a minute.\n"
    "  Neither in hand → the letter is still a draft: `draft: true`, and no `sent:`.\n"
)

REFUSAL = (
    "🚫 comms-draft-guard: this write marks an outgoing letter as sent (`sent:`) without proof.\n\n"
    + HOWTO
    + "\n  Neither in hand → the letter is still a draft: `draft: true`, and no `sent:`.\n"
)

AFTER_BASH = (
    "🚫 comms-sent-check: an outgoing letter is marked sent (`sent:`) without a proof that holds, and HEAD does not have it sent:\n"
    "%s\n\n"
    "  The command has already run: the files are on disk as it left them.\n"
    + HOWTO
    + "\n  Neither in hand → put it back: `draft: true`, and no `sent:`.\n"
    "  A letter this session did not mark sent: tell the owner, and leave the file to them.\n"
)

# The owner sent it by hand: what left is the owner's text, and it can differ
# from this copy. Field case (program, 2026-10-18): a reply sent from the mail
# client went out with the greeting and a request rewritten — the «Hi» went from
# the greeting, and a question to one person became a promise to ask another; both
# surfaced only because the agent compared Sent with the draft when asked. The
# moment to say it is the one this module already sees: a letter turning sent
# with `sent-proof: owner`.
RECONCILE = (
    "📮 comms: the owner sent %s by hand (`sent-proof: owner`), so what left may differ from this copy. "
    "Find the letter in Sent — through the access layer where it is on this machine — and make this "
    "copy the text that left. Each difference is a line in the project's journal of cuts (skill "
    "`letters` § 9), and a promise of the owner's that appears in it goes to their list at HQ."
)


def _context(event, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}},
                     ensure_ascii=False))


# Outgoing letters, wherever their track is — the guard's path shape.
LETTERS = ":(glob)**/comms/*-out.md"
READ_LIMIT = 65536
SHOWN = 10
# One question to the journal costs about 0.35 s (measured 2026-10-13). After a
# shell command, only a letter written in this window is asked about: the
# command that wrote it is followed up once, and later commands that mention
# `comms` do not ask again about the same uncommitted letters.
FRESH_SECONDS = 300
JOURNAL_TIMEOUT = 10


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


def _access_layer():
    """→ the access layer's command on this machine, or None — the order
    comms-now uses, without its per-project setting (`comms_people.access_layer`)."""
    try:
        import comms_people as peoplemod
        return peoplemod.access_layer()
    except Exception:  # no directory, no holder, no checkout here — no journal to ask
        return None


def _existing_dir(path):
    d = os.path.dirname(os.path.abspath(path))
    while d and not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return d


def journal_says(letter_path, proof):
    """Is `proof` a send from the project the letter lives in? Asks the access
    layer's journal. → (code, line): 0 there · 1 not there, the line says why ·
    2 cannot tell — also when there is no access layer here, it fails, or it is
    slow; then the presence of the field is all that was checked."""
    binary = _access_layer()
    if not binary or not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        return 2, ""
    try:
        run = subprocess.run([binary, "sent", _existing_dir(letter_path), proof],
                             capture_output=True, text=True, timeout=JOURNAL_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return 2, ""
    lines = [l.strip() for l in ((run.stdout or "") + "\n" + (run.stderr or "")).splitlines() if l.strip()]
    return (run.returncode if run.returncode in (0, 1) else 2), (lines[0] if lines else "")


def proof_refused(letter_path, keys):
    """→ the access layer's line when the letter's proof is an id its journal
    does not have for this project; None otherwise (no proof is not this
    function's question)."""
    proof = keys.get(PROOF_KEY).strip() if has_proof(keys) else ""
    if not proof or proof.lower() == OWNER:
        return None
    code, line = journal_says(letter_path, proof)
    return (line or "no send with the id %s" % proof) if code == 1 else None


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
    if not is_sent(keys):
        return 0
    if not has_proof(keys):
        sys.stderr.write(REFUSAL)
        return 2
    line = proof_refused(path, keys)
    if line is not None:
        sys.stderr.write(NOT_IN_JOURNAL % line)
        return 2
    if keys[PROOF_KEY].strip().lower() == OWNER:
        _context("PreToolUse", RECONCILE % "this letter")
    return 0


def _git(top, *args):
    """→ stdout bytes, or None when git fails or is not there. Plumbing only:
    none of these calls refreshes or writes the index (see `edited_records` in
    comms-pending.py for why that matters on this owner's machines)."""
    try:
        proc = subprocess.run(["git", "-C", top] + list(args), capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout if proc.returncode == 0 else None


def _paths(raw):
    return [p for p in (raw or b"").decode("utf-8", "surrogateescape").split("\0") if p]


def unproven_since_head(cwd, hand=None):
    """Outgoing letters sent now without a proof that holds, and not sent in HEAD.
    → [(path relative to the work tree, why)], or None outside a git work tree —
    nothing to compare with, nothing is said. A list given as `hand` collects the
    letters that turned sent with `sent-proof: owner` in the last FRESH_SECONDS.

    Candidates are the letters that differ from HEAD (added or modified) and the
    untracked ones; a letter as committed is not read at all. A letter sent in
    HEAD is history, as in the guard. No HEAD yet — every letter is new. A proof
    is asked of the journal only for a letter written in the last FRESH_SECONDS."""
    top = _git(cwd, "rev-parse", "--show-toplevel")
    top = top.decode("utf-8", "surrogateescape").strip() if top else ""
    if not top:
        return None
    has_head = _git(top, "rev-parse", "--verify", "-q", "HEAD") is not None
    if has_head:
        changed = _git(top, "diff-index", "--name-only", "-z", "--no-renames",
                       "--diff-filter=AM", "HEAD", "--", LETTERS)
    else:
        changed = _git(top, "ls-files", "-z", "--cached", "--", LETTERS)
    untracked = _git(top, "ls-files", "-z", "--others", "--exclude-standard", "--", LETTERS)
    found, seen = [], set()
    for rel in _paths(changed) + _paths(untracked):
        if rel in seen:
            continue
        seen.add(rel)
        try:
            with open(os.path.join(top, rel), encoding="utf-8", errors="replace") as fh:
                keys = _keys(fh.read(READ_LIMIT))
        except OSError:
            continue
        if not is_sent(keys):
            continue
        path = os.path.join(top, rel)
        if has_proof(keys):
            proof = keys[PROOF_KEY].strip()
            try:
                if time.time() - os.path.getmtime(path) > FRESH_SECONDS:
                    continue
            except OSError:
                continue
            if proof.lower() == OWNER:
                if hand is not None:
                    committed = _git(top, "show", "HEAD:" + rel) if has_head else None
                    if committed is None or not is_sent(_keys(committed.decode("utf-8", "replace")[:READ_LIMIT])):
                        hand.append(rel)
                continue
        committed = _git(top, "show", "HEAD:" + rel) if has_head else None
        if committed is None:
            where = "not committed yet"
        elif not is_sent(_keys(committed.decode("utf-8", "replace")[:READ_LIMIT])):
            where = "unsent in HEAD"
        else:
            continue
        if not has_proof(keys):
            found.append((rel, where + ", no `sent-proof:`"))
            continue
        line = proof_refused(path, keys)
        if line is not None:
            found.append((rel, where + ", `sent-proof:` not in the access layer's journal: " + line))
    return found


def bash_verdict(payload):
    """→ exit code after a Bash call. Only a command that could have touched a
    letter is followed up: it names `comms`, an `-out.md`, or writes `sent:`."""
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return 3
    if not any(word in command for word in ("comms", "-out.md", "sent:")):
        return 0
    cwd = payload.get("cwd")
    hand = []
    found = unproven_since_head(cwd if isinstance(cwd, str) and cwd else os.getcwd(), hand)
    # Said after the command that marks a letter sent, not after every later
    # command that names `comms` within the window.
    hand = hand if "sent" in command else []
    note = RECONCILE % ", ".join("`%s`" % rel for rel in hand[:SHOWN]) if hand else ""
    if not found:
        if note:
            _context("PostToolUse", note)
        return 0
    lines = ["    %s — %s" % item for item in found[:SHOWN]]
    if len(found) > SHOWN:
        lines.append("    … and %d more" % (len(found) - SHOWN))
    sys.stderr.write(AFTER_BASH % "\n".join(lines))
    if note:
        sys.stderr.write("\n" + note + "\n")
    return 2


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, UnicodeDecodeError):
        return 3
    if not isinstance(payload, dict):
        return 3
    if payload.get("tool_name") == "Bash":
        return bash_verdict(payload)
    return verdict(payload)


if __name__ == "__main__":
    sys.exit(main())
