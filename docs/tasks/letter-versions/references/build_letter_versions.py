"""Derive the versions of outgoing letters from what collect_letter_versions.py kept.

For a letter folder under ~/.claude/vdm/letter-versions/<project>/<letter>/: every whole text that can be
known — a harness copy (fh/), a Write, a heredoc `cat > letter`, an Edit, a python `str.replace` with
literal strings or a `sed -i` made only of `s` commands replayed on the text before it, the file as it is
now — in time order, identical neighbours dropped, into versions/. And index.md: the list, the last draft
(the last version whose frontmatter is not sent), and the body diffs first version → last draft and last
draft → now, as unified diffs (*.diff) and word by word (*.wdiff.md, `[-struck-]{+added+}`).

A command that writes the letter some other way (a script with computed strings, another sed command) is
not replayed: index.md lists it as a gap, and the next harness copy or Write shows its result.
What the owner changed in the mail client is not here unless the project put the sent text into the
file (letters § 9): last draft → now is the diff against that, not against Sent.

Run: python3 -I build_letter_versions.py [--all | <letter dir>...]   (default: letters with sent-proof: owner;
--all also takes letters no longer on disk, from their traces and copies, and writes <project>/INDEX.md)
"""
import ast, difflib, glob, json, os, re, shutil, subprocess, sys, tempfile

H = os.path.expanduser('~')
OUT = os.path.join(H, '.claude', 'vdm', 'letter-versions')
HEREDOC = re.compile(r"""<<-?\s*['"]?(\w+)['"]?[^\n]*\n(.*?)\n\1(?:\n|$)""", re.S)
SED_I = re.compile(r"""\bsed\s+-i\s*(?:''|"")?\s+(-E\s+)?(?:-e\s+)?'([^']*)'\s+([^;&|\n]+)""")
WRITES = re.compile(r"sed\s+-i|perl\s+-[a-z]*i|write_text|\.write\(|>\s*\S*-out\.md|\bmv\b|\bcp\b|tee\b")


def split_fm(text):
    m = re.match(r'---\n(.*?)\n---\n?', text, re.S)
    return (m.group(1), text[m.end():]) if m else ('', text)


def is_sent(text):
    fm, _ = split_fm(text)
    if re.search(r'^draft:\s*true\s*$', fm, re.M): return False
    return bool(re.search(r'^sent:\s*\d{4}-\d\d-\d\d', fm, re.M))


def python_pairs(code):
    """(old, new) of every str.replace and every list of string pairs whose strings are literals — written
    in place or assigned once to a name (`old_body = \"\"\"…\"\"\"`)."""
    try: tree = ast.parse(code)
    except SyntaxError: return None
    names = {}
    for n in ast.walk(tree):
        if (isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
                and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)):
            names[n.targets[0].id] = None if n.targets[0].id in names else n.value.value
    def lit(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, str): return n.value
        if isinstance(n, ast.Name): return names.get(n.id)
        return None
    pairs = []
    for n in ast.walk(tree):
        if (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'replace'
                and len(n.args) >= 2 and lit(n.args[0]) is not None and lit(n.args[1]) is not None):
            pairs.append((n.lineno, n.col_offset, lit(n.args[0]), lit(n.args[1])))
        elif isinstance(n, (ast.List, ast.Tuple)) and n.elts and all(
                isinstance(e, ast.Tuple) and len(e.elts) == 2 and lit(e.elts[0]) is not None
                and lit(e.elts[1]) is not None for e in n.elts):
            for e in n.elts:
                pairs.append((e.lineno, e.col_offset, lit(e.elts[0]), lit(e.elts[1])))
    return [(a, b) for _, _, a, b in sorted(pairs)]


def s_only(script):
    """True if the sed script is nothing but `s` commands with g, I or a number for flags."""
    i, n = 0, len(script)
    while i < n:
        while i < n and script[i] in ' \t;\n': i += 1
        if i >= n: break
        if script[i] != 's' or i + 1 >= n: return False
        d = script[i + 1]; i += 2
        for _ in range(2):
            while i < n and script[i] != d:
                i += 2 if script[i] == '\\' else 1
            if i >= n: return False
            i += 1
        while i < n and script[i] in 'gI0123456789': i += 1
    return True


def sed_replay(cur, ere, script):
    """The text after the very sed that ran, applied to a scratch copy of it."""
    with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False, encoding='utf-8') as tf:
        tf.write(cur); tmp = tf.name
    try:
        r = subprocess.run(['/usr/bin/sed'] + (['-E'] if ere else []) + ['-e', script, tmp],
                           capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    if r.returncode: return None
    out = r.stdout
    return out[:-1] if out.endswith('\n') and not cur.endswith('\n') else out


def events(d, name):
    """(time, order, source, kind, payload) — kind: full | edit | pairs | gap."""
    ev = []
    for f in sorted(glob.glob(os.path.join(d, 'fh', '*.md'))):
        m = re.match(r'(\d{4}-\d\d-\d\dT)(\d\d)(\d\d)(\d\d(?:\.\d+)?Z)__(\w+)__v(\d+)\.md$', os.path.basename(f))
        if not m: continue
        t = '%s%s:%s:%s' % m.group(1, 2, 3, 4)
        ev.append((t, 0, 'harness copy %s v%s' % (m.group(5), m.group(6)), 'full', open(f, encoding='utf-8').read()))
    tr = os.path.join(d, 'trace.jsonl')
    for line in open(tr, encoding='utf-8') if os.path.exists(tr) else []:
        r = json.loads(line)
        t, tool, inp, sess = r.get('at') or '', r['tool'], r.get('input') or {}, os.path.basename(r.get('session') or '')[:8]
        src = '%s %s' % (tool, sess)
        if tool == 'Write':
            ev.append((t, 1, src, 'full', inp.get('content') or ''))
        elif tool == 'Edit':
            ev.append((t, 1, src, 'edit', [(inp.get('old_string') or '', inp.get('new_string') or '', inp.get('replace_all'))]))
        elif tool == 'MultiEdit':
            ev.append((t, 1, src, 'edit', [(e.get('old_string') or '', e.get('new_string') or '', e.get('replace_all'))
                                           for e in inp.get('edits') or []]))
        elif tool == 'Bash':
            cmd = inp.get('command') or ''
            parts = []  # (position in the command, event): one command may write the letter twice
            for m in HEREDOC.finditer(cmd):
                head = cmd[max(0, m.start() - 300):m.start()].rsplit('\n', 1)[-1]
                if re.search(r'cat\s*>\s*\S*' + re.escape(name), head):
                    parts.append((m.start(), (t, 1, src + ' heredoc', 'full', m.group(2) + '\n')))
                elif re.search(r'python3?\s+-', head) and name in m.group(2):
                    pairs = python_pairs(m.group(2))
                    if pairs: parts.append((m.start(), (t, 1, src + ' python', 'pairs', (pairs, cmd))))
            for m in SED_I.finditer(cmd):
                if name in m.group(3) and s_only(m.group(2)):
                    parts.append((m.start(), (t, 1, src + ' sed', 'sed', (bool(m.group(1)), m.group(2)))))
            ev += [e for _, e in sorted(parts, key=lambda p: p[0])]
            if not parts and WRITES.search(cmd):
                ev.append((t, 1, src, 'gap', cmd))
    now = os.path.join(d, 'now.md')
    if os.path.exists(now):
        ev.append(('~now', 2, 'file now', 'full', open(now, encoding='utf-8').read()))
    return sorted(ev, key=lambda e: (e[0], e[1]))


def kind_of(src):
    for k, label in (('harness', 'harness copy'), ('heredoc', 'heredoc'), ('python', 'python (replay)'),
                     ('sed', 'sed (replay)'), ('Edit', 'Edit (replay)'), ('Write', 'Write'), ('now', 'file now')):
        if k in src: return label
    return src


def wdiff(a, b):
    ta, tb = re.findall(r'\s+|[^\s]+', a), re.findall(r'\s+|[^\s]+', b)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes():
        if op == 'equal': out.append(''.join(ta[i1:i2]))
        if op in ('delete', 'replace'): out.append('[-' + ''.join(ta[i1:i2]) + '-]')
        if op in ('insert', 'replace'): out.append('{+' + ''.join(tb[j1:j2]) + '+}')
    return ''.join(out)


def changed_words(a, b):
    ta, tb = a.split(), b.split()
    sm = difflib.SequenceMatcher(None, ta, tb, autojunk=False)
    return sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in sm.get_opcodes() if op != 'equal')


def build(d):
    name = os.path.basename(d).split('__')[-1]
    vers, gaps, cur = [], [], None
    replayed, check = False, [0, 0]  # a harness copy after replayed writes: [same body, other body]
    for t, _, src, kind, p in events(d, name):
        new, note = None, ''
        if kind == 'full':
            new = p
            if replayed and src.startswith('harness'): check[split_fm(new)[1] != split_fm(cur)[1]] += 1
            replayed = False
        elif kind == 'edit' and cur is not None:
            new = cur
            for old, rep, all_ in p:
                if old and old in new: new = new.replace(old, rep) if all_ else new.replace(old, rep, 1)
                else: new = None; break
            if new is None: gaps.append((t, src, 'Edit did not apply to the version before it'))
        elif kind == 'pairs' and cur is not None:
            pairs, cmd = p
            new, hit = cur, 0
            for old, rep in pairs:
                if old and old in new: new = new.replace(old, rep, 1); hit += 1
            note = ' (replayed %d of %d replacements)' % (hit, len(pairs))
            if hit == 0: new = None
            if hit < len(pairs): gaps.append((t, src, 'python: %d of %d replacements found in the text' % (hit, len(pairs))))
        elif kind == 'sed' and cur is not None:
            new = sed_replay(cur, *p)
            if new is None: gaps.append((t, src, 'sed failed on the version before it: ' + p[1][:120]))
        elif kind == 'gap':
            gaps.append((t, src, 'not replayed: ' + ' '.join(p.split())[:160]))
        if new is not None and new != cur:
            vers.append((t, src + note, new)); cur = new
            replayed = replayed or kind != 'full'
    vd = os.path.join(d, 'versions')
    shutil.rmtree(vd, ignore_errors=True); os.makedirs(vd)
    for i, (t, src, text) in enumerate(vers, 1):
        open(os.path.join(vd, '%02d.md' % i), 'w', encoding='utf-8').write(text)
    drafts = [i for i, v in enumerate(vers) if not is_sent(v[2])]
    last = drafts[-1] if drafts else None
    lines = ['# %s' % os.path.relpath(d, OUT), '',
             '| # | when (UTC) | source | state | words changed |', '|---|---|---|---|---|']
    for i, (t, src, text) in enumerate(vers):
        prev = split_fm(vers[i - 1][2])[1] if i else ''
        lines.append('| %02d | %s | %s | %s | %s |' % (i + 1, t[:19].replace('T', ' '), src,
                     'sent' if is_sent(text) else 'draft' + (' ← last' if i == last else ''),
                     changed_words(prev, split_fm(text)[1]) if i else '—'))
    if gaps:
        lines += ['', '## Gaps — writes not replayed', ''] + ['- %s %s: %s' % (t[:19], s, w) for t, s, w in gaps]
    summary = {'letter': os.path.relpath(d, OUT), 'versions': len(vers), 'gaps': len(gaps),
               'last_draft_from': kind_of(vers[last][1]) if last is not None else '—',
               'replay_check': '%d/%d' % (check[0], sum(check)) if sum(check) else '—',
               'first_to_last_draft': None, 'last_draft_to_now': None}
    if last is not None and vers:
        first_b, last_b, now_b = (split_fm(vers[0][2])[1], split_fm(vers[last][2])[1], split_fm(vers[-1][2])[1])
        for key, a, b, an, bn in (('first_to_last_draft', first_b, last_b, '01', '%02d' % (last + 1)),
                                  ('last_draft_to_now', last_b, now_b, '%02d' % (last + 1), 'now')):
            n = changed_words(a, b)
            summary[key] = n
            base = os.path.join(d, key.replace('_', '-'))
            open(base + '.diff', 'w', encoding='utf-8').write(''.join(difflib.unified_diff(
                a.splitlines(True), b.splitlines(True), an, bn)))
            open(base + '.wdiff.md', 'w', encoding='utf-8').write(wdiff(a, b))
            lines += ['', '## %s → %s: %d words changed in the body' % (an, bn, n),
                      '`%s.diff`, `%s.wdiff.md`' % ((key.replace('_', '-'),) * 2)]
    open(os.path.join(d, 'index.md'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    now = os.path.join(d, 'now.md')
    summary['owner_sent'] = os.path.exists(now) and bool(
        re.search(r'^sent-proof:\s*owner', open(now, encoding='utf-8').read(), re.M))
    summary['on_disk'] = os.path.exists(now)
    return summary


def project_index(proj, rows):
    """<project>/INDEX.md: the project's letters, those the owner sent first, then by the size of the change."""
    w = lambda v: '—' if v is None else str(v)
    rows = sorted(rows, key=lambda r: (not r['owner_sent'], -(r['first_to_last_draft'] or 0), r['letter']))
    out = ['# Outgoing letters of `%s`: versions from the harness transcripts' % proj, '',
           'Built by `build_letter_versions.py` from what `collect_letter_versions.py` kept. Per letter: '
           '`index.md` (the versions, the gaps), `versions/NN.md`, and the body diffs '
           '`first-to-last-draft.*` and `last-draft-to-now.*`. "now" is the file as it was at collection; '
           'it is the sent text only where the project reconciled it with Sent. '
           'What the owner said in those sessions: `_owner-turns/<session>.jsonl`.', '',
           '| letter | sent by owner | on disk | versions | words: first → last draft | words: last draft → now |',
           '|---|---|---|---|---|---|']
    for r in rows:
        name = r['letter'].split('/', 1)[1]
        out.append('| [%s](%s/index.md) | %s | %s | %d | %s | %s |' % (
            name.replace('__', '/'), name, 'yes' if r['owner_sent'] else '', 'yes' if r['on_disk'] else 'gone',
            r['versions'], w(r['first_to_last_draft']), w(r['last_draft_to_now'])))
    open(os.path.join(OUT, proj, 'INDEX.md'), 'w', encoding='utf-8').write('\n'.join(out) + '\n')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if args: dirs = args
    else:
        dirs = sorted(d for d in glob.glob(os.path.join(OUT, '*', '*'))
                      if not os.path.basename(d).startswith('_') and os.path.isdir(d) and (
                          '--all' in sys.argv if not os.path.exists(os.path.join(d, 'now.md')) else
                          '--all' in sys.argv or re.search(r'^sent-proof:\s*owner',
                                                           open(os.path.join(d, 'now.md'), encoding='utf-8').read(), re.M)))
    rows = [build(d) for d in dirs]
    if '--all' in sys.argv:
        for proj in sorted({r['letter'].split('/')[0] for r in rows}):
            project_index(proj, [r for r in rows if r['letter'].startswith(proj + '/')])
    w = lambda v: '—' if v is None else str(v)
    print('| letter | versions | gaps | replay = next harness copy | last draft from '
          '| words: first → last draft | words: last draft → now |')
    print('|---|---|---|---|---|---|---|')
    for r in rows:
        print('| %s | %d | %d | %s | %s | %s | %s |' % (r['letter'], r['versions'], r['gaps'], r['replay_check'],
                                                  r['last_draft_from'],
                                                  w(r['first_to_last_draft']), w(r['last_draft_to_now'])))


main()
