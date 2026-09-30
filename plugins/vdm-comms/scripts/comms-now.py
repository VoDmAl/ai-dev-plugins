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
import os
import re
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


def due_of(item):
    value = item.get("due")
    if not value:
        return None
    try:
        return datetime.date.fromisoformat(str(value))
    except ValueError:
        return None


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
        text = item_text(item)
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

    soon_lines = []
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

    sections = [("now-mine", with_replies(mine_lines))]
    sections.append(("now-soon", with_replies(soon_lines)))
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
