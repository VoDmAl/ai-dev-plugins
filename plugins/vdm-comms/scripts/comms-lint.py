#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms-lint — contract validator for a meetings tree.

The contract is a FLOOR, not a ceiling: what the linter checks is the part
three independent repositories turned out to share, measured on their live
trees rather than on their documentation. Extra frontmatter keys, extra
sections and extra file classes are never violations — a project layers its own
conventions on top, and this linter stays silent about them.

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
  * a series file's `slug:`, when present, names the file — a slug that
    disagrees is a contradiction, and contradictions are what the floor reports
  * the BODY of a series file is never checked
  * a directory without <meetings-dir> exits silently

Above the floor sit a project's OWN conventions, which the plugin enforces
only when the project names them — `comms.meeting-rules`:

    forbidden-keys    [keys]   frontmatter keys a meeting file must not carry
    people-profiles   true     every people / absent / topics[].owner has a profile;
                               a series file's counterparts too (warning)
    topic-owner       [roles]  every topic in these role files names an owner
    tail-owner        true     a topic with no track names an owner
    max-must          N        an agenda carries at most N `must: true` topics
    topic-track-line  "> …"    the first line under each topic heading starts so,
                               and carries a link or the word "tail" / "хвост"
    series-slug       true     a series file carries `slug:` at all
    covered-bool      true     a record's `covered:` is true or false (warning)
    unique-topics     true     topic names do not repeat (warning)
    required-keys     [keys]   keys that must be present (null and [] allowed)

A file carrying `migrated_from` is a record imported as it was: the authoring
rules (topic-owner, max-must, topic-track-line) skip it, and the reference
rules (people-profiles, tail-owner) only warn — it was written before the
convention, and failing it for that is reporting history as a defect.

Exit: 0 clean (warnings do not count), 1 violations found.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fm  # noqa: E402

DIR_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-([^/]+)$")
ROLE_RE = re.compile(r"^(index|prep|agenda|pitch(-v\d+)?)\.md$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TOPIC_HEAD_RE = re.compile(r"^##\s+((?:Тема|Topic)\s+\d+\.\s*.+?)\s*$")
TAIL_WORDS = ("хвост", "tail")

# Outgoing letters: `<track>/comms/<date>-<slug>-out.md`.
LETTER_RE = re.compile(r"(^|/)comms/[^/]+-out\.md$")
HEADING_ANY_RE = re.compile(r"^#{1,6}\s")
ATTACH_HEAD_RE = re.compile(r"^#{1,6}\s*📎")
CHECK_ITEM_RE = re.compile(r"^\s*[-*]\s+\[[ xX]\]\s+(.*)$")
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\(\s*<?([^)>]+?)>?\s*\)")
WIKI_LINK_RE = re.compile(r"\[\[[^\]]+\]\]")

KNOWN_TYPES = ("meeting", "meeting-series", "index", "readme", "meeting-link")

today = cfgmod.today
track_exists = cfgmod.track_exists
project_root_of = cfgmod.project_root_of

class Report:
    """A verdict on one file. `skipped` is the third outcome besides "failed" and
    "passed": nothing on this file was under a rule. It exists because printing
    `ok` — or nothing — for a file that was never checked is the same answer as
    for a file that was checked and clean, and a reader cannot tell them apart.
    Field case, 2026-09-23: 88 letters with a multi-line goal read as having
    passed, when the linter had not looked at them at all."""

    def __init__(self, path):
        self.path = path
        self.errors = []
        self.warnings = []
        self.skipped = None

    def error(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def skip(self, reason):
        self.skipped = reason

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
    if LETTER_RE.search(rel.replace(os.sep, "/")):
        return _lint_letter(rep, path)
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
        else:
            rep.skip("no frontmatter and not a role file — raw material is not under contract")
        return rep

    if is_role or ftype == "meeting":
        if ftype is not None and ftype != "meeting":
            rep.warn("`type: %s` on a role file — the shared contract says `meeting`, "
                     "and the role comes from the file name" % ftype)
        _lint_meeting(rep, data, body, path, rel, kind, dir_name, leaf, cfg, project_root)
        return rep

    if ftype == "meeting-series":
        _lint_series(rep, data, rel, meetings_dir, rules_of(cfg), cfg, project_root)
        return rep

    # index / readme / generated pointers own their own shape; an unknown type
    # on a non-role file is a project's own class, not a violation.
    rep.skip("not a role file, and `type: %s` carries no contract here — only its "
             "frontmatter was read" % (ftype if ftype is not None else "—"))
    return rep


def _lint_letter(rep, path):
    """An outgoing letter that attaches files lists them where the person who
    sends it will look: a `📎` section in the body, one `- [ ]` per file, each a
    link to the file itself.

    Not the frontmatter — nobody reads it while sending, it is the machine
    layer. Not a path in backticks in a blockquote — it does not click and it
    blends into the header. Both were tried on a live letter, and the
    attachment got lost while the body already said "attached".

    Soft until named: checked only for a letter not yet sent, and only once the
    letter itself says it attaches something (`attachments:` in its
    frontmatter, or a `📎` heading). A letter that attaches nothing is never
    asked about attachments. The frontmatter is read leniently — a letter is
    not under the meeting contract, and a shape the vendored reader does not
    know must not turn into a verdict about the letter."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        rep.error("cannot read file: %s" % exc)
        return rep
    try:
        fm_text, body = fm.split_frontmatter(text)
    except fm.FrontmatterError:
        return rep
    if fm.scalar_keys(fm_text).get("sent") not in (None, "", False):
        rep.skip("a letter already sent — the record is history")
        return rep
    try:
        attachments = fm.parse(fm_text).get("attachments") if fm_text.strip() else None
    except fm.FrontmatterError:
        attachments = None
    if isinstance(attachments, str):
        attachments = [attachments]
    declared = [a for a in (attachments or []) if a] if isinstance(attachments, list) else []

    has_section, in_section, items = False, False, []
    for line in body.split("\n"):
        if HEADING_ANY_RE.match(line):
            in_section = bool(ATTACH_HEAD_RE.match(line))
            has_section = has_section or in_section
            continue
        if in_section:
            m = CHECK_ITEM_RE.match(line)
            if m:
                items.append(m.group(1))

    if declared and not has_section:
        rep.error("`attachments:` names %d file(s), but the body has no `## 📎 …` section — "
                  "the person sending the letter reads the body, not the frontmatter: one "
                  "`- [ ] [<name the file goes out under>](attachments/<file>) — what it is and "
                  "why now` per file, before the letter text" % len(declared))
        return rep
    if not has_section:
        rep.skip("a letter that attaches nothing — the 📎 checklist is the only rule "
                 "for letters")
        return rep
    if not items:
        rep.error("the 📎 section has no `- [ ]` items — one checkbox per file to attach")
        return rep
    here = os.path.dirname(os.path.abspath(path))
    for item in items:
        links = MD_LINK_RE.findall(item)
        if not links and not WIKI_LINK_RE.search(item):
            rep.error("a 📎 item is not a link to the file: %r — a path in backticks does "
                      "not open" % item[:80])
            continue
        for _text, target in links:
            if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                continue  # a URL is somebody else's to keep alive
            local = urllib.parse.unquote(target.split("#", 1)[0])
            if local and not os.path.exists(os.path.normpath(os.path.join(here, local))):
                rep.error("a 📎 item links %s, which does not exist next to the letter"
                          % target)
    return rep


def rules_of(cfg):
    """`comms.meeting-rules` as a dict; anything else reads as "no rules"."""
    raw = cfg.get("meeting-rules")
    return raw if isinstance(raw, dict) else {}


def _str_list(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(v) for v in value if isinstance(v, (str, int, float)) and str(v)]
    return []


def _lint_series(rep, data, rel, meetings_dir, rules, cfg, project_root):
    parts = rel.split(os.sep)
    if len(parts) != 2:
        rep.error("a series file belongs at %s/<series>.md" % meetings_dir)
    name = os.path.splitext(parts[-1])[0]
    slug = data.get("slug")
    if slug is not None and str(slug) != name:
        rep.error("`slug: %s` disagrees with the file name %s.md" % (slug, name))
    elif slug is None and rules.get("series-slug"):
        rep.error("no `slug:` — comms.meeting-rules.series-slug asks every series file to "
                  "carry one (= %s)" % name)
    # The people a series meets live in its `counterparts:`; a name there with no
    # profile is the same gap as in a meeting's `people:`. A WARNING, not an
    # error: that is what the tool this plugin replaced said, and the switch was
    # accepted file for file on the number of warnings — turning it into an error
    # would change the verdict without anything in the field asking for it.
    if rules.get("people-profiles"):
        pdir = str(cfg.get("people-dir") or "people").strip("/")
        values = data.get("counterparts")
        values = [values] if isinstance(values, str) else values
        for v in values if isinstance(values, list) else []:
            slug_v = str(v).strip() if v is not None else ""
            if slug_v and not os.path.isfile(os.path.join(project_root, pdir, slug_v + ".md")):
                rep.warn("`counterparts`: no profile %s/%s.md" % (pdir, slug_v))
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

    _lint_meeting_rules(rep, data, body, leaf, cfg, project_root)

    if cfg.get("topic-sections") and not data.get("migrated_from"):
        _lint_topic_sections(rep, data, body)


def _lint_meeting_rules(rep, data, body, leaf, cfg, project_root):
    """The project's own conventions — see `comms.meeting-rules` in the module
    docstring. Each rule is off until the project names it; the floor above
    never depends on any of them."""
    rules = rules_of(cfg)
    if not rules:
        return
    role = leaf[:-3].split("-")[0] if leaf.endswith(".md") else leaf
    migrated = bool(data.get("migrated_from"))
    soft = rep.warn if migrated else rep.error
    raw_topics = data.get("topics")
    topics = [t for t in raw_topics if isinstance(t, dict)] if isinstance(raw_topics, list) else []

    def topic_label(idx, t):
        name = str(t.get("name") or "").strip()
        return "topic %d «%s»" % (idx, name) if name else "topic %d" % idx

    forbidden = _str_list(rules.get("forbidden-keys"))
    for key in forbidden:
        if key in data:
            rep.error("`%s:` is a retired key in this project (comms.meeting-rules.forbidden-keys)"
                      % key)
    for idx, t in enumerate(topics, 1):
        for key in forbidden:
            if key in t:
                rep.error("%s carries the retired key `%s:`" % (topic_label(idx, t), key))

    for key in _str_list(rules.get("required-keys")):
        if key not in data:
            rep.error("no `%s:` — comms.meeting-rules.required-keys asks for it "
                      "(null and [] are fine; the key itself says the question was answered)"
                      % key)

    if rules.get("people-profiles"):
        pdir = str(cfg.get("people-dir") or "people").strip("/")

        def has_profile(value):
            slug = str(value).strip()
            return not slug or os.path.isfile(os.path.join(project_root, pdir, slug + ".md"))

        for key in ("people", "absent"):
            values = data.get(key)
            values = [values] if isinstance(values, str) else (values or [])
            for v in values if isinstance(values, list) else []:
                if v and not has_profile(v):
                    soft("`%s`: no profile %s/%s.md" % (key, pdir, str(v).strip()))
        for idx, t in enumerate(topics, 1):
            if t.get("owner") and not has_profile(t["owner"]):
                soft("%s: owner %s has no profile %s/%s.md"
                     % (topic_label(idx, t), t["owner"], pdir, str(t["owner"]).strip()))

    if role in _str_list(rules.get("topic-owner")) and not migrated:
        for idx, t in enumerate(topics, 1):
            if not t.get("owner"):
                rep.error("%s has no `owner` — every topic in %s names one "
                          "(comms.meeting-rules.topic-owner)" % (topic_label(idx, t), leaf))

    if rules.get("tail-owner"):
        for idx, t in enumerate(topics, 1):
            if not t.get("track") and not t.get("owner"):
                soft("%s is a tail (no track) with no `owner` — who holds it on their side?"
                     % topic_label(idx, t))

    limit = rules.get("max-must")
    if (role == "agenda" and not migrated and isinstance(limit, int)
            and not isinstance(limit, bool) and limit > 0):
        musts = sum(1 for t in topics if t.get("must") is True)
        if musts > limit:
            rep.error("%d topics are `must: true` — at most %d (comms.meeting-rules.max-must)"
                      % (musts, limit))

    prefix = rules.get("topic-track-line")
    if (isinstance(prefix, str) and prefix.strip() and not migrated
            and role in ("index", "prep", "agenda")):
        _lint_track_lines(rep, body, prefix.strip())

    if rules.get("covered-bool") and role == "index":
        for idx, t in enumerate(topics, 1):
            if "covered" in t and not isinstance(t["covered"], bool):
                rep.warn("%s: `covered: %s` is neither true nor false"
                         % (topic_label(idx, t), t["covered"]))

    if rules.get("unique-topics"):
        names = [str(t.get("name") or "").strip() for t in topics if t.get("name")]
        for name in sorted({n for n in names if names.count(n) > 1}):
            rep.warn("topic name «%s» repeats — a link to its section becomes ambiguous" % name)


def _lint_track_lines(rep, body, prefix):
    """Under every `## Topic N. …` heading the first non-empty line starts with
    `prefix` and names where the topic lives: a link, or the word for a tail."""
    lines = (body or "").split("\n")
    fence = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        m = TOPIC_HEAD_RE.match(line)
        if not m:
            continue
        following = next((x.strip() for x in lines[i + 1:] if x.strip()), None)
        heading = m.group(1)
        if following is None or not following.startswith(prefix):
            rep.error("under «## %s» the first line is not «%s …»" % (heading, prefix))
        elif ("[[" not in following and "](" not in following
              and not any(w in following.lower() for w in TAIL_WORDS)):
            rep.error("«## %s»: the «%s» line names neither a track link nor a tail"
                      % (heading, prefix))


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
    print("error\tseries file slug disagrees with its file name")
    print("warning\tunknown type")
    print("warning\tseries file missing")
    print("warning\ttopic without track and without tail")
    print("never\tbody of a series file")
    print("# opt-in, comms.meeting-rules — a project's own conventions, off until named")
    print("rule\tforbidden-keys [keys]\terror: a retired key in a meeting file or a topic")
    print("rule\tpeople-profiles true\terror: people / absent / topics[].owner without <people-dir>/<slug>.md")
    print("rule\tpeople-profiles true\twarning: a series file's counterparts without <people-dir>/<slug>.md")
    print("rule\ttopic-owner [roles]\terror: a topic without owner in these role files")
    print("rule\ttail-owner true\terror: a topic with no track and no owner")
    print("rule\tmax-must N\terror: more than N `must: true` topics in agenda.md")
    print("rule\ttopic-track-line \"> …\"\terror: a topic section not opening with that line + a link or tail")
    print("rule\tseries-slug true\terror: a series file without `slug:`")
    print("rule\tcovered-bool true\twarning: `covered:` in index.md neither true nor false")
    print("rule\tunique-topics true\twarning: a topic name that repeats")
    print("rule\trequired-keys [keys]\terror: a key absent from a meeting file (null and [] allowed)")
    print("relax\tmigrated_from\tauthoring rules skip it; people-profiles and tail-owner only warn")
    print("# outgoing letters — */comms/*-out.md, not yet sent, that attach something")
    print("letter\tattachments: in frontmatter without a `## 📎 …` section\terror")
    print("letter\ta 📎 section with no `- [ ]` items, or an item that is not a link\terror")
    print("letter\ta 📎 item linking a file that does not exist next to the letter\terror")


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
        rel = os.path.relpath(os.path.abspath(path), root)
        if rep is None:
            # Named on the command line and outside the meetings tree: say so.
            # An empty answer here read as "checked, clean" in the field.
            if not args.quiet:
                print("%s: skipped (not under the meetings contract — outside %s/ and "
                      "not an outgoing letter)" % (rel, cfg["meetings-dir"]))
            continue
        for msg in rep.errors:
            print("✖ %s: %s" % (rel, msg))
        for msg in rep.warnings:
            print("⚠ %s: %s" % (rel, msg))
        if rep.errors:
            failures += 1
        elif not rep.warnings and not args.quiet:
            if rep.skipped:
                print("%s: skipped (%s)" % (rel, rep.skipped))
            else:
                print("%s: ok" % rel)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
