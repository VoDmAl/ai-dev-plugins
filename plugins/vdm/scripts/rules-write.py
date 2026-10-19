#!/usr/bin/env python3
"""rules-write.py — install a rewritten shared rules layer, or refuse to.

A lesson about how the assistant works is folded into the whole layer
(`~/.claude/vdm/rules.md`) by a subagent, which may rewrite one rule or several
(crystal rules-dream, DL #2). A rewrite destroys the text it replaces, and the
file has no history of its own: `~/.claude` is synced between the owner's
machines by Syncthing, and parallel sessions write the same file. So the
rewrite is installed by this script and never by an edit:

  * `--hash` prints the file's fingerprint. The subagent gets it with the text
    it reads; the write is refused if the file changed since (exit 3) — a
    neighbouring session's lesson would otherwise vanish without a trace;
  * Syncthing is asked whether changes to the file are still on their way, and
    a conflict copy beside it is a refusal too (exit 4): either means another
    machine's edit is not in the text the subagent read;
  * the candidate's layer must fit the hook's budget (`shared-rules.sh
    --measure`), or nothing is written (exit 5);
  * the version it replaces goes to `~/.claude/vdm/history/`, the last 50 kept.

`--diff` prints how the layer — headings and first paragraphs, what a session
receives — differs between the live file and a candidate: exit 0 when it does
not, 1 when it does. A candidate whose layer is unchanged is written at once; a
changed layer is shown to the owner first (DL #3).

Usage:
  rules-write.py --hash
  rules-write.py --diff CANDIDATE
  rules-write.py --base HASH CANDIDATE [--session ID]

Exit: 0 written / layer unchanged · 1 layer differs (--diff) · 2 usage or a
candidate with no rules · 3 the file changed since HASH · 4 Syncthing has
changes on the way, or a conflict copy lies beside the file · 5 the candidate
does not fit the layer.

Environment: VDM_RULES_SYNC_CHECK — `off`, or the command to ask instead of
`syncthing-caught-up`; VDM_RULES_HISTORY_KEEP — versions kept (default 50).
"""

import argparse
import datetime
import difflib
import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SHARED_RULES = os.path.join(HERE, "shared-rules.sh")
RULE_RE = re.compile(r"(?m)^## \S")


def live_path():
    return os.path.join(os.path.expanduser("~"), ".claude", "vdm", "rules.md")


def fingerprint(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except FileNotFoundError:
        return "absent"


def layer(path=None):
    """The rules as a session receives them, from the hook itself."""
    cmd = ["bash", SHARED_RULES, "--layer"] + ([path] if path else [])
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def sync_refusal(path):
    """A reason not to write, or None. Codes of `syncthing-caught-up`: 0 nothing
    coming, 1 changes coming, 2 not in Syncthing, 3 cannot tell — only 1 refuses,
    3 is said; no command, no check (as git-guard-prepare asks it)."""
    base = os.path.basename(path)
    stem, suffix = os.path.splitext(base)
    copies = sorted(glob.glob(os.path.join(os.path.dirname(path), glob.escape(stem) + ".sync-conflict-*" + suffix)))
    if copies:
        return ("a Syncthing conflict copy lies beside the file: %s — another machine's edit is not in the "
                "text the rewrite was made from; merge it into rules.md, then read the file again"
                % ", ".join(os.path.basename(c) for c in copies))
    cmd = os.environ.get("VDM_RULES_SYNC_CHECK") or shutil.which("syncthing-caught-up")
    if not cmd or cmd == "off":
        return None
    try:
        rc = subprocess.run([cmd, "--fast", path], capture_output=True, text=True, timeout=30).returncode
    except (OSError, subprocess.TimeoutExpired):
        return None
    if rc == 1:
        return "Syncthing has changes to the file on the way — wait until they land, then read it again"
    if rc == 3:
        print("rules-write: Syncthing cannot tell whether changes are coming; writing anyway", file=sys.stderr)
    return None


def keep_history(path, session, keep):
    hist = os.path.join(os.path.dirname(path), "history")
    os.makedirs(hist, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    tag = re.sub(r"[^A-Za-z0-9-]", "", session or "")[:8] or "unknown"
    dest = os.path.join(hist, "rules-%s-%s.md" % (stamp, tag))
    n = 1
    while os.path.exists(dest):
        n += 1
        dest = os.path.join(hist, "rules-%s-%s-%d.md" % (stamp, tag, n))
    shutil.copy2(path, dest)
    versions = sorted(glob.glob(os.path.join(hist, "rules-*.md")))
    for old in versions[:-keep] if keep > 0 else []:
        os.remove(old)
    return dest


def install(path, candidate_text):
    """Replace the file in one rename, keeping its mode."""
    mode = 0o644
    try:
        mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".rules-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(candidate_text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def main(argv):
    ap = argparse.ArgumentParser(prog="rules-write.py")
    ap.add_argument("--hash", action="store_true")
    ap.add_argument("--diff", metavar="CANDIDATE")
    ap.add_argument("--base", metavar="HASH")
    ap.add_argument("--session", default=os.environ.get("CLAUDE_SESSION_ID", ""))
    ap.add_argument("candidate", nargs="?")
    args = ap.parse_args(argv)
    path = live_path()

    if args.hash:
        print(fingerprint(path))
        return 0

    if args.diff:
        if not os.path.isfile(args.diff):
            print("rules-write: no candidate at %s" % args.diff, file=sys.stderr)
            return 2
        before, after = layer(), layer(args.diff)
        if before == after:
            print("rules-write: the layer is unchanged — what sessions receive stays the same")
            return 0
        sys.stdout.writelines(difflib.unified_diff(
            before.splitlines(True), after.splitlines(True), "layer now", "layer after"))
        return 1

    if not args.base or not args.candidate:
        ap.print_usage(sys.stderr)
        return 2
    try:
        with open(args.candidate, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        print("rules-write: cannot read the candidate: %s" % e, file=sys.stderr)
        return 2
    if not RULE_RE.search(text):
        print("rules-write: the candidate has no `## ` rule — refusing to replace the layer with it",
              file=sys.stderr)
        return 2
    now = fingerprint(path)
    if now != args.base:
        print("rules-write: %s changed since it was read (%s, now %s) — another session or machine wrote it; "
              "fold the lesson into the file as it is now" % (path, args.base[:12], now[:12]), file=sys.stderr)
        return 3
    why = sync_refusal(path)
    if why:
        print("rules-write: %s" % why, file=sys.stderr)
        return 4
    measured = subprocess.run(["bash", SHARED_RULES, "--measure", args.candidate],
                              capture_output=True, text=True)
    if measured.returncode != 0:
        sys.stderr.write(measured.stdout)
        print("rules-write: the candidate does not fit the layer — nothing written", file=sys.stderr)
        return 5
    keep = int(os.environ.get("VDM_RULES_HISTORY_KEEP", "50") or 50)
    saved = keep_history(path, args.session, keep) if now != "absent" else None
    install(path, text)
    print("rules-write: written %s%s" % (path, " — the previous version is %s" % saved if saved else ""))
    sys.stdout.write(measured.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
