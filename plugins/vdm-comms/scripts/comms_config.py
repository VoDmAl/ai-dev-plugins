#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared configuration for the comms tools — one reader, two callers.

The linter and the index generator must agree on where meetings live and what
a track is; two readers would be two answers the day one of them is edited.
Read through `json` from the standard library rather than through `jq`: the
tools already require python3 and nothing else, and adding a second dependency
to read three keys would undo that.

Config lives in `.claude/vdm-plugins.json` (or `.qwen/…`) under `comms`:

    meetings-dir      where meetings live                    (default "meetings")
    track-roots       allowed first segment of a track path  (default: any)
    series            declared series slugs                  (default: no check)
    topic-sections    also check the body's topic sections   (default false)
    link-style        markdown | wikilink, for generated links (default markdown)
    registry-columns  INDEX.md columns, in order             (default date, meeting, series, tracks)
    series-columns    a series file's columns, in order      (default date, meeting)
    generate          which generated artefacts are this plugin's: registry,
                      series, pointers; [] = none            (default: all three)
    meeting-rules     opt-in authoring rules for the linter  (default: none — see comms-lint.py)
    pending-paths     globs of files holding pending items   (default: none -> off)
    pending-sections  {"waiting": [...], "action": [...]}    (default: none)
    owners            accepted owner names, in report order  (default: none)
    people-dir        directory of people profiles           (default "people")
    hq                a hand's HQ: the intercom identity of the project whose
                      people/ this one reads (comms_people.py) (default: none —
                      the project is its own HQ)
    pending-draft-days unsent-draft age threshold, 0 = off   (default 3)
    pending-transcript-days  window for "held, no transcript", 0 = off (default 0)
    register          how requests are made to the usual reader: volunteer |
                      executor | peer; a letter's own `register:` wins (default: none)
    language          the language of outgoing letters, e.g. en, ru  (default: none)
    letter-form       per channel: what an outgoing DRAFT must carry — `channel`,
                      `subject`, `separator`, `goal`, `known`; `*` applies to every draft; merged
                      over the default key by key       (default {"email": ["subject"]})
    now               the live signals/now.md (comms-now.py): {"owner": [names
                      that mean the owner], "instructions": path, "path":
                      output, default "signals/now.md", "echelon": false | path
                      to its bin/echelon}                 (default: none -> off)
    enabled           false switches the whole plugin off    (default true)

Only what genuinely differed between the three field repositories is
configurable; everything else is a floor written into the code.
"""
from __future__ import annotations

import datetime
import json
import os
import re

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

DEFAULTS = {
    "meetings-dir": "meetings",
    "track-roots": [],
    "series": [],
    "topic-sections": False,
    "labels": "en",
    # The generated layer. Empty column lists mean the defaults written in
    # comms-index.py, so a project names only what it wants different.
    "link-style": "markdown",
    "registry-columns": [],
    "series-columns": [],
    # Which of the three generated artefacts are this plugin's to write and to
    # call stale. None = all of them; a project that writes its own registry
    # (hq: its linter owns INDEX.md and the series blocks) names only what
    # is left, and `[]` hands the whole layer back. Unlike the column lists, an
    # empty list is an answer here, not "use the default".
    "generate": None,
    # Opt-in authoring rules for the meetings linter — a project's own
    # conventions, named in its own config. Empty = the floor only.
    "meeting-rules": {},
    # The pending half. `pending-paths` defaults to nothing on purpose: where a
    # repository keeps its open obligations is the one thing that cannot be
    # guessed — the three field repositories put them in `gaps|org|incidents/
    # */index.md`, in `tracks/*/index.md` and in `docs/tasks/<key>/<slug>.md`
    # respectively. Empty means the pending tools stay silent rather than
    # enforcing a contract nobody declared.
    "pending-paths": [],
    "pending-sections": {},
    "owners": [],
    "people-dir": "people",
    # A hand keeps no people/ and reads its HQ's (owner with echelon,
    # 2026-10-01; comms_people.py). Unset: this project is its own HQ.
    "hq": None,
    "pending-draft-days": 3,
    # Off by default: a repository that keeps no transcripts would be told
    # about every meeting it holds, for a reason it never chose.
    "pending-transcript-days": 0,
    # What an outgoing DRAFT must carry, per channel (`channel:` in its
    # frontmatter, normalised to its first word). The default is the one thing
    # true of every email in every repository — it has a subject; a separator
    # before the text to send is a project's own convention (hq keeps it,
    # half of command-center's letters do not), so it is opted into, not
    # imposed. `*` applies to every draft, including one with no channel yet.
    "letter-form": {"email": ["subject"]},
    # Who the project usually writes to, and in what language (owner, 2026-09-28;
    # skill `letters` § 6). Undeclared = no profile: the rules for every register
    # apply. A letter to someone else carries its own `register:`.
    "register": None,
    "language": None,
    # The live signals/now.md (comms-now.py, workitem vdm-comms-live-now). Off
    # until a project says which names in its items mean the owner.
    "now": None,
}

REGISTERS = ("volunteer", "executor", "peer")

# Wording for the files the generator writes INTO THE PROJECT. It is the one
# part of this plugin that ends up in somebody else's document, so it cannot be
# hardcoded in the language its authors happen to work in: a table headed
# "Дата | Встреча" appearing in an English repository is the plugin deciding
# something that was never its call.
#
# `comms.labels` takes "en" (default), "ru", or an object overriding individual
# keys — the object is merged over English, so a project renames one column
# without restating the rest.
LABELS = {
    "en": {
        "col-date": "Date",
        "col-meeting": "Meeting",
        "col-series": "Series",
        "col-tracks": "Tracks",
        "col-people": "Participants",
        "col-topics": "Topics",
        "col-materials": "Materials",
        "topics-tails": "%(n)d (+%(tails)d tail)",
        "material-transcript": "transcript",
        "registry-empty": "no meetings yet",
        "series-empty": "no meetings in this series yet",
        # %(ref)s is the link, already written in `link-style`. The older form
        # `[%(source)s](%(link)s)` still works in an override: %(link)s stays
        # the bare relative path.
        "pointer-line": "Meeting %(date)s — %(ref)s",
        "pointer-record": "record",
        "pointer-materials": "Materials: %(list)s",
        "pointer-topics": "Topics on this track:",
        "letter-subject": "Subject",
        "letter-text": "Text to send, as it will go out.",
        "now-instructions": "How to work with this file",
        "now-no-instructions": "No instructions yet — set `comms.now.instructions` to the file that says how to work with now.md.",
        "now-orphans": "Replies without an item",
        "now-mine": "Your move",
        "now-soon": "Today and tomorrow",
        "now-others": "Led by others",
        "now-lifted": "overdue since %(due)s · %(owner)s",
        "now-draft": "draft not sent",
        "now-us": "us",
        "now-no-owner": "no owner",
        "now-today": "today",
        "now-tomorrow": "tomorrow",
        "now-empty": "nothing",
        "now-echelon-missing": "echelon not reached (%(why)s) — no calendar and no tasks from it in this build",
        "now-incomplete": "echelon's collection is incomplete: %(errors)s",
        "now-echelon-others": "echelon: waiting for others",
        "now-msk": "MSK",
    },
    "ru": {
        "col-date": "Дата",
        "col-meeting": "Встреча",
        "col-series": "Серия",
        "col-tracks": "Треки",
        "col-people": "Участники",
        "col-topics": "Тем",
        "col-materials": "Материалы",
        "topics-tails": "%(n)d (+%(tails)d хвост)",
        "material-transcript": "транскрипт",
        "registry-empty": "встреч пока нет",
        "series-empty": "встреч серии пока нет",
        "pointer-line": "Встреча %(date)s — %(ref)s",
        "pointer-record": "протокол",
        "pointer-materials": "Материалы: %(list)s",
        "pointer-topics": "Темы этого трека:",
        "letter-subject": "Тема",
        "letter-text": "Текст к отправке — так, как он уйдёт.",
        "now-instructions": "Как работать с этим файлом",
        "now-no-instructions": "Инструкции пока нет — задайте `comms.now.instructions`: файл о том, как работать с now.md.",
        "now-orphans": "Реплики без пункта",
        "now-mine": "Твой ход",
        "now-soon": "Сегодня и завтра",
        "now-others": "Ведут другие",
        "now-lifted": "срок %(due)s прошёл · %(owner)s",
        "now-draft": "черновик не отправлен",
        "now-us": "мы",
        "now-no-owner": "без владельца",
        "now-today": "сегодня",
        "now-tomorrow": "завтра",
        "now-empty": "пусто",
        "now-echelon-missing": "echelon недоступен (%(why)s) — календаря и задач от него в этой сборке нет",
        "now-incomplete": "сбор echelon неполон: %(errors)s",
        "now-echelon-others": "echelon: ждут других",
        "now-msk": "МСК",
    },
}


CHANNEL_WORD_RE = re.compile(r"[^\W_][\w-]*")


def channel_of(value):
    """The channel a letter declares, normalised to its first word, lowercase.

    Measured 2026-09-25 across three repositories: `channel:` was already in 46
    letters, written as free text — `SMS` and `sms`, `eXpress` and `express`,
    `intercom (~/.claude/…/letter.md)`, a whole sentence about the thread. The
    field is recognised as people write it rather than re-specified: its first
    word is the channel, the rest is their note."""
    if value in (None, "", False, True):
        return None
    m = CHANNEL_WORD_RE.search(str(value).strip().lower())
    return m.group(0) if m else None


def form_need(cfg, channel):
    """What a draft on `channel` owes, per `comms.letter-form`: the `*` list, then
    the channel's own, without repeats. One reader for the linter that checks a
    draft and the scaffold that writes one — two readers would be two answers
    the day one of them is edited. None when the config is not a mapping."""
    form = cfg.get("letter-form") or {}
    if not isinstance(form, dict):
        return None
    need = []
    for key in ("*", channel):
        elements = form.get(key) if key else None
        if isinstance(elements, list):
            need += [e for e in elements if e not in need]
    return need


def labels(cfg):
    """Resolve `comms.labels` into a complete wording map."""
    value = cfg.get("labels", "en")
    if isinstance(value, dict):
        merged = dict(LABELS["en"])
        merged.update({k: v for k, v in value.items() if isinstance(v, str)})
        return merged
    return dict(LABELS.get(str(value), LABELS["en"]))


def today():
    """Today, overridable for tests via COMMS_TODAY."""
    override = os.environ.get("COMMS_TODAY")
    if override and DATE_RE.match(override):
        return datetime.date.fromisoformat(override)
    return datetime.date.today()


def project_root_of(path):
    """Nearest ancestor holding .git; the file's own directory otherwise."""
    start = os.path.abspath(path)
    cur = start if os.path.isdir(start) else os.path.dirname(start)
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.dirname(start) if not os.path.isdir(start) else start
        cur = parent


def config_path(project_root):
    for harness in (".claude", ".qwen"):
        p = os.path.join(project_root, harness, "vdm-plugins.json")
        if os.path.isfile(p):
            return p
    return None


def load(project_root):
    """Return (config, error). An unreadable config is an error, not a default:
    silently falling back would enforce a contract nobody configured."""
    cfg = dict(DEFAULTS)
    cfg["enabled"] = True
    path = config_path(project_root)
    if not path:
        return cfg, None
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        return cfg, "config unreadable (%s): %s" % (path, exc)
    section = raw.get("comms")
    if not isinstance(section, dict):
        return cfg, None
    for key in DEFAULTS:
        if key in section and section[key] is not None:
            cfg[key] = section[key]
    # letter-form is merged key by key: a project that adds `*` keeps the
    # default's `email`, and one that wants no email rule says `"email": []`.
    if isinstance(section.get("letter-form"), dict):
        cfg["letter-form"] = dict(DEFAULTS["letter-form"], **section["letter-form"])
    cfg["enabled"] = section.get("enabled", True)
    return cfg, None


def track_exists(project_root, track):
    """A track may be a directory OR a single file — half of one repository's
    tracks resolve to `<path>.md`, so checking `isdir` alone rejects them."""
    base = os.path.join(project_root, track)
    return os.path.isdir(base) or os.path.isfile(base + ".md")
