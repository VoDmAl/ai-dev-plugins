#!/usr/bin/env python3
"""comms-now.py — build the live `signals/now.md` from the project's homes.

`now.md` is the owner's STATE, not a news feed: what waits for the owner's move,
what falls due today and tomorrow, what others lead. It is rebuilt from the
homes — the open items of the files in `comms.pending-paths` — by this script,
without a model, and never edited by hand: an item's text lives in its home,
and the build only carries it over.

Who runs it (workitem vdm-comms-live-now, DL #1, owner 2026-09-30): not a hook.
The plugin's hooks write no project files (comms-plugin DL #9). echelon runs
this after a pass (`after_pass` of the project), and a session runs it when the
hook says the file is behind.

What goes where (DL #7):
  * «your move» — items owned by one of `comms.now.owner`; another owner's item
    whose date has passed (lifted, saying whose it was); unsent drafts, since
    what goes out in the owner's name waits for the owner;
  * «today and tomorrow» — every item due on those two days;
  * «led by others» — the rest, grouped by owner.

An item with a block id (`^a3f` at the end of its line) links to that line in
its home, in `comms.link-style`; one without is shown with its `file:line`.

The owner may write a reply straight into now.md — a line starting `>>@ai`
under an item (DL #3). A rebuild keeps it under the item with the same block id;
when that item is gone, the reply moves to the top, under «replies without an
item». The session answers the reply and deletes the line; the build never
drops one.

Frontmatter: `built:` (the moment of this build) and `your-move:` (the count
the session-start line shows) — agreed with echelon (DL #6).

Usage: comms-now.py [--project-root DIR] [--stdout]
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import comms_config as cfgmod  # noqa: E402

DEFAULT_PATH = "signals/now.md"
LINK_STYLES = ("markdown", "wikilink")

# An Obsidian block id ends the line: ` ^a3f`.
ID_RE = re.compile(r"\s\^([A-Za-z0-9-]+)\s*$")
# The id an item line of now.md links to: `#^a3f|` (wikilink) or `#^a3f)` (markdown).
LINKED_ID_RE = re.compile(r"#\^([A-Za-z0-9-]+)[|)]")
# A reply: `>>@ai` at the start of the line (list indentation allowed), any case.
REPLY_RE = re.compile(r"^\s*>>@ai\b", re.IGNORECASE)
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def load_pending():
    """comms-pending, loaded by path — its name has a hyphen. Its definition of
    an item is the one this build must use, not a second copy of it."""
    spec = importlib.util.spec_from_file_location("comms_pending", os.path.join(HERE, "comms-pending.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def link(style, here_dir, root, relpath, text, anchor=None):
    target = os.path.relpath(os.path.join(root, relpath), here_dir).replace(os.sep, "/")
    if style == "wikilink":
        if target.endswith(".md"):
            target = target[:-3]
        if anchor:
            target += "#^" + anchor
        return "[[%s|%s]]" % (target, text)
    target = target.replace(" ", "%20")
    if anchor:
        target += "#^" + anchor
    return "[%s](%s)" % (text, target)


def block_id(item):
    m = ID_RE.search(item.get("line") or "")
    return m.group(1) if m else None


def item_text(item):
    return ID_RE.sub("", item.get("text") or "").strip()


SHORT_MAX = 200
SHORT_MIN = 60
# A sentence ends at . ! ? followed by a space; "15.09", "v1.2" inside a clause
# do not end one, the space after the stop does. An initial — "Смирнов В. 30.09"
# — does not end one either (measured on hq's homes, 2026-09-30).
SENTENCE_END_RE = re.compile(r"(?<!\s[A-ZА-ЯЁ])(?<!^[A-ZА-ЯЁ])(?<!\([A-ZА-ЯЁ])[.!?…](?=\s)")


def shorten(text, due=None):
    """The start of an item, not its paragraph (owner, 2026-09-30, DL #8): the
    first sentence, at most ~SHORT_MAX characters, cut at a word and marked «…».
    The date is kept when it was in the part cut off; a code span or emphasis cut
    in half is closed, so the cut does not leak markup into the next line."""
    if len(text) <= SHORT_MAX and not SENTENCE_END_RE.search(text[:-1] if text else ""):
        return text
    # The first sentence — unless it is too short to say what the item is about
    # ("⏰ Отправлено 21.09."), then up to the next one, within SHORT_MAX.
    end = None
    for m in SENTENCE_END_RE.finditer(text):
        if m.end() > SHORT_MAX:
            break
        end = m.end()
        if end >= SHORT_MIN:
            break
    if end and end >= SHORT_MIN and end < len(text.rstrip()):
        cut = text[:end]
    elif len(text) > SHORT_MAX:
        cut = text[:SHORT_MAX]
        if " " in cut:
            cut = cut[:cut.rfind(" ")]
    else:
        return text
    cut = cut.rstrip()
    if cut.count("`") % 2:
        cut += "`"
    stars = cut.count("*") - 2 * cut.count("**")
    if cut.count("**") % 2:
        cut += "**"
    if stars % 2:
        cut += "*"
    cut += " …"
    if due and due.isoformat() not in cut:
        cut += " ⏰ %s" % due.isoformat()
    return cut


def due_of(item):
    value = item.get("due")
    if not value:
        return None
    try:
        return datetime.date.fromisoformat(str(value))
    except ValueError:
        return None


MSK = datetime.timezone(datetime.timedelta(hours=3))


def echelon_bin(now_cfg):
    """→ path of echelon's `bin/echelon`, or None when the project switched it off.

    `ECHELON_BIN` wins (tests, an unusual install); then `comms.now.echelon` as a
    path; then `ECHELON_HOME` — echelon's own convention, the one its sheet skill
    uses — with its default checkout."""
    setting = now_cfg.get("echelon", True)
    if setting is False:
        return None
    if os.environ.get("ECHELON_BIN"):
        return os.environ["ECHELON_BIN"]
    if isinstance(setting, str) and setting.strip():
        return os.path.expanduser(setting.strip())
    home = os.environ.get("ECHELON_HOME") or os.path.join(os.path.expanduser("~"), "AI Projects", "echelon")
    return os.path.join(home, "bin", "echelon")


def echelon_json(binary, command, root):
    """→ (data, None) or (None, why). echelon exits 0 on an incomplete slice too;
    incompleteness is in `complete` / `errors`, and the build shows it."""
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        return None, "no %s" % binary
    try:
        run = subprocess.run([binary, command, "--project", root, "--json"],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, "%s %s: %s" % (os.path.basename(binary), command, exc)
    if run.returncode != 0:
        tail = (run.stderr or "").strip().splitlines()
        return None, "%s %s: %s" % (os.path.basename(binary), command, tail[-1] if tail else "exit %d" % run.returncode)
    try:
        return json.loads(run.stdout), None
    except ValueError:
        return None, "%s %s: not JSON" % (os.path.basename(binary), command)


def mentions(ref, text):
    return re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(ref), text or "") is not None


def event_line(event, lab, today):
    """`- 🗓 today 15:00–16:00 (MSK 18:00–19:00) **Title**` — the machine's zone
    first, Moscow in brackets when the machine is elsewhere (the sheet's rule).
    The project's meetings in bold, the rest dimmed; a cancelled one struck."""
    try:
        start = datetime.datetime.fromisoformat(event["start"]).astimezone()
        end = datetime.datetime.fromisoformat(event["end"]).astimezone() if event.get("end") else None
    except (KeyError, TypeError, ValueError):
        return None
    span = start.strftime("%H:%M") + ("–" + end.strftime("%H:%M") if end else "")
    if start.utcoffset() != datetime.timedelta(hours=3):
        m_start = start.astimezone(MSK)
        m_span = m_start.strftime("%H:%M") + ("–" + end.astimezone(MSK).strftime("%H:%M") if end else "")
        span += " (%s %s)" % (lab["now-msk"], m_span)
    title = str(event.get("title") or "").strip()
    if event.get("canceled"):
        title = "~~%s~~" % title
    elif event.get("relevant"):
        title = "**%s**" % title
    else:
        title = "_%s_" % title
    day = start.date()
    if day == today:
        when = lab["now-today"]
    elif day == today + datetime.timedelta(days=1):
        when = lab["now-tomorrow"]
    else:
        when = day.isoformat()
    return start, "- 🗓 %s %s %s" % (when, span, title)


def task_line(task):
    """One line for an echelon task. A Jira key or an MR is its `ref` beside the
    title; where the title already says the ref — a letter's subject is both, a
    chat's title names the chat — it is said once. The link is the `url`; a chat
    without one (anything but a Telegram supergroup) links to its anchor in the
    project's mirror, which Obsidian resolves by name (echelon, 2026-09-30)."""
    ref = str(task.get("ref") or "").strip()
    title = str(task.get("title") or "").strip()
    url = str(task.get("url") or "").strip()
    mirror = str(task.get("mirror") or "").strip()
    if ref and title and ref not in title:
        label, rest = ref, " · " + title
    else:
        label, rest = title or ref, ""
    if url:
        head = "[%s](%s)" % (label, url)
    elif mirror:
        head = "[[%s|%s]]" % (mirror, label)
    else:
        head = label
    line = "- ↗ %s%s" % (head, rest)
    if task.get("why"):
        line += " — %s" % task["why"]
    return line


def old_replies(path):
    """→ ({block id: [reply lines]}, [orphan reply lines]) from the current now.md.

    A reply belongs to the item line above it. Lines inside a code block are
    not replies — the marker is one only as prose."""
    by_id, orphans = {}, []
    if not os.path.isfile(path):
        return by_id, orphans
    current, fenced = None, False
    with open(path, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if FENCE_RE.match(line):
                fenced = not fenced
                continue
            if fenced:
                continue
            if line.startswith("#"):
                current = None
                continue
            if REPLY_RE.match(line):
                if current:
                    by_id.setdefault(current, []).append(line)
                else:
                    orphans.append(line)
                continue
            m = LINKED_ID_RE.search(line)
            if m and line.lstrip().startswith("- "):
                current = m.group(1)
    return by_id, orphans


def build(root, cfg, today, now_cfg, pending):
    lab = cfgmod.labels(cfg)
    style = str(cfg.get("link-style") or "markdown")
    if style not in LINK_STYLES:
        style = "markdown"
    out_rel = str(now_cfg.get("path") or DEFAULT_PATH)
    out_path = os.path.join(root, out_rel)
    here = os.path.dirname(out_path)
    owners_me = [str(o) for o in (now_cfg.get("owner") or [])]
    folded_me = {pending.fold(o) for o in owners_me}

    def home_of(item):
        # The track a line lives in: its directory for an index.md, else the file.
        rel = item["file"]
        base = os.path.basename(rel)
        if base in ("index.md", "README.md"):
            return os.path.basename(os.path.dirname(rel)) or base
        return base[:-3] if base.endswith(".md") else base

    def render(item, suffix=""):
        bid = block_id(item)
        text = shorten(item_text(item), due_of(item))
        if bid:
            line = "- %s · %s · %s" % (link(style, here, root, item["file"], bid, bid), home_of(item), text)
        else:
            line = "- %s · %s — %s:%s" % (home_of(item), text, item["file"], item.get("line_no"))
        return line + suffix

    items = pending.collect(root, cfg, today)
    tomorrow = today + datetime.timedelta(days=1)

    def is_mine(item):
        return item.get("owner_kind") == "owner" and pending.fold(item.get("owner") or "") in folded_me

    def owner_label(item):
        kind = item.get("owner_kind")
        if kind == "us":
            return lab["now-us"]
        if kind == "missing" or not item.get("owner") or item.get("owner") == "(no owner)":
            return lab["now-no-owner"]
        return item["owner"]

    mine, others = [], {}
    for item in items:
        due = due_of(item)
        if is_mine(item):
            mine.append((due or datetime.date.max, 0, render(item)))
        elif due and due < today:
            suffix = " — ⬆ " + lab["now-lifted"] % {"due": due.isoformat(), "owner": owner_label(item)}
            mine.append((due, 1, render(item, suffix)))
        else:
            others.setdefault(owner_label(item), []).append((due or datetime.date.max, render(item)))
    mine.sort(key=lambda t: (t[0], t[1]))
    mine_lines = [t[2] for t in mine]
    for draft in pending.unsent_drafts(root, cfg, today, min_age=0):
        name = os.path.basename(draft["file"])[:-3] if draft["file"].endswith(".md") else draft["file"]
        mine_lines.append("- ✉ %s: %s" % (lab["now-draft"], link(style, here, root, draft["file"], name)))

    # echelon: the owner's tasks bypass the filter (ТЗ §2), and the calendar
    # fills «today and tomorrow». A task an owner's home item already carries is
    # not doubled — the home's text is the session's, and richer.
    notes_mine, notes_soon, events = [], [], []
    binary = echelon_bin(now_cfg)
    if binary:
        owner_texts = [item_text(i) for i in items if is_mine(i)]
        mine_data, why = echelon_json(binary, "mine", root)
        soon_data, why_soon = echelon_json(binary, "soon", root)
        if why and why_soon:
            notes_mine.append("- ⚠ " + lab["now-echelon-missing"] % {"why": why})
        if mine_data is not None:
            if mine_data.get("complete") is False and mine_data.get("errors"):
                notes_mine.append("- ⚠ " + lab["now-incomplete"] % {"errors": "; ".join(map(str, mine_data["errors"]))})
            for task in mine_data.get("items") or []:
                ref = str(task.get("ref") or "")
                if task.get("turn") == "owner":
                    if ref and any(mentions(ref, t) for t in owner_texts):
                        continue
                    mine_lines.append(task_line(task))
                else:
                    others.setdefault(lab["now-echelon-others"], []).append((datetime.date.max, task_line(task)))
        if soon_data is not None:
            if soon_data.get("complete") is False and soon_data.get("errors"):
                notes_soon.append("- ⚠ " + lab["now-incomplete"] % {"errors": "; ".join(map(str, soon_data["errors"]))})
            for event in soon_data.get("events") or []:
                got = event_line(event, lab, today)
                if got:
                    events.append(got)
    events.sort(key=lambda t: t[0])

    soon_lines = [line for _, line in events]
    for item in sorted(items, key=lambda i: (due_of(i) or datetime.date.max)):
        due = due_of(item)
        if due == today:
            soon_lines.append(render(item).replace("- ", "- ⏰ %s: " % lab["now-today"], 1))
        elif due == tomorrow:
            soon_lines.append(render(item).replace("- ", "- ⏰ %s: " % lab["now-tomorrow"], 1))

    replies, orphans = old_replies(out_path)

    body = []
    instructions = now_cfg.get("instructions")
    if instructions:
        body.append(link(style, here, root, str(instructions), lab["now-instructions"]))
    else:
        body.append("> " + lab["now-no-instructions"])
    body.append("")

    placed = set()

    def with_replies(lines):
        res = []
        for line in lines:
            res.append(line)
            m = LINKED_ID_RE.search(line)
            if m and m.group(1) in replies and m.group(1) not in placed:
                res.extend(replies[m.group(1)])
                placed.add(m.group(1))
        return res

    sections = [("now-mine", notes_mine + with_replies(mine_lines))]
    sections.append(("now-soon", notes_soon + with_replies(soon_lines)))
    other_lines = []
    for owner in sorted(others, key=lambda o: (o in (lab["now-us"], lab["now-no-owner"]), pending.fold(o))):
        other_lines.append("### %s" % owner)
        other_lines.append("")
        other_lines.extend(with_replies([r for _, r in sorted(others[owner], key=lambda t: t[0])]))
        other_lines.append("")
    sections.append(("now-others", other_lines))

    lost = list(orphans)
    for bid, lines in replies.items():
        if bid not in placed:
            lost.extend(lines)
    if lost:
        body.append("## %s" % lab["now-orphans"])
        body.append("")
        body.extend(lost)
        body.append("")

    for key, lines in sections:
        body.append("## %s" % lab[key])
        body.append("")
        while lines and lines[-1] == "":
            lines = lines[:-1]
        body.extend(lines if lines else ["_%s_" % lab["now-empty"]])
        body.append("")

    built = datetime.datetime.now().astimezone().replace(microsecond=0).isoformat()
    front = ["---", "built: %s" % built, "your-move: %d" % len(mine_lines), "---", ""]
    return out_path, "\n".join(front + body).rstrip("\n") + "\n", len(mine_lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build signals/now.md from the project's homes.")
    ap.add_argument("--project-root", default=None)
    ap.add_argument("--stdout", action="store_true", help="print instead of writing the file")
    args = ap.parse_args(argv)

    root = os.path.abspath(args.project_root or cfgmod.project_root_of(os.getcwd()))
    cfg, err = cfgmod.load(root)
    if err:
        print("comms-now: %s — nothing built." % err, file=sys.stderr)
        return 2
    now_cfg = cfg.get("now")
    if not isinstance(now_cfg, dict):
        print("comms-now: comms.now is not configured in %s — nothing built. "
              "Set it in .claude/vdm-plugins.json: {\"comms\": {\"now\": {\"owner\": [\"<the owner's name in items>\"]}}}"
              % root, file=sys.stderr)
        return 2
    if not now_cfg.get("owner"):
        print("comms-now: comms.now.owner is empty — which names in the items mean the owner? Nothing built.",
              file=sys.stderr)
        return 2
    if not cfg.get("pending-paths"):
        print("comms-now: comms.pending-paths is not set — there are no homes to build from. Nothing built.",
              file=sys.stderr)
        return 2

    pending = load_pending()
    out_path, text, n = build(root, cfg, cfgmod.today(), now_cfg, pending)
    if args.stdout:
        sys.stdout.write(text)
        return 0
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, out_path)
    print("comms-now: %s — your move: %d" % (os.path.relpath(out_path, root), n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
