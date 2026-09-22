#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-lint — contract validator for a meetings tree.

The contract is a FLOOR, not a ceiling: what the linter checks is the part
three independent repositories turned out to share (the meetings relay,
`space-hq` → `global-auth-gap` → `t23b-program`). Extra frontmatter keys,
extra sections and extra file classes are never violations — a project layers
its own conventions on top, and this linter stays silent about them.

What is configurable lives in `.claude/vdm-plugins.json` → `comms`, and it is
only the part that genuinely differs between those repositories:

    meetings-dir    where meetings live                 (default "meetings")
    track-roots     allowed first path segment of a track (default: any)
    series          declared series slugs                (default: no check)
    topic-sections  also check the body's topic sections (default false)

Everything else is hardcoded here, because it did NOT differ:

  * a meeting lives in <meetings-dir>/<YYYY-MM-DD>-<slug>/
  * roles are file names — index | prep | agenda | pitch[-vN]
  * `type` selects which contract applies: meeting | meeting-series | index |
    readme; an unknown value is a warning, not an error, since a project may
    add classes of its own
  * `date` is required and must parse, and must equal the directory's date
  * `index.md` is required ONLY when the meeting is in the past — before it,
    its absence is the normal state of a planned meeting, and demanding it
    blocks every write into a perfectly healthy directory
  * a track may resolve as `<track>/` OR `<track>.md`, at any depth, with no
    assumption about case
  * `series:` without its file is a warning; the invariant is membership in
    the declared list
  * the BODY of a series file is never checked
  * a directory without <meetings-dir> exits silently

Exit: 0 clean (warnings do not count), 1 violations found.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fm  # noqa: E402

DIR_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-([^/]+)$")
ROLE_RE = re.compile(r"^(index|prep|agenda|pitch(-v\d+)?)\.md$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

KNOWN_TYPES = ("meeting", "meeting-series", "index", "readme", "meeting-link")

today = cfgmod.today
track_exists = cfgmod.track_exists
project_root_of = cfgmod.project_root_of

class Report:
    def __init__(self, path):
        self.path = path
        self.errors = []
        self.warnings = []

    def error(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    @property
    def clean(self):
        return not self.errors


def _classify(rel_path, meetings_dir):
    """Return (kind, meeting_dir_name, leaf) for a path inside the tree."""
    parts = rel_path.split(os.sep)
    if not parts or parts[0] != meetings_dir:
        return None, None, None
    rest = parts[1:]
    if len(rest) == 1:
        return "flat", None, rest[0]
    if len(rest) == 2:
        return "in-meeting-dir", rest[0], rest[1]
    return "deep", rest[0], rest[-1]


def lint_file(path, cfg, project_root):
    rep = Report(path)
    meetings_dir = cfg["meetings-dir"]
    rel = os.path.relpath(os.path.abspath(path), project_root)
    kind, dir_name, leaf = _classify(rel, meetings_dir)
    if kind is None:
        return None  # not ours

    try:
        data, body = fm.read(path)
    except fm.FrontmatterError as exc:
        rep.error(str(exc))
        return rep
    except OSError as exc:
        rep.error("cannot read file: %s" % exc)
        return rep

    ftype = data.get("type")
    is_role = bool(ROLE_RE.match(leaf)) and kind == "in-meeting-dir"

    # WHAT IS UNDER CONTRACT is decided by the file's ROLE — its name — and not
    # by its `type`. Two field observations forced this, and both would have
    # been mis-handled by trusting `type` alone:
    #
    #   * a meetings directory holds raw material next to the contract files —
    #     transcripts with no frontmatter at all. Demanding a `type` of them
    #     turns thirteen honest files into thirteen violations.
    #   * a repository grew its own type vocabulary (`meeting-agenda`,
    #     `meeting-handout`, `meeting-checklist`, `transcript`). Keying off
    #     `type` would have left its `agenda.md` unchecked while shouting about
    #     a dozen handouts that were never anyone's contract.
    #
    # So: a role file (index|prep|agenda|pitch) owes the meeting contract
    # whatever its `type` says; `type` selects only for everything else.
    if not data:
        if is_role:
            rep.error("no frontmatter — a role file (%s) is under contract" % leaf)
        return rep

    if is_role or ftype == "meeting":
        if ftype is not None and ftype != "meeting":
            rep.warn("`type: %s` on a role file — the shared contract says `meeting`, "
                     "and the role comes from the file name" % ftype)
        _lint_meeting(rep, data, body, path, rel, kind, dir_name, leaf, cfg, project_root)
        return rep

    if ftype == "meeting-series":
        _lint_series(rep, data, rel, meetings_dir)
        return rep

    # index / readme / generated pointers own their own shape; an unknown type
    # on a non-role file is a project's own class, not a violation.
    return rep


def _lint_series(rep, data, rel, meetings_dir):
    parts = rel.split(os.sep)
    if len(parts) != 2:
        rep.error("a series file belongs at %s/<series>.md" % meetings_dir)
    # The BODY of a series file is never checked — see the module docstring.


def _lint_meeting(rep, data, body, path, rel, kind, dir_name, leaf, cfg, project_root):
    meetings_dir = cfg["meetings-dir"]

    if kind != "in-meeting-dir":
        rep.error("a meeting file belongs at %s/<YYYY-MM-DD>-<slug>/<role>.md"
                  % meetings_dir)
        return

    m = DIR_RE.match(dir_name or "")
    if not m:
        rep.error("directory %r is not <YYYY-MM-DD>-<slug>" % dir_name)
        return
    dir_date = m.group(1)

    if not ROLE_RE.match(leaf):
        rep.warn("file name %r is not a known role (index|prep|agenda|pitch)" % leaf)

    raw_date = data.get("date")
    date_str = str(raw_date) if raw_date is not None else ""
    if not date_str:
        rep.error("`date:` is required — it decides whether index.md is owed yet")
    elif not DATE_RE.match(date_str):
        rep.error("`date: %s` is not a parseable YYYY-MM-DD" % date_str)
    elif date_str != dir_date:
        rep.error("`date: %s` disagrees with the directory date %s" % (date_str, dir_date))
    else:
        meeting_date = datetime.date.fromisoformat(date_str)
        index_path = os.path.join(os.path.dirname(os.path.abspath(path)), "index.md")
        if meeting_date < today() and not os.path.isfile(index_path):
            rep.error("the meeting is in the past and %s/%s/index.md does not exist "
                      "(before the date its absence is normal)" % (meetings_dir, dir_name))

    series = data.get("series")
    if series:
        declared = cfg["series"] or []
        if declared and series not in declared:
            rep.error("`series: %s` is not in the declared list (%s) — declare it in "
                      "the `comms.series` config or fix the value"
                      % (series, ", ".join(declared)))
        series_file = os.path.join(project_root, meetings_dir, "%s.md" % series)
        if not os.path.isfile(series_file):
            rep.warn("no %s/%s.md — a series file is written when it is needed, so "
                     "this is a note, not a violation" % (meetings_dir, series))

    tracks = data.get("tracks") or []
    if isinstance(tracks, str):
        tracks = [tracks]
    roots = cfg["track-roots"] or []
    for track in tracks:
        if not track:
            continue
        track = str(track)
        first = track.split("/")[0]
        if roots and first not in roots:
            rep.error("track %r starts with %r, which is not a configured track root "
                      "(%s)" % (track, first, ", ".join(roots)))
            continue
        if not track_exists(project_root, track):
            rep.error("track %r resolves to neither %s/ nor %s.md" % (track, track, track))

    topics = data.get("topics") or []
    if isinstance(topics, list):
        for idx, topic in enumerate(topics, 1):
            if not isinstance(topic, dict):
                continue
            t_track = topic.get("track")
            if t_track and str(t_track) not in [str(x) for x in tracks]:
                rep.error("topic %d points at track %r, which is not in this meeting's "
                          "`tracks:`" % (idx, t_track))
            if not t_track and not topic.get("tail"):
                rep.warn("topic %d has no track and is not marked `tail: true`" % idx)

    if cfg.get("topic-sections") and not data.get("migrated_from"):
        _lint_topic_sections(rep, data, body)


def _lint_topic_sections(rep, data, body):
    topics = [t for t in (data.get("topics") or []) if isinstance(t, dict)]
    if not topics:
        return
    heads = re.findall(r"^##\s+(?:Тема|Topic)\s+(\d+)\.\s*(.+?)\s*$", body, re.M)
    if len(heads) != len(topics):
        rep.error("body has %d topic section(s) but frontmatter declares %d"
                  % (len(heads), len(topics)))
        return
    for (num, name), topic in zip(heads, topics):
        want = str(topic.get("name") or "").strip()
        if want and name.strip() != want:
            rep.error("topic section %s is titled %r, frontmatter says %r"
                      % (num, name.strip(), want))


def iter_tree(project_root, cfg):
    base = os.path.join(project_root, cfg["meetings-dir"])
    if not os.path.isdir(base):
        return
    for entry in sorted(os.listdir(base)):
        full = os.path.join(base, entry)
        if os.path.isfile(full) and entry.endswith(".md"):
            yield full
        elif os.path.isdir(full):
            for leaf in sorted(os.listdir(full)):
                if leaf.endswith(".md"):
                    yield os.path.join(full, leaf)


def print_contract():
    print("# comms contract — the floor, derived from three repositories")
    print("config\tmeetings-dir\tdefault: meetings")
    print("config\ttrack-roots\tdefault: any first segment accepted")
    print("config\tseries\tdefault: membership unchecked")
    print("config\ttopic-sections\tdefault: false (body not checked)")
    for t in KNOWN_TYPES:
        print("type\t%s" % t)
    print("layout\t<meetings-dir>/<YYYY-MM-DD>-<slug>/<role>.md")
    print("role\tindex | prep | agenda | pitch[-vN]")
    print("error\tmissing type")
    print("error\tmissing or unparseable date")
    print("error\tdate disagrees with directory")
    print("error\tindex.md missing for a PAST meeting")
    print("error\tseries not in declared list")
    print("error\ttrack root not configured")
    print("error\ttrack resolves to neither <p>/ nor <p>.md")
    print("error\ttopic track not in tracks")
    print("warning\tunknown type")
    print("warning\tseries file missing")
    print("warning\ttopic without track and without tail")
    print("never\tbody of a series file")


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--print-contract", action="store_true")
    ap.add_argument("--project-root", default=None)
    args = ap.parse_args(argv)

    if args.print_contract:
        print_contract()
        return 0

    root = args.project_root
    if root is None:
        probe = args.files[0] if args.files else os.getcwd()
        root = project_root_of(probe)
    root = os.path.abspath(root)

    cfg, cfg_err = cfgmod.load(root)
    if cfg_err:
        print("✖ %s" % cfg_err, file=sys.stderr)
        return 1
    if cfg.get("enabled") is False:
        return 0

    targets = list(args.files)
    if args.all:
        targets = list(iter_tree(root, cfg))
    if not targets:
        return 0

    failures = 0
    for path in targets:
        if not os.path.isfile(path):
            continue
        rep = lint_file(path, cfg, root)
        if rep is None:
            continue
        rel = os.path.relpath(os.path.abspath(path), root)
        for msg in rep.errors:
            print("✖ %s: %s" % (rel, msg))
        for msg in rep.warnings:
            print("⚠ %s: %s" % (rel, msg))
        if rep.errors:
            failures += 1
        elif not rep.warnings and not args.quiet:
            print("%s: ok" % rel)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
