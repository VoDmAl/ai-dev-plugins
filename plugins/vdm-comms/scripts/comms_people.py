#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comms_people — whose `people/` a project reads, and what a profile says
about writing to that person.

Roles (owner with echelon, 2026-10-01 — echelon DL #75; here DL #2 of
`vdm-comms-outward-checks`):

  * an **HQ** keeps `people/` and writes everything in its own zone;
  * a **hand** keeps no `people/`. It writes its own: its tickets, MRs and
    branches, answers to the people in its tickets. Anyone else goes through
    the HQ, and a new person turning up in its ticket is a reason to tell the
    HQ. A hand reads the HQ's profiles straight from disk.

A hand names its HQ in `comms.hq` — the HQ's intercom identity, not a path.
A path differs per machine and per clone, while the identity does not, and
echelon knows projects by it too. The checkout comes from the intercom
directory (`<store>/_registry/<identity>.json` → `paths`), the directory name
from the HQ's own `comms.people-dir`. So an HQ that keeps its people under
`wiki/entities/people` needs no special case. No `comms.hq` means the project is
its own HQ.

Two fields in a profile's frontmatter. Both are read by echelon as well, which
is why their shape is fixed here and not left to each HQ:

    trust: team | peer | careful | top
    mail_from:
      - to: ivan@their.example
        from: Our Name <me@ours.example>

`trust` is how freely the person may be written to, and how closely the text is
checked first (owner: «не true/false а степень свободности общения и выверения
того что пишем»):

    team     a hand writes itself
    peer     a hand writes itself; the tone is the skill's
    careful  only the HQ writes; every word checked, the owner sees it first
    top      leadership; only the HQ, and the owner decides whether to write

No field, no profile, or a value outside the four reads as `careful`. That
default is the owner's rule, and it makes an unmarked profile the safe case.
`trust` is read line by line (`scalar_keys`), so a profile whose other
frontmatter is outside what the reader supports keeps its level.

`mail_from` is a list of pairs, not a map from address to address. A key holding
`@` is outside the reader's subset, and a pair is exactly what the owner named:
«этому человеку — с моего ящика y на его ящик x». In echelon's order of From,
this pair comes first.

Not to be confused with `comms.register` (`letters` § 6). That one says how a
request is made. `trust` says who may write at all, and how much checking it
takes. `peer` exists on both axes and means different things on each.

Stdlib only, like the rest of the plugin. The intercom store root is resolved
in the same order as `intercom_store_root` in the vdm plugin
(`intercom-common.sh`): $VDM_INTERCOM_ROOT, then `intercom.root` in
~/.claude/vdm-plugins.json, then ~/.claude/vdm/intercom.
"""
from __future__ import annotations

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fmmod  # noqa: E402

LEVELS = ("team", "peer", "careful", "top")
DEFAULT_LEVEL = "careful"

MEANING = {
    "team": "a hand writes itself",
    "peer": "a hand writes itself; the tone is the skill's",
    "careful": "only the HQ writes; every word checked, the owner sees it before it goes",
    "top": "leadership: only the HQ, and the owner decides whether to write at all",
}

# Shorter than this, a search would find a person in every profile's prose.
MIN_SEARCH = 3


class Unresolved(Exception):
    """The people directory this project reads could not be found."""


# --- where the profiles are -------------------------------------------------

def store_root():
    home = os.path.expanduser("~")
    root = os.environ.get("VDM_INTERCOM_ROOT") or ""
    if not root:
        try:
            with open(os.path.join(home, ".claude", "vdm-plugins.json"), encoding="utf-8") as fh:
                root = ((json.load(fh) or {}).get("intercom") or {}).get("root") or ""
        except (OSError, ValueError, AttributeError):
            root = ""
    if not root:
        root = os.path.join(home, ".claude", "vdm", "intercom")
    if root == "~":
        root = home
    elif root.startswith("~/"):
        root = os.path.join(home, root[2:])
    return root


def fold(name):
    """intercom's name folding: ASCII-only lowercase, runs of blanks and `_`
    to `-`. A name in another script matches case-exactly, as it does there."""
    s = "".join(c.lower() if c.isascii() else c for c in str(name))
    return re.sub(r"[ \t_]+", "-", s).strip("-")


def registry_entry(identity):
    """The intercom directory entry `identity` addresses — by its file first,
    then by a folded identity / alias / name, as `intercom.sh resolve` does."""
    reg = os.path.join(store_root(), "_registry")
    if not os.path.isdir(reg):
        raise Unresolved("comms.hq is `%s`, but there is no intercom directory at %s "
                         "(the vdm plugin keeps it)" % (identity, reg))
    direct = os.path.join(reg, identity + ".json")
    # A `<id>.sync-conflict-*.json` beside an entry is Syncthing's copy of the
    # losing side of two machines editing it at once — not a second agent, and
    # read as one it makes every name of the entry ambiguous (the same filter
    # as `_intercom_registry_files` in the vdm plugin's intercom-common.sh).
    candidates = [direct] if os.path.isfile(direct) else sorted(
        os.path.join(reg, f) for f in os.listdir(reg)
        if f.endswith(".json") and ".sync-conflict-" not in f)
    want = fold(identity)
    hits = []
    for path in candidates:
        try:
            with open(path, encoding="utf-8") as fh:
                entry = json.load(fh)
        except (OSError, ValueError):
            continue
        if path == direct:
            return entry
        names = [entry.get("identity")] + list(entry.get("aliases") or []) + list(entry.get("names") or [])
        if want in {fold(n) for n in names if n}:
            hits.append(entry)
    if len(hits) == 1:
        return hits[0]
    if hits:
        raise Unresolved("comms.hq `%s` names several agents in the intercom directory: %s"
                         % (identity, ", ".join(sorted(str(h.get("identity")) for h in hits))))
    raise Unresolved("comms.hq is `%s`, but no agent in the intercom directory goes by "
                     "that name — `/vdm:intercom resolve %s`" % (identity, identity))


def locate(project_root, cfg):
    """→ {"dir", "hq", "hq_root"}; `hq` is None for a project that is its own
    HQ. Raises Unresolved, saying what is missing."""
    hq = cfg.get("hq")
    if isinstance(hq, str) and hq.strip():
        hq = hq.strip()
        entry = registry_entry(hq)
        paths = [p for p in (entry.get("paths") or []) if isinstance(p, str)]
        live = [p for p in paths if os.path.isdir(p)]
        if not live:
            raise Unresolved("comms.hq `%s` is registered, but none of its checkouts is on "
                             "this machine: %s" % (hq, ", ".join(paths) or "no paths recorded"))
        for root in live:
            hq_cfg, err = cfgmod.load(root)
            pdir = os.path.join(root, str(hq_cfg.get("people-dir") or "people").strip("/"))
            if not err and os.path.isdir(pdir):
                return {"dir": pdir, "hq": hq, "hq_root": root}
        raise Unresolved("comms.hq `%s` → %s, but there is no people directory there"
                         % (hq, live[0]))
    pdir = os.path.join(project_root, str(cfg.get("people-dir") or "people").strip("/"))
    if os.path.isdir(pdir):
        return {"dir": pdir, "hq": None, "hq_root": project_root}
    raise Unresolved("no `%s/` here and no `comms.hq` — a hand names the HQ whose "
                     "people/ it reads: \"hq\": \"<intercom identity>\" under `comms`"
                     % str(cfg.get("people-dir") or "people").strip("/"))


# --- one person --------------------------------------------------------------

def _profiles(pdir):
    for dp, dn, fn in os.walk(pdir):
        dn[:] = sorted(d for d in dn if not d.startswith("."))
        for f in sorted(fn):
            if f.endswith(".md"):
                yield os.path.join(dp, f)


def find(pdir, who):
    """Profiles of `who`: the file `<who>.md` when there is one, else every
    profile mentioning `who` as a whole token — a login, an address, a handle,
    the way a hand meets a person in a ticket.

    A token in a profile's frontmatter outranks one in prose. Identity data
    lives there (`identity:` → `jira:`, `email:`, a `mail_from` pair), while
    prose mentions other people freely: "writes to anna_k often" in one
    profile must not make `anna_k` ambiguous. Prose is searched when no
    frontmatter holds the token — the form of an HQ whose profiles have none."""
    who = str(who).strip()
    if who.endswith(".md"):
        who = who[:-3]
    if not who:
        return []
    for cand in (who, who.lower()):
        path = os.path.join(pdir, cand + ".md")
        if "/" not in cand and os.path.isfile(path):
            return [path]
    if len(who) < MIN_SEARCH:
        return []
    token = re.compile(r"(?<![\w.@+-])%s(?![\w@+-])" % re.escape(who), re.IGNORECASE)
    in_fm, in_body = [], []
    for path in _profiles(pdir):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        try:
            fm_text, body = fmmod.split_frontmatter(text)
        except fmmod.FrontmatterError:
            fm_text, body = "", text
        if token.search(fm_text):
            in_fm.append(path)
        elif token.search(body):
            in_body.append(path)
    return in_fm or in_body


def read_profile(path):
    """→ {"trust", "trust_note", "mail_from", "notes"}. Never raises on a
    readable file: a profile the reader cannot fully parse still has a level."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    notes = []
    try:
        fm_text, _ = fmmod.split_frontmatter(text)
    except fmmod.FrontmatterError as exc:
        fm_text = ""
        notes.append("frontmatter unreadable: %s" % exc)
    raw = fmmod.scalar_keys(fm_text).get("trust") if fm_text else None
    level, note = level_of(raw)
    pairs = []
    if fm_text and re.search(r"(?m)^mail_from:", fm_text):
        try:
            value = fmmod.parse(fm_text).get("mail_from")
        except fmmod.FrontmatterError as exc:
            value = None
            notes.append("mail_from unreadable: %s" % exc)
        for item in value if isinstance(value, list) else []:
            if isinstance(item, dict) and item.get("to") and item.get("from"):
                pairs.append((str(item["to"]).strip(), str(item["from"]).strip()))
            else:
                notes.append("mail_from: an item without both `to:` and `from:` — skipped: %r" % (item,))
        if value is not None and not isinstance(value, list):
            notes.append("mail_from is a list of `- to: … / from: …` pairs — not read")
    return {"trust": level, "trust_note": note, "mail_from": pairs, "notes": notes}


def level_of(raw):
    """→ (level, note). The note says why a level is the default."""
    if raw in (None, ""):
        return DEFAULT_LEVEL, "no `trust:` in the profile"
    value = str(raw).strip().lower()
    if value in LEVELS:
        return value, None
    return DEFAULT_LEVEL, "unknown `trust: %s` — the levels are %s" % (raw, ", ".join(LEVELS))


def next_step(level, hq):
    """What this project does about writing to a person at `level`."""
    if hq:
        if level in ("team", "peer"):
            return "this project is a hand of `%s`: write it yourself" % hq
        return ("this project is a hand of `%s`: do not write — brief the HQ "
                "(/vdm:intercom send %s <brief-slug>): who, where they turned up, what we need from them"
                % (hq, hq))
    if level == "careful":
        return "a draft only, every word checked; the owner reads it before it goes"
    if level == "top":
        return "ask the owner whether to write at all, before any draft"
    return "write it yourself"


def describe(project_root, cfg, who):
    """→ (exit code, lines). 0 one profile · 2 none (careful) · 3 several ·
    1 the people directory could not be found."""
    try:
        where = locate(project_root, cfg)
    except Unresolved as exc:
        return 1, ["people: unresolved — %s" % exc,
                   "trust: %s — until it resolves, everyone counts as careful (%s)"
                   % (DEFAULT_LEVEL, MEANING[DEFAULT_LEVEL])]
    origin = "hq `%s`" % where["hq"] if where["hq"] else "this project's own"
    lines = ["people: %s (%s)" % (where["dir"], origin)]
    hits = find(where["dir"], who)
    if not hits:
        lines.append("trust: %s — `%s` is not in people/ (%s)" % (DEFAULT_LEVEL, who, MEANING[DEFAULT_LEVEL]))
        lines.append("next: %s" % next_step(DEFAULT_LEVEL, where["hq"]))
        if not where["hq"]:
            lines.append("      someone written to again gets a profile with `trust:` — the HQ's call")
        return 2, lines
    if len(hits) > 1:
        lines.append("`%s` is in %d profiles — name the file:" % (who, len(hits)))
        for path in hits:
            lines.append("  %s  trust: %s" % (os.path.relpath(path, where["hq_root"]), read_profile(path)["trust"]))
        return 3, lines
    info = read_profile(hits[0])
    lines.append("profile: %s" % os.path.relpath(hits[0], where["hq_root"]))
    note = " (%s)" % info["trust_note"] if info["trust_note"] else ""
    lines.append("trust: %s%s — %s" % (info["trust"], note, MEANING[info["trust"]]))
    for to, frm in info["mail_from"]:
        lines.append("mail_from: to %s → from %s" % (to, frm))
    for n in info["notes"]:
        lines.append("note: %s" % n)
    lines.append("next: %s" % next_step(info["trust"], where["hq"]))
    return 0, lines


def recipient_line(project_root, cfg, slug):
    """One block for the draft scaffold: the recipient's level and the next
    step, at the moment the letter is born. Never raises — a scaffold that
    fails over a profile would leave the letter unwritten."""
    try:
        _, lines = describe(project_root, cfg, slug)
    except Exception as exc:  # noqa: BLE001
        return "Recipient `%s`: profile not checked (%s) — counts as careful." % (slug, exc)
    # The location line is noise in a scaffold; "people: unresolved" is the reason.
    body = [ln for ln in lines if not ln.startswith("people:") or "unresolved" in ln]
    return "\n".join(["Recipient `%s`:" % slug] + ["  " + ln for ln in body])
