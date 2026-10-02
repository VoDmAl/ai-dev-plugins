#!/usr/bin/env python3
"""hook-cancellations.py — how often this machine's harness cancelled the suite's
hooks, and what happened to the tool call behind a cancelled blocking guard.

Reads every transcript under ~/.claude/projects (read-only). Two tables:

  1. per hook: records with a duration, cancellations, p50/p99/max of the
     durations on record. A hook leaves a duration record only when it printed
     something — a silent guard is visible here only through its cancellations.
  2. every cancelled PreToolUse guard of the suite, with the fate of its call:
     RAN (a non-error tool_result), ERROR, or NO RESULT.

Written for hook-timeout-fail-open (2026-10-01), whose baseline it produced:
20 guard cancellations since 2026-09-03, RAN in all 20. Re-run it after the
60/30 s ceilings have been live for a while — a PreToolUse row in table 2
dated after the rollout means 60 s was not enough.

Usage: python3 hook-cancellations.py [--since YYYY-MM-DD]
"""
import collections, glob, json, os, re, sys

GUARDS = ('git-guard-hook', 'crystal-completion-guard', 'comms-draft-guard', 'comms-eml-guard')
SUITE = GUARDS + ('git-guard-reminder', 'crystal-stop-reminder', 'crystal-hydrate', 'intercom-identity-check',
                  'shared-rules', 'reminders', 'orphan-guard-hook', 'crystal-lint', 'shell-syntax-check',
                  'comms-index-check', 'comms-pending-check', 'comms-lint', 'comms-pending')
since = sys.argv[sys.argv.index('--since') + 1] if '--since' in sys.argv else ''


def script_of(cmd):
    m = re.search(r'([A-Za-z0-9_.-]+)\.(?:sh|py)', cmd or '')
    return m.group(1) if m else None


durs = collections.defaultdict(list)
cancels = collections.Counter()
rows = []
for f in glob.glob(os.path.expanduser('~/.claude/projects') + '/*/*.jsonl'):
    with open(f, errors='replace') as fh:
        txt = fh.read()
    if 'hook_' not in txt:
        continue
    recs = []
    for line in txt.splitlines():
        try:
            recs.append(json.loads(line))
        except ValueError:
            pass
    results = {}
    for d in recs:
        c = (d.get('message') or {}).get('content') if isinstance(d.get('message'), dict) else None
        for it in c if isinstance(c, list) else []:
            if isinstance(it, dict) and it.get('type') == 'tool_result':
                results[it.get('tool_use_id')] = bool(it.get('is_error'))
    for d in recs:
        if since and (d.get('timestamp') or '') < since:
            continue
        a = d.get('attachment') if isinstance(d.get('attachment'), dict) else d
        t = a.get('type', '')
        if not t.startswith('hook_'):
            continue
        s = script_of(a.get('command'))
        if s not in SUITE:
            continue
        key = '%s %s' % (a.get('hookEvent') or (a.get('hookName') or '').split(':')[0], s)
        if t == 'hook_cancelled':
            cancels[key] += 1
            if a.get('hookEvent') == 'PreToolUse' and s in GUARDS:
                r = results.get(a.get('toolUseID'))
                fate = 'NO RESULT' if r is None else ('ERROR' if r else 'RAN')
                rows.append((d.get('timestamp'), s, a.get('hookName'), a.get('durationMs'), a.get('timeoutMs'), fate))
        elif 'durationMs' in a:
            durs[key].append(int(a['durationMs']))

print('%-45s %7s %7s %6s %6s %7s' % ('hook', 'records', 'cancel', 'p50', 'p99', 'max'))
for k in sorted(set(durs) | set(cancels)):
    xs = sorted(durs.get(k, []))
    q = (lambda p: xs[min(len(xs) - 1, int(p * (len(xs) - 1)))]) if xs else (lambda p: '-')
    print('%-45s %7d %7d %6s %6s %7s' % (k, len(xs), cancels[k], q(.5), q(.99), xs[-1] if xs else '-'))
print('\ncancelled blocking guards → the tool call:')
for r in sorted(rows, key=lambda r: r[0] or ''):
    print('  %s  %-26s %-22s %6sms / %sms  %s' % (r[0], r[1], (r[2] or '')[:22], r[3], r[4], r[5]))
print('  total %d, ran %d' % (len(rows), sum(1 for r in rows if r[5] == 'RAN')))
