#!/usr/bin/env python3
"""Smoke-test the boundary-aware blocking logic in git-guard-hook.py.

Dev-only — not shipped to user plugin installs (scripts/ is repo-root, hooks
load only plugins/X/scripts/). Run manually:

    python3 scripts/test-git-guard-hook.py

Covers the false-positive class that motivated the v2.3.0 hook rewrite (substring
match against `git\\s+commit` triggered on quoted strings, comments, heredoc
bodies — see PROJECT_CHANGELOG 2026-05-07).
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "plugins", "vdm-git", "scripts", "git-guard-hook.py")

spec = importlib.util.spec_from_file_location("ggh", HOOK)
ggh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ggh)


CASES = [
    # (should_block, description, command)

    # --- SUBCOMMAND PREFIXES (must NOT block) ---
    # `\b` sits between a word char and a non-word one, and `-` is non-word, so
    # `git\s+commit\b` matched `git commit-tree`. The matcher was reading a
    # string prefix where it meant to read a subcommand: it blocked plumbing that
    # moves no ref, while `git update-ref` — which does — was never listed.
    # Found 2026-08-25 when `git commit-tree` was blocked while building a test
    # fixture in a throwaway repo.
    (False, "commit-tree is plumbing",   'git commit-tree $tree -m x'),
    (False, "commit-graph is a cache",   'git commit-graph write'),
    (False, "commit-tree after &&",      'cd /r && git commit-tree $t'),
    (False, "push prefix is not push",   'git push-hook-thing'),
    # …and the real thing must still block, or the fix has simply disarmed it.
    (True,  "commit still blocks",       'git commit -m x'),
    (True,  "commit -- pathspec blocks", "git commit -F /tmp/m.txt -- 'a' 'b'"),

    # --- TRUE POSITIVES (must block) ---
    (True,  "direct commit",          'git commit -m foo'),
    (True,  "commit with -F",         "git commit -F /tmp/msg.txt"),
    (True,  "chained &&",             "cd /repo && git commit -m foo"),
    (True,  "chained ;",              "cd /repo; git commit"),
    (True,  "subshell $()",           'echo $(git commit -m foo)'),
    (True,  "backtick subshell",      'X=`git commit`'),
    (True,  "if-block",               'if git commit; then echo done; fi'),
    (True,  "tab whitespace",         "git\tcommit"),
    (True,  "leading whitespace",     "   git commit -m foo"),
    (True,  "newline-separated",      "echo hi\ngit commit"),
    (True,  "push direct",            "git push origin master"),
    (True,  "push chained",           "git status && git push"),
    (True,  "after pipe",             'echo foo | git commit'),
    (True,  "after ||",               'false || git commit'),

    # --- FALSE POSITIVES (must NOT block) ---
    (False, "grep arg dq",            'grep "git commit" file'),
    (False, "grep arg sq",            "grep 'git commit' file"),
    (False, "echo dq",                'echo "git commit"'),
    (False, "echo sq",                "echo 'git commit'"),
    (False, "comment after space",    'ls # git commit'),
    (False, "comment line",           '# git commit triggers here'),
    (False, "heredoc body",           'cat <<EOF\ngit commit -m foo\nEOF'),
    (False, "heredoc-quoted marker",  "cat <<'EOF'\ngit commit\nEOF"),
    (False, "indented heredoc",       'cat <<-EOF\n\tgit commit\n\tEOF'),
    (False, "var assignment quoted",  'X="git commit"'),
    (False, "json payload",           '{"command":"git commit -m foo"}'),
    (False, "gitk (longer name)",     'gitk commit'),
    (False, "ls",                     'ls -la'),
    (False, "git status (allowed)",   'git status'),
    (False, "git diff (allowed)",     'git diff --cached'),
    (False, "literal in path arg",    'cat /var/log/git-commit.log'),
    (False, "in URL string",          'curl https://example.com/git/commit'),
]


def main():
    fails = 0
    for expected, desc, cmd in CASES:
        got = ggh._command_invokes(cmd, "commit") or ggh._command_invokes(cmd, "push")
        ok = "✓" if got == expected else "✗"
        if got != expected:
            fails += 1
        print(f"  {ok} expect={'BLOCK' if expected else 'PASS '}  "
              f"got={'BLOCK' if got else 'PASS '}  {desc}")
        if got != expected:
            print(f"      cmd={cmd!r}")
    print()
    if fails:
        print(f"FAIL: {fails}/{len(CASES)} cases")
        return 1
    print(f"OK: {len(CASES)}/{len(CASES)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
