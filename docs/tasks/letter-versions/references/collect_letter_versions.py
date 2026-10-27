"""Collect every trace of outgoing letters from the harness transcripts before they are deleted.

For each tool call in ~/.claude/projects/**/*.jsonl that touches an outgoing letter (`*/comms/*-out.md`) —
Write, Edit, MultiEdit, a Bash command naming it — or drafts a text through the access layer (`*_draft`,
`*_send`), one JSON line goes to ~/.claude/vdm/letter-versions/<project>/<letter>/trace.jsonl (or
<project>/_drafts.jsonl for drafts not tied to a file): when, which session, which tool, the input as written.
The letter as it is on disk now is copied beside it (`now.md`). Nothing is reconstructed or judged here:
this keeps the evidence; the versions and the diff are derived from it later.

Idempotent: a line is keyed by (session file, record uuid, tool_use id) and written once.
Run: python3 -I collect_letter_versions.py [--dry]
"""
import glob, json, os, re, shutil, subprocess, sys

H = os.path.expanduser('~')
SRC = os.path.join(H, '.claude', 'projects')
OUT = os.path.join(H, '.claude', 'vdm', 'letter-versions')
DRY = '--dry' in sys.argv
LETTER = re.compile(r'([^\s\'"`=<>|;&()]*comms/[^\s\'"`=<>|;&()]*-out\.md)')
DRAFT_TOOL = re.compile(r'(mail_draft|mail_send|tg_draft|tg_send|zulip_send)')

_top = {}
def project_root(path):
    d = os.path.dirname(path)
    while d and d != '/':
        if d in _top: return _top[d]
        if os.path.isdir(os.path.join(d, '.git')) or os.path.isfile(os.path.join(d, '.git')):
            _top[os.path.dirname(path)] = d
            return d
        d = os.path.dirname(d)
    return None

def slug_of(root):
    return os.path.basename(root.rstrip('/')) if root else '_unknown'

def letters_in(tool, inp, cwd):
    """Absolute paths of outgoing letters this call names."""
    found = []
    if tool in ('Write', 'Edit', 'MultiEdit', 'Read'):
        p = inp.get('file_path') or ''
        if re.search(r'comms/[^/]*-out\.md$', p):
            found.append(p)
    elif tool == 'Bash':
        cmd = inp.get('command') or ''
        # `cd <dir> && …` (or `;`): relative paths in the command are from there, not the session's cwd
        m = re.match(r'\s*cd\s+(?:"([^"]+)"|\'([^\']+)\'|(\S+))\s*(?:&&|;)', cmd)
        if m:
            base = m.group(1) or m.group(2) or m.group(3)
            base = os.path.expanduser(base.replace('$HOME', H))
            cwd = base if os.path.isabs(base) else os.path.normpath(os.path.join(cwd or '/', base))
        for m in LETTER.finditer(cmd):
            found.append(m.group(1))
    out = []
    for p in found:
        if '*' in p or '$' in p: continue
        if not os.path.isabs(p): p = os.path.normpath(os.path.join(cwd or '/', p))
        # test fixtures and scratch copies are no letters to people
        if p.startswith(('/private/', '/tmp/', '/var/folders/')) or '/cc-vdm-plugins/' in p: continue
        out.append(p)
    return sorted(set(out))

def main():
    files = glob.glob(os.path.join(SRC, '**', '*.jsonl'), recursive=True)
    seen_keys = set()
    # what is already collected
    for t in glob.glob(os.path.join(OUT, '**', '*.jsonl'), recursive=True):
        for line in open(t, encoding='utf-8', errors='replace'):
            try: seen_keys.add(json.loads(line)['key'])
            except Exception: pass
    new = 0; letters = set(); drafts = 0; oldest = {}
    for f in sorted(files):
        try:
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if '-out.md' not in line and not DRAFT_TOOL.search(line): continue
                    try: d = json.loads(line)
                    except Exception: continue
                    if d.get('type') != 'assistant': continue
                    cwd = d.get('cwd') or ''
                    for c in (d.get('message') or {}).get('content') or []:
                        if not (isinstance(c, dict) and c.get('type') == 'tool_use'): continue
                        tool = c.get('name') or ''
                        inp = c.get('input') or {}
                        key = '%s|%s|%s' % (os.path.relpath(f, SRC), d.get('uuid'), c.get('id'))
                        rec = {'key': key, 'at': d.get('timestamp'), 'session': os.path.relpath(f, SRC),
                               'cwd': cwd, 'tool': tool, 'input': inp}
                        targets = []
                        if tool != 'Read':
                            targets = letters_in(tool, inp, cwd)
                        is_draft = bool(DRAFT_TOOL.search(tool)) or (
                            tool.endswith('call_write') and DRAFT_TOOL.search(json.dumps(inp)[:200] or ''))
                        dests = []
                        for p in targets:
                            root = project_root(p) or project_root(os.path.join(cwd, 'x'))
                            rel = os.path.relpath(p, root) if root else os.path.basename(p)
                            dests.append((os.path.join(OUT, slug_of(root), rel.replace('/', '__')), p))
                            letters.add(p)
                        if is_draft and not targets:
                            root = project_root(os.path.join(cwd, 'x'))
                            dests.append((os.path.join(OUT, slug_of(root), '_drafts'), None))
                            drafts += 1
                        for dest, p in dests:
                            k2 = key + '|' + (p or '_drafts')
                            if k2 in seen_keys: continue
                            seen_keys.add(k2)
                            rec2 = dict(rec, key=k2, letter=p)
                            oldest[dest] = min(oldest.get(dest, rec['at'] or '9'), rec['at'] or '9')
                            new += 1
                            if DRY: continue
                            os.makedirs(dest, exist_ok=True)
                            with open(os.path.join(dest, 'trace.jsonl'), 'a', encoding='utf-8') as out:
                                out.write(json.dumps(rec2, ensure_ascii=False) + '\n')
        except Exception as e:
            print('skip', f, e, file=sys.stderr)
    # the letter as it is now
    copied = 0
    for p in letters:
        root = project_root(p)
        rel = os.path.relpath(p, root) if root else os.path.basename(p)
        dest = os.path.join(OUT, slug_of(root), rel.replace('/', '__'))
        if os.path.isfile(p) and not DRY:
            os.makedirs(dest, exist_ok=True)
            shutil.copyfile(p, os.path.join(dest, 'now.md'))
            copied += 1
        elif not os.path.exists(p) and not DRY:
            os.makedirs(dest, exist_ok=True)
            open(os.path.join(dest, 'GONE'), 'w').write('not on disk at collection time\n')
    projects = sorted({os.path.relpath(d, OUT).split('/')[0] for d in oldest})
    print('transcripts:', len(files), ' new trace lines:', new, ' letters:', len(letters),
          ' draft calls without a file:', drafts, ' now.md copied:', copied)
    print('projects:', ', '.join(projects))
    print('oldest trace:', min(oldest.values()) if oldest else '-')

main()
