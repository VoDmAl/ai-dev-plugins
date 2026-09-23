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

Anything outside that subset is reported rather than guessed at: a parser that
silently returns half a document is the same failure mode as a gate that
silently returns success.
"""
from __future__ import annotations

import re

_KEY_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<key>[A-Za-z_][A-Za-z0-9_.-]*):(?P<rest>.*)$")
_ITEM_RE = re.compile(r"^(?P<indent>[ \t]*)-(?P<rest>.*)$")


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


def _scalar(raw):
    s = raw.strip()
    if s == "" or s in ("null", "~", "Null", "NULL"):
        return None
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    if s in ("true", "True", "TRUE"):
        return True
    if s in ("false", "False", "FALSE"):
        return False
    # Strip a trailing comment only when it is clearly one (preceded by space).
    m = re.search(r"\s+#", s)
    if m:
        s = s[: m.start()].rstrip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    return s


def _flow_seq(raw):
    inner = raw.strip()[1:-1].strip()
    if not inner:
        return []
    return [_scalar(part) for part in inner.split(",")]


def _indent_of(line):
    return len(line) - len(line.lstrip(" \t"))


def parse(fm_text):
    """Parse frontmatter text into a dict. Raises FrontmatterError."""
    data = {}
    lines = [ln for ln in fm_text.split("\n")]
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        m = _KEY_RE.match(line)
        if not m or _indent_of(line) != 0:
            raise FrontmatterError("cannot read line %d: %r" % (i + 1, line))
        key = m.group("key")
        rest = m.group("rest")
        if rest.strip().startswith("[") and rest.strip().endswith("]"):
            data[key] = _flow_seq(rest)
            i += 1
            continue
        if rest.strip():
            data[key] = _scalar(rest)
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
                        entry[cm.group("key")] = _scalar(cm.group("rest"))
                        i += 1
                    items.append(entry)
                    continue
                items.append(_scalar(first))
                i += 1
                continue
            km = _KEY_RE.match(nxt)
            if km:
                mapping[km.group("key")] = _scalar(km.group("rest"))
                i += 1
                continue
            raise FrontmatterError("cannot read line %d inside `%s`: %r" % (i + 1, key, nxt))
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
