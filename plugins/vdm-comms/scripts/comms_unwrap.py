#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_unwrap — hard-wrapped paragraphs in the text a draft sends out.

A paragraph wrapped at ~100 columns looks right wherever Markdown is rendered:
the renderer joins the lines. Mail, SMS, a chat or a CMS field keep every line
break, and the text arrives broken mid-sentence. The defect is invisible in the
editor and visible only to the recipient (crystal `outgoing-text-unwrapped`).

So the check is bound to where the text goes, not to the file type: a draft
that declares a `channel:` whose receiver does not render Markdown (`comms-lint`
reads `comms.markdown-channels`). What is checked is the text that is pasted —
everything after the `---` separator, or the whole body when the draft has none.

DETECTION, ported from the content project's `unwrap-markdown.py` (its version
of 2026-10-13). A paragraph is a run of non-blank prose lines, split before
every line that opens a construct of its own. Fences, tables and HTML runs are
not prose. A paragraph is wrapped when all of these hold:

  * it has two lines or more;
  * every line but the last is at least MIN_WIDTH long — a shorter line is a
    deliberate break (an address block, a greeting);
  * no line is longer than MAX_WIDTH — a text that already writes long lines is
    not wrapping;
  * the lines but the last lie within SPREAD of each other — machine wrapping
    leaves a hard right edge;
  * at least one of them ends mid-sentence.

Five classes of false findings were met on a live tree (2026-10-07); the first
two the content project fixed itself, the other three are fixed here:

  1. a heading and the line under it — a heading is one line by definition;
  2. a checklist line without a list marker, `[x] PROJ-123 …`;
  3. «label: value» lines without bold, `Now: …` / `Goal: …`;
  4. identifiers one per line without a fence, `auth_login_total — …`;
  5. a two-line message whose first line ends with a link.

Two more were met on the letters of three projects (2026-10-14): a label in
bold or italics, `**The table is a link:**`, whose colon stands inside the
emphasis, and a line ending with `→` before the example it introduces. Both end
where their author meant them to.

FIX. Each paragraph becomes one line: the first line as it is, the rest joined
with a single space. Two invariants are asserted before anything is written,
and a failed one leaves the file alone:

  * the text, whitespace-normalised, is the same — nothing was lost or added;
  * the structure is the same: as many lines open a heading, a list item, a
    `[x]` or a `label:`, and every heading and rule reads word for word as it
    did. The first invariant cannot see two lines merged into one by
    definition, and that is how the fixer broke a checklist and a heading on
    2026-10-07 while it passed. The count alone misses the heading: one that
    takes the line under it is still one heading — hence the second half. The
    structure is read more broadly than detection splits, so a construct that
    detection does not know refuses the fix instead of being swallowed.

Stdlib only, like the rest of the plugin.
"""
from __future__ import annotations

import re

MIN_WIDTH = 55   # a shorter line before a break is a deliberate break
MAX_WIDTH = 125  # a longer line means the text does not wrap at all
SPREAD = 25      # machine wrapping leaves a hard right edge

SEPARATOR_RE = re.compile(r"^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$")

# A line that opens a construct: it can start a paragraph, never continue one.
CONSTRUCT = re.compile(r"""
      \#{1,6}\s                          # heading
    | >                                  # blockquote
    | \|                                 # table row
    | (?:```|~~~)                        # fence
    | (?:---+|===+|\*\*\*+|___+)\s*$     # rule / setext underline
    | [-*+]\s                            # bullet
    | \d+[.)]\s                          # ordered item
    | <                                  # HTML
    | \[\^                               # footnote definition
    | \[[ xX]\]\s                        # class 2: a checklist line with no list marker
    | !\[                                # an image
    | \*\*[^*\n]{1,44}(?:\*\*\s*:|:\*\*) # **Field**: value
    | \([^)\n]{1,40}\)\s*$               # a bare annotation such as (47 chars)
    | [^\W\d_][\w-]*(?:[ ][\w-]+){0,3}:\s   # class 3: a label of up to four words
    | `?[^\W\d_][\w-]*(?:[_.][\w-]+)+`?(?=\s|$)   # class 4: an identifier opens the line
""", re.X)

# A construct that is one line by definition: what follows starts a paragraph of
# its own (class 1).
SINGLE_LINE = re.compile(r"\#{1,6}\s|(?:---+|===+|\*\*\*+|___+)\s*$")

TERMINAL = (".", "!", "?", ":", ";", "…", "»", '"', ")", "|", "→")
# Class 5: a line that ends with a link ends where its author meant it to.
ENDS_WITH_URL = re.compile(r"https?://\S+$")

# The structure the fix must keep, written apart from CONSTRUCT and read more
# broadly: a label of up to four words of any characters, digits and quotes too.
STRUCTURE = re.compile(r"""
      \#{1,6}\s
    | [-*+]\s | \d+[.)]\s
    | \[[ xX]\]\s
    | \*\*[^*\n]{1,44}(?:\*\*\s*:|:\*\*)
    | [^\s:]+(?:[ ][^\s:]+){0,3}:\s
""", re.X)


class Refused(Exception):
    """The fix would change the text or its structure; nothing is written."""


def outgoing(lines):
    """(start, end) of the text a draft sends: after the `---` separator, or
    the whole body when there is none. The frontmatter is never part of it."""
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() in ("---", "..."):
                start = i + 1
                break
    for i in range(start, len(lines)):
        if SEPARATOR_RE.match(lines[i]):
            return i + 1, len(lines)
    return start, len(lines)


def _prose(lines, start, end):
    """(index, line, is_prose) over lines[start:end]: fences, tables and HTML
    runs are not prose."""
    in_fence = in_html = False
    for i in range(start, end):
        raw = lines[i]
        s = raw.strip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            yield i, raw, False
            continue
        if in_fence:
            yield i, raw, False
            continue
        if not s:
            in_html = False
        elif s.startswith("<") and not in_html:
            in_html = True
        yield i, raw, not in_html and not s.startswith("|")


def paragraphs(lines, start, end):
    """Runs of prose lines of two or more, split before every construct."""
    cur = []
    for i, raw, is_prose in _prose(lines, start, end):
        s = raw.strip()
        if not s or not is_prose:
            if len(cur) > 1:
                yield cur
            cur = []
            continue
        # Four spaces of indent with nothing above is indented code, not a wrap.
        indent_code = len(raw) - len(raw.lstrip()) >= 4 and not cur
        if CONSTRUCT.match(s) or indent_code:
            if len(cur) > 1:
                yield cur
            cur = [] if indent_code or SINGLE_LINE.match(s) else [(i, raw)]
            continue
        cur.append((i, raw))
    if len(cur) > 1:
        yield cur


def _ends_sentence(raw):
    # Emphasis and a code span close after the punctuation they wrap: `**Label:**`.
    s = raw.rstrip().rstrip("*_`")
    return s.endswith(TERMINAL) or bool(ENDS_WITH_URL.search(s))


def is_wrapped(para, min_width=MIN_WIDTH, max_width=MAX_WIDTH):
    body = [raw for _, raw in para]
    if any(raw.endswith("  ") or raw.rstrip().endswith("\\") for raw in body[:-1]):
        return False  # an explicit Markdown hard break
    lens = [len(raw.rstrip()) for raw in body]
    head = lens[:-1]
    if min(head) < min_width or max(lens) > max_width:
        return False
    if max(head) - min(head) > SPREAD:
        return False
    return any(not _ends_sentence(raw) for raw in body[:-1])


def wrapped(lines, start=0, end=None):
    """The wrapped paragraphs of lines[start:end], as lists of (index, line)."""
    end = len(lines) if end is None else end
    return [p for p in paragraphs(lines, start, end) if is_wrapped(p)]


def _norm(text):
    return re.sub(r"\s+", " ", text).strip()


def _structure(lines, start, end):
    """(how many lines open a construct, the one-line constructs word for word)."""
    opening, single = 0, []
    for _, raw, prose in _prose(lines, start, end):
        s = raw.strip()
        if prose and STRUCTURE.match(s):
            opening += 1
        if prose and SINGLE_LINE.match(s):
            single.append(s)
    return opening, single


def unwrap(lines, paras, start=0, end=None):
    """`lines` with each paragraph in `paras` joined into one line. Raises
    Refused when the text or its structure would change."""
    end = len(lines) if end is None else end
    new = list(lines)
    for para in paras:
        first = para[0][1].rstrip()
        new[para[0][0]] = first + " " + " ".join(raw.strip() for _, raw in para[1:])
        for i, _ in para[1:]:
            new[i] = None
    joined = sum(len(p) - 1 for p in paras)
    out = [ln for ln in new if ln is not None]
    if _norm("\n".join(out)) != _norm("\n".join(lines)):
        raise Refused("the text would change")
    (opening, single), (opening_was, single_was) = (_structure(out, start, end - joined),
                                                    _structure(lines, start, end))
    if single != single_was:
        raise Refused("a heading would take the line under it")
    if opening != opening_was:
        raise Refused("a list item, a `[x]` or a `label:` line would be joined into the "
                      "line above it")
    return out
