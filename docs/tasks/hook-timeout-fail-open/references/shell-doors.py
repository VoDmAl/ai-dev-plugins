#!/usr/bin/env python3
"""shell-doors.py — which tools hand a command string to a shell on this machine,
and would git-guard have stopped any commit that went through one it does not read.

Reads every transcript under ~/.claude/projects, subagents included (read-only).
Two tables:

  1. every tool whose input carried a string `command`: calls, first seen, and
     whether git-guard reads it (its SHELL_TOOLS). A row marked "NOT READ" is a
     door the guard is not watching.
  2. every call through a tool the guard does NOT read, replayed through the
     guard as if it were Bash: any exit 2 is a commit or push that went past it.

Written for hook-timeout-fail-open Sidetrack #1 (2026-10-01), whose decision it
backs: Bash 50 383 calls, Monitor 60 (first 2026-09-14) — and all 60 Monitor
commands replayed through the guard came back allowed. Re-run it with the
cancellation re-measure: a new NOT READ row means the harness opened a door.

Usage: python3 shell-doors.py   (from the repo root)
"""
import collections, glob, importlib.util, json, os, subprocess, sys

GUARD = os.path.abspath('plugins/vdm-git/scripts/git-guard-hook.py')
if not os.path.isfile(GUARD):
    sys.exit('run from the repo root: %s not found' % GUARD)
spec = importlib.util.spec_from_file_location('git_guard_hook', GUARD)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
READ = set(mod.SHELL_TOOLS)

calls = collections.Counter()
first = {}
unread = []
root = os.path.expanduser('~/.claude/projects')
for f in glob.glob(root + '/**/*.jsonl', recursive=True):
    with open(f, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if '"tool_use"' not in line or '"command"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get('message')
            for c in (msg.get('content') if isinstance(msg, dict) else None) or []:
                if not isinstance(c, dict) or c.get('type') != 'tool_use':
                    continue
                inp = c.get('input')
                cmd = inp.get('command') if isinstance(inp, dict) else None
                if not isinstance(cmd, str):
                    continue
                name, ts = c.get('name', '?'), rec.get('timestamp', '')
                calls[name] += 1
                if name not in first or ts < first[name]:
                    first[name] = ts
                if name not in READ:
                    unread.append((name, ts, os.path.relpath(f, root).split(os.sep)[0], cmd))

print('tools with a string `command` (git-guard reads: %s)' % ', '.join(sorted(READ)))
for name, n in calls.most_common():
    print('  %-28s %7d  first %s  %s' % (name, n, first[name][:10], 'read' if name in READ else 'NOT READ'))

blocked = []
for name, ts, proj, cmd in unread:
    p = subprocess.run(['python3', GUARD], input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, cwd='/')
    if p.returncode == 2:
        blocked.append((ts, name, proj, cmd[:200].replace('\n', ' ⏎ ')))
print('\ncalls through tools the guard does not read: %d; a commit or push among them: %d' % (len(unread), len(blocked)))
for row in sorted(blocked):
    print('  %s  %s  %s\n    %s' % row)
