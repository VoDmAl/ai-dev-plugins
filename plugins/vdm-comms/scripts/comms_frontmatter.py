#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Minimal YAML-frontmatter reader — stdlib only, vendored on purpose.

Why vendored rather than PyYAML. Three repositories arrived at "stdlib only"
independently (the meetings relay, §А5): a plugin that brings PyYAML becomes
the first third-party dependency in a project that has none, and then every
write into the meetings directory depends on a `pip install` having happened.
The whole "the hook blocks every write on a machine without the dependency"
fork disappears together with the dependency. Price: this file, once.

Scope is deliberately small — the subset that actually appears in meeting and
series frontmatter:

    key: value            scalars: bare, 'single', "double", null/~, true/false
    key: [a, b]           flow sequences
    key:                  block sequences of scalars
      - a
      - b
    key:                  block sequences of mappings
      - name: x
        track: y
    key: |                block scalars — literal `|` and folded `>`, with the
      line one              chomping indicators `-` / `+` and an explicit
      line two              indentation digit; at the top level, inside a
                            nested mapping and inside a sequence item alike

Anything outside that subset is reported rather than guessed at: a parser that
silently returns half a document is the same failure mode as a gate that
silently returns success.
"""
from __future__ import annotations

import re

_KEY_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<key>[A-Za-z_][A-Za-z0-9_.-]*):(?P<rest>.*)$")
_ITEM_RE = re.compile(r"^(?P<indent>[ \t]*)-(?P<rest>.*)$")
# `|`, `>`, optionally with a chomping indicator and an indentation digit in
# either order (`|-`, `>+`, `|2`, `|2-`, `|-2`), optionally followed by a comment.
_BLOCK_RE = re.compile(r"^(?P<style>[|>])(?P<a>[+-]?)(?P<digit>[1-9]?)(?P<b>[+-]?)\s*(?:#.*)?$")


class FrontmatterError(Exception):
    """The document has frontmatter and it could not be read."""


def split_frontmatter(text):
    """Return (frontmatter_text, body_text). Both empty strings if absent."""
    if not text.startswith("---"):
        return "", text
    lines = text.split("\n")
    if lines[0].strip() != "---":
        return "", text
    for i in range(1, len(lines)):
        if lines[i].strip() in ("---", "..."):
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    raise FrontmatterError("frontmatter opened with `---` but never closed")


def _uncomment(rest):
    """`key:   # a note` has no value — the note is a comment, and a comment is
    never data. Found on a live file: `epic:   # MCP does not return the epic`
    read back as the epic being "# MCP does not return the epic"."""
    return "" if rest.strip().startswith("#") else rest


def _strip_trailing_comment(s):
    """Drop ` # …` after a value. A fully quoted string keeps its `#` — it is
    content — and so does a `#` glued to text (`https://x/#anchor`)."""
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s
    if s.startswith("["):
        close = s.rfind("]")
        if close != -1 and (not s[close + 1:].strip() or s[close + 1:].strip().startswith("#")):
            return s[: close + 1]
    m = re.search(r"\s+#", s)
    return s[: m.start()].rstrip() if m else s


def _scalar(raw):
    # The comment goes BEFORE anything is recognised. The old order checked
    # null / true / false first and cut the comment last, so `sent: false  # not
    # yet` came back as the string "false" — which every caller reads as "a
    # value is present", i.e. as SENT: the draft vanished from the unsent list.
    # Live in two repositories' meeting templates, from where it spreads into
    # every new meeting.
    s = _strip_trailing_comment(_uncomment(raw))
    if s == "" or s in ("null", "~", "Null", "NULL"):
        return None
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    if s in ("true", "True", "TRUE"):
        return True
    if s in ("false", "False", "FALSE"):
        return False
    return s


def _value(raw):
    """A flow list or a scalar — the flow list recognised after its comment is
    gone, so `people: []  # none yet` is an empty list and not the string "[]"."""
    s = _strip_trailing_comment(_uncomment(raw))
    if s.startswith("[") and s.endswith("]"):
        return _flow_seq(s)
    return _scalar(s)


def _flow_seq(raw):
    inner = raw.strip()[1:-1].strip()
    if not inner:
        return []
    return [_scalar(part) for part in inner.split(",")]


def _indent_of(line):
    return len(line) - len(line.lstrip(" \t"))


def _block_header(rest):
    """The block-scalar header in `rest`, or None."""
    m = _BLOCK_RE.match(rest.strip())
    if not m or (m.group("a") and m.group("b")):
        return None
    return m


def _read_block(lines, i, parent_indent, header):
    """Read a block scalar whose header sits on line i-1 at `parent_indent`.
    Returns (value, next_i).

    Field case, 2026-09-23: a repository whose own rule is that a letter's goal
    has two halves, each on its own line, writes `goal: |` in 92 files. This
    reader stopped on the first continuation line with "cannot read line N", the
    hook turned that into a blocked write, and the only way out was to squeeze
    two sentences into one quoted line — the linter dictating a worse document.
    A block scalar is ordinary YAML; reading it is the whole fix."""
    style = header.group("style")
    chomp = header.group("a") or header.group("b")
    digit = header.group("digit")
    n = len(lines)
    block_indent = parent_indent + int(digit) if digit else None
    raw = []
    while i < n:
        line = lines[i]
        if not line.strip():
            raw.append("")
            i += 1
            continue
        ind = _indent_of(line)
        if block_indent is None:
            if ind <= parent_indent:
                break
            block_indent = ind
        if ind < block_indent:
            break
        raw.append(line[block_indent:])
        i += 1
    # Blank lines after the last content line belong to the chomping decision,
    # not to the text; and they may be the separator before the next key.
    trailing = 0
    while raw and raw[-1] == "":
        raw.pop()
        trailing += 1
    if style == "|":
        text = "\n".join(raw)
    else:
        # Folded: lines of one paragraph join with a space, a blank line is a
        # line break. More-indented lines keep their own line, as in YAML.
        out, para = [], []
        for ln in raw:
            if ln == "":
                if para:
                    out.append(" ".join(para))
                    para = []
                out.append("")
            elif ln[:1] in (" ", "\t"):
                if para:
                    out.append(" ".join(para))
                    para = []
                out.append(ln)
            else:
                para.append(ln)
        if para:
            out.append(" ".join(para))
        text = "\n".join(out).replace("\n\n", "\n")
    if chomp == "-" or not raw:
        return text, i
    if chomp == "+":
        return text + "\n" * (trailing + 1), i
    return text + "\n", i


def _continuation_error(lines, i, key):
    """A value spread over several lines without a block header. Name the shape
    rather than the line: "cannot read line N" told the reader nothing about
    what to write instead."""
    return FrontmatterError(
        "cannot read line %d: `%s:` continues on the next line — a value over "
        "several lines needs a block scalar (`%s: |`) or one quoted line"
        % (i + 1, key, key))


def parse(fm_text):
    """Parse frontmatter text into a dict. Raises FrontmatterError."""
    data = {}
    lines = [ln for ln in fm_text.split("\n")]
    i = 0
    n = len(lines)
    last_scalar = None
    while i < n:
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        m = _KEY_RE.match(line)
        if not m or _indent_of(line) != 0:
            if last_scalar is not None and _indent_of(line) > 0:
                raise _continuation_error(lines, i, last_scalar)
            raise FrontmatterError("cannot read line %d: %r" % (i + 1, line))
        key = m.group("key")
        rest = _uncomment(m.group("rest"))
        last_scalar = None
        if _strip_trailing_comment(rest).startswith("[") and _strip_trailing_comment(rest).endswith("]"):
            data[key] = _value(rest)
            i += 1
            continue
        header = _block_header(rest)
        if header:
            data[key], i = _read_block(lines, i + 1, 0, header)
            continue
        if rest.strip():
            data[key] = _scalar(rest)
            last_scalar = key
            i += 1
            continue
        # Block value: a sequence, a nested mapping, or nothing.
        i += 1
        items = []
        mapping = {}
        while i < n:
            nxt = lines[i]
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                i += 1
                continue
            im = _ITEM_RE.match(nxt)
            # A block sequence may sit at indent 0 — that is ordinary YAML, and
            # it is what one of the field repositories writes:
            #     people:
            #     - some-person
            # So the end of a block value is the next KEY at indent 0, never
            # just "indent 0". Reading it as the end cost this parser every
            # `index.md` in that repository on its first run.
            if _indent_of(nxt) == 0 and not im:
                break
            if im:
                item_indent = _indent_of(nxt)
                first = im.group("rest")
                fm_ = _KEY_RE.match(first.strip())
                if fm_:
                    # `- key: value` → a mapping item; collect its siblings.
                    entry = {}
                    k = fm_.group("key")
                    # The first key of an item sits after "- ", so its block
                    # content is indented past the dash.
                    key_col = item_indent + (len(nxt) - len(nxt.lstrip(" \t-")) - item_indent)
                    hdr = _block_header(fm_.group("rest"))
                    if hdr:
                        entry[k], i = _read_block(lines, i + 1, key_col, hdr)
                    else:
                        entry[k] = _scalar(fm_.group("rest"))
                        i += 1
                    while i < n:
                        cont = lines[i]
                        if not cont.strip():
                            i += 1
                            continue
                        if _indent_of(cont) <= item_indent:
                            break
                        cm = _KEY_RE.match(cont)
                        if not cm:
                            raise FrontmatterError(
                                "cannot read line %d inside `%s`: %r" % (i + 1, key, cont)
                            )
                        hdr = _block_header(cm.group("rest"))
                        if hdr:
                            entry[cm.group("key")], i = _read_block(
                                lines, i + 1, _indent_of(cont), hdr)
                            continue
                        entry[cm.group("key")] = _scalar(cm.group("rest"))
                        i += 1
                    items.append(entry)
                    continue
                items.append(_scalar(first))
                i += 1
                continue
            km = _KEY_RE.match(nxt)
            if km:
                hdr = _block_header(km.group("rest"))
                if hdr:
                    mapping[km.group("key")], i = _read_block(lines, i + 1, _indent_of(nxt), hdr)
                    continue
                raw_v = _strip_trailing_comment(_uncomment(km.group("rest")))
                if raw_v.startswith("[") and raw_v.endswith("]"):
                    mapping[km.group("key")] = _flow_seq(raw_v)
                    i += 1
                    continue
                if raw_v:
                    mapping[km.group("key")] = _scalar(raw_v)
                    i += 1
                    continue
                # An empty nested value may open a list of scalars — one level of
                # `key → list`, which is what live people profiles carry
                # (`identity:` → `git:` → `- "Name <mail>"`). Items may sit deeper
                # than the key or level with it; both are YAML.
                sub_indent = _indent_of(nxt)
                j, sub_items = i + 1, []
                while j < n:
                    ln = lines[j]
                    if not ln.strip() or ln.lstrip().startswith("#"):
                        j += 1
                        continue
                    ind = _indent_of(ln)
                    im2 = _ITEM_RE.match(ln)
                    if ind < sub_indent or not im2 or (ind == sub_indent and not im2):
                        break
                    if _KEY_RE.match(im2.group("rest").strip()):
                        break  # a list of mappings here: outside the subset, refused below
                    sub_items.append(_scalar(im2.group("rest")))
                    j += 1
                if sub_items:
                    mapping[km.group("key")] = sub_items
                    i = j
                    continue
                mapping[km.group("key")] = None
                i += 1
                continue
            raise FrontmatterError("cannot read line %d inside `%s`: %r" % (i + 1, key, nxt))
        if items and mapping:
            # `links:` → `blocks:` → `- X`: a mapping whose values are lists.
            # Outside the subset; the old code folded both into one list and
            # returned it as if that were the document.
            raise FrontmatterError(
                "`%s:` is a mapping whose values are lists or mappings — outside what this "
                "reader supports; write the inner lists in flow form (`blocks: [X, Y]`)" % key)
        if items:
            data[key] = items
        elif mapping:
            data[key] = mapping
        else:
            data[key] = None
    return data


def scalar_keys(fm_text):
    """Top-level `key: value` pairs of a frontmatter block, read line by line.

    For callers that need one flag or two (`draft:`, `sent:`) from files that
    are not meetings — letters, ticket drafts — whose frontmatter may carry
    shapes `parse` refuses. Refusing the whole file there would drop exactly
    the document the caller was looking for. A block value (a list, a nested
    mapping) comes back as None, the same as an empty scalar.

    The value is read on its own line and nowhere else. That is the point:
    `^sent:\\s*\\S` looked like "a sent: with a value" and was not — `\\s`
    crosses the newline, so an empty `sent:` followed by `url:` read as sent,
    and a ticket draft 131 days old vanished from the list of unsent drafts.
    """
    out = {}
    for line in fm_text.split("\n"):
        m = _KEY_RE.match(line)
        if not m or _indent_of(line) != 0:
            continue
        out[m.group("key")] = _scalar(m.group("rest"))
    return out


def read(path):
    """Read a file → (data, body). Missing frontmatter yields ({}, text)."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    fm_text, body = split_frontmatter(text)
    if not fm_text.strip():
        return {}, body
    return parse(fm_text), body
