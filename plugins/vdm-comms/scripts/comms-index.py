#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-index — the generated layer over a meetings tree.

Three artefacts are derived from the meetings themselves and therefore go
stale the moment a meeting changes:

  * `<meetings-dir>/INDEX.md`   — the registry of every meeting
  * `<meetings-dir>/<series>.md` — the list of that series' meetings
  * `<track>/comms/<date>-<slug>-meeting.md` — a pointer, so a meeting shows up
    in the chronology of each track it touched (letters live there; a meeting
    that leaves no trace there is invisible where the reader is looking)

The plugin does NOT write them behind your back. `--check` compares what is on
disk with what the meetings say and reports the difference; `--write` applies
it, and the diff is yours to read. The reason is not timidity: a hook that
writes into a project's files is the one piece of this the field repositories
pushed back on, and a generator that fails silently leaves a registry that is
confidently wrong — which is worse than one that is visibly behind. Comparing
two artefacts on disk, on the other hand, cannot go stale: it is recomputed
every time it is asked.

Insertion points are explicit markers, so nothing is guessed:

    <!-- registry:start -->   …table…   <!-- registry:end -->
    <!-- meetings:start -->   …table…   <!-- meetings:end -->

A file without its markers is reported, never rewritten — where the table goes
is the project's call.

Exit: 0 in sync / 1 drift (with --check) or wrote something (with --write).
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fm  # noqa: E402

DIR_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-([^/]+)$")
SOURCE_ORDER = ("index.md", "agenda.md", "prep.md")
GENERATED_BY = "vdm-comms"

REGISTRY_START = "<!-- registry:start -->"
REGISTRY_END = "<!-- registry:end -->"
SERIES_START = "<!-- meetings:start -->"
SERIES_END = "<!-- meetings:end -->"

SKIP_DIRS = ("node_modules", "vendor", "__pycache__", "attachments", "_import")


class Meeting:
    def __init__(self, root, meetings_dir, dir_name):
        self.root = root
        self.meetings_dir = meetings_dir
        self.dir_name = dir_name
        m = DIR_RE.match(dir_name)
        self.date = m.group(1) if m else ""
        self.slug = m.group(2) if m else dir_name
        self.source = None
        self.data = {}
        self.title = self.slug
        for leaf in SOURCE_ORDER:
            path = os.path.join(root, meetings_dir, dir_name, leaf)
            if os.path.isfile(path):
                self.source = leaf
                try:
                    self.data, body = fm.read(path)
                except (fm.FrontmatterError, OSError):
                    self.data, body = {}, ""
                self.title = self._title(body)
                break

    def _title(self, body):
        t = self.data.get("title")
        if t:
            return str(t)
        m = re.search(r"^#\s+(.+?)\s*$", body or "", re.M)
        if m:
            return m.group(1)
        return self.slug

    @property
    def rel_dir(self):
        return "%s/%s" % (self.meetings_dir, self.dir_name)

    @property
    def rel_source(self):
        return "%s/%s" % (self.rel_dir, self.source or "")

    @property
    def tracks(self):
        raw = self.data.get("tracks") or []
        if isinstance(raw, str):
            raw = [raw]
        return [str(t) for t in raw if t]

    @property
    def series(self):
        s = self.data.get("series")
        return str(s) if s else ""

    def topics_for(self, track):
        out = []
        for topic in self.data.get("topics") or []:
            if isinstance(topic, dict) and str(topic.get("track") or "") == track:
                name = str(topic.get("name") or "").strip()
                if name:
                    out.append(name)
        return out


def collect(root, meetings_dir):
    base = os.path.join(root, meetings_dir)
    if not os.path.isdir(base):
        return []
    meetings = []
    for entry in sorted(os.listdir(base)):
        full = os.path.join(base, entry)
        if not os.path.isdir(full):
            continue
        if not DIR_RE.match(entry):
            continue
        meetings.append(Meeting(root, meetings_dir, entry))
    return meetings


def registry_table(meetings, lab):
    rows = ["| %s | %s | %s | %s |" % (lab["col-date"], lab["col-meeting"],
                                       lab["col-series"], lab["col-tracks"]),
            "|---|---|---|---|"]
    for m in sorted(meetings, key=lambda x: x.date, reverse=True):
        link = "[%s](%s/%s)" % (m.title.replace("|", "\\|"), m.dir_name, m.source or "")
        tracks = ", ".join("`%s`" % t for t in m.tracks) or "—"
        rows.append("| %s | %s | %s | %s |" % (m.date, link, m.series or "—", tracks))
    if len(rows) == 2:
        rows.append("| — | %s | — | — |" % lab["registry-empty"])
    return "\n".join(rows)


def series_table(meetings, series, lab):
    rows = ["| %s | %s |" % (lab["col-date"], lab["col-meeting"]), "|---|---|"]
    picked = [m for m in meetings if m.series == series]
    for m in sorted(picked, key=lambda x: x.date, reverse=True):
        rows.append("| %s | [%s](%s/%s) |"
                    % (m.date, m.title.replace("|", "\\|"), m.dir_name, m.source or ""))
    if len(rows) == 2:
        rows.append("| — | %s |" % lab["series-empty"])
    return "\n".join(rows)


def replace_between(text, start, end, payload):
    """Return (new_text, status). status: replaced | missing-markers | same."""
    si = text.find(start)
    ei = text.find(end)
    if si == -1 or ei == -1 or ei < si:
        return text, "missing-markers"
    new = text[: si + len(start)] + "\n" + payload + "\n" + text[ei:]
    if new == text:
        return text, "same"
    return new, "replaced"


def pointer_path(root, track, meeting):
    return os.path.join(root, track, "comms", "%s-%s-meeting.md" % (meeting.date, meeting.slug))


def pointer_body(meeting, track, lab):
    lines = [
        "---",
        "type: meeting-link",
        "date: %s" % meeting.date,
        "meeting: %s" % meeting.rel_dir,
        "generated: %s" % GENERATED_BY,
        "---",
        "",
        "# %s" % meeting.title,
        "",
        lab["pointer-line"] % {"date": meeting.date,
                               "source": meeting.source or lab["pointer-record"],
                               "link": "../../%s" % meeting.rel_source},
        "",
    ]
    topics = meeting.topics_for(track)
    if topics:
        lines.append(lab["pointer-topics"])
        lines.append("")
        for t in topics:
            lines.append("- %s" % t)
        lines.append("")
    lines.append("<!-- generated by %s — edits here are overwritten -->" % GENERATED_BY)
    lines.append("")
    return "\n".join(lines)


def is_directory_track(root, track):
    return os.path.isdir(os.path.join(root, track))


def plan(root, meetings_dir, meetings, lab):
    """Return (actions, notes). Each action is (kind, path, payload)."""
    actions = []
    notes = []

    # 1. Registry.
    index_path = os.path.join(root, meetings_dir, "INDEX.md")
    table = registry_table(meetings, lab)
    if os.path.isfile(index_path):
        with open(index_path, encoding="utf-8") as fh:
            current = fh.read()
        new, status = replace_between(current, REGISTRY_START, REGISTRY_END, table)
        if status == "missing-markers":
            notes.append("%s/INDEX.md has no %s / %s markers — add them where the table "
                         "should go; nothing was written" % (meetings_dir, REGISTRY_START,
                                                             REGISTRY_END))
        elif status == "replaced":
            actions.append(("registry", index_path, new))
    else:
        notes.append("%s/INDEX.md does not exist — create it with the %s / %s markers"
                     % (meetings_dir, REGISTRY_START, REGISTRY_END))

    # 2. Series blocks.
    for series in sorted({m.series for m in meetings if m.series}):
        spath = os.path.join(root, meetings_dir, "%s.md" % series)
        if not os.path.isfile(spath):
            continue  # a series file is written when it is needed (lint warns)
        with open(spath, encoding="utf-8") as fh:
            current = fh.read()
        new, status = replace_between(current, SERIES_START, SERIES_END,
                                      series_table(meetings, series, lab))
        if status == "missing-markers":
            notes.append("%s/%s.md has no %s / %s markers — add them to get the meeting "
                         "list generated" % (meetings_dir, series, SERIES_START, SERIES_END))
        elif status == "replaced":
            actions.append(("series:%s" % series, spath, new))

    # 3. Pointers.
    wanted = {}
    for m in meetings:
        for track in m.tracks:
            if not is_directory_track(root, track):
                notes.append("track `%s` of %s resolves to a FILE, not a directory — no "
                             "pointer written (a file track has no comms/ to put it in)"
                             % (track, m.rel_dir))
                continue
            p = pointer_path(root, track, m)
            wanted[p] = pointer_body(m, track, lab)

    for p, body in sorted(wanted.items()):
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                current = fh.read()
            if current == body:
                continue
            if GENERATED_BY not in current:
                notes.append("%s exists and was not generated by this plugin — left alone"
                             % os.path.relpath(p, root))
                continue
        actions.append(("pointer", p, body))

    # 4. Pointers that are ours but no longer wanted. Walk with the same
    # pruning a tree scan always needs: a repository's bulk is .git, vendored
    # dependencies and attachments, and paying for those on every check is how
    # a cheap signal turns into one that gets switched off.
    for track_dir, subdirs, files in os.walk(root):
        subdirs[:] = [d for d in subdirs
                      if not d.startswith(".") and d not in SKIP_DIRS]
        if os.path.basename(track_dir) != "comms":
            continue
        for leaf in files:
            if not leaf.endswith("-meeting.md"):
                continue
            p = os.path.join(track_dir, leaf)
            if p in wanted:
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    current = fh.read()
            except OSError:
                continue
            if GENERATED_BY in current:
                actions.append(("remove", p, None))

    return actions, notes


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--project-root", default=None)
    ap.add_argument("--meetings-dir", default=None)
    args = ap.parse_args(argv)

    root = os.path.abspath(args.project_root or cfgmod.project_root_of(os.getcwd()))
    cfg, cfg_err = cfgmod.load(root)
    if cfg_err:
        print("⚠ %s" % cfg_err)
        return 1
    if cfg.get("enabled") is False:
        return 0
    meetings_dir = args.meetings_dir or cfg["meetings-dir"]
    if not os.path.isdir(os.path.join(root, meetings_dir)):
        return 0

    meetings = collect(root, meetings_dir)
    actions, notes = plan(root, meetings_dir, meetings, cfgmod.labels(cfg))

    if args.write:
        for kind, path, payload in actions:
            if kind == "remove":
                try:
                    os.remove(path)
                    print("− %s" % os.path.relpath(path, root))
                except OSError as exc:
                    print("! could not remove %s: %s" % (os.path.relpath(path, root), exc))
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(payload)
            print("✎ %s" % os.path.relpath(path, root))
        for n in notes:
            print("⚠ %s" % n)
        if not actions and not args.quiet:
            print("comms-index: already in sync (%d meeting(s))" % len(meetings))
        return 1 if actions else 0

    # --check (default)
    if actions and not args.quiet:
        print("comms-index: %d generated artefact(s) are behind the meetings:"
              % len(actions))
        for kind, path, _ in actions:
            verb = "remove" if kind == "remove" else "update"
            print("  %s %s" % (verb, os.path.relpath(path, root)))
    if notes and not args.quiet:
        for n in notes:
            print("⚠ %s" % n)
    return 1 if actions else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
