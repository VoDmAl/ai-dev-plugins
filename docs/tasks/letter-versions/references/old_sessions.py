"""Live agent sessions on this machine that started before the installed vdm-comms.

A session loads its hooks when it starts, so one started before the install of vdm-comms 0.37.0 writes no
letter versions until it is restarted (crystal `letter-versions`, DL #7). The last run of the collector waits
until this prints `alive before: 0` on both machines.

Run: python3 -I old_sessions.py            (this machine)
     ssh -o BatchMode=yes m3 'python3 -I -' < old_sessions.py     (the other one; from m3, `lft`)
Exit: 0 none left · 1 some left · 2 cannot tell.
"""
import datetime, glob, json, os, sys

FIRST = (0, 37, 0)  # the first vdm-comms that keeps letter versions
# installed_plugins.json keeps only the current version, so the moment the recorder arrived is read off the
# plugin cache: the earliest-created version folder at or above FIRST.
born = []
for d in glob.glob(os.path.expanduser('~/.claude/plugins/cache/*/vdm-comms/*/')):
    try:
        v = tuple(int(x) for x in os.path.basename(d.rstrip('/')).split('.'))
    except ValueError:
        continue
    if v >= FIRST:
        st = os.stat(d)
        born.append((getattr(st, 'st_birthtime', st.st_mtime), '.'.join(map(str, v))))
if not born:
    print('cannot tell: no vdm-comms %s or later in the plugin cache' % '.'.join(map(str, FIRST)))
    sys.exit(2)
cut, version = min(born)
installed = datetime.datetime.fromtimestamp(cut, datetime.timezone.utc).isoformat(timespec='seconds')
old = []
for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
    try:
        s = json.load(open(f))
        os.kill(int(s['pid']), 0)
    except Exception:
        continue
    t = s.get('startedAt')
    t = t / 1000 if isinstance(t, (int, float)) and t > 1e11 else t
    if isinstance(t, (int, float)) and t < cut:
        old.append((datetime.datetime.fromtimestamp(t).strftime('%m-%d %H:%M'), os.path.basename(s.get('cwd', '?'))))
print('vdm-comms %s arrived %s | alive before: %d' % (version, installed, len(old)))
for when, project in sorted(old):
    print('  %s  %s' % (when, project))
sys.exit(1 if old else 0)
