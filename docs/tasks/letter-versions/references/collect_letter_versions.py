"""Collect every trace of outgoing letters from the harness transcripts before they are deleted.

For each tool call in ~/.claude/projects/**/*.jsonl that touches an outgoing letter (`*/comms/*-out.md`) —
Write, Edit, MultiEdit, a Bash command naming it — or drafts a text through the access layer (`*_draft`,
`*_send`), one JSON line goes to ~/.claude/vdm/letter-versions/<project>/<letter>/trace.jsonl (or
<project>/_drafts/trace.jsonl for drafts not tied to a file): when, which session, which tool, the input as
written. The letter as it is on disk now is copied beside it (`now.md`). Nothing is reconstructed or judged
here: this keeps the evidence; the versions and the diff are derived from it later.

The harness also keeps whole copies of an edited file, one per turn, in ~/.claude/file-history/<session>/
(named by the transcript's `file-history-snapshot` records). Those of a letter go to <letter>/fh/
`<backupTime>__<session>__v<N>.md`. The folder is per machine — Syncthing does not carry it — so a session
run on the other machine has its copies there: `--fh-list` prints the ones missing here, to be pulled
read-only into a staging folder and passed as `--fh-root <dir>`.

What the owner typed in a session that touched a letter goes to <project>/_owner-turns/<session>.jsonl of
each project whose letters it touched:
the versions show what changed, these turns show which change the owner asked for. Harness-made turns
(commands, their output, notices) are left out.

Idempotent: a line is keyed by (session file, record uuid, tool_use id) and written once; a copy, by its name.
Run: python3 -I collect_letter_versions.py [--dry] [--fh-root <dir>]... | --fh-list
"""
import glob, json, os, re, shutil, subprocess, sys

H = os.path.expanduser('~')
SRC = os.path.join(H, '.claude', 'projects')
OUT = os.path.join(H, '.claude', 'vdm', 'letter-versions')
FH_LIST = '--fh-list' in sys.argv
DRY = '--dry' in sys.argv or FH_LIST
FH_ROOTS = [os.path.join(H, '.claude', 'file-history')] + [
    sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == '--fh-root']
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
        p = resolve(p, cwd)
        if is_fixture(p): continue
        out.append(p)
    return sorted(set(out))

ROOTS = set()  # the project root of every session's cwd

def resolve(p, cwd):
    """Absolute path of a letter a call names. A relative one that is not under cwd may be another project's,
    named from a session elsewhere: it is tried under every project root the sessions ran in (and beside it,
    for `<project>/…`) and taken when exactly one of them has it."""
    if os.path.isabs(p): return p
    a = os.path.normpath(os.path.join(cwd or '/', p))
    if os.path.exists(a): return a
    hits = {os.path.normpath(os.path.join(base, p)) for r in ROOTS for base in (r, os.path.dirname(r))}
    hits = [h for h in hits if os.path.isfile(h)]
    return hits[0] if len(hits) == 1 else a

def is_fixture(p):
    """Test fixtures and scratch copies are no letters to people."""
    return p.startswith(('/private/', '/tmp/', '/var/folders/')) or '/cc-vdm-plugins/' in p

def owner_text(u):
    """What the owner typed in a turn; harness-made turns (commands, outputs, notices) are not theirs."""
    if u.get('type') != 'user' or u.get('isMeta') or u.get('toolUseResult'): return None
    c = (u.get('message') or {}).get('content')
    if isinstance(c, list):
        c = '\n'.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
    if not isinstance(c, str) or not c.strip() or c.lstrip().startswith('<'): return None
    return c

def dest_of(p, cwd):
    root = project_root(p) or project_root(os.path.join(cwd or '/', 'x'))
    rel = os.path.relpath(p, root) if root else os.path.basename(p)
    return os.path.join(OUT, slug_of(root), rel.replace('/', '__'))

def main():
    files = glob.glob(os.path.join(SRC, '**', '*.jsonl'), recursive=True)
    seen_keys = set()
    # what is already collected
    for t in glob.glob(os.path.join(OUT, '**', '*.jsonl'), recursive=True):
        for line in open(t, encoding='utf-8', errors='replace'):
            try: seen_keys.add(json.loads(line)['key'])
            except Exception: pass
    for f in files:
        with open(f, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                if '"cwd"' not in line: continue
                try: c = json.loads(line).get('cwd')
                except Exception: continue
                r = c and project_root(os.path.join(c, 'x'))
                if r: ROOTS.add(r)
                break
    new = 0; letters = set(); drafts = 0; oldest = {}
    fh_copied = 0; fh_missing = []; fh_done = set(); turns_saved = 0
    for f in sorted(files):
        try:
            scwd = None; snaps = []; turns = []; touched = set()
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    # the session's first cwd: tracked paths in file-history snapshots are relative to it
                    if scwd is None and '"cwd"' in line:
                        try: scwd = json.loads(line).get('cwd')
                        except Exception: pass
                    if '"type":"user"' in line and '"toolUseResult"' not in line and '/subagents/' not in f:
                        try: u = json.loads(line)
                        except Exception: continue
                        text = owner_text(u)
                        if text: turns.append({'at': u.get('timestamp'), 'text': text})
                        continue
                    if '-out.md' not in line and not DRAFT_TOOL.search(line): continue
                    try: d = json.loads(line)
                    except Exception: continue
                    if d.get('type') == 'file-history-snapshot':
                        for p, b in ((d.get('snapshot') or {}).get('trackedFileBackups') or {}).items():
                            if re.search(r'comms/[^/]*-out\.md$', p) and b.get('backupFileName'):
                                snaps.append((p, b))
                        continue
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
                            dests.append((dest_of(p, cwd), p))
                            letters.add(p)
                        if is_draft and not targets:
                            root = project_root(os.path.join(cwd, 'x'))
                            dests.append((os.path.join(OUT, slug_of(root), '_drafts'), None))
                            drafts += 1
                        touched.update(os.path.relpath(dest, OUT).split(os.sep)[0] for dest, _ in dests)
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
            # whole copies of the letter the harness kept for this session, one per turn
            sid = os.path.basename(f)[:-len('.jsonl')]
            for p, b in snaps:
                rp = b.get('realParentDir')
                a = os.path.join(rp, os.path.basename(p)) if rp else resolve(p, scwd)
                if is_fixture(a): continue
                dest = dest_of(a, scwd)
                touched.add(os.path.relpath(dest, OUT).split(os.sep)[0])
                name = '%s__%s__v%s.md' % ((b.get('backupTime') or '').replace(':', ''), sid[:8], b.get('version'))
                target = os.path.join(dest, 'fh', name)
                if target in fh_done or os.path.exists(target): continue
                fh_done.add(target)
                letters.add(a)
                src = next((s for s in (os.path.join(r, sid, b['backupFileName']) for r in FH_ROOTS)
                            if os.path.isfile(s)), None)
                if src is None:
                    fh_missing.append(sid + '/' + b['backupFileName'])
                    continue
                fh_copied += 1
                if DRY: continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(src, target)
            # a transcript only grows, and a deleted one must not shrink what was kept
            for proj in sorted(touched) if turns and not DRY else ():
                tdir = os.path.join(OUT, proj, '_owner-turns')
                tpath = os.path.join(tdir, sid + '.jsonl')
                had = sum(1 for _ in open(tpath, encoding='utf-8')) if os.path.exists(tpath) else 0
                if len(turns) > had:
                    os.makedirs(tdir, exist_ok=True)
                    with open(tpath, 'w', encoding='utf-8') as out:
                        out.writelines(json.dumps(x, ensure_ascii=False) + '\n' for x in turns)
                    turns_saved += 1
        except Exception as e:
            print('skip', f, e, file=sys.stderr)
    if FH_LIST:
        print('\n'.join(sorted(set(fh_missing))))
        return
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
    print('file-history copies taken:', fh_copied, ' not on this machine:', len(set(fh_missing)),
          '(--fh-list names them)' if fh_missing else '')
    print('sessions whose owner turns were saved or grew:', turns_saved)
    print('projects:', ', '.join(projects))
    print('oldest trace:', min(oldest.values()) if oldest else '-')

main()
