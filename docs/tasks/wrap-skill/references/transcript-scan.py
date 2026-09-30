#!/usr/bin/env python3
"""Reproduce the field evidence behind the wrap-skill crystal.

Scans Claude Code transcripts (~/.claude/projects/*/*.jsonl) for the owner's
"can we move to a clean session / will anything not survive?" asks, and for each
one collects the assistant's reply and tool calls up to the next real user turn.

Run 2026-09-30: 61 hits, of which ~45 are genuine asks (the rest are pasted
handoff texts, bare /compact, and this very request); 10 projects; all dated
2026-09-03..2026-09-30.

Usage: python3 transcript-scan.py > hits.json
The output holds other people's names and private content from those projects —
keep it out of this repository (the crystal transcribes, it does not store).
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.expanduser('~/.claude/projects')
ASK = re.compile(
    r'(чист\w*\s+сесс)|(нов\w*\s+сесс)|(handoff|хэндофф|хендофф)'
    r'|(не\s+пережив[её]т)|(только\s+в\s+(чате|истории))|(в\s+истории\s+чат)'
    r'|(ничего\s+не\s+(осталось|потеря))|(compact|компакт)', re.I)
REASSURE = re.compile(r'не\s+переживай|не\s+переживаем|не\s+волнуйся', re.I)


def texts_of(rec):
    c = rec.get('message', {}).get('content')
    if isinstance(c, str):
        return [c]
    if isinstance(c, list):
        return [x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text']
    return []


def tools_of(rec):
    c = rec.get('message', {}).get('content')
    out = []
    if isinstance(c, list):
        for x in c:
            if isinstance(x, dict) and x.get('type') == 'tool_use':
                inp = x.get('input', {})
                s = inp.get('command') or inp.get('file_path') or inp.get('skill') or ''
                out.append(f"{x.get('name')}: {str(s)[:140]}")
    return out


def main():
    res, seen = [], set()
    for f in glob.glob(ROOT + '/*/*.jsonl'):
        proj = os.path.basename(os.path.dirname(f))
        try:
            lines = open(f, encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            continue
        recs = []
        for line in lines:
            if '"type":"user"' not in line and '"type":"assistant"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not rec.get('isSidechain'):
                recs.append(rec)
        for i, rec in enumerate(recs):
            if rec.get('type') != 'user' or rec.get('isMeta'):
                continue
            for t in texts_of(rec):
                if not t or t.startswith('<') or len(t) > 1500 or t.startswith('User: ## Conversation'):
                    continue
                if not ASK.search(t):
                    continue
                if REASSURE.search(t) and not re.search(r'сесс|handoff', t, re.I):
                    continue
                if t[:200] in seen:
                    continue
                seen.add(t[:200])
                reply, tools = [], []
                for nxt in recs[i + 1:]:
                    if nxt.get('type') == 'user' and not nxt.get('isMeta'):
                        if any(x and not x.startswith('<') for x in texts_of(nxt)):
                            break
                        continue
                    if nxt.get('type') == 'assistant':
                        reply += texts_of(nxt)
                        tools += tools_of(nxt)
                res.append({'proj': proj, 'ts': rec.get('timestamp', ''), 'user': t.strip(),
                            'tools': tools, 'reply': '\n'.join(reply)[-2500:]})
    res.sort(key=lambda x: x['ts'])
    json.dump(res, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
