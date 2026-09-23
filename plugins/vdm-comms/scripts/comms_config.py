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
    meeting-rules     opt-in authoring rules for the linter  (default: none — see comms-lint.py)
    pending-paths     globs of files holding pending items   (default: none -> off)
    pending-sections  {"waiting": [...], "action": [...]}    (default: none)
    owners            accepted owner names, in report order  (default: none)
    people-dir        directory of people profiles           (default "people")
    pending-draft-days unsent-draft age threshold, 0 = off   (default 3)
    pending-transcript-days  window for "held, no transcript", 0 = off (default 0)
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
    "pending-draft-days": 3,
    # Off by default: a repository that keeps no transcripts would be told
    # about every meeting it holds, for a reason it never chose.
    "pending-transcript-days": 0,
}

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
    },
}


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
    cfg["enabled"] = section.get("enabled", True)
    return cfg, None


def track_exists(project_root, track):
    """A track may be a directory OR a single file — half of one repository's
    tracks resolve to `<path>.md`, so checking `isdir` alone rejects them."""
    base = os.path.join(project_root, track)
    return os.path.isdir(base) or os.path.isfile(base + ".md")
