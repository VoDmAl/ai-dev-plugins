#!/usr/bin/env python3
"""Survey of the git-guard commit line across the projects of one machine.

Crystal `git-commit-privilege`, Next action 1: the facts the owner and the assistant need to choose the
principle by which a repository's agent gets `git commit` and `git push`.

Reads, read-only:
  * the harness transcripts (default ~/.claude/projects, *.jsonl modified within --days):
      - every `!` command the owner ran (`<bash-input>`) and its output (`<bash-stdout>`/`<bash-stderr>`):
        runs of a prepared line (full form or short call), hand-typed `git commit`, `git push`;
      - every Bash call of the assistant that ran `git-guard-prepare` (a prepared line) or `git commit` /
        `git push` itself (blocked by the guard, or not);
      - record timestamps per session, to see sessions working in one tree at the same time;
  * the git-guard state (default ~/.local/state/vdm-git): how each line died (`.gone`: committed, replaced,
    expired, untraceable) and which still wait;
  * each project's repository: CI files, remote host, merges on the current branch, commits and authors
    within --days, correspondence-like directories.

Prints JSON on stdout: projects as P1..Pn, hosts as H1..Hn — no names, so the output can be quoted in the
crystal. With --names the mapping goes to stderr only, for the owner's eyes; never paste it into the repo
(Critical Rule 7).

Python 3.9 (the other machine runs 3.9): stdlib only.
Usage: python3 -I commit-line-survey.py [--days 30] [--transcripts DIR] [--state DIR] [--names]
"""
import argparse
import collections
import datetime as dt
import glob
import html
import json
import os
import re
import statistics
import subprocess
import sys
import time

# Short calls lived in /tmp/vdm-git-<uid>/ before the state directory got its sh/ (both are read).
TOKEN_RE = re.compile(r'(?:/sh/|-commit-|/vdm-git-\d+/)(\d{10})-(\d+)\.(?:sh|txt)')
SHORT_CALL_RE = re.compile(r'short call: sh \S*/(?:sh|vdm-git-\d+)/(\d{10})-(\d+)\.sh')
COMMIT_OK_RE = re.compile(r'^\[[^\]\n]+ [0-9a-f]{7,}\]', re.M)
TS_RE = re.compile(r'"timestamp":"([0-9T:.\-]+)Z?"')
SID_RE = re.compile(r'"sessionId":"([0-9a-f\-]{36})"')
PREP_CMD_RE = re.compile(r'(?:^|[;&|(]\s*|\n\s*)(?:\S*/)?git-guard-prepare(?:\s|$)')
PREP_FLAG_RE = re.compile(r'\s+--(?:help|verify-last|check|pending)\b')
GIT_VERB_RE = {v: re.compile(r'(?:^|[;&|(]\s*|\n\s*)git\s+(?:-C\s+\S+\s+|-c\s+\S+\s+)*%s(?:\s|$)' % v)
               for v in ('commit', 'push')}
QUOTED_RE = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def unquote(cmd):
    """Blank quoted strings, so `grep 'git commit'` is not read as a commit."""
    return QUOTED_RE.sub('""', cmd)


NEEDLES = ('bash-input', 'bash-stdout', 'git-guard-prepare', 'tool_result')
GIT_NEEDLE_RE = re.compile(r'git (?:-[cC] \S+ )*(?:commit|push)\b')  # `git -C "$d" commit` has no "git commit"


def parse_ts(s):
    s = s.rstrip('Z')
    try:
        return dt.datetime.fromisoformat(s[:26]).replace(tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for x in content:
            if isinstance(x, dict):
                if x.get('type') == 'text':
                    out.append(x.get('text', ''))
                elif x.get('type') == 'tool_result':
                    out.append(text_of(x.get('content')))
        return '\n'.join(out)
    return ''


def between(s, tag):
    m = re.search('<%s>(.*?)</%s>' % (tag, tag), s, re.S)
    return html.unescape(m.group(1)) if m else ''


def classify_commit(out):
    if COMMIT_OK_RE.search(out):
        return 'ok'
    low = out.lower()
    if 'you will be notified when it completes' in low:
        return 'backgrounded'
    for key, label in (
        ('changed after they were staged', 'paths-changed-after-staging'),
        ('this line is void', 'void-line'),
        ('строка снята', 'void-line'),
        ('index.lock', 'index-lock-busy'),
        ('vdx doctor', 'hook-refused'),
        ('could not read log file', 'fatal-log-file'),
        ('no such file or directory', 'no-such-file'),
        ('nothing to commit', 'nothing-to-commit'),
        ('no changes added to commit', 'nothing-to-commit'),
        ('pre-commit', 'hook-refused'),
        ('gate', 'hook-refused'),
        ('blocked', 'hook-refused'),
    ):
        if key in low:
            return label
    return 'other-failure' if out.strip() else 'no-output'


def prep_refusal(out):
    low = out.lower()
    for key, label in (
        ('over this project\'s ceiling', 'subject-over-ceiling'),
        ('still waiting', 'a-line-still-waiting'),
        ('nothing staged', 'nothing-staged'),
        ('differs from the index', 'tree-differs-from-index'),
        ('hook error', 'project-hook'),
        ('swept in', 'previous-commit-swept-in'),
        ('not committed', 'previous-commit-swept-in'),
        ('syncthing conflict copies', 'sync-conflict-copies-in-git'),
        ('documents this commit may leave behind', 'docs-left-behind'),
        ('replacement character', 'replacement-character'),
        ('command not found: git-guard-prepare', 'helper-not-on-path'),
        ('was never run', 'earlier-line-never-run'),
    ):
        if key in low:
            return label
    return 'other'


def void_reason(out):
    m = re.search(r'this line is void — ([^;\n]+)', out)
    if not m:
        return None
    r = m.group(1)
    for key in ('already committed', 'replaced', 'expired', 'cannot be traced', 'deleted outside'):
        if key in r:
            return key
    return 'other'


def classify_push(out):
    low = out.lower()
    if 'everything up-to-date' in low:
        return 'up-to-date'
    if '->' in out or '-> ' in out:
        return 'ok'
    for key, label in (
        ('no configured push destination', 'no-remote'),
        ('does not appear to be a git repository', 'no-remote'),
        ('rejected', 'rejected'),
        ('has no upstream branch', 'no-upstream'),
    ):
        if key in low:
            return label
    return 'other-failure' if out.strip() else 'no-output'


class Toplevel:
    def __init__(self):
        self.cache = {}

    def __call__(self, cwd):
        if not cwd:
            return None
        if cwd in self.cache:
            return self.cache[cwd]
        top = None
        if os.path.isdir(cwd):
            try:
                r = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'],
                                   capture_output=True, text=True, timeout=10)
                if r.returncode == 0:
                    top = r.stdout.strip()
            except Exception:
                pass
        self.cache[cwd] = top or cwd
        return self.cache[cwd]


def scan_transcripts(root, since, toplevel):
    files = [f for f in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True)
             if os.path.getmtime(f) >= since and '/subagents/' not in f]
    runs, pushes, typed, preps, agent_git = [], [], [], [], []
    activity = collections.defaultdict(lambda: collections.defaultdict(set))  # project -> sid -> minutes
    sessions_seen = set()
    for f in files:
        pending = None   # (record, kind) awaiting its <bash-stdout>
        tool_calls = {}  # tool_use id -> (kind, project, ts, cmd)
        sid_file = None
        try:
            fh = open(f, encoding='utf-8', errors='replace')
        except OSError:
            continue
        with fh:
            for line in fh:
                m = TS_RE.search(line)
                ts = parse_ts(m.group(1)) if m else None
                if ts is not None and ts < since:
                    continue
                has = [n for n in NEEDLES if n in line]
                if GIT_NEEDLE_RE.search(line):
                    has.append('git')
                if has == ['tool_result'] and not tool_calls:
                    has = []
                if not has:
                    if ts is not None:
                        ms = SID_RE.search(line)
                        mc = re.search(r'"cwd":"([^"]+)"', line)
                        if ms and mc:
                            sid_file = ms.group(1)
                            activity[toplevel(mc.group(1))][sid_file].add(int(ts // 60))
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get('isSidechain'):
                    continue
                sid = o.get('sessionId') or sid_file
                cwd = o.get('cwd')
                proj = toplevel(cwd) if cwd else None
                if ts is not None and sid and proj:
                    activity[proj][sid].add(int(ts // 60))
                    sessions_seen.add(sid)
                msg = o.get('message') or {}
                content = msg.get('content')
                if o.get('type') == 'user' and isinstance(content, str) and ts is not None:
                    if content.startswith('<bash-input>') or '<bash-input>' in content[:40]:
                        cmd = between(content, 'bash-input')
                        pending = dict(sid=sid, project=proj, ts=ts, cmd=cmd)
                        continue
                    if '<bash-stdout>' in content and pending:
                        out = between(content, 'bash-stdout') + '\n' + between(content, 'bash-stderr')
                        cmd = pending['cmd']
                        is_line = bool(TOKEN_RE.search(cmd))
                        if is_line:
                            mt = TOKEN_RE.search(cmd)
                            runs.append(dict(pending, token='%s-%s' % mt.groups(),
                                             prep_epoch=int(mt.group(1)),
                                             result=classify_commit(out), void=void_reason(out),
                                             with_push='git push' in cmd))
                        elif re.search(r'\bgit\s+commit\b', cmd):
                            typed.append(dict(pending, result=classify_commit(out)))
                        if re.search(r'\bgit\s+push\b', cmd):
                            pushes.append(dict(pending, result=classify_push(out),
                                               after_line=is_line))
                        pending = None
                        continue
                if o.get('type') == 'assistant' and isinstance(content, list):
                    for x in content:
                        if not isinstance(x, dict) or x.get('type') != 'tool_use':
                            continue
                        if x.get('name') != 'Bash':
                            continue
                        cmd = unquote((x.get('input') or {}).get('command', ''))
                        kind = None
                        mp = PREP_CMD_RE.search(cmd)
                        if mp and not PREP_FLAG_RE.match(cmd, mp.end() - 1):
                            kind = 'prep'
                        elif GIT_VERB_RE['commit'].search(cmd):
                            kind = 'agent-commit'
                        elif GIT_VERB_RE['push'].search(cmd):
                            kind = 'agent-push'
                        if kind:
                            tool_calls[x.get('id')] = (kind, sid, proj, ts, cmd)
                if o.get('type') == 'user' and isinstance(content, list):
                    for x in content:
                        if not isinstance(x, dict) or x.get('type') != 'tool_result':
                            continue
                        call = tool_calls.pop(x.get('tool_use_id'), None)
                        if not call:
                            continue
                        kind, csid, cproj, cts, cmd = call
                        out = text_of(x.get('content'))
                        if kind == 'prep':
                            ms = SHORT_CALL_RE.search(out) or TOKEN_RE.search(out)
                            preps.append(dict(sid=csid, project=cproj, ts=cts,
                                              token=('%s-%s' % ms.groups()) if ms else None,
                                              refused=not ms, refusal=None if ms else prep_refusal(out),
                                              still_waiting='STILL WAITING' in out or 'still waiting' in out))
                        else:
                            blocked = out.lstrip().startswith('PreToolUse:Bash hook error') or (
                                'git-guard' in out and (x.get('is_error') or 'block' in out.lower()))
                            if kind == 'agent-commit':
                                res = 'blocked' if blocked else (
                                    'ok' if COMMIT_OK_RE.search(out) else 'no-commit-made')
                            else:
                                res = 'blocked' if blocked else classify_push(out)
                            agent_git.append(dict(kind=kind, sid=csid, project=cproj, ts=cts, result=res))
    return dict(files=len(files), sessions=len(sessions_seen), runs=runs, pushes=pushes, typed=typed,
                preps=preps, agent_git=agent_git, activity=activity)


KINDS = ('runs', 'pushes', 'typed', 'preps', 'agent_git')


def event_key(kind, r):
    return (kind, r.get('sid'), r.get('ts'), r.get('cmd') or r.get('kind') or r.get('token'))


def scan_state(state_dir, since):
    gone = collections.Counter()
    waiting = []
    for f in glob.glob(os.path.join(state_dir, '**', '*-commit-*.gone'), recursive=True):
        if os.path.getmtime(f) < since:
            continue
        try:
            line = open(f, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        gone[void_reason(line) or 'other'] += 1
    for f in glob.glob(os.path.join(state_dir, '**', '*-commit-*.txt'), recursive=True):
        mt = re.search(r'-commit-(\d{10})-(\d+)\.txt$', f)
        if mt and int(mt.group(1)) >= since:
            waiting.append('%s-%s' % mt.groups())
    return gone, waiting


def git(top, *args):
    try:
        r = subprocess.run(['git', '-C', top] + list(args), capture_output=True, text=True, timeout=30)
        return r.stdout if r.returncode == 0 else ''
    except Exception:
        return ''


def repo_features(top, days, hosts):
    feat = dict(exists=os.path.isdir(os.path.join(top, '.git')) or os.path.isfile(os.path.join(top, '.git')))
    if not feat['exists']:
        return feat
    feat['ci'] = any(os.path.exists(os.path.join(top, p)) for p in
                     ('.gitlab-ci.yml', '.github/workflows', '.woodpecker.yml', '.woodpecker', 'Jenkinsfile',
                      '.circleci', 'bitbucket-pipelines.yml'))
    url = git(top, 'remote', 'get-url', 'origin').strip()
    host = None
    if url:
        m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^:/]+)', url)
        host = m.group(1) if m else url
    if host:
        if host not in hosts:
            hosts[host] = 'H%d' % (len(hosts) + 1)
        feat['remote'] = hosts[host]
    else:
        feat['remote'] = None
    since = '%d days ago' % days
    log = git(top, 'log', '--since', since, '--format=%H%x09%ae%x09%ad%x09%P', '--date=short')
    rows = [l.split('\t') for l in log.splitlines() if l.count('\t') == 3]
    feat['commits'] = len(rows)
    feat['merges'] = sum(1 for r in rows if len(r[3].split()) > 1)
    feat['authors'] = len({r[1] for r in rows})
    per_day = collections.Counter(r[2] for r in rows)
    feat['active_days'] = len(per_day)
    feat['median_per_active_day'] = statistics.median(per_day.values()) if per_day else 0
    feat['max_per_day'] = max(per_day.values()) if per_day else 0
    branch = git(top, 'rev-parse', '--abbrev-ref', 'HEAD').strip()
    default = git(top, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD').strip().split('/')[-1]
    feat['on_default_branch'] = (branch == default) if default else None
    feat['remote_branches'] = len([l for l in git(top, 'branch', '-r').splitlines() if '->' not in l])
    feat['hooks_path'] = bool(git(top, 'config', 'core.hooksPath').strip())
    names = set()
    for dirpath, dirnames, _ in os.walk(top):
        depth = dirpath[len(top):].count(os.sep)
        dirnames[:] = [d for d in dirnames if not d.startswith('.') and d != 'node_modules'] if depth < 2 else []
        names.update(d.lower() for d in dirnames)
    feat['correspondence_dirs'] = sorted(names & {'meetings', 'comms', 'people', 'letters', 'mail'})
    return feat


def pct(values, q):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo), 1)


def overlap_share(activity_by_sid, minutes):
    """Share of `minutes` (prep moments) at which another session of the same tree was active within ±10 min."""
    if not minutes:
        return None
    hits = 0
    for sid, minute in minutes:
        found = False
        for other, mins in activity_by_sid.items():
            if other == sid:
                continue
            if any((minute + d) in mins for d in range(-10, 11)):
                found = True
                break
        hits += found
    return round(hits / len(minutes), 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=30)
    ap.add_argument('--transcripts', default=os.path.expanduser('~/.claude/projects'))
    ap.add_argument('--state', default=os.path.join(
        os.environ.get('XDG_STATE_HOME', os.path.expanduser('~/.local/state')), 'vdm-git'))
    ap.add_argument('--names', action='store_true', help='print the P/H mapping to stderr (never commit it)')
    ap.add_argument('--dump-events', metavar='FILE',
                    help='write the raw events of this machine (session ids, project paths) and stop')
    ap.add_argument('--merge-events', metavar='FILE', nargs='*', default=[],
                    help='events dumped on another machine; duplicates (synced transcripts) dropped')
    a = ap.parse_args()
    t0 = time.time()
    since = t0 - a.days * 86400
    top = Toplevel()
    tr = scan_transcripts(os.path.realpath(a.transcripts), since, top)
    gone, waiting = scan_state(a.state, since)
    if a.dump_events:
        ev = {k: tr[k] for k in KINDS}
        ev['activity'] = {p: {sid: sorted(m) for sid, m in d.items()} for p, d in tr['activity'].items()}
        ev.update(files=tr['files'], gone=dict(gone), waiting=waiting)
        if a.dump_events == '-':
            json.dump(ev, sys.stdout)
        else:
            with open(a.dump_events, 'w') as fh:
                json.dump(ev, fh)
        print('events: %s (%d s)' % (a.dump_events, time.time() - t0), file=sys.stderr)
        return
    a.machines = 1 + len(a.merge_events)
    for f in a.merge_events:
        ev = json.load(open(f))
        for k in KINDS:
            seen = {event_key(k, r) for r in tr[k]}
            tr[k].extend(r for r in ev[k] if event_key(k, r) not in seen)
        for p, d in ev['activity'].items():
            for sid, mins in d.items():
                tr['activity'][p][sid].update(mins)
        tr['files'] += ev['files']
        gone.update(ev['gone'])
        waiting.extend(ev['waiting'])
    tr['sessions'] = len({sid for d in tr['activity'].values() for sid in d})

    projects = set()
    for key in ('runs', 'pushes', 'typed', 'preps', 'agent_git'):
        projects.update(r['project'] for r in tr[key] if r.get('project'))
    ranked = sorted(projects, key=lambda p: -sum(1 for k in ('runs', 'preps', 'agent_git')
                                                   for r in tr[k] if r.get('project') == p))
    label = {p: 'P%d' % (i + 1) for i, p in enumerate(ranked)}
    hosts = {}
    out_projects = []
    for p in ranked:
        rs = [r for r in tr['runs'] if r['project'] == p]
        waits = [(r['ts'] - r['prep_epoch']) / 60 for r in rs if r['result'] == 'ok' and r['ts'] >= r['prep_epoch']]
        pr = [r for r in tr['preps'] if r['project'] == p]
        ag = [r for r in tr['agent_git'] if r['project'] == p]
        pu = [r for r in tr['pushes'] if r['project'] == p]
        ty = [r for r in tr['typed'] if r['project'] == p]
        prep_minutes = [(r['sid'], int(r['ts'] // 60)) for r in pr if r.get('ts') and r.get('token')]
        out_projects.append(dict(
            project=label[p],
            features=repo_features(p, a.days, hosts),
            sessions=len(tr['activity'].get(p, {})),
            preps=len([r for r in pr if r['token']]),
            prep_refused=len([r for r in pr if r['refused']]),
            prep_refusals=dict(collections.Counter(r['refusal'] for r in pr if r['refused'])),
            line_runs=dict(collections.Counter(r['result'] for r in rs)),
            void_reasons=dict(collections.Counter(r['void'] for r in rs if r['void'])),
            line_runs_with_push_in_same_paste=len([r for r in rs if r['with_push']]),
            wait_minutes=dict(n=len(waits), median=pct(waits, .5), p75=pct(waits, .75), max=pct(waits, 1),
                              over_30=len([w for w in waits if w > 30]), over_120=len([w for w in waits if w > 120])),
            typed_commits=dict(collections.Counter(r['result'] for r in ty)),
            pushes=dict(collections.Counter(r['result'] for r in pu)),
            agent_commits=dict(collections.Counter(r['result'] for r in ag if r['kind'] == 'agent-commit')),
            agent_pushes=dict(collections.Counter(r['result'] for r in ag if r['kind'] == 'agent-push')),
            prep_with_other_session_within_10min=overlap_share(tr['activity'].get(p, {}), prep_minutes),
        ))
    all_waits = [(r['ts'] - r['prep_epoch']) / 60 for r in tr['runs'] if r['result'] == 'ok' and r['ts'] >= r['prep_epoch']]
    report = dict(
        machines=a.machines,
        window_days=a.days,
        generated=dt.datetime.now().astimezone().isoformat(timespec='minutes'),
        transcripts_scanned=tr['files'],
        sessions_with_records=tr['sessions'],
        session_ids=sorted({r['sid'] for k in ('runs', 'pushes', 'typed', 'preps', 'agent_git')
                            for r in tr[k] if r.get('sid')}),
        totals=dict(
            preps=len([r for r in tr['preps'] if r['token']]),
            prep_refusals=dict(collections.Counter(r['refusal'] for r in tr['preps'] if r['refused'])),
            line_runs=dict(collections.Counter(r['result'] for r in tr['runs'])),
            wait_minutes=dict(n=len(all_waits), median=pct(all_waits, .5), p75=pct(all_waits, .75),
                              max=pct(all_waits, 1)),
            pushes=dict(collections.Counter(r['result'] for r in tr['pushes'])),
            typed_commits=dict(collections.Counter(r['result'] for r in tr['typed'])),
            agent_commits=dict(collections.Counter(r['result'] for r in tr['agent_git'] if r['kind'] == 'agent-commit')),
            agent_pushes=dict(collections.Counter(r['result'] for r in tr['agent_git'] if r['kind'] == 'agent-push')),
            state_gone=dict(gone),
            state_waiting=len(waiting),
        ),
        projects=out_projects,
        seconds=round(time.time() - t0),
    )
    json.dump(report, sys.stdout, ensure_ascii=False, indent=1)
    print()
    if a.names:
        for p in ranked:
            print('%s\t%s' % (label[p], p), file=sys.stderr)
        for h, l in hosts.items():
            print('%s\t%s' % (l, h), file=sys.stderr)


if __name__ == '__main__':
    main()
