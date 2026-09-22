#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared configuration for the comms tools — one reader, two callers.

The linter and the index generator must agree on where meetings live and what
a track is; two readers would be two answers the day one of them is edited.
Read through `json` from the standard library rather than through `jq`: the
tools already require python3 and nothing else, and adding a second dependency
to read three keys would undo that.

Config lives in `.claude/vdm-plugins.json` (or `.qwen/…`) under `comms`:

    meetings-dir    where meetings live                    (default "meetings")
    track-roots     allowed first segment of a track path  (default: any)
    series          declared series slugs                  (default: no check)
    topic-sections  also check the body's topic sections   (default false)
    enabled         false switches the whole plugin off    (default true)

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
}


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
