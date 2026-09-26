#!/usr/bin/env python3
"""The case table for the command matcher in git-guard-hook.py.

Dev-only — not shipped to user plugin installs (scripts/ is repo-root, hooks
load only plugins/X/scripts/). Run by tests/git-guard-hook.test.sh and
tests/shellwords.test.sh, so a change to the guard or to the reader it shares
runs every case. Until 2026-09-26 it was run by hand only, and no gate called
it. Run on its own:

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

    # --- READ AS THE SHELL READS IT (Sidetrack #18, crystal-wake) ---
    # The matcher cut "inert" text with regexes that did not follow the quoting.
    # A `<<` that no line closes was taken for a heredoc to the end of the
    # command, a `#` inside quotes for a comment, and an apostrophe inside "…"
    # paired with the next '…'. Each threw away the commit that came after it.
    (True,  "after a here-string",          'cat <<<"msg" > /tmp/m && git commit -F /tmp/m'),
    (True,  "after an arithmetic shift",    'echo $((1<<2)); git commit -m x'),
    (True,  "after << inside quotes",       'echo "a <<b" && git commit -m x'),
    (True,  "after # inside quotes",        'echo "step #1" && git commit -m x'),
    (True,  "after an apostrophe in \"…\"",  'echo "it\'s" && git commit -m \'x\''),
    (True,  "through a line continuation",  'git \\\ncommit -m x'),
    (True,  "a heredoc no line closes is read, not cut", 'cat <<EOF\ngit commit -m x'),
    (True,  "after a closed heredoc",       "cat <<'EOF'\nbody\nEOF\ngit commit -m x"),
    (True,  "a # inside a word is no comment", 'curl http://x/#frag && git commit -m x'),
    (True,  "quotes that never close",      'git commit -m "unclosed'),
    # git's own options stand between `git` and the subcommand, and the program
    # is git however the shell is asked for it.
    (True,  "git -C <dir> commit",          'git -C /repo commit -m x'),
    (True,  "git -c k=v commit",            'git -c user.name=x commit -m x'),
    (True,  "git --no-pager commit",        'git --no-pager commit -m x'),
    (True,  "git --git-dir=… commit",       'git --git-dir=/r/.git commit -m x'),
    (True,  "git -C <dir> push",            'git -C /repo push'),
    (True,  "\\git",                         '\\git commit -m x'),
    (True,  "'git' in quotes",              "'git' commit -m x"),
    (True,  "\"commit\" in quotes",          'git "commit" -m x'),
    (True,  "/usr/bin/git",                 '/usr/bin/git commit -m x'),
    # Command text the shell runs from inside a command.
    (True,  "bash -c '…'",                  "bash -c 'git commit -m x'"),
    (True,  "sh -c \"…\"",                   'sh -c "git commit"'),
    (True,  "bash -lc with cd",             "bash -lc 'cd /r && git commit -m x'"),
    (True,  "bash -o pipefail -c",          "bash -o pipefail -c 'git commit -m x'"),
    (True,  "eval",                         'eval "git commit -m x"'),
    (True,  "$( ) inside \"…\"",             'echo "$(git commit -m x)"'),
    (True,  "backticks inside \"…\"",        'echo "`git commit`"'),
    # …and the same reading lets through what it always let through.
    (False, "git -C <dir> status",          'git -C /repo status'),
    (False, "git -c k=v log",               'git -c color.ui=never log'),
    (False, "--no-pager log --grep commit", 'git --no-pager log --grep commit'),
    (False, "commit inside a --grep value", 'git log --grep="fix commit"'),
    (False, "bash -c with status",          "bash -c 'git status'"),
    (False, "$( ) with status",             'echo "$(git status)"'),
    (False, "quotes that never close, no git", 'echo "unclosed'),
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
