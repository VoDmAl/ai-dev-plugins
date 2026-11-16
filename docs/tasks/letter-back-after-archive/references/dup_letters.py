import os, re, sys, time, collections
root = os.path.expanduser('~/.claude/vdm/intercom')
def fm(p):
    d = {}
    try:
        with open(p, encoding='utf-8', errors='replace') as f:
            if f.readline().strip() != '---': return d
            for l in f:
                if l.strip() == '---': break
                m = re.match(r'^([a-z_-]+):\s*(.*)$', l)
                if m: d[m.group(1)] = m.group(2).strip().strip('"')
    except OSError: pass
    return d
groups = collections.defaultdict(list); total = 0; mism = []; now = time.time()
for inbox in sorted(os.listdir(root)):
    if inbox.startswith('_'): continue
    b = os.path.join(root, inbox)
    if not os.path.isdir(b): continue
    for sub, where in ((b, 'inbox'), (os.path.join(b, '_done'), 'done')):
        if not os.path.isdir(sub): continue
        for n in os.listdir(sub):
            if not n.endswith('.md') or n == 'README.md': continue
            p = os.path.join(sub, n); e = fm(p)
            if not e.get('slug'): continue
            total += 1
            groups[(inbox, e.get('from'), e['slug'], e.get('created'))].append((where, n))
            if n[:-3] != e['slug']:
                st = os.stat(p); txt = open(p, encoding='utf-8', errors='replace').read()
                mism.append((inbox, where, n, e['slug'], (now - st.st_ctime) / 86400, '- [ ] ' in txt))
print('letters with an envelope:', total)
d = {k: v for k, v in groups.items() if len(v) > 1}
print('same envelope (inbox, from, slug, created) in 2+ files:', len(d))
for k, v in sorted(d.items(), key=lambda kv: kv[0][3] or ''):
    print(' ', k[0], k[2], k[3], [f'{w}:{n}' for w, n in v])
print('file name != envelope slug:', len(mism))
c = collections.Counter('sync-conflict' if '.sync-conflict-' in m[2] else ('stamp' if re.search(r'\.\d{9,}\.md$', m[2]) else 'renamed') for m in mism)
print(' by kind:', dict(c))
r = [m for m in mism if m[1] == 'done' and m[4] < 14 and m[5]]
print(' in _done, ctime under 14d, with an open item:', len(r))
for m in r: print('  ', m[0], m[2], '| slug', m[3], '| %.1fd' % m[4])
