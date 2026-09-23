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

Every link is computed from the directory of the file it is written INTO.
The first version wrote `../../<meeting>` into every pointer, which is right for
a one-segment track and wrong for every deeper one: from `<root>/<x>/comms/` it
lands in `<root>/meetings/`, and in a note vault a click on it creates an empty
file there. A repository whose tracks all sit two segments deep had all 87 of
its pointers broken that way.

`comms.link-style` picks the syntax: `markdown` (default) or `wikilink`, for a
repository kept as a note vault, where a code span or a markdown link is not an
edge of the graph.

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
ROLE_RE = re.compile(r"^(index|prep|agenda|pitch(-v\d+)?)\.md$")
TOPIC_HEAD_RE = re.compile(r"^##\s+((?:Тема|Topic)\s+\d+\.\s*(.+?))\s*$", re.M)
SOURCE_ORDER = ("index.md", "agenda.md", "prep.md")
ROLE_ORDER = {"index.md": 0, "agenda.md": 1, "prep.md": 2}
GENERATED_BY = "vdm-comms"

REGISTRY_START = "<!-- registry:start -->"
REGISTRY_END = "<!-- registry:end -->"
SERIES_START = "<!-- meetings:start -->"
SERIES_END = "<!-- meetings:end -->"

SKIP_DIRS = ("node_modules", "vendor", "__pycache__", "attachments", "_import")

COLUMNS = ("date", "meeting", "series", "people", "tracks", "topics", "materials")
REGISTRY_COLUMNS = ("date", "meeting", "series", "tracks")
SERIES_COLUMNS = ("date", "meeting")
LINK_STYLES = ("markdown", "wikilink")


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
        self.body = ""
        self.title = self.slug
        for leaf in SOURCE_ORDER:
            path = os.path.join(root, meetings_dir, dir_name, leaf)
            if os.path.isfile(path):
                self.source = leaf
                try:
                    self.data, body = fm.read(path)
                except (fm.FrontmatterError, OSError):
                    self.data, body = {}, ""
                self.body = body or ""
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
    def abs_dir(self):
        return os.path.join(self.root, self.meetings_dir, self.dir_name)

    @property
    def abs_source(self):
        return os.path.join(self.abs_dir, self.source) if self.source else None

    def _list(self, key):
        raw = self.data.get(key) or []
        if isinstance(raw, str):
            raw = [raw]
        return [str(x) for x in raw if x]

    @property
    def tracks(self):
        return self._list("tracks")

    @property
    def people(self):
        return self._list("people")

    @property
    def series(self):
        s = self.data.get("series")
        return str(s) if s else ""

    @property
    def topics(self):
        return [t for t in (self.data.get("topics") or []) if isinstance(t, dict)]

    def topics_for(self, track):
        out = []
        for topic in self.topics:
            if str(topic.get("track") or "") == track:
                name = str(topic.get("name") or "").strip()
                if name:
                    out.append(name)
        return out

    def topic_heading(self, name):
        """The body's own heading for a topic, or None. An anchor has to name
        the heading exactly as written, so it is read, never composed — a
        composed `Topic 3. …` in a repository that writes `Тема 3. …` is a
        link that opens the file and silently misses the section."""
        for m in TOPIC_HEAD_RE.finditer(self.body):
            if m.group(2).strip() == name:
                return m.group(1).strip()
        return None

    def materials(self):
        """The other role files and the transcripts, in a stable order."""
        try:
            leaves = sorted(os.listdir(self.abs_dir))
        except OSError:
            return []
        roles = sorted((leaf for leaf in leaves if ROLE_RE.match(leaf) and leaf != self.source),
                       key=lambda leaf: (ROLE_ORDER.get(leaf, 3), leaf))
        transcripts = [leaf for leaf in leaves if leaf.startswith("transcript")]
        return roles + transcripts


class Writer:
    """How links are written into ONE generated file: from its directory, in
    the configured style. A link's target is always an absolute path until the
    last moment, and becomes relative to `here` only here — there is no other
    place a relative path is made, so there is no other place to get it wrong.
    """

    def __init__(self, here, style):
        self.here = here
        self.style = style

    def rel(self, path):
        return os.path.relpath(path, self.here).replace(os.sep, "/")

    def link(self, path, text, table=False, anchor=None):
        target = self.rel(path)
        if table:
            text = text.replace("|", "\\|")
        if self.style == "wikilink":
            if target.endswith(".md"):
                target = target[:-3]
            if anchor:
                target += "#" + anchor
            return "[[%s%s%s]]" % (target, "\\|" if table else "|", text)
        return "[%s](%s)" % (text, target.replace(" ", "%20"))


def link_style(cfg):
    style = str(cfg.get("link-style") or "markdown")
    return style if style in LINK_STYLES else "markdown"


def columns(cfg, key, default, notes):
    raw = cfg.get(key)
    if not isinstance(raw, list) or not raw:
        return list(default)
    unknown = [c for c in raw if c not in COLUMNS]
    if unknown:
        notes.append("comms.%s: unknown column(s) %s — known: %s"
                     % (key, ", ".join(map(str, unknown)), ", ".join(COLUMNS)))
    return [c for c in raw if c in COLUMNS] or list(default)


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


# --------------------------------------------------------------------------- #
# cells
# --------------------------------------------------------------------------- #

def _material_label(leaf, lab):
    if leaf.startswith("transcript"):
        return lab["material-transcript"]
    return leaf[:-3] if leaf.endswith(".md") else leaf


def _track_cell(w, root, track):
    """Markdown keeps the code span it always had. In a vault every mention is
    an edge of the graph, so a track becomes a link to its `index.md` — or to
    `<track>.md` when the track is a file — and stays plain text when there is
    nothing to open."""
    if w.style != "wikilink":
        return "`%s`" % track
    short = track.split("/", 1)[1] if "/" in track else track
    base = os.path.join(root, track)
    if os.path.isdir(base):
        index = os.path.join(base, "index.md")
        return w.link(index, short, table=True) if os.path.isfile(index) else short
    if os.path.isfile(base + ".md"):
        return w.link(base + ".md", short, table=True)
    return short


def _person_cell(w, root, cfg, slug):
    profile = os.path.join(root, str(cfg.get("people-dir") or "people").strip("/"), slug + ".md")
    return w.link(profile, slug, table=True) if os.path.isfile(profile) else slug


def _cell(col, w, root, cfg, lab, m):
    if col == "date":
        return m.date
    if col == "meeting":
        if m.abs_source:
            return w.link(m.abs_source, m.title, table=True)
        return m.title.replace("|", "\\|")
    if col == "series":
        if not m.series:
            return "—"
        spath = os.path.join(root, m.meetings_dir, "%s.md" % m.series)
        if w.style == "wikilink" and os.path.isfile(spath):
            return w.link(spath, m.series, table=True)
        return m.series
    if col == "people":
        return ", ".join(_person_cell(w, root, cfg, p) for p in m.people) or "—"
    if col == "tracks":
        return ", ".join(_track_cell(w, root, t) for t in m.tracks) or "—"
    if col == "topics":
        n = len(m.topics)
        tails = sum(1 for t in m.topics if t.get("tail") is True or not t.get("track"))
        return lab["topics-tails"] % {"n": n, "tails": tails} if tails else str(n)
    if col == "materials":
        return " · ".join(w.link(os.path.join(m.abs_dir, leaf), _material_label(leaf, lab), table=True)
                          for leaf in m.materials()) or "—"
    return "—"


def _table(meetings, cols, w, root, cfg, lab, empty):
    rows = ["| %s |" % " | ".join(lab["col-%s" % c] for c in cols),
            "|%s|" % "|".join("---" for _ in cols)]
    for m in sorted(meetings, key=lambda x: x.date, reverse=True):
        rows.append("| %s |" % " | ".join(_cell(c, w, root, cfg, lab, m) for c in cols))
    if len(rows) == 2:
        filler = ["—"] * len(cols)
        filler[min(1, len(cols) - 1)] = empty
        rows.append("| %s |" % " | ".join(filler))
    return "\n".join(rows)


def registry_table(root, meetings_dir, meetings, cfg, lab, cols):
    w = Writer(os.path.join(root, meetings_dir), link_style(cfg))
    return _table(meetings, cols, w, root, cfg, lab, lab["registry-empty"])


def series_table(root, meetings_dir, meetings, series, cfg, lab, cols):
    w = Writer(os.path.join(root, meetings_dir), link_style(cfg))
    picked = [m for m in meetings if m.series == series]
    return _table(picked, cols, w, root, cfg, lab, lab["series-empty"])


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


def pointer_body(root, meeting, track, cfg, lab):
    w = Writer(os.path.join(root, track, "comms"), link_style(cfg))
    source_text = meeting.source or lab["pointer-record"]
    target = meeting.abs_source or meeting.abs_dir
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
        # `link` stays the bare relative path and `source` its text, so a
        # project that overrode `pointer-line` in the old `[%(source)s](%(link)s)`
        # form keeps working; `ref` is the link already written in the style.
        lab["pointer-line"] % {"date": meeting.date,
                               "source": source_text,
                               "link": w.rel(target),
                               "ref": w.link(target, source_text)},
        "",
    ]
    materials = meeting.materials()
    if materials:
        lines.append(lab["pointer-materials"] % {
            "list": " · ".join(w.link(os.path.join(meeting.abs_dir, leaf), _material_label(leaf, lab))
                               for leaf in materials)})
        lines.append("")
    topics = meeting.topics_for(track)
    if topics:
        lines.append(lab["pointer-topics"])
        lines.append("")
        for name in topics:
            # An anchor only where it can land: a wikilink to a heading the
            # body really has. Markdown anchors are renderer-specific slugs,
            # and a guessed one is a link that silently misses its section.
            heading = meeting.topic_heading(name) if w.style == "wikilink" and meeting.abs_source else None
            lines.append("- %s" % (w.link(meeting.abs_source, name, anchor=heading) if heading else name))
        lines.append("")
    lines.append("<!-- generated by %s — edits here are overwritten -->" % GENERATED_BY)
    lines.append("")
    return "\n".join(lines)


def is_directory_track(root, track):
    return os.path.isdir(os.path.join(root, track))


def plan(root, meetings_dir, meetings, cfg, lab):
    """Return (actions, notes). Each action is (kind, path, payload)."""
    actions = []
    notes = []
    reg_cols = columns(cfg, "registry-columns", REGISTRY_COLUMNS, notes)
    ser_cols = columns(cfg, "series-columns", SERIES_COLUMNS, notes)
    if str(cfg.get("link-style") or "markdown") not in LINK_STYLES:
        notes.append("comms.link-style: %r is not one of %s — markdown is used"
                     % (cfg.get("link-style"), ", ".join(LINK_STYLES)))

    # 1. Registry.
    index_path = os.path.join(root, meetings_dir, "INDEX.md")
    table = registry_table(root, meetings_dir, meetings, cfg, lab, reg_cols)
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
                                      series_table(root, meetings_dir, meetings, series,
                                                   cfg, lab, ser_cols))
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
            wanted[p] = pointer_body(root, m, track, cfg, lab)

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
    actions, notes = plan(root, meetings_dir, meetings, cfg, cfgmod.labels(cfg))

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
