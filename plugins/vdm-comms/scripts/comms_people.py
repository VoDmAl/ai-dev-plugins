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

Which HQ a hand belongs to is recorded once, at the access layer (owner,
2026-10-02: one record needs no reconciling, a second one in the hand's own
repository would put the limit in the hands of the project it limits —
DL #4, #5). It is asked, never configured here: `<access layer> hq <project
root>` answers the HQ's intercom identity, or nothing for a project that is its
own HQ (`hq_of`). The checkout comes from the intercom directory
(`<store>/_registry/<identity>.json` → `paths`), the directory name from the
HQ's own `comms.people-dir`. So an HQ that keeps its people under
`wiki/entities/people` needs no special case.

Two fields in a profile's frontmatter. Both are read by echelon as well, which
is why their shape is fixed here and not left to each HQ:

    trust: team | peer | careful | exec
    mail_from:
      - to: ivan@their.example
        from: Our Name <me@ours.example>

`trust` is how freely the person may be written to, and how closely the text is
checked first (owner: «не true/false а степень свободности общения и выверения
того что пишем»):

    team     a hand writes itself
    peer     a hand writes itself; the tone is the skill's
    careful  only the HQ writes; every word checked, the owner sees it first
    exec     leadership; only the HQ, and the owner decides whether to write

No field, no profile, or a value outside the four reads as `careful`. That
default is the owner's rule, and it makes an unmarked profile the safe case.
`trust` is read line by line (`scalar_keys`), so a profile whose other
frontmatter is outside what the reader supports keeps its level.

`trust: top` is the former name of `exec` and reads as `exec`, with a note.
Until 2026-10-07 `top` answered a second question as well — who may *read*: echelon
closes the person's threads to agents and signals the owner. That one is not
tied to rank (a lawyer's letters can be more closed than a manager's routine
mail), so it is now a field of its own, `confidential: true`, which echelon
reads and this module does not: it says nothing about writing. A profile still
saying `top` becomes `trust: exec` plus `confidential: true`. Reading `top` as
an unknown value would fall back to `careful` and drop the owner's question
without a word (crystal `vdm-comms-outward-checks`, DL #6).

`mail_from` is a list of pairs, not a map from address to address. A key holding
`@` is outside the reader's subset, and a pair is exactly what the owner named:
«этому человеку — с моего ящика y на его ящик x». In echelon's order of From,
this pair comes first.

Not to be confused with `comms.register` (`letters` § 6). That one says how a
request is made. `trust` says who may write at all, and how much checking it
takes. `peer` exists on both axes and means different things on each; `exec`
and the register `executor` only sound alike.

Stdlib only, like the rest of the plugin. The intercom store root is resolved
in the same order as `intercom_store_root` in the vdm plugin
(`intercom-common.sh`): $VDM_INTERCOM_ROOT, then `intercom.root` in
~/.claude/vdm-plugins.json, then ~/.claude/vdm/intercom.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comms_config as cfgmod  # noqa: E402
import comms_frontmatter as fmmod  # noqa: E402

LEVELS = ("team", "peer", "careful", "exec")
DEFAULT_LEVEL = "careful"

# A former name → the level it means now.
RENAMED = {"top": "exec"}

MEANING = {
    "team": "a hand writes itself",
    "peer": "a hand writes itself; the tone is the skill's",
    "careful": "only the HQ writes; every word checked, the owner sees it before it goes",
    "exec": "leadership: only the HQ, and the owner decides whether to write at all",
}

# Shorter than this, a search would find a person in every profile's prose.
MIN_SEARCH = 3


class Unresolved(Exception):
    """The people directory this project reads could not be found."""


class NoAccessLayer(Unresolved):
    """This machine has no access layer: no intercom directory, or no agent in
    it declares the role. Not an error of one — there is nobody to ask."""


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


def entry_files(reg):
    """Every entry file of the intercom directory `reg`, sorted.

    A `<id>.sync-conflict-*.json` beside an entry is Syncthing's copy of the
    losing side of two machines editing it at once — not a second agent, and
    read as one it makes every name of the entry ambiguous (the same filter
    as `_intercom_registry_files` in the vdm plugin's intercom-common.sh)."""
    return sorted(os.path.join(reg, f) for f in os.listdir(reg)
                  if f.endswith(".json") and ".sync-conflict-" not in f)


def registry_entry(identity):
    """The intercom directory entry `identity` addresses — by its file first,
    then by a folded identity / alias / name, as `intercom.sh resolve` does."""
    reg = os.path.join(store_root(), "_registry")
    if not os.path.isdir(reg):
        raise Unresolved("the HQ is `%s`, but there is no intercom directory at %s "
                         "(the vdm plugin keeps it)" % (identity, reg))
    direct = os.path.join(reg, identity + ".json")
    candidates = [direct] if os.path.isfile(direct) else entry_files(reg)
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
        raise Unresolved("the HQ `%s` names several agents in the intercom directory: %s"
                         % (identity, ", ".join(sorted(str(h.get("identity")) for h in hits))))
    raise Unresolved("the HQ is `%s`, but no agent in the intercom directory goes by "
                     "that name — `/vdm:intercom resolve %s`" % (identity, identity))


# The agent through which projects reach external systems is found by the role
# its intercom entry declares, never by its name or a path of one machine
# (vdm plugin, intercom-agent-roles DL #2). Its command is `bin/<its identity>`
# in its checkout — `intercom role access-layer --path` answers the same.
ACCESS_ROLE = "access-layer"


def role_holder(role):
    """The one intercom directory entry that declares `role`. Raises
    NoAccessLayer when there is no directory or no holder, Unresolved when
    there are several."""
    reg = os.path.join(store_root(), "_registry")
    if not os.path.isdir(reg):
        raise NoAccessLayer("no intercom directory at %s (the vdm plugin keeps it)" % reg)
    hits = []
    for path in entry_files(reg):
        try:
            with open(path, encoding="utf-8") as fh:
                entry = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(entry, dict) and role in (entry.get("roles") or []):
            hits.append(entry)
    if len(hits) == 1:
        return hits[0]
    if hits:
        raise Unresolved("several agents in the intercom directory declare the role %s: %s"
                         % (role, ", ".join(sorted(str(h.get("identity")) for h in hits))))
    raise NoAccessLayer("no agent in the intercom directory declares the role %s "
                        "(/vdm:intercom role %s)" % (role, role))


def access_layer_bin():
    """→ the access layer's command on this machine: `<checkout>/bin/<identity>`
    of the agent holding ACCESS_ROLE. Raises Unresolved, saying what is missing."""
    entry = role_holder(ACCESS_ROLE)
    ident = str(entry.get("identity") or "")
    paths = [p for p in (entry.get("paths") or []) if isinstance(p, str)]
    for root in paths:
        binary = os.path.join(root, "bin", ident)
        if ident and os.path.isfile(binary) and os.access(binary, os.X_OK):
            return binary
    raise Unresolved("`%s` holds the role %s, but none of its checkouts on this machine has bin/%s: %s"
                     % (ident, ACCESS_ROLE, ident, ", ".join(paths) or "no paths recorded"))


def access_layer():
    """→ the access layer's command. `ECHELON_BIN` wins (tests, an unusual
    install), then `ECHELON_HOME`, then the agent whose intercom entry declares
    the role access-layer. Raises NoAccessLayer / Unresolved as
    `access_layer_bin` does; a command named by the environment is returned
    unchecked."""
    if os.environ.get("ECHELON_BIN"):
        return os.environ["ECHELON_BIN"]
    if os.environ.get("ECHELON_HOME"):
        return os.path.join(os.environ["ECHELON_HOME"], "bin", "echelon")
    return access_layer_bin()


# echelon answers in about 0.3 s; this machine runs at a load of 40–70 at times.
HQ_TIMEOUT = 10


def hq_of(project_root):
    """→ the intercom identity of this project's HQ, or None when the project
    is its own. Asked of the access layer: `<its command> hq <project root>`
    (agreed with echelon 2026-10-02, `people-hq-command-form-outcome`). A line
    is the HQ; an empty answer with exit 0 is "its own HQ"; exit 1 with the
    reason on stderr is "the HQ is unknown". A directory inside the project, a
    worktree, answers for the nearest project.

    Raises NoAccessLayer when this machine has none: nobody records hands
    there, and `locate` reads the project's own people/. An access layer that
    is there and cannot answer raises Unresolved — taking its failure for an
    empty answer would let a hand pass for its own HQ, which is why echelon
    gives a broken record exit 1 rather than an empty line."""
    binary = access_layer()
    name = os.path.basename(binary)
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise Unresolved("the access layer's command is not on this machine: %s" % binary)
    try:
        run = subprocess.run([binary, "hq", project_root],
                             capture_output=True, text=True, timeout=HQ_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Unresolved("`%s hq` gave no answer in %d s" % (name, HQ_TIMEOUT))
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unresolved("`%s hq` did not run: %s" % (name, exc))
    if run.returncode != 0:
        # A crash exits 1 as well; its last line is the one that says why.
        tail = [ln.strip() for ln in (run.stderr or "").splitlines() if ln.strip()]
        raise Unresolved("the access layer does not know this project's HQ (`%s hq`, exit %d: %s)"
                         % (name, run.returncode, tail[-1] if tail else "no reason given"))
    lines = [ln.strip() for ln in (run.stdout or "").splitlines() if ln.strip()]
    return lines[0] if lines else None


def locate(project_root, cfg):
    """→ {"dir", "hq", "hq_root"}; `hq` is None for a project that is its own
    HQ. Raises Unresolved, saying what is missing."""
    try:
        hq, asked = hq_of(project_root), True
    except NoAccessLayer:
        hq, asked = None, False
    if hq:
        entry = registry_entry(hq)
        paths = [p for p in (entry.get("paths") or []) if isinstance(p, str)]
        live = [p for p in paths if os.path.isdir(p)]
        if not live:
            raise Unresolved("the HQ `%s` is registered, but none of its checkouts is on "
                             "this machine: %s" % (hq, ", ".join(paths) or "no paths recorded"))
        for root in live:
            hq_cfg, err = cfgmod.load(root)
            pdir = os.path.join(root, str(hq_cfg.get("people-dir") or "people").strip("/"))
            if not err and os.path.isdir(pdir):
                return {"dir": pdir, "hq": hq, "hq_root": root}
        raise Unresolved("the HQ `%s` → %s, but there is no people directory there"
                         % (hq, live[0]))
    name = str(cfg.get("people-dir") or "people").strip("/")
    pdir = os.path.join(project_root, name)
    if os.path.isdir(pdir):
        return {"dir": pdir, "hq": None, "hq_root": project_root}
    if asked:
        raise Unresolved("no `%s/` here, and the access layer names no HQ for this project — "
                         "a hand's HQ is recorded there, not in this repository" % name)
    raise Unresolved("no `%s/` here, and no access layer on this machine to name an HQ" % name)


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
    if value in RENAMED:
        return RENAMED[value], ("`trust: %s` is the former name — the profile becomes "
                                "`trust: %s` plus `confidential: true`" % (value, RENAMED[value]))
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
    if level == "exec":
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
