#!/usr/bin/env python3
"""What /vdm:wrap handed the user: the start phrases in Claude Code transcripts (wrap-skill DL #16).

Read-only, prints counts and dates only. One machine is enough: ~/.claude/projects is synced between the
owner's two (2026-11-09: 365 of 365 runs common).

    python3 -I docs/tasks/wrap-skill/references/start-phrase-scan.py [session-id-prefix-to-skip]

A run is a user turn that typed the slash command or called the Skill tool with wrap. The phrase is looked for
in every assistant text of that turn, last first: the last text is usually the note after the commit, and it
often holds the phrase inside a sentence, without a label. "Used" compares the phrase with the first prompt of
the project's next transcript by slug or text, so a parallel session counts as "something else".
"""
import collections
import glob
import json
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.expanduser("~/.claude/projects")
SKIP = sys.argv[1] if len(sys.argv) > 1 else None
NOT_A_TURN = ("<local-command", "<task-notification", "<system-reminder", "<bash-input", "<bash-stdout", "<bash-stderr")
LABEL = re.compile(
    r"(?im)^[\s>*_#-]*(?:новая сессия|следующая сессия|в новой сессии|в чистой сессии|для новой сессии|стартовая фраза"
    r"|первая фраза|первой фразой|фраза для новой сессии|фраза для старта|new session|start phrase|next session)[^\n]*"
)
INLINE = re.compile(
    r"(?:чист\w+\s+сесси\w+|нов\w+\s+сесси\w+|следующ\w+|фраз\w+|начн\w+|начинай|начать|стартов\w+|со слова|запуск\w*)"
    r"[^«»\n]{0,110}«((?:[^«»]|«[^»]*»)+)»",
    re.I,
)
COMMAND = re.compile(r"/vdm:intercom pickup [\w.-]+|vdx ai [^\n`]*--focused[^\n`]*")
BARE = re.compile(
    r"/vdm:intercom pickup [\w.-]+|(?:продолжаем|продолжим|берём|берем|бери|continue|беру)(?: кристалл| crystal| письмо)? `?[\w.-]+`?",
    re.I,
)
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)+")
STEP = re.compile(r"сначала|затем|потом|после|если |first|then", re.I)
NO_PROMPT = re.compile(r"без (?:лишнего )?промпта|без фразы|сам(?:о)? (?:всплыл|выскоч|подхват)|лишн\w+ промпт|бесит", re.I)
clean = lambda s: s.strip().strip("«»\"`*: ").strip()


def text_of(rec):
    c = rec.get("message", {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_turn(rec):
    if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isCompactSummary") or rec.get("isSidechain"):
        return False
    c = rec.get("message", {}).get("content")
    if isinstance(c, list) and not any(isinstance(b, dict) and b.get("type") == "text" for b in c):
        return False
    t = text_of(rec).strip()
    return bool(t) and not t.startswith(NOT_A_TURN)


def records(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def turns_of(path):
    turns, cur = [], None
    for rec in records(path):
        if is_turn(rec):
            user = text_of(rec).strip()
            cur = {"user": user, "ts": rec.get("timestamp", ""), "end": rec.get("timestamp", ""), "texts": [],
                   "wrap": bool(re.search(r"<command-name>/(?:vdm:)?wrap</command-name>", user))}
            turns.append(cur)
        elif cur is not None and rec.get("type") == "assistant" and not rec.get("isSidechain"):
            for b in rec.get("message", {}).get("content") or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    cur["texts"].append(b["text"])
                    cur["end"] = rec.get("timestamp", "")
                elif b.get("type") == "tool_use" and b.get("name") == "Skill":
                    if (b.get("input") or {}).get("skill") in ("vdm:wrap", "wrap"):
                        cur["wrap"] = True
    return turns


def from_label(text):
    hits = list(LABEL.finditer(text))
    if not hits:
        return None
    line, _, rest = text[hits[-1].start():].lstrip(" \n\t>*_#-").partition("\n")
    cut = re.search(r"[:—]", line)
    head = line[cut.end():].strip() if cut else ""
    body = (head + "\n" + rest).strip() if head else rest.strip()
    if body.startswith("```"):
        end = body.find("```", 3)
        return body[3:end].strip() if end > 0 else body[3:].strip()
    return body.split("\n\n")[0].strip()


def phrase_of(texts):
    for text in reversed(texts):
        p = from_label(text)
        if p and len(clean(p)) > 2:
            return clean(p)
        m = list(INLINE.finditer(text))
        if m:
            return clean(m[-1].group(1))
        m = COMMAND.findall(text)
        if m:
            return clean(m[-1])
    return None


def shape(p):
    if p is None:
        return "no phrase"
    if BARE.fullmatch(p):
        return "bare pointer"
    if len(p) <= 15:
        return "one word"
    if SLUG.search(p) or "pickup" in p:
        return "pointer + tail"
    return "words, no slug"


def first_prompt(path):
    for n, rec in enumerate(records(path)):
        if n > 600:
            return None
        if is_turn(rec):
            t = text_of(rec).strip()
            if not t.startswith(("<command-name>/clear", "<command-message>clear")):
                return rec.get("timestamp", ""), t
    return None


def used(p, q):
    norm = lambda s: re.sub(r"[\s«»\"`'/]+", " ", s).strip().lower()
    return any(s in q for s in SLUG.findall(p)) or norm(p)[:40] in norm(q) or (len(norm(q)) > 3 and norm(q) in norm(p))


def main():
    out = subprocess.run(["grep", "-lE", r'"skill":"(vdm:)?wrap"|command-name>/(vdm:)?wrap<', "-r", "--include=*.jsonl", ROOT],
                         capture_output=True, text=True).stdout.split("\n")
    paths = [p for p in out if p and p.count("/") == ROOT.count("/") + 2 and not (SKIP and os.path.basename(p).startswith(SKIP))]
    runs, firsts = [], {}
    for path in paths:
        project = os.path.dirname(path)
        turns = turns_of(path)
        for i, t in enumerate(turns):
            if t["wrap"] and t["texts"]:
                runs.append({"project": project, "file": path, "ts": t["ts"], "end": t["end"], "phrase": phrase_of(t["texts"]),
                             "longest": max(map(len, t["texts"])), "next": turns[i + 1]["user"] if i + 1 < len(turns) else ""})
    for r in runs:
        r["shape"] = shape(r["phrase"])
        if r["project"] not in firsts:
            found = ((first_prompt(f), f) for f in glob.glob(os.path.join(r["project"], "*.jsonl")))
            firsts[r["project"]] = sorted((fp[0], f, fp[1]) for fp, f in found if fp)
        following = [x for x in firsts[r["project"]] if x[0] > r["end"] and x[1] != r["file"]]
        r["opened"] = None if not following or not r["phrase"] else used(r["phrase"], following[0][2])

    print("runs", len(runs), "projects", len({r["project"] for r in runs}), "span", min(r["ts"] for r in runs)[:10], max(r["ts"] for r in runs)[:10])
    for k, v in collections.Counter(r["shape"] for r in runs).most_common():
        print(f"  {k:16} {v:4} {100 * v / len(runs):5.1f}%")
    ls = sorted(len(r["phrase"]) for r in runs if r["phrase"])
    print("phrase length: n", len(ls), "median", statistics.median(ls), "p90", ls[int(len(ls) * .9)], "max", ls[-1],
          "<=80:", sum(x <= 80 for x in ls), ">120:", sum(x > 120 for x in ls))
    tails = [r for r in runs if r["shape"] == "pointer + tail"]
    print("tails naming a step or an order:", sum(bool(STEP.search(r["phrase"])) for r in tails), "of", len(tails))
    main_len = sorted(r["longest"] for r in runs)
    print("longest reply of the wrap turn: median", statistics.median(main_len), "p75", main_len[len(main_len) * 3 // 4], "p90", main_len[int(len(main_len) * .9)])
    groups = collections.defaultdict(list)
    for r in runs:
        groups[r["ts"][:7] + (" 01-15" if int(r["ts"][8:10]) <= 15 else " 16+")].append(r)
    for k in sorted(groups):
        wp = [r for r in groups[k] if r["phrase"]]
        print(f"  {k}  phrases {len(wp):4}  with tail {sum(r['shape'] == 'pointer + tail' for r in wp):4}  median {statistics.median(len(r['phrase']) for r in wp) if wp else 0:.0f}")
    o = [r["opened"] for r in runs if r["phrase"]]
    print("next session opened with the phrase: yes", o.count(True), "no", o.count(False), "no next session", o.count(None))
    asks = [r["ts"][:10] for r in runs if r["next"] and NO_PROMPT.search(r["next"])]
    print("user turns right after a wrap asking for no prompt:", len(asks), asks)


main()
