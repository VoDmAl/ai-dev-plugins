#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pymorphy3>=2.0", "natasha>=1.6"]
# ///
"""pii-scan.py — people, work identifiers and agent names in what this repository publishes.

This repository is public, and its history keeps whatever was ever committed. The
crystal docs/tasks/public-repo-cleanup records why a detector is needed at all: the
soft rule "may you keep it?" failed six times, and two manual grep passes in a row
missed people a detector then found — grep only finds what you already know.

It is dev tooling of THIS repository (DL #9): it ships to no user. Its two
dependencies are declared in the header above, so `uv run scripts/pii-scan.py`
installs them into uv's cache on first run and nothing lands in the work tree.

WHAT IT LOOKS FOR, AND WHERE THE KNOWLEDGE COMES FROM

  book      exact match against what the owner already keeps outside this repo,
            read at run time and never written here (DL #6):
              * people/ profiles of every project in the intercom registry —
                surnames, Latin slugs, e-mail addresses, phones, logins;
              * the registry's agent names, except this repository's own;
              * an optional private terms file (--terms, $PII_SCAN_TERMS) for
                names no registry knows: internal systems, teams, trackers.
            A first name alone is NOT here. The address books hold every common
            one, so it would block every fictional "Ivan" while identifying no
            one; a Cyrillic first name is the morph layer's job.
  morph     pymorphy3: a capitalised Cyrillic word with a first-name, surname or
            patronymic reading.
  ner       natasha: PER spans in lines that carry Cyrillic (a Russian model —
            on Latin-only lines it adds noise, not recall).
  pattern   task keys (ABC-123), Jira mentions [~login], e-mail addresses, URL
            hosts, phone numbers.
  identity  history only: an author or committer other than the public identity
            (this clone's user.name / user.email, or --identity).

scripts/pii-allow.txt lets ordinary words through (DL #8). It is public and is
reviewed in the commit that grows it, so nothing in it may identify anyone. The
book layer honours only its `common` and `public` kinds: a fictional example that
collides with a real person's surname is a finding — pick another surname.

MODES
  tree      tracked and untracked-but-not-ignored files, and their paths
  index     lines the staged diff adds, and the paths it adds
  history   every unique line of every blob reachable from any ref, every commit
            message, every path, every author and committer
  files     the files named on the command line

The full report goes OUTSIDE the repository (default: under $TMPDIR): it holds
the very strings it found. stdout carries a summary grouped by value.

Exit: 0 = clean, 1 = findings, 2 = setup error (a dependency, no address books,
a report path inside the repository), 3 = a line of --expect found nothing.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import Counter, defaultdict
from typing import NamedTuple

CYR = "А-ЯЁа-яё"
LETTERS = "A-Za-z" + CYR
WORD_RE = re.compile(rf"[{LETTERS}]+")
HAS_CYR_RE = re.compile(rf"[{CYR}]")
NAME_TAGS = frozenset({"Name", "Surn", "Patr"})
LAYERS = ("identity", "book", "pattern", "morph", "ner")

ALLOW_KINDS = {
    "word": "morph/ner: a word that names no one — jargon, a fictional example",
    "common": "book: an ordinary word that happens to be someone's surname or an agent's name",
    "public": "every layer: the owner's own public identity",
    "key": "pattern: a task-key prefix that is no tracker (UTF-8, PROJ-123)",
    "login": "pattern: a placeholder inside [~…]",
    "email": "pattern: an address or a domain that may be published",
    "host": "pattern: a URL host (or its parent domain) that may be published",
}

# Both are written so that this file does not match itself: digits come first
# in the key's character class, and the mention's tilde is an escape.
KEY_RE = re.compile(r"(?<![0-9A-Za-z_])([A-Z][0-9A-Z]{1,14})-(\d{1,7})(?![0-9A-Za-z_])")
MENTION_RE = re.compile(r"\[\x7e([^\]\s]+)\]")
EMAIL_RE = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})")
URL_HOST_RE = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://(?:[^@/\s]+@)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)")
SCP_HOST_RE = re.compile(r"(?i)(?<![\w.-])[\w.-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)+):(?!/)")
# Phone shapes, strict on purpose: a loose digit run meets dates, sizes and hashes
# on every line. A phone the address books know is matched by digits instead.
PHONE_RES = (
    re.compile(r"(?<![\w+])\+\d{1,3}[ -]?\(?\d{3}\)?[ -]?\d{3}[ -]?\d{2}[ -]?\d{2}(?!\d)"),
    re.compile(r"(?<![\w(])\(\d{3}\)[ -]?\d{3}[ -]\d{4}(?!\d)"),
    re.compile(r"(?<![\w+])8[ -]?\(?9\d{2}\)?[ -]?\d{3}[ -]?\d{2}[ -]?\d{2}(?!\d)"),
)
DIGIT_RUN_RE = re.compile(r"\+?\(?\d[\d ()-]{8,20}\d")


def die(msg: str) -> None:
    print(f"pii-scan: {msg}", file=sys.stderr)
    sys.exit(2)


def git(*args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], input=data, capture_output=True, check=True).stdout


def fold(s: str) -> str:
    return s.lower().replace("ё", "е")


def is_cyr(word: str) -> bool:
    return "\u0400" <= word[:1] <= "\u04ff"


def squash(s: str) -> str:
    """How a multi-word or hyphenated name is compared: case and separators gone."""
    return re.sub(r"[-_\s]+", "", fold(s))


def snippet(text: str, value: str, width: int = 70) -> str:
    i = text.find(value)
    if i < 0:
        i = fold(text).find(fold(value))
    i = max(i, 0)
    a, b = max(0, i - width), min(len(text), i + len(value) + width)
    return ("…" if a else "") + text[a:b].strip() + ("…" if b < len(text) else "")


# ---------------------------------------------------------------------------
# Morphology
# ---------------------------------------------------------------------------

class WordInfo(NamedTuple):
    tags: frozenset        # name grammemes of the readings scored 0.1 or more
    norms: frozenset       # the folded word and every normal form
    surn_norms: frozenset  # the folded word and the normal forms of surname readings
    given: bool            # reads as a first name or patronymic in the nominative
    known: bool            # some reading comes from the dictionary, not a guess


class Morph:
    """pymorphy3 behind a per-word cache: the same word recurs thousands of times.

    Two ways to compare, on purpose. A word in the TEXT is compared by all its
    normal forms, so "Петровой" still meets "Петров" when the analyser has no
    surname reading for that form. A SURNAME from an address book is stored by
    its surname readings only: the book "Котов" must not meet "Коты" through the
    reading "кот", nor "Петра" through the first name hidden in "Петров".

    Whether a word in an address book is a first name is read in the nominative
    singular only. Half of all surnames are also a first name's genitive plural
    ("Сидоров" of "Сидор"), and taking that reading dropped them from the book.
    """

    def __init__(self) -> None:
        import pymorphy3

        self._m = pymorphy3.MorphAnalyzer()
        self._cache: dict[str, WordInfo] = {}

    def info(self, word: str) -> WordInfo:
        hit = self._cache.get(word)
        if hit is None:
            raw = fold(word)
            tags, norms, surn_norms, given, known = set(), {raw}, {raw}, False, False
            for p in self._m.parse(word):
                gr = p.tag.grammemes
                if p.score >= 0.05:
                    norms.add(fold(p.normal_form))
                    if "Surn" in gr:
                        surn_norms.add(fold(p.normal_form))
                    if ("Name" in gr or "Patr" in gr) and "nomn" in gr and "sing" in gr:
                        given = True
                if p.score >= 0.1:
                    tags |= NAME_TAGS & gr
                known = known or p.is_known
            hit = WordInfo(frozenset(tags), frozenset(norms), frozenset(surn_norms), given, known)
            self._cache[word] = hit
        return hit


# ---------------------------------------------------------------------------
# Allowlist (public, in the repo)
# ---------------------------------------------------------------------------

class Allow:
    def __init__(self, path: str, morph: Morph) -> None:
        self.morph = morph
        self.path = path
        self.values: dict[str, set[str]] = defaultdict(set)
        self.norms: dict[str, set[str]] = defaultdict(set)
        self.count = 0
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except FileNotFoundError:
            die(f"allowlist not found: {path}")
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kind, _, value = line.partition(" ")
            value = value.strip()
            if kind not in ALLOW_KINDS or not value:
                die(f"{path}:{n}: expected '<kind> <value>', kind one of: {', '.join(ALLOW_KINDS)}")
            self.count += 1
            if kind in ("key", "login"):
                self.values[kind].add(value)
            elif kind in ("email", "host"):
                self.values[kind].add(fold(value))
            elif kind == "common":
                self.values[kind].add(squash(value))
                if is_cyr(value) and WORD_RE.fullmatch(value):
                    self.norms[kind] |= morph.info(value).norms
            else:  # word, public — compared word by word
                for w in WORD_RE.findall(value):
                    self.values[kind].add(fold(w))
                    if is_cyr(w):
                        self.norms[kind] |= morph.info(w).norms

    def word(self, w: str, *kinds: str) -> bool:
        """Is this single word let through by any of the kinds?"""
        f = fold(w)
        if any(f in self.values[k] for k in kinds):
            return True
        if is_cyr(w):
            norms = self.morph.info(w).norms
            return any(norms & self.norms[k] for k in kinds)
        return False

    def common(self, name: str) -> bool:
        """Is this name an ordinary word here? A Cyrillic one in any of its forms."""
        sq = squash(name)
        if sq in self.values["common"] or sq in self.values["public"]:
            return True
        if is_cyr(name) and WORD_RE.fullmatch(name):
            return bool(self.morph.info(name).norms & (self.norms["common"] | self.norms["public"]))
        return False

    def domain(self, host: str, *kinds: str) -> bool:
        h = fold(host).rstrip(".")
        for k in kinds:
            for v in self.values[k]:
                if h == v or h.endswith("." + v):
                    return True
        return False


# ---------------------------------------------------------------------------
# What the owner already knows: registry, people/ profiles, private terms
# ---------------------------------------------------------------------------

def registry_dir(override: str | None) -> str:
    """Same resolution as intercom_store_root: env, global config, default."""
    if override:
        return override
    root = os.environ.get("VDM_INTERCOM_ROOT", "")
    if not root:
        try:
            cfg = json.load(open(os.path.expanduser("~/.claude/vdm-plugins.json")))
            root = (cfg.get("intercom") or {}).get("root") or ""
        except (OSError, ValueError):
            root = ""
    root = os.path.expanduser(root or "~/.claude/vdm/intercom")
    return os.path.join(root, "_registry")


def load_registry(path: str) -> list[dict]:
    if not os.path.isdir(path):
        die(f"intercom registry not found: {path} (set VDM_INTERCOM_ROOT or --registry)")
    out = []
    for f in sorted(glob.glob(os.path.join(path, "*.json"))):
        if ".sync-conflict-" in f:
            continue
        try:
            out.append(json.load(open(f, encoding="utf-8")))
        except (OSError, ValueError):
            print(f"pii-scan: skipped unreadable registry entry {f}", file=sys.stderr)
    return out


def entry_tokens(e: dict) -> set[str]:
    toks = {e.get("identity") or ""}
    toks |= set(e.get("names") or [])
    for a in e.get("aliases") or []:
        toks.add(a)
        toks |= {p for p in a.split("/") if len(p) >= 4}
    for p in e.get("paths") or []:
        toks.add(os.path.basename(p.rstrip("/")))
    return {t.strip() for t in toks if t and len(t.strip()) >= 3}


FM_RE = re.compile(r"\A---\n(.*?)\n---[ \t]*(?:\n|\Z)", re.S)
KEY_LINE_RE = re.compile(r"([A-Za-z_][\w-]*):\s*(.*)$")
NAME_FIELDS = ("slug", "identity", "short-name", "maiden-name", "aliases", "patronymic")


def frontmatter(text: str) -> dict[str, list[str]]:
    """Top-level key -> its values, nested lines included. Tolerant on purpose:
    profiles are hand-written, and a parser that refused one would drop a person."""
    m = FM_RE.match(text)
    out: dict[str, list[str]] = defaultdict(list)
    if not m:
        return out
    key = None
    for line in m.group(1).splitlines():
        if line.lstrip().startswith("#"):
            continue  # a note about the person ("found in git, not confirmed"), not a value
        km = KEY_LINE_RE.match(line)
        if km and not line[:1].isspace():
            key, value = km.group(1), km.group(2)
        elif key and line[:1].isspace():
            value = re.sub(r"^\s*(?:-\s+)?(?:[\w-]+:\s*)?", "", line)
        else:
            continue
        value = value.split(" #", 1)[0].strip().strip("\"'[]")
        if value:
            out[key].append(value)
    return out


class Book:
    """Surnames, slugs, addresses and phones of the people the owner keeps profiles of."""

    def __init__(self, entries: list[dict], morph: Morph, allow: Allow) -> None:
        self.morph, self.allow = morph, allow
        self.cyr: dict[str, str] = {}      # name norm -> label; capitalised in the text
        self.lat: dict[str, str] = {}      # folded Latin token -> label
        self.literal: dict[str, str] = {}  # folded e-mail or login -> label
        self.phones: dict[str, str] = {}   # last ten digits -> label
        self.dirs: list[str] = []
        self.profiles = 0
        seen: set[str] = set()
        for e in entries:
            ident = e.get("identity") or "?"
            for root in e.get("paths") or []:
                for d, owners in self._people_dirs(root):
                    real = os.path.realpath(d)
                    if real in seen:
                        continue
                    seen.add(real)
                    self.dirs.append(d)
                    for f in sorted(glob.glob(os.path.join(d, "**", "*.md"), recursive=True)):
                        self._profile(f, f"{ident}:{os.path.relpath(f, d)}")
                    # comms.owners mixes people with roles ("владелец", "юристы"):
                    # a word counts when it reads as a surname, or is no
                    # dictionary word at all.
                    for o in owners:
                        if isinstance(o, str) and is_cyr(o) and WORD_RE.fullmatch(o):
                            info = morph.info(o)
                            if "Surn" in info.tags or not info.known:
                                self._name(o, f"{ident}:comms.owners")

    @staticmethod
    def _people_dirs(root: str):
        owners: list = []
        cands = ["people", "wiki/entities/people"]
        try:
            comms = json.load(open(os.path.join(root, ".claude", "vdm-plugins.json"))).get("comms") or {}
            if comms.get("people-dir"):
                cands.insert(0, str(comms["people-dir"]).strip("/"))
            owners = comms.get("owners") or []
        except (OSError, ValueError, AttributeError):
            pass
        first = True
        for c in cands:
            d = os.path.join(root, c)
            if os.path.isdir(d):
                yield d, (owners if first else [])
                first = False

    def _profile(self, path: str, label: str) -> None:
        base = os.path.basename(path)
        if base.startswith("_") or base.lower() in ("readme.md", "index.md"):
            return
        self.profiles += 1
        text = open(path, "rb").read().replace(b"\0", b"").decode("utf-8", "ignore")
        head = FM_RE.match(text)
        fm = frontmatter(text)
        # Every address anywhere in the frontmatter: an identity block lists the
        # person's git signatures as "Name (login) <address>".
        for em in EMAIL_RE.finditer(head.group(1) if head else ""):
            self.literal[fold(em.group(0))] = label
        h1 = re.search(r"^# (.+)$", text, re.M)
        if h1:
            self._name(h1.group(1), label)
        self._name(base[:-3], label)
        for k in NAME_FIELDS:
            for v in fm.get(k, []):
                self._name(v, label)
                if k == "identity":
                    for login in re.findall(r"\(([\w.-]{3,})\)", v):
                        self.literal[fold(login)] = label
                    if re.fullmatch(r"[\w.-]{4,}", v) and not v.isdigit():
                        self.literal[fold(v)] = label  # a bare handle
        for v in fm.get("corp-login", []):
            if len(v) >= 3:
                self.literal[fold(v)] = label
        for v in fm.get("phone", []):
            for part in v.split(","):
                digits = re.sub(r"\D", "", part)
                if len(digits) >= 10:
                    self.phones[digits[-10:]] = label

    def _name(self, text: str, label: str) -> None:
        """One name string: a heading, a file stem, a slug, a field value."""
        # "First Last (Nick), ORG", "Name (login) <address>": the name is what
        # comes before the first parenthesis, bracket, comma or dash.
        text = re.split(r"\s*(?:[(<,;]|\s[—–-]\s)", text, maxsplit=1)[0].strip()
        words = WORD_RE.findall(text)
        slug = bool(re.fullmatch(r"[a-z0-9]+(?:[-_.][a-z0-9]+)*", text))
        # One to four words, each capitalised (particles like "von" aside) — or a
        # slug. A sentence that found its way into a field is not a name.
        if not words or len(words) > 4 or not (slug or all(w[:1].isupper() or len(w) <= 3 for w in words)):
            return
        if self.allow.common(text):
            return
        latin = [w for w in words if not is_cyr(w) and (slug or (w[:1].isupper() and not w.isupper()))]
        for w in words:
            if len(w) < 3 or self.allow.common(w):
                continue
            if is_cyr(w):
                if not w[:1].isupper():
                    continue
                info = self.morph.info(w)
                if info.given:
                    continue  # a first name or a patronymic: the morph layer's
                for n in info.surn_norms:
                    self.cyr.setdefault(n, label)
            elif latin and w == latin[-1] and len(latin) > 1:
                self.lat.setdefault(fold(w), label)  # the last word of a full name

    @property
    def logins(self) -> re.Pattern | None:
        """Logins and handles as one regex: matched as whole tokens, any case."""
        if not hasattr(self, "_logins"):
            alts = sorted((re.escape(x) for x in self.literal if "@" not in x), key=len, reverse=True)
            self._logins = re.compile(rf"(?<![\w.@-])(?:{'|'.join(alts)})(?![\w@-])", re.I) if alts else None
        return self._logins

    def word(self, w: str) -> str | None:
        if is_cyr(w):
            if not w[:1].isupper():
                return None
            for n in self.morph.info(w).norms:
                if n in self.cyr:
                    return self.cyr[n]
            return None
        if len(w) > 1 and w.isupper():
            return None  # LIN, MARK: a constant or an acronym, not a name
        return self.lat.get(fold(w))


class Names:
    """Agent names from the registry, or the private terms: single Cyrillic words
    matched by normal form (an agent is declined like any noun), everything else
    by one regex with separators made optional."""

    def __init__(self, morph: Morph) -> None:
        self.morph = morph
        self.cyr: dict[str, str] = {}
        self.alts: dict[str, str] = {}   # squashed name -> label
        self.extra: list[tuple[re.Pattern, str]] = []
        self.sources: list[str] = []
        self._re: re.Pattern | None = None

    def add(self, name: str, label: str) -> None:
        name = name.strip()
        if len(name) < 3:
            return
        if is_cyr(name) and WORD_RE.fullmatch(name):
            for n in self.morph.info(name).norms:
                self.cyr.setdefault(n, label)
        else:
            self.alts.setdefault(squash(name), label)
            self.sources.append(name)
            self._re = None

    def add_regex(self, pattern: str, label: str) -> None:
        self.extra.append((re.compile(pattern), label))

    def __len__(self) -> int:
        return len(self.cyr) + len(self.alts) + len(self.extra)

    def regex(self) -> re.Pattern | None:
        if self._re is None and self.alts:
            parts = []
            for name in sorted(self.sources, key=len, reverse=True):
                pieces = [re.escape(p) for p in re.split(r"[-_\s]+", name) if p]
                parts.append(r"[-_\s]?".join(pieces))
            body = "|".join(dict.fromkeys(parts))
            self._re = re.compile(rf"(?<![{LETTERS}0-9])(?:{body})(?![{LETTERS}0-9])", re.I)
        return self._re

    def finditer(self, text: str):
        rx = self.regex()
        if rx:
            for m in rx.finditer(text):
                yield m, self.alts.get(squash(m.group(0)), "?")
        for rx2, label in self.extra:
            for m in rx2.finditer(text):
                yield m, label

    def word(self, w: str) -> str | None:
        if not is_cyr(w):
            return None
        for n in self.morph.info(w).norms:
            if n in self.cyr:
                return self.cyr[n]
        return None


def load_agents(entries: list[dict], own: list[dict], morph: Morph, allow: Allow) -> Names:
    own_tokens = {squash(t) for e in own for t in entry_tokens(e)}
    names = Names(morph)
    for e in entries:
        if e in own:
            continue
        for t in entry_tokens(e):
            if squash(t) in own_tokens or allow.common(t):
                continue
            names.add(t, e.get("identity") or "?")
    return names


DEFAULT_TERMS = "~/.claude/vdm/pii-terms.txt"


def default_terms() -> str | None:
    """The owner's private list, next to the vdm store: present on every machine
    that syncs it, absent in a clone elsewhere — then the coverage line says 0."""
    path = os.path.expanduser(DEFAULT_TERMS)
    return path if os.path.isfile(path) else None


def load_terms(path: str | None, morph: Morph) -> Names:
    """Private terms: one per line; `#` comments; filter-repo lines are accepted
    as they are (`literal==>replacement`, `regex:…==>…`), so the replacement list
    of the rewrite can be checked against the result of the rewrite."""
    terms = Names(morph)
    if not path:
        return terms
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        die(f"terms file not found: {path}")
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.split("==>", 1)[0]
        if line.startswith("regex:"):
            terms.add_regex(line[len("regex:"):], "terms")
        elif line.startswith("glob:"):
            continue
        else:
            terms.add(line[len("literal:"):] if line.startswith("literal:") else line, "terms")
    return terms


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

class Findings:
    def __init__(self) -> None:
        self.groups: dict[tuple[str, str, str], dict] = {}

    def add(self, layer: str, kind: str, value: str, item: "Item", label: str | None = None) -> None:
        key = (layer, kind, value)
        g = self.groups.get(key)
        if g is None:
            g = self.groups[key] = {"layer": layer, "kind": kind, "value": value, "label": label,
                                    "count": 0, "where": [], "context": snippet(item.text, value)}
        g["count"] += item.weight
        for loc in item.locs:
            if len(g["where"]) < 12 and loc not in g["where"]:
                g["where"].append(loc)

    def sorted(self) -> list[dict]:
        return sorted(self.groups.values(),
                      key=lambda g: (LAYERS.index(g["layer"]), g["kind"], -g["count"], g["value"]))


class Item:
    """One line of text to scan, where it was seen, and how many times."""
    __slots__ = ("text", "locs", "weight")

    def __init__(self, text: str, locs: list[str], weight: int = 1) -> None:
        self.text, self.locs, self.weight = text, locs, weight


# ---------------------------------------------------------------------------
# The scan
# ---------------------------------------------------------------------------

class Scanner:
    def __init__(self, morph: Morph, allow: Allow, book: Book, agents: Names, terms: Names, ner: bool) -> None:
        self.morph, self.allow, self.book, self.agents, self.terms = morph, allow, book, agents, terms
        self.use_ner = ner
        self.out = Findings()

    def scan(self, items: list[Item]) -> Findings:
        reported: list[set[str]] = []
        for it in items:
            reported.append(self._line(it))
        if self.use_ner:
            self._ner(items, reported)
        return self.out

    def _line(self, it: Item) -> set[str]:
        text, out, allow = it.text, self.out, self.allow
        done: set[str] = set()

        for m in KEY_RE.finditer(text):
            if m.group(1) not in allow.values["key"]:
                out.add("pattern", "task-key", m.group(0), it)
        for m in MENTION_RE.finditer(text):
            if m.group(1) not in allow.values["login"]:
                out.add("pattern", "mention", m.group(0), it)
        for m in EMAIL_RE.finditer(text):
            addr = m.group(0)
            label = self.book.literal.get(fold(addr))
            if label:
                out.add("book", "email", addr, it, label)
            elif fold(addr) not in allow.values["email"] and not allow.domain(m.group(1), "email", "host"):
                out.add("pattern", "email", addr, it)
        for rx in (URL_HOST_RE, SCP_HOST_RE):
            for m in rx.finditer(text):
                if not allow.domain(m.group(1), "host", "email"):
                    out.add("pattern", "host", m.group(1).lower(), it)
        for m in DIGIT_RUN_RE.finditer(text):
            digits = re.sub(r"\D", "", m.group(0))
            if len(digits) >= 10 and digits[-10:] in self.book.phones:
                out.add("book", "phone", m.group(0).strip(), it, self.book.phones[digits[-10:]])
        for rx in PHONE_RES:
            for m in rx.finditer(text):
                if re.sub(r"\D", "", m.group(0))[-10:] not in self.book.phones:
                    out.add("pattern", "phone", m.group(0), it)
        if self.book.logins:
            for m in self.book.logins.finditer(text):
                out.add("book", "login", m.group(0), it, self.book.literal.get(fold(m.group(0))))
                done.add(fold(m.group(0)))

        # A term inside an agent's name ("acme" in an agent called "acme-hq")
        # is the same finding twice: the first span reported wins.
        spans: list[tuple[int, int]] = []
        for kind, names in (("agent", self.agents), ("term", self.terms)):
            for m, label in names.finditer(text):
                a, b = m.span()
                if allow.common(m.group(0)) or any(a < y and x < b for x, y in spans):
                    continue
                out.add("book", kind, m.group(0), it, label)
                done.add(fold(m.group(0)))
                spans.append((a, b))

        for m in WORD_RE.finditer(text):
            w = m.group(0)
            if len(w) < 3 or fold(w) in done or allow.word(w, "public"):
                continue
            label = self.book.word(w)
            if label:
                out.add("book", "person", w, it, label)
                done.add(fold(w))
                continue
            for kind, names in (("agent", self.agents), ("term", self.terms)):
                label = names.word(w)
                if label and not allow.common(w):
                    out.add("book", kind, w, it, label)
                    done.add(fold(w))
                    break
            else:
                if is_cyr(w) and w[:1].isupper():
                    tags = self.morph.info(w).tags
                    if tags and not allow.word(w, "word"):
                        out.add("morph", "person", w, it)
                        done.add(fold(w))
        return done

    def _ner(self, items: list[Item], reported: list[set[str]]) -> None:
        from natasha import NewsEmbedding, NewsNERTagger

        tagger = NewsNERTagger(NewsEmbedding())
        idx = [i for i, it in enumerate(items) if HAS_CYR_RE.search(it.text)]
        # One line, one text: the model tags each on its own. Lines joined into
        # one document let a neighbour's words change a line's tags, so the same
        # history gave different findings from run to run — useless as a check.
        for i, markup in zip(idx, tagger.map([items[i].text for i in idx])):
            for span in markup.spans:
                if span.type != "PER":
                    continue
                value = " ".join(markup.text[span.start:span.stop].split())
                # What the model can add over the other layers is a Cyrillic word
                # the dictionary does not know: a word read as a name is already
                # the morph layer's, and a dictionary word without a name reading
                # is a sentence-initial noun ("Хук", "Ответ") — nine tenths of
                # what the model tags on this repository's prose. Latin words are
                # left to the book layer: the model is Russian.
                fresh = [w for w in WORD_RE.findall(value)
                         if w[:1].isupper() and len(w) >= 3 and is_cyr(w)
                         and fold(w) not in reported[i]
                         and not self.morph.info(w).known
                         and not self.allow.word(w, "word", "public")]
                if fresh:
                    self.out.add("ner", "person", value, items[i])


# ---------------------------------------------------------------------------
# Sources of text, per mode
# ---------------------------------------------------------------------------

def decode(blob: bytes) -> str | None:
    if b"\0" in blob[:8192]:
        return None
    return blob.decode("utf-8", "replace")


def tree_items(root: str) -> list[Item]:
    files = git("-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")
    items = []
    for f in sorted({f for f in files if f}):
        items.append(Item(f, [f"{f} (path)"]))
        p = os.path.join(root, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        text = decode(open(p, "rb").read())
        if text is None:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if line.strip():
                items.append(Item(line, [f"{f}:{n}"]))
    return items


def files_items(paths: list[str]) -> list[Item]:
    items = []
    for f in paths:
        try:
            text = decode(open(f, "rb").read())
        except OSError as exc:
            die(f"cannot read {f}: {exc}")
        items.append(Item(f, [f"{f} (path)"]))
        if text is None:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if line.strip():
                items.append(Item(line, [f"{f}:{n}"]))
    return items


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def index_items(root: str) -> list[Item]:
    items = []
    status = git("-C", root, "diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=AR").decode().split("\0")
    i = 0
    while i < len(status) - 1:
        code = status[i]
        if code.startswith("R"):
            path, i = status[i + 2], i + 3
        else:
            path, i = status[i + 1], i + 2
        items.append(Item(path, [f"{path} (path)"]))
    diff = git("-C", root, "diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "-M",
               "--diff-filter=ACMR").decode("utf-8", "replace")
    path, line_no = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            m = HUNK_RE.match(line)
            line_no = int(m.group(1)) if m else 0
        elif line.startswith("+") and path:
            if line[1:].strip():
                items.append(Item(line[1:], [f"{path}:{line_no}"]))
            line_no += 1
    return items


def history_items(root: str, reflog: bool) -> tuple[list[Item], dict]:
    revs = ["--all"] + (["--reflog"] if reflog else [])
    objects = git("-C", root, "rev-list", *revs, "--objects").decode("utf-8", "replace").splitlines()
    path_of: dict[str, str] = {}
    for line in objects:
        sha, _, path = line.partition(" ")
        if path:
            path_of.setdefault(sha, path)
    shas = list(path_of)
    checks = git("-C", root, "cat-file", "--batch-check=%(objectname) %(objecttype)",
                 data="\n".join(shas).encode()).decode().splitlines()
    blobs = [c.split()[0] for c in checks if c.endswith(" blob")]

    lines: dict[str, list] = {}
    raw = git("-C", root, "cat-file", "--batch", data="\n".join(blobs).encode())
    pos = 0
    for sha in blobs:
        nl = raw.index(b"\n", pos)
        size = int(raw[pos:nl].split()[2])
        body = raw[nl + 1:nl + 1 + size]
        pos = nl + 1 + size + 1
        text = decode(body)
        if text is None:
            continue
        path = path_of[sha]
        for line in set(text.splitlines()):
            if not line.strip():
                continue
            rec = lines.get(line)
            if rec is None:
                lines[line] = [1, [path]]
            else:
                rec[0] += 1
                if len(rec[1]) < 3 and path not in rec[1]:
                    rec[1].append(path)
    items = [Item(t, locs, n) for t, (n, locs) in sorted(lines.items())]

    paths = set(git("-C", root, "log", *revs, "--format=", "--name-only", "--no-renames")
                .decode("utf-8", "replace").splitlines()) | set(path_of.values())
    items += [Item(p, [f"{p} (path)"]) for p in sorted(p for p in paths if p)]

    log = git("-C", root, "log", *revs, "--format=%h%x1f%B%x1e").decode("utf-8", "replace")
    msg_lines: dict[str, list] = {}
    for rec in log.split("\x1e"):
        if "\x1f" not in rec:
            continue
        h, body = rec.strip("\n").split("\x1f", 1)
        for line in body.splitlines():
            if line.strip():
                msg_lines.setdefault(line, []).append(f"commit {h}")
    items += [Item(t, locs[:3], len(locs)) for t, locs in msg_lines.items()]

    ids = Counter()
    fmt = "%an%x1f%ae%x1f%cn%x1f%ce"
    for line in git("-C", root, "log", *revs, f"--format={fmt}").decode("utf-8", "replace").splitlines():
        an, ae, cn, ce = line.split("\x1f")
        ids[("author", f"{an} <{ae}>")] += 1
        ids[("committer", f"{cn} <{ce}>")] += 1
    stats = {"blobs": len(blobs), "unique_lines": len(lines), "paths": len(paths),
             "messages": len(msg_lines), "identities": ids}
    return items, stats


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("mode", choices=("tree", "index", "history", "files"))
    ap.add_argument("paths", nargs="*", help="files to scan (mode files)")
    ap.add_argument("--report", help="where the JSON report goes; must be outside the repository")
    ap.add_argument("--allow", help="allowlist (default: scripts/pii-allow.txt next to this script)")
    ap.add_argument("--registry", help="intercom registry dir (default: as intercom resolves it)")
    ap.add_argument("--terms", default=os.environ.get("PII_SCAN_TERMS") or default_terms(),
                    help=f"private terms file, outside the repo (default: $PII_SCAN_TERMS, else {DEFAULT_TERMS} if present)")
    ap.add_argument("--identity", help='public identity "Name <email>" (default: this clone\'s user.name/user.email)')
    ap.add_argument("--reflog", action="store_true", help="history: also objects reachable only from reflogs")
    ap.add_argument("--expect", help="file of regexes (one per line) every one of which must match a reported "
                                     "value — the recall check that makes a later zero mean something")
    ap.add_argument("--no-ner", action="store_true", help="skip the natasha layer (the slow one)")
    ap.add_argument("--quiet", action="store_true", help="no per-value lines on stdout, only the totals")
    args = ap.parse_args()

    try:
        root = git("rev-parse", "--show-toplevel").decode().strip()
    except subprocess.CalledProcessError:
        die("not inside a git repository")
    real_root = os.path.realpath(root)
    if args.mode == "files" and not args.paths:
        die("mode files needs at least one path")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    report = args.report or os.path.join(tempfile.gettempdir(), "pii-scan", f"{args.mode}-{stamp}.json")
    report = os.path.abspath(os.path.expanduser(report))
    if os.path.realpath(report).startswith(real_root + os.sep):
        die(f"the report would land inside the repository: {report}")

    try:
        morph = Morph()
    except ImportError as exc:
        die(f"{exc}. Run through uv, which installs the dependencies from the script header: "
            f"uv run {os.path.relpath(__file__)} {args.mode}")
    t0 = time.time()
    allow = Allow(args.allow or os.path.join(os.path.dirname(os.path.abspath(__file__)), "pii-allow.txt"), morph)
    entries = load_registry(registry_dir(args.registry))
    own = [e for e in entries if any(os.path.realpath(p) == real_root for p in e.get("paths") or [])]
    book = Book(entries, morph, allow)
    if not book.profiles:
        die("no people/ profiles found through the intercom registry — the exact layer would be empty")
    agents = load_agents(entries, own, morph, allow)
    terms = load_terms(args.terms, morph)

    stats: dict = {}
    if args.mode == "tree":
        items = tree_items(root)
    elif args.mode == "index":
        items = index_items(root)
    elif args.mode == "files":
        items = files_items(args.paths)
    else:
        items, stats = history_items(root, args.reflog)
    t1 = time.time()

    found = Scanner(morph, allow, book, agents, terms, not args.no_ner).scan(items)
    if args.mode == "history":
        if args.identity:
            expected = args.identity
        else:
            name = git("-C", root, "config", "user.name").decode().strip()
            email = git("-C", root, "config", "user.email").decode().strip()
            expected = f"{name} <{email}>"
        for (role, ident), n in stats.pop("identities").items():
            if ident != expected:
                found.add("identity", role, ident, Item(ident, [f"{n} commits"], n))
        stats["expected_identity"] = expected
    t2 = time.time()

    coverage = {
        "registry": len(entries), "own_entries": [e.get("identity") for e in own],
        "people_dirs": book.dirs, "profiles": book.profiles,
        "book_tokens": len(book.cyr) + len(book.lat) + len(book.literal) + len(book.phones),
        "agent_names": len(agents), "terms": len(terms), "terms_file": args.terms,
        "allow_entries": allow.count, "ner": not args.no_ner, "items": len(items),
        "seconds": {"load": round(t1 - t0, 1), "scan": round(t2 - t1, 1)}, **stats,
    }
    groups = found.sorted()
    os.makedirs(os.path.dirname(report), exist_ok=True)
    with open(report, "w", encoding="utf-8") as fh:
        json.dump({"mode": args.mode, "root": root, "generated": stamp, "coverage": coverage,
                   "findings": groups}, fh, ensure_ascii=False, indent=1)

    print(f"pii-scan {args.mode}: {len(items)} lines · books {len(book.dirs)} dirs, {book.profiles} profiles"
          f" · agents {len(agents)} · terms {len(terms)} · allow {allow.count}"
          f" · ner {'on' if not args.no_ner else 'off'} · {coverage['seconds']['load'] + coverage['seconds']['scan']:.0f}s")
    if not args.quiet:
        for g in groups:
            where = ", ".join(g["where"][:3])
            label = f"  [{g['label']}]" if g["label"] else ""
            print(f"  {g['layer']:<8} {g['kind']:<9} {g['value']}  ×{g['count']}  {where}{label}")
    per_layer = Counter(g["layer"] for g in groups)
    summary = ", ".join(f"{layer} {per_layer[layer]}" for layer in LAYERS if per_layer[layer]) or "none"
    print(f"distinct values: {len(groups)} ({summary}) · report: {report}")
    if args.expect:
        missing = expect(args.expect, groups)
        print(f"expected: {missing[0] - len(missing[1])}/{missing[0]} found"
              + (" · missing: " + ", ".join(missing[1]) if missing[1] else ""))
        if missing[1]:
            return 3
    return 1 if groups else 0


def expect(path: str, groups: list[dict]) -> tuple[int, list[str]]:
    """A zero from this scanner proves nothing unless the same scanner, on the
    text before the cleanup, finds every case the cleanup is about."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        die(f"expect file not found: {path}")
    pats = [ln.strip() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]
    values = [fold(g["value"]) for g in groups]
    missing = [p for p in pats if not any(re.search(p, v, re.I) for v in values)]
    return len(pats), missing


if __name__ == "__main__":
    sys.exit(main())
