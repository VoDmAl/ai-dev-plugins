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

What the journal never saw is looked for in the project's mail and chats (the
access layer, 2026-11-04, its commit 0538d95): a letter the owner sent by hand
gets a proof that can be checked, the Message-ID found in Sent or the chat
message's id, instead of their word. What left is still their text, so such an
id gets the same note as `owner` (RECONCILE). And the 0 now says who the send
went to, on a second line, so a real id on the wrong letter is caught
(`other_recipients`). Crystal `comms-sent-proof-hand-sent`, DL #3.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_frontmatter as fmmod  # noqa: E402

# The versions of a letter are kept from the processes this module already
# runs — before a write and after a shell command (comms_versions.py). A
# recorder must never take the gate down with it: anything it raises is
# swallowed here, and the gate answers as if it were not there.
try:
    import comms_versions as vermod  # noqa: E402
except Exception:  # pragma: no cover — a broken recorder, the gate goes on
    vermod = None


def _keep(call, *args):
    """→ what the recorder returned, or None when it failed or is absent."""
    if vermod is None:
        return None
    try:
        return getattr(vermod, call)(*args)
    except Exception:
        return None

PROOF_KEY = "sent-proof"
OWNER = "owner"

HOWTO = """\
  A letter becomes "sent" by what shows it left, not by the assistant's word.
  Add to the frontmatter, next to `sent:`:
    sent-proof: <id from the sending tool's answer>
                 — a mail's message_id, a chat message's id or link, a ticket write's `audit` id;
                   where the access layer is on this machine, it is checked against its journal of sends
    sent-proof: <the letter's Message-ID from Sent, or the chat message's id or `t.me/c/…` link>
                 — the owner sent it by hand; the access layer looks in the project's mail and chats
    sent-proof: owner
                 — the owner said, in this conversation, that they sent this letter themselves
"""

NOT_CONFIRMED = (
    "🚫 comms-draft-guard: the access layer does not confirm the proof in `sent-proof:`:\n"
    "    %s\n\n"
    "  An id it finds for this project neither among its sends nor in the project's mail and chats is invented or\n"
    "  another project's, or newer than what it has collected.\n"
    + HOWTO
    + "\n  Sent a moment ago: it shows after the next collection — write again then.\n"
    "  A letter older than the window its line names, or a direct message outside the project's chats: it will never\n"
    "  show there, and `sent-proof: owner` is the way.\n"
    "  Neither in hand → the letter is still a draft: `draft: true`, and no `sent:`.\n"
)

OTHER_RECIPIENTS = (
    "🚫 comms-draft-guard: the send in `sent-proof:` went to someone else, by the access layer:\n"
    "    %s\n\n"
    "  Nobody in the letter's `to:` is among those it went to. Either the id is another letter's — find this one's —\n"
    "  or `to:` is not who got the letter (the owner changed it when sending): make it who did.\n"
    + HOWTO
    + "\n  Neither in hand → the letter is still a draft: `draft: true`, and no `sent:`.\n"
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

VERSIONS_CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "comms-versions.py")

# The owner sent it by hand: what left is the owner's text, and it can differ
# from this copy. Field case (program, 2026-10-18): a reply sent from the mail
# client went out with the greeting and a request rewritten — the «Hi» went from
# the greeting, and a question to one person became a promise to ask another; both
# surfaced only because the agent compared Sent with the draft when asked. The
# moment to say it is the one this module already sees: a letter turning sent
# with `sent-proof: owner`, or with an id the access layer found outside its
# journal of sends.
RECONCILE = (
    "📮 comms: the owner sent %s by hand, so what left may differ from this copy. "
    "Find the letter in Sent — through the access layer where it is on this machine — and make this "
    "copy the text that left; with `sent-proof: owner`, what you find there takes its place: the "
    "letter's Message-ID, or a chat message's id or `t.me/c/…` link, which can be checked. "
    "Each difference is a line in the project's journal of cuts (skill "
    "`letters` § 9), and a promise of the owner's that appears in it goes to their list at HQ. "
    "Then `\"" + VERSIONS_CLI.replace("%", "%%") + "\" diff <letter>` shows every version the letter "
    "had, each after the owner's turn that preceded it: the last step is what the owner changed in the "
    "mail client, the steps before it what they asked for in the conversation — lines for the same journal."
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

# A send the access layer found through a tool, as its line opens: `<moment>
# <via> …`. Any other 0 was seen in the project's mail or chats, sent by hand. A
# new tool or a reworded line then reads as by hand: one note too many, which
# costs less than a hand-sent letter nobody reconciles.
THROUGH_TOOL = re.compile(r"^\S+\s+(?:mail_send|zulip_send|tg_send|call_write|api_write\w*)(?:\s|$)")
# A letter it knows only by a reply to it. The second line then names who
# answered, not who it went to, and someone in cc may well be the one who did.
BY_REPLY = "на него ответили"
ADDRESS = re.compile(r"[\w.+-]+@[\w.-]+\.\w+")


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
    layer. → (code, lines): 0 there, the lines say when and who to · 1 not there,
    the line says why · 2 cannot tell — also when there is no access layer here,
    it fails, or it is slow; then the presence of the field is all that was
    checked."""
    binary = _access_layer()
    if not binary or not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        return 2, []
    try:
        run = subprocess.run([binary, "sent", _existing_dir(letter_path), proof],
                             capture_output=True, text=True, timeout=JOURNAL_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return 2, []
    lines = [l.strip() for l in ((run.stdout or "") + "\n" + (run.stderr or "")).splitlines() if l.strip()]
    return (run.returncode if run.returncode in (0, 1) else 2), lines


def letter_to(text):
    """→ the items of a letter's `to:`, in each shape letters have it: a flow
    list, a scalar, commas in a scalar, a block list. Measured 2026-11-04 on the
    1031 `*-out.md` of this machine: 238, 84 and 35 of them, 674 with no `to:`.
    A name beside an address stays in its item; an item with a comma in a name
    splits, and its halves name no profile, which reads as "cannot tell"."""
    try:
        fm_text, _ = fmmod.split_frontmatter(text)
    except fmmod.FrontmatterError:
        return []
    value = fmmod.scalar_keys(fm_text).get("to")
    if isinstance(value, str):
        raw = value.strip()
        parts = (raw[1:-1] if raw.startswith("[") and raw.endswith("]") else raw).split(",")
    else:
        block = re.search(r"(?m)^to:[ \t]*\n((?:[ \t]*-[^\n]*(?:\n|$))+)", fm_text)
        parts = [line.strip()[1:] for line in block.group(1).splitlines()] if block else []
    return [item for item in (part.strip().strip("'\"") for part in parts) if item]


def _people_dir(letter_path):
    """→ the profiles this letter's project reads, or None: then a word in `to:`
    cannot be read. Asks the access layer once, and only for a letter with such
    a word whose send has someone to compare it with."""
    try:
        import comms_config as cfgmod
        import comms_people as peoplemod
        root = cfgmod.project_root_of(_existing_dir(letter_path))
        cfg, err = cfgmod.load(root)
        return None if err else peoplemod.locate(root, cfg)["dir"]
    except Exception:  # no directory, no access layer, an answer it cannot give
        return None


def _one_profile(pdir, word):
    """→ the path of the one profile `word` names, or None."""
    try:
        import comms_people as peoplemod
        hits = peoplemod.find(pdir, word)
    except Exception:
        return None
    return hits[0] if len(hits) == 1 else None


def other_recipients(letter_path, text, first, second):
    """Did this send go to somebody other than the letter says? Refusing a real
    send costs the owner a word, so only a "yes" that holds refuses: every item
    of `to:` could be read, on the side the access layer answered with, and none
    of them is among those it went to. One in common is enough, and anything out
    of reach is "cannot tell" — that item may be the one who got it.

    Not "all of `to:`": the owner changes recipients in the mail client. Measured
    2026-11-04: of 232 letters with an id on this machine the access layer
    confirmed 19, and in the 5 where `to:` and its line could meet at all, 3
    could be compared and all 3 agreed in full. That is too few to justify
    anything stricter. An address is compared with addresses; a word — a `people/`
    slug, or what names one profile — with the people of a direct message, or by
    the addresses in its profile with those of a mail; a handle with a handle. A
    group or chat by name, and a Zulip target, compare with nothing."""
    if not second or BY_REPLY in first:
        return False
    if second.startswith("people: "):
        to_part, people_part = "", second[len("people: "):]
    else:
        to_part, _, people_part = second.partition("; people: ")
        to_part = to_part[len("to: "):] if to_part.startswith("to: ") else ""
    got_addresses = {a.lower() for a in ADDRESS.findall(to_part)}
    got_handles = {w.strip().lower() for w in to_part.split(",") if w.strip().startswith("@")}
    got_people = {p.strip().lower() for p in people_part.split(",") if p.strip()}
    if not (got_addresses or got_handles or got_people):
        return False
    items = letter_to(text)
    if not items:
        return False
    pdir = None
    for item in items:
        addresses = {a.lower() for a in ADDRESS.findall(item)}
        if addresses:
            if not got_addresses or addresses & got_addresses:
                return False
            continue
        if item.startswith("@"):
            if not got_handles or item.lower() in got_handles:
                return False
            continue
        if not (got_people or got_addresses):
            return False
        pdir = pdir or _people_dir(letter_path)
        path = _one_profile(pdir, item) if pdir else None
        if not path:
            return False
        if got_people:
            if os.path.splitext(os.path.basename(path))[0].lower() in got_people:
                return False
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                in_profile = {a.lower() for a in ADDRESS.findall(fh.read())}
        except OSError:
            return False
        if not in_profile or in_profile & got_addresses:
            return False
    return True


def proof_verdict(letter_path, keys, text):
    """What the access layer says of this letter's proof → (refusal, by_hand).
    `refusal` is None, or (the message to fill, the line to fill it with);
    `by_hand` — the id was found outside its journal of sends. No proof, or the
    owner's word, is not this function's question."""
    proof = keys.get(PROOF_KEY).strip() if has_proof(keys) else ""
    if not proof or proof.lower() == OWNER:
        return None, False
    code, lines = journal_says(letter_path, proof)
    first = lines[0] if lines else ""
    if code == 1:
        return (NOT_CONFIRMED, first or "no send with the id %s" % proof), False
    if code != 0:
        return None, False
    second = lines[1] if len(lines) > 1 else ""
    if other_recipients(letter_path, text, first, second):
        return (OTHER_RECIPIENTS, "the letter's `to:` is %s; the send — %s"
                % (", ".join(letter_to(text)), second)), False
    return None, not THROUGH_TOOL.match(first)


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
        # The letter as it lies before this write: an edit made outside any
        # tool call — the owner in an editor — is a version of its own.
        _keep("save", path, "before %s" % tool, payload)
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
    refusal, by_hand = proof_verdict(path, keys, after)
    if refusal is not None:
        sys.stderr.write(refusal[0] % refusal[1])
        return 2
    if by_hand or keys[PROOF_KEY].strip().lower() == OWNER:
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


def changed_letters(cwd):
    """→ (work tree, has HEAD, [letter relative to it…]) — the outgoing letters
    that differ from HEAD (added or modified) and the untracked ones — or None
    outside a git work tree. No HEAD yet — every letter is new."""
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
    rels = []
    for rel in _paths(changed) + _paths(untracked):
        if rel not in rels:
            rels.append(rel)
    return top, has_head, rels


def unproven_since_head(cwd, hand=None, changed=None):
    """Outgoing letters sent now without a proof that holds, and not sent in HEAD.
    → [(path relative to the work tree, why)], or None outside a git work tree —
    nothing to compare with, nothing is said. A list given as `hand` collects the
    letters that turned sent by the owner's hand in the last FRESH_SECONDS:
    `sent-proof: owner`, or an id found outside the journal of sends.

    Candidates are `changed_letters` — given as `changed` when the caller has
    them already; a letter as committed is not read at all. A letter sent in
    HEAD is history, as in the guard. A proof is asked of the journal only for a
    letter written in the last FRESH_SECONDS."""
    if changed is None:
        changed = changed_letters(cwd)
    if changed is None:
        return None
    top, has_head, rels = changed
    found = []
    for rel in rels:
        try:
            with open(os.path.join(top, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read(READ_LIMIT)
            keys = _keys(text)
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
        refusal, by_hand = proof_verdict(path, keys, text)
        if refusal is not None:
            said = ("the access layer does not confirm" if refusal[0] is NOT_CONFIRMED else "went to someone else")
            found.append((rel, where + ", `sent-proof:` " + said + ": " + refusal[1]))
        elif by_hand and hand is not None:
            hand.append(rel)
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
    cwd = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    changed = changed_letters(cwd)
    hand = []
    found = unproven_since_head(cwd, hand, changed) if changed is not None else None
    # Said after the command that marks a letter sent, not after every later
    # command that names `comms` within the window.
    hand = hand if "sent" in command else []
    note = RECONCILE % ", ".join("`%s`" % rel for rel in hand[:SHOWN]) if hand else ""
    unsaved = (_keep("save_changed", changed[0], changed[2], payload, command) or []) if changed else []
    # The letters it names, too: outside a git work tree there is nothing to
    # list by, and a command that commits leaves nothing that differs from HEAD.
    unsaved += _keep("save_named", command, cwd, payload, "after Bash") or []
    if unsaved:
        note = "\n\n".join(n for n in (note, vermod.unsaved_note(unsaved)) if n)
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
