#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-pending — who owes what, to whom, and by when.

An open checkbox has no second artefact to compare against, so "this item went
stale" is not detectable at all. The missing artefact is the **date the item
promised to be revisited**, written on the same line. With it, the signal is an
ordinary comparison — and that is the whole mechanism here.

## Two markers, one detector

Field repositories converged on two spellings of the same thing, and neither is
reducible to the other:

    - [ ] **<owner>** — <what> ⏰ 2026-09-26
    - [ ] **<owner>** — <what> ⏰ after: <the event that will signal>
    - [ ] <what> (due: 2026-09-26)

`⏰ after: <event>` cannot be written as `(due:)` — that is why both exist, not
an accident of history. `(due:)` is the crystal suite's own marker, so a
repository already using crystals writes the same thing in `docs/tasks/**` and
here without learning a second form.

The event word is read in either language (`после`, `after`, `когда`, `when`,
…). Reading is permissive on purpose: this tool reads text the project wrote,
and a project does not change language because a plugin was installed. What the
plugin *writes* is a different matter and is governed by `comms.labels`;
diagnostics like this one's output are the plugin talking to you, and stay in
English.

## Two scopes, and why a section changes the contract

`comms.pending-paths` says which files hold obligations. Inside those files:

  * a line inside a **declared section** (`comms.pending-sections`) is under the
    full contract — owner and date are both required;
  * anywhere else, only a line that already **carries a date marker** is an
    item, and the only violation available is a broken marker.

That is the suite's standing law — soft until named, binding once named —
applied to a heading. Naming `## Ожидаем ответы` as a waiting section is the act
that makes everything under it an obligation; without such a declaration a
checkbox is just a checkbox, and linting every checkbox in a repository is how
a linter gets switched off.

## Owner

Measured against 314 live items rather than against the documented contract,
because the two disagree. The written rule is `**<owner>** — <what>`; two
thirds of the corpus does not have that shape. What it does have:

    - [ ] 🔴 **[[../../people/x|Surname]] / Agent API — subject.**   owner inside the bold
    - [ ] ⏰ 2026-09-15 — Finance — what we expect                    owner not marked at all
    - ⏰ **2026-09-15** — `team`: what we expect                      the bold is the DATE

So: a people wikilink wins when it OPENS the head of the item (alone, or inside
the emphasis that opens it — further in, the person is the one being told,
asked or written to); otherwise the first emphasised fragment (bold or code
span) with everything after a separator and a trailing parenthesis cut off —
a declared name, a role word plus a declared name (`**agent limeflow**`), or
"we"; otherwise a name from `comms.owners` that the head starts with. The
whitelist is what keeps `**Решить судьбу GA-5168**` from being read as a
person — a bold fragment is a subject at least as often as it is an owner, and
no structural rule separates them.

In an `action` section the owner defaults to "us": the section already said
whose ball it is, and repeating it on every line is noise.

## Use

    comms-pending.py                     summary: overdue · 7 days · by event
    comms-pending.py --owner             the same, grouped by owner
    comms-pending.py --all               everything, including far-dated
    comms-pending.py --brief             one line, for a session-start reminder
    comms-pending.py --json              machine-readable
    comms-pending.py --lint [files]      contract violations
    comms-pending.py --lint --changed F  only lines absent from HEAD (the hook)

Exit: 0 clean, 1 violations (`--lint`) or something to say (`--brief`).
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fmmod  # noqa: E402

SOON_DAYS = 7
HEAD_CHARS = 160

FENCE_RE = re.compile(r"^(```|~~~)")
HEADING_RE = re.compile(r"^(#{1,2})\s+(.*?)\s*$")
ITEM_OPEN_RE = re.compile(r"^- \[ \]\s*(.*)$")
ITEM_DONE_RE = re.compile(r"^- \[[xX]\]")
ITEM_BULLET_RE = re.compile(r"^- (?!\[[ xX]\])\s*(.*)$")

BOLD_RE = re.compile(r"\*\*([^*]+?)\*\*")
CODE_RE = re.compile(r"`([^`]+?)`")
WIKI_ALIAS_RE = re.compile(r"\[\[[^\]|]*\|([^\]]*)\]\]")
WIKI_RE = re.compile(r"\[\[([^\]|]*)\]\]")
MDLINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
# U+1F100–1F2FF is not decoration-adjacent trivia: 🆕 lives there, and a flag
# the class did not know stayed glued to the front of the owner. ⏰ is left out
# on purpose — it is the date marker, and the head of an item steps over it
# with its date, not as a flag.
EMOJI_RE = re.compile(r"[\U0001F100-\U0001F2FF\U0001F300-\U0001FAFF☀-➿️⬀-⯿⏳]")

# `(due:)` — the crystal marker. A broken value is a violation in its own right:
# it looks like a promise and is invisible to every detector, which is the one
# state this marker exists to rule out.
DUE_ISO_RE = re.compile(r"\(due:\s*(\d{4})-(\d{2})-(\d{2})\s*\)")
DUE_ANY_RE = re.compile(r"\(due:\s*([^)]*)\)")

# `⏰` — the field marker. The gap allowance absorbs `⏰ **2026-09-15**` and
# `⏰ ~2026-09-15`, both of which occur live.
CLOCK_ISO_RE = re.compile(r"⏰[^\d]{0,40}?(\d{4})-(\d{2})-(\d{2})")
CLOCK_DMY_RE = re.compile(r"⏰[^\d]{0,40}?~?(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?")
# Each cue word starts at a word boundary: without it `к` matched the end of
# «синк 27.08» («a sync on 27.08» — history, not a promise) and dated the line.
LOOSE_DMY_RE = re.compile(
    r"(?:\b[Пп]ересмотр|\b[Сс]рок|\b[Rr]eview|\b[Dd]ue|\bк|\bдо|\bby)"
    r"\s*\**~?(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?\**")
EVENT_RE = re.compile(
    r"⏰\s*\**\s*(?:после|по событию|при|когда|after|once|upon|when|on)\b\s*[:—–-]?", re.I)

LEAD_CHARS = 80
LEAD_SEP_RE = re.compile(r"\s+(?:—|–|→)\s+|\s*:\s+")
PAREN_TAIL_RE = re.compile(r"\s*\([^()]*\)\s*$")
LEAD_CLOCK_RE = re.compile(r"⏰[^\d]{0,20}?~?(?:\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}(?:\.\d{4})?)\**")

# Read in either language; see the module docstring. A project writing "we" and
# a project writing "мы" mean the same group, and neither should have to say so
# in configuration.
US_WORDS = ("мы", "я", "we", "us", "i")
US_LABEL = "us"
NO_OWNER = "(no owner)"

SEND_WORDS_RE = re.compile(r"отправить|отправка|драфт|черновик|send\b|draft\b|📝", re.I)
OUT_LINK_RE = re.compile(r"\[\[([^\]|]*comms/[^\]|#]*-out)(?:\.md)?[^\]]*\]\]"
                         r"|\]\(([^)]*comms/[^)]*-out\.md)\)")
FILE_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")
LETTER_READ_LIMIT = 65536
PRUNE_DIRS = {"node_modules", "vendor", "dist", "build", "target", "__pycache__"}


# --------------------------------------------------------------------------- #
# text helpers
# --------------------------------------------------------------------------- #

def fold(text):
    return re.sub(r"\s+", " ", (text or "")).strip().lower()


def clean(text):
    text = WIKI_ALIAS_RE.sub(r"\1", text)
    text = WIKI_RE.sub(r"\1", text)
    text = MDLINK_RE.sub(r"\1", text)
    return text


def strip_emoji(text):
    return EMOJI_RE.sub("", text or "").strip()


def _boundary_find(hay, needle):
    """Index of `needle` in `hay`, both folded, not glued to a word.

    `kratos` must match `kratos-агент` and must not match inside a longer word:
    a two-letter team name in the whitelist would otherwise claim every item
    whose text happens to contain those letters.
    """
    if not needle:
        return -1
    i = hay.find(needle)
    while i != -1:
        before = hay[i - 1] if i else ""
        j = i + len(needle)
        after = hay[j] if j < len(hay) else ""
        if not before.isalnum() and not after.isalnum():
            return i
        i = hay.find(needle, i + 1)
    return -1


# --------------------------------------------------------------------------- #
# dates
# --------------------------------------------------------------------------- #

def _mkdate(y, m, d):
    try:
        return datetime.date(int(y), int(m), int(d))
    except ValueError:
        return None


def parse_date(line, today):
    """→ (date | None, kind) with kind ∈ iso | dmy | loose | event | broken | none."""
    m = DUE_ISO_RE.search(line)
    if m:
        d = _mkdate(*m.groups())
        if d:
            return d, "iso"
        return None, "broken"
    if DUE_ANY_RE.search(line):
        return None, "broken"

    m = CLOCK_ISO_RE.search(line)
    if m:
        d = _mkdate(*m.groups())
        if d:
            return d, "iso"
        return None, "broken"
    if EVENT_RE.search(line):
        return None, "event"
    # `dd.mm` is not an unambiguous shape — `до 8.19.1` is a version number and
    # `§4.2` is a section. An unparseable one is therefore NOT a date at all,
    # not a broken date; only the two explicit forms above can be broken.
    m = CLOCK_DMY_RE.search(line)
    if m:
        d = _mkdate(m.group(3) or today.year, m.group(2), m.group(1))
        if d:
            return d, "dmy"
    if "⏰" in line:
        m = LOOSE_DMY_RE.search(line)
        if m:
            d = _mkdate(m.group(3) or today.year, m.group(2), m.group(1))
            if d:
                return d, "loose"
    # A bare `⏰` with no date is a MISSING date, not a broken one. One
    # repository uses the clock as the marker for "this line is a hook" and
    # writes the date separately or not at all; calling that a broken marker
    # would report 26 violations where the contract says "no date", and the two
    # deserve different words — a missing date is a gap, a broken one is a
    # promise that cannot fire.
    return None, "none"


# --------------------------------------------------------------------------- #
# owners
# --------------------------------------------------------------------------- #

def people_re(cfg):
    d = re.escape(str(cfg.get("people-dir") or "people").strip("/"))
    return re.compile(r"\[\[[^\]|]*" + d + r"/([^\]|]+?)(?:\|([^\]]*))?\]\]")


def _cut_at_separator(text):
    return re.split(r"\s+(?:→|—|–|:)\s+", text)[0].strip(" :—–→`")


def _match_listed(candidate, owners):
    cand = fold(candidate)
    for name in owners:
        n = fold(name)
        if not n:
            continue
        if cand == n or (cand.startswith(n) and not cand[len(n):len(n) + 1].isalnum()):
            return name
    return None


def lead_segment(body):
    """The head of the item — the only place an owner can be.

    Measured, not assumed. Searching the whole line for a known name attributed
    `- [ ] Завершить миграцию пользователей ETNA → Kratos` to the Kratos team
    and `- [ ] Реактивировать диалог с СБ` to security: in both the name is the
    SUBJECT, and the owner is whoever the section says. Sixty-one such
    misattributions in one repository of 304 items — a report that confident and
    that wrong is worse than no report.

    So the search is bounded to what precedes the first separator, after a
    leading date marker is stepped over (`⏰ 2026-09-15 — Finance — …` puts the
    counterparty *after* the first dash, and that shape is a third of another
    repository's items).
    """
    s = body.strip()
    while s:
        m = EMOJI_RE.match(s)
        if m:
            s = s[m.end():].lstrip()
            continue
        if s[0] in " \t":
            s = s[1:]
            continue
        break
    m = LEAD_CLOCK_RE.match(s)
    if m:
        s = re.sub(r"^\s*(?:—|–|→|:)\s*", "", s[m.end():])
    elif s.startswith("⏰"):
        # A bare clock is a flag, like 🔴: `⏰ If <person> comes back with …`
        # opens with the condition, and the person in it is not the owner.
        s = s[1:].lstrip()
    m = LEAD_SEP_RE.search(s)
    if m:
        s = s[:m.start()]
    return s[:LEAD_CHARS]


def _opening(lead):
    """The lead with what opens it stepped over — `**`, `_`, a backtick, and
    the flags written inside the emphasis (`**🆕 [[…|Name]] (security)**`) —
    so a link inside the emphasis that opens the item still counts as opening
    it."""
    s = lead
    while True:
        t = s.lstrip(" \t*_`")
        m = EMOJI_RE.match(t)
        if m:
            t = t[m.end():]
        if t == s:
            return s
        s = t


def _emphasis_candidates(lead):
    hits = sorted([m for m in BOLD_RE.finditer(lead)] + [m for m in CODE_RE.finditer(lead)],
                  key=lambda m: m.start())
    return hits


def _match_role_named(candidate, owners):
    """`**agent limeflow**`, `**команда Kratos**` — one word naming a role,
    then a declared name. Only inside emphasis: bold is a label someone chose,
    while the same two words in running text are as often a verb and its
    object («Спросить limeflow»), which is the misattribution this whole rule
    set exists to avoid."""
    words = fold(candidate).split(" ")
    for name in owners:
        n = fold(name).split(" ")
        if n != [""] and len(words) == len(n) + 1 and words[1:] == n:
            return name
    return None


def parse_owner(body, side, cfg, prx, today):
    """→ (display, kind, key) with kind ∈ person | owner | us | missing.

    `key` is what the report groups by and `display` is what it prints. They
    differ for people: a Russian repository writes the same person as
    «Харламов», «Харламова» and «Харламову» depending on the sentence, and
    grouping on the written form produces three owners who are one. The profile
    slug behind the wikilink does not decline.
    """
    owners = [o for o in (cfg.get("owners") or []) if isinstance(o, str)]
    lead = lead_segment(body)

    # A person is the owner only when the link OPENS the head of the item —
    # alone, or inside the emphasis that opens it. Anywhere later in the head
    # the person is the object of the sentence: «Tell <person> that…», «Ask
    # <person> about…», «Second letter to <person>: …». Four such items in one
    # repository's action section were handed to the person being told,
    # asked or written to, while the ball was ours — the same class as the
    # team name mid-sentence, and it gets the same rule.
    pm = prx.match(_opening(lead))
    if pm:
        slug = (pm.group(1) or "").strip().rstrip("\\")
        alias = _cut_at_separator(strip_emoji(pm.group(2) or slug))
        if alias:
            return alias, "person", "person:" + fold(slug)

    for em in _emphasis_candidates(lead):
        cand = _cut_at_separator(clean(strip_emoji(em.group(1))))
        # `**We (the platform team)**` qualifies the owner, it does not rename
        # it: compared whole, the parenthesis made «we» unrecognisable.
        cand = PAREN_TAIL_RE.sub("", cand).strip()
        if not cand:
            continue
        # `- ⏰ **2026-09-15** — who: what` emphasises the DATE. A date is never
        # an owner, so step over it rather than reporting a group called 2026.
        if parse_date("⏰ " + cand, today)[1] in ("iso", "dmy"):
            continue
        listed = _match_listed(cand, owners) or _match_role_named(cand, owners)
        if listed:
            return listed, "owner", "owner:" + fold(listed)
        if fold(cand) in US_WORDS:
            return US_LABEL, "us", "us"
        break

    # Unmarked owner: the declared vocabulary, and only where the lead STARTS
    # with it. Anywhere else in the lead it is a mention, not a hand-off.
    bare = fold(clean(lead).strip(" *`~"))
    listed = _match_listed(bare, owners)
    if listed:
        return listed, "owner", "owner:" + fold(listed)
    if bare in US_WORDS:
        return US_LABEL, "us", "us"

    if side == "action":
        return US_LABEL, "us", "us"
    return None, "missing", "missing"


# --------------------------------------------------------------------------- #
# scanning
# --------------------------------------------------------------------------- #

def section_sides(cfg):
    """→ [(side, folded-heading-prefix)] from `comms.pending-sections`."""
    raw = cfg.get("pending-sections") or {}
    out = []
    if isinstance(raw, dict):
        for side in ("waiting", "action"):
            for head in raw.get(side) or []:
                if isinstance(head, str) and head.strip():
                    out.append((side, fold(head)))
    return out


def _side_of(heading, sides):
    h = fold(heading)
    for side, prefix in sides:
        if h.startswith(prefix):
            return side
    return None


def pending_files(root, cfg):
    """Expand `comms.pending-paths`, then add the declared series files.

    Globs are relative to the project root. A series file's queue of topics is
    where a promise made at a meeting waits for the next one — `| … | ours,
    ⏰ 22.09 |` — so once the pending half is on, `<meetings-dir>/<series>.md`
    of every series in `comms.series` is read too. Taken from the declared
    list rather than from a glob on purpose: `meetings/*.md` also matches the
    directory's README, whose prose explains the ⏰ marker in a bullet and would
    come back as an obligation. The list already says which files are series;
    asking for it twice is how the two copies drift."""
    patterns = [p for p in (cfg.get("pending-paths") or []) if isinstance(p, str) and p.strip()]
    if not patterns:
        return []
    seen, out = set(), []

    def add(path):
        real = os.path.abspath(path)
        if os.path.isfile(real) and real not in seen:
            seen.add(real)
            out.append(real)

    for pattern in patterns:
        for path in sorted(glob.glob(os.path.join(root, pattern), recursive=True)):
            add(path)
    meetings_dir = str(cfg.get("meetings-dir") or "meetings")
    for series in cfg.get("series") or []:
        if isinstance(series, str) and series.strip():
            add(os.path.join(root, meetings_dir, "%s.md" % series.strip()))
    return out


def in_scope(root, cfg, path):
    return os.path.abspath(path) in set(pending_files(root, cfg))


CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")


def table_item(line):
    """A table row carrying a date marker → (marker cell, readable text).

    A queue of topics is a table, and its promises sit in a cell — `| 2 | the
    status of X | … | our promise, ⏰ 22.09 |`. A scanner that reads bullets
    only never sees them, and adding the file to `pending-paths` does not help.

    Such a row is an item and never a strict one: a table has no checkbox to
    declare an obligation and no head to put an owner in, so demanding the
    line contract of it would be demanding a different file format. The only
    violation available is the one available everywhere — a broken marker.
    The date is read from the marker's own cell: across cells, `⏰` would pick
    up the next column's `08.09.2026`, which is when the topic was queued."""
    if "⏰" not in line and "(due:" not in line:
        return None
    cells = [c.strip() for c in CELL_SPLIT_RE.split(line.strip().strip("|"))]
    marker = next((c for c in cells if "⏰" in c or "(due:" in c), None)
    if not marker or marker.startswith("~~"):
        return None
    words = [clean(c).replace("\\|", "|").strip() for c in cells]
    text = " · ".join(w for w in words if w and w not in ("—", "-", "–"))
    return marker, re.sub(r"\*\*", "", text)


def scan_file(path, root, cfg, sides, today, prx):
    """Items in one file. Fenced blocks are skipped: a documented example is not
    an obligation, and a doc describing this format would otherwise report
    itself."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return []
    rel = os.path.relpath(os.path.abspath(path), root)
    items, fence, side = [], None, None

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        stripped = line.lstrip()
        fm = FENCE_RE.match(stripped)
        if fm:
            token = fm.group(1)
            fence = None if fence == token else (fence or token)
            continue
        if fence is not None:
            continue

        hm = HEADING_RE.match(line)
        if hm:
            side = _side_of(hm.group(2), sides)
            continue

        if line.startswith("|"):
            row = table_item(line)
            if row:
                cell, text = row
                due, dkind = parse_date(cell, today)
                owner, okind, okey = parse_owner(cell, None, cfg, prx, today)
                items.append({
                    "file": rel,
                    "line_no": lineno,
                    "section": side or "",
                    "strict": False,
                    "owner": owner or NO_OWNER,
                    "owner_kind": okind,
                    "owner_key": okey,
                    "due": due.isoformat() if due else None,
                    "date_kind": dkind,
                    "text": text,
                    "line": line,
                })
            continue

        if not line or line[0] in " \t":
            continue
        if ITEM_DONE_RE.match(line):
            continue
        m = ITEM_OPEN_RE.match(line)
        checkbox = m is not None
        if not m:
            m = ITEM_BULLET_RE.match(line)
        if not m:
            continue
        body = m.group(1)
        if "~~" in body[:8]:
            continue

        due, dkind = parse_date(body, today)
        strict = side is not None
        # An item is an OPEN CHECKBOX inside a declared section, or any bullet
        # carrying a marker. A bare `⏰` counts as a marker even with no date
        # behind it: one repository uses the clock to mean "this line is a
        # hook", and dropping those would silently lose the very lines whose
        # missing date is the finding. A plain prose bullet with no marker at
        # all is not an obligation — the checkbox is what declares one, and
        # treating every bullet in a section as a promise is how a linter earns
        # its first `|| true`.
        marked = dkind != "none" or "⏰" in body or "(due:" in body
        if not marked and not (checkbox and strict):
            continue

        owner, okind, okey = parse_owner(body, side, cfg, prx, today)
        items.append({
            "file": rel,
            "line_no": lineno,
            "section": side or "",
            "strict": strict,
            "owner": owner or NO_OWNER,
            "owner_kind": okind,
            "owner_key": okey,
            "due": due.isoformat() if due else None,
            "date_kind": dkind,
            "text": re.sub(r"\*\*", "", clean(body)).strip(),
            "line": line,
        })
    return items


def collect(root, cfg, today, files=None):
    sides = section_sides(cfg)
    prx = people_re(cfg)
    out = []
    for path in (files if files is not None else pending_files(root, cfg)):
        out.extend(scan_file(path, root, cfg, sides, today, prx))
    return out


def letter_flags(path):
    """→ (is_draft, is_sent), read from the file's frontmatter and nowhere else.

    `sent:` counts only with a value ON ITS OWN LINE. An empty `sent:` is what
    a ticket-draft template writes on purpose, and `null` / `""` say the same
    thing; none of them is a send. A file whose frontmatter cannot be found is
    neither — it declared nothing, and a detector must not guess.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read(LETTER_READ_LIMIT)
        fm_text, _ = fmmod.split_frontmatter(text)
    except (OSError, UnicodeDecodeError, fmmod.FrontmatterError):
        return False, False
    keys = fmmod.scalar_keys(fm_text)
    return keys.get("draft") is True, keys.get("sent") not in (None, "", False)


def unsent_drafts(root, cfg, today):
    """Written and never sent: any `*.md` inside a `comms/` directory whose own
    frontmatter says `draft: true` and carries no `sent:` value.

    The file names itself a draft, so the name of the file is not asked. The
    first version asked it — `*-out.md` only — and a repository whose ticket
    drafts are `*-task.md` and `*-draft.md` lost eight of twelve from the list,
    including one found by accident after six weeks, which is the whole class
    this list exists for.

    Deliberately NOT the draft guard's scope. The guard refuses to CREATE a
    `*-out.md` claiming `sent:`, and it keys off direction for a reason: an
    inbound letter carries `sent:` legitimately (the day the other side sent
    it — a quarter of the inbound letters in the repository measured). Here the
    question is the opposite one, and the frontmatter answers it directly."""
    try:
        threshold = int(cfg.get("pending-draft-days", 3))
    except (TypeError, ValueError):
        threshold = 3
    if threshold <= 0:
        return []
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in PRUNE_DIRS]
        if os.path.basename(dirpath) != "comms":
            continue
        for name in sorted(filenames):
            if not name.endswith(".md"):
                continue
            path = os.path.join(dirpath, name)
            is_draft, is_sent = letter_flags(path)
            if not is_draft or is_sent:
                continue
            dm = FILE_DATE_RE.match(name)
            fdate = _mkdate(*dm.groups()) if dm else None
            age = (today - fdate).days if fdate else None
            if age is not None and age < threshold:
                continue
            out.append({"file": os.path.relpath(path, root), "age": age})
    return sorted(out, key=lambda d: -(d["age"] or 0))


MEETING_DIR_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})-")


def meetings_without_transcript(root, cfg, today):
    """Meetings held within the last `pending-transcript-days` whose record
    has no transcript yet — a file named `transcript*` in the meeting's
    directory, or a non-empty `transcript:` in its `index.md`.

    Off by default (0): a repository that does not keep transcripts would
    otherwise be told about every meeting it ever held, and a signal that is
    always on for a reason the project never chose is one it switches off.
    The window exists because the signal is about a transcript that is still
    easy to get; a year-old meeting is history, not a loose end. Today's
    meeting is not counted — its transcript arriving later that day is the
    normal case, not a lapse."""
    try:
        window = int(cfg.get("pending-transcript-days", 0) or 0)
    except (TypeError, ValueError):
        window = 0
    if window <= 0:
        return []
    base = os.path.join(root, str(cfg.get("meetings-dir") or "meetings"))
    if not os.path.isdir(base):
        return []
    edge = today - datetime.timedelta(days=window)
    out = []
    for name in sorted(os.listdir(base)):
        m = MEETING_DIR_RE.match(name)
        mdir = os.path.join(base, name)
        if not m or not os.path.isdir(mdir):
            continue
        held = _mkdate(*m.groups())
        if not held or not edge <= held < today:
            continue
        try:
            leaves = os.listdir(mdir)
        except OSError:
            continue
        if any(leaf.startswith("transcript") for leaf in leaves):
            continue
        index = os.path.join(mdir, "index.md")
        if os.path.isfile(index):
            try:
                with open(index, encoding="utf-8") as fh:
                    fm_text, _ = fmmod.split_frontmatter(fh.read(LETTER_READ_LIMIT))
                if fmmod.scalar_keys(fm_text).get("transcript") not in (None, "", False):
                    continue
            except (OSError, UnicodeDecodeError, fmmod.FrontmatterError):
                pass
        out.append({"meeting": os.path.relpath(mdir, root), "age": (today - held).days})
    return out


def stale_sent_hints(root, items):
    """An item that says "send X" pointing at a letter that already carries
    `sent:`. Not a violation — the item may still owe something after the
    letter went out — but the one formal sign available that an open item is
    already done, and an item that is done and open is the state the whole
    mechanism exists to notice."""
    hints = []
    for it in items:
        if not SEND_WORDS_RE.search(it["line"]):
            continue
        for lm in OUT_LINK_RE.finditer(it["line"]):
            rel = lm.group(1) or lm.group(2)
            if not rel:
                continue
            if not rel.endswith(".md"):
                rel += ".md"
            path = os.path.normpath(os.path.join(root, os.path.dirname(it["file"]), rel))
            if not os.path.isfile(path):
                continue
            if letter_flags(path)[1]:
                hints.append((it, os.path.relpath(path, root)))
                break
    return hints


# --------------------------------------------------------------------------- #
# buckets, report, lint
# --------------------------------------------------------------------------- #

def buckets(items, today):
    edge = today + datetime.timedelta(days=SOON_DAYS)
    dated = [(i, datetime.date.fromisoformat(i["due"])) for i in items if i["due"]]
    return {
        "overdue": [i for i, d in dated if d < today],
        "soon": [i for i, d in dated if today <= d <= edge],
        "later": [i for i, d in dated if d > edge],
        "event": [i for i in items if i["date_kind"] == "event"],
        "undated": [i for i in items if not i["due"] and i["date_kind"] not in ("event",)],
    }


def _fmt(it, with_file=True, with_owner=True):
    flag = "🔴" if "🔴" in it["line"][:14] else "  "
    when = it["due"] or ("on an event" if it["date_kind"] == "event" else "no date")
    head = "%s %s" % (flag, when)
    if with_owner:
        head += " · %s" % it["owner"]
    if with_file:
        head += " · %s" % it["file"]
    text = it["text"]
    if len(text) > 170:
        text = text[:167] + "…"
    return "%s\n      %s" % (head, text)


def _block(title, lst, key=None, with_file=True, with_owner=True):
    if not lst:
        return
    print("## %s (%d)" % (title, len(lst)))
    for it in sorted(lst, key=key or (lambda i: (i["due"] or "9999", i["file"]))):
        print("  " + _fmt(it, with_file, with_owner))
    print()


def report(root, cfg, items, today, by_owner=False, show_all=False):
    b = buckets(items, today)
    files = {i["file"] for i in items}
    print("# Pending on %s — %d open item(s) in %d file(s)\n" % (today.isoformat(), len(items), len(files)))

    if by_owner:
        order = [o for o in (cfg.get("owners") or []) if isinstance(o, str)]
        rank = {fold(o): n for n, o in enumerate(order)}
        groups, shown = {}, {}
        for it in items:
            groups.setdefault(it["owner_key"], []).append(it)
            shown.setdefault(it["owner_key"], it["owner"])

        # The other side first, ours last: people, then the declared owners in
        # the order `owners` lists them, then "us", then items nobody owns. An
        # item waiting on someone else decays while we do nothing, and being
        # read first is the only thing that recovers it — the order that put
        # "us" on top was the reader's own list read before anyone else's.
        # A name that stands for our side (the maintainer's own) goes LAST in
        # `owners`, and lands right before "us".
        def group_key(key):
            if key == "missing":
                return (4, "")
            if key == "us":
                return (3, "")
            kind, _, name = key.partition(":")
            if kind == "person":
                return (0, name)
            if name in rank:
                return (1, "%04d" % rank[name])
            return (2, name)

        for key in sorted(groups, key=group_key):
            name, lst = shown[key], groups[key]
            if not show_all:
                keep = set(id(i) for i in b["overdue"] + b["soon"] + b["event"] + b["undated"])
                lst = [i for i in lst if id(i) in keep]
            _block(name, lst)
    else:
        _block("🔴 Overdue", b["overdue"])
        _block("⏰ Next %d days" % SOON_DAYS, b["soon"])
        _block("🔁 Waiting on an event", b["event"], key=lambda i: i["file"])
        red = [i for i in b["undated"] if "🔴" in i["line"][:14]]
        if show_all:
            _block("❔ No review date — will not fire on its own", b["undated"], key=lambda i: i["file"])
            _block("📅 Later", b["later"])
        else:
            if red:
                _block("❔ No review date, 🔴 only — %d undated in total, rest under --all" % len(b["undated"]),
                       red, key=lambda i: i["file"])
            elif b["undated"]:
                print("## ❔ No review date: %d (--all)\n" % len(b["undated"]))
            if b["later"]:
                print("## 📅 Dated beyond %d days: %d (--all)\n" % (SOON_DAYS, len(b["later"])))

    hints = stale_sent_hints(root, items)
    if hints:
        print("## ⚠ Possibly already done — the item points at a letter marked `sent:` (%d)" % len(hints))
        for it, rel in hints:
            print("  %s → %s" % (it["file"], rel))
        print()
    drafts = unsent_drafts(root, cfg, today)
    if drafts:
        print("## 📝 Written and never sent (%d)" % len(drafts))
        for d in drafts:
            age = "%3d d" % d["age"] if d["age"] is not None else "  ? d"
            print("  %s · %s" % (age, d["file"]))
        print()
    untranscribed = meetings_without_transcript(root, cfg, today)
    if untranscribed:
        print("## 🎙 Held, no transcript yet — last %s days (%d)"
              % (cfg.get("pending-transcript-days"), len(untranscribed)))
        for m in untranscribed:
            print("  %3d d · %s" % (m["age"], m["meeting"]))
        print()
    return 0


def brief(root, cfg, items, today):
    """One line for a session start. Silent when there is nothing to act on."""
    b = buckets(items, today)
    drafts = unsent_drafts(root, cfg, today)
    untranscribed = meetings_without_transcript(root, cfg, today)
    parts = []
    if b["overdue"]:
        parts.append("%d overdue" % len(b["overdue"]))
    if b["soon"]:
        parts.append("%d due within %d days" % (len(b["soon"]), SOON_DAYS))
    if drafts:
        parts.append("%d unsent draft(s)" % len(drafts))
    if untranscribed:
        parts.append("%d meeting(s) without a transcript" % len(untranscribed))
    if not parts:
        return 0
    if b["event"]:
        parts.append("%d waiting on an event" % len(b["event"]))
    print("[comms] pending: %s." % " · ".join(parts))
    return 1


def head_lines(root, path):
    rel = os.path.relpath(os.path.abspath(path), root)
    try:
        out = subprocess.check_output(["git", "-C", root, "show", "HEAD:%s" % rel],
                                      text=True, stderr=subprocess.DEVNULL)
    except Exception:  # noqa: BLE001
        return set()
    return set(line.rstrip() for line in out.splitlines())


LINT_CAP = 20


def lint(root, cfg, items, changed_only=False, cap=None):
    """Violations. `changed_only` keeps the lines absent from HEAD — a file that
    is new or untracked has no HEAD form, so every line counts as new, which is
    true and can still be a flood. Hence the cap: a hook that returns eighty
    findings at once is read as breakage and switched off, and the first twenty
    say the same thing."""
    if changed_only:
        cache, kept = {}, []
        for it in items:
            path = os.path.join(root, it["file"])
            if path not in cache:
                cache[path] = head_lines(root, path)
            if it["line"] not in cache[path]:
                kept.append(it)
        items = kept

    problems, printed, suppressed = 0, 0, 0
    for it in items:
        warns = []
        if it["date_kind"] == "broken":
            warns.append("broken date marker — invisible to every detector, so it promises nothing")
        if it["strict"]:
            if it["owner_kind"] == "missing":
                warns.append("no owner (a people link, an emphasised name, or a name from comms.owners)")
            if it["date_kind"] == "none":
                warns.append("no `⏰ <YYYY-MM-DD>`, `⏰ after: <event>` or `(due: YYYY-MM-DD)`")
            elif it["date_kind"] in ("dmy", "loose"):
                warns.append("date not in ISO form (read as %s)" % it["due"])
        if warns:
            problems += 1
            if cap is not None and printed >= cap:
                suppressed += 1
                continue
            printed += 1
            print("⚠ %s:%d — %s" % (it["file"], it["line_no"], "; ".join(warns)))
            print("    %s" % it["text"][:140])
    if suppressed:
        print("… and %d more" % suppressed)
    if problems:
        print("comms-pending: %d item(s) outside the contract" % problems)
    return 1 if problems else 0


def print_contract():
    print("# comms pending contract")
    print("config\tpending-paths\tglobs of files holding pending items (empty = off)")
    print("config\tpending-sections\t{\"waiting\": [...], \"action\": [...]} — headings, matched by prefix")
    print("config\towners\taccepted owner names, in report order")
    print("config\tpeople-dir\tdirectory of people profiles (default: people)")
    print("config\tpending-draft-days\tunsent-draft age threshold, 0 = off (default: 3)")
    print("config\tpending-transcript-days\twindow for 'held, no transcript', 0 = off (default: 0)")
    print("marker\t⏰ YYYY-MM-DD")
    print("marker\t⏰ after: <event>\tany of после|при|когда|after|when|once|upon|on")
    print("marker\t(due: YYYY-MM-DD)\tthe crystal suite's own form")
    print("owner\t[[…/<people-dir>/<slug>|Alias]] OPENING the item | **name** | `name` | a name from comms.owners")
    print("owner\ta person further into the head is the object («tell <person>»), not the owner")
    print("order\t--owner: people · comms.owners in listed order · us · no owner")
    print("scope\tinside a declared section: owner AND date required")
    print("scope\telsewhere: only a line already carrying a marker is an item")
    print("scope\ta table row carrying a marker is an item, never a strict one")
    print("scope\t<meetings-dir>/<series>.md of every declared series is read too")
    print("draft\tany */comms/*.md whose frontmatter says draft: true and has no sent: value")
    print("skip\t- [x], ~~struck through~~, indented children, fenced code blocks")
    print("error\tbroken date marker")
    print("error\tno owner (declared section only)")
    print("error\tno date (declared section only)")
    print("error\tdate not in ISO form (declared section only)")


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--owner", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--brief", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--lint", action="store_true")
    ap.add_argument("--changed", action="store_true")
    ap.add_argument("--cap", type=int, default=None)
    ap.add_argument("--print-contract", action="store_true")
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args(argv)

    if args.print_contract:
        print_contract()
        return 0

    root = args.project_root
    if root is None:
        root = cfgmod.project_root_of(args.files[0] if args.files else os.getcwd())
    root = os.path.abspath(root)

    cfg, cfg_err = cfgmod.load(root)
    if cfg_err:
        print("✖ %s" % cfg_err, file=sys.stderr)
        return 1
    if cfg.get("enabled") is False:
        return 0

    today = cfgmod.today()
    scoped = pending_files(root, cfg)
    if not scoped:
        return 0

    if args.files:
        wanted = {os.path.abspath(f) for f in args.files}
        targets = [p for p in scoped if p in wanted]
        if not targets:
            return 0
    else:
        targets = scoped

    items = collect(root, cfg, today, files=targets)

    if args.lint:
        return lint(root, cfg, items, changed_only=args.changed, cap=args.cap)
    if args.json:
        print(json.dumps({"today": today.isoformat(), "items": items,
                          "drafts": unsent_drafts(root, cfg, today),
                          "meetings_without_transcript":
                              meetings_without_transcript(root, cfg, today)},
                         ensure_ascii=False, indent=1))
        return 0
    if args.brief:
        return brief(root, cfg, items, today)
    return report(root, cfg, items, today, by_owner=args.owner, show_all=args.all)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
