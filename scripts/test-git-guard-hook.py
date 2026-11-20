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
    # A newline ends a command (Sidetrack #19): `git` and `commit` on two lines
    # are two commands, and neither of them commits.
    (True,  "commit on the line after cd",  'cd /repo\ngit commit -m x'),
    (False, "git and commit on two lines",  'git\ncommit'),
]


# A push under the project's grant (git-guard.assistant naming `push`) goes
# through only when it is plain — push_refusal() returns None. Pure: no git, no
# grant read; docs/tasks/git-commit-privilege, DL #2.
PUSH_CASES = [
    # (allowed, description, command)
    (True,  "plain push",                    'git push'),
    (True,  "remote and branch",             'git push origin master'),
    (True,  "set upstream",                  'git push -u origin feature-x'),
    (True,  "tags",                          'git push --tags'),
    (True,  "a refspec that only renames",   'git push origin HEAD:refs/heads/main'),
    (True,  "after a status, in sequence",   'git status --short && git push'),
    (False, "--force",                       'git push --force'),
    (False, "-f",                            'git push -f origin master'),
    (False, "-f inside a cluster",           'git push -uf origin master'),
    (False, "--force-with-lease",            'git push --force-with-lease'),
    (False, "--force-with-lease=ref",        'git push --force-with-lease=main:abc origin main'),
    (False, "+refspec forces",               'git push origin +main'),
    (False, "--delete",                      'git push origin --delete old'),
    (False, ":branch deletes",               'git push origin :old'),
    (False, "--mirror",                      'git push --mirror'),
    (False, "--prune",                       'git push --prune origin'),
    (False, "--no-verify",                   'git push --no-verify'),
    (False, "cd elsewhere first",            'cd /other/repo && git push'),
    (False, "git -C elsewhere",              'git -C /other/repo push'),
    (False, "git -c before push",            'git -c core.hooksPath=/dev/null push'),
    (False, "env assignment in front",       'GIT_DIR=/other/.git git push'),
    (False, "inside bash -c",                "bash -c 'git push'"),
    (False, "inside a substitution",         'echo "$(git push)"'),
    (False, "a second push forces",          'git push && git push --force'),
    (False, "unclosed quote",                'git push "origin'),
    # git takes any unambiguous prefix of a long option: a deny-list let these
    # through (automated security review, 2026-11-20), the allow-list does not.
    (False, "--forc, a prefix of --force",   'git push --forc origin master'),
    (False, "--no-ver, a prefix of --no-verify", 'git push --no-ver'),
    (False, "--receive-pack runs a program", 'git push --receive-pack=x origin'),
    (False, "-o push option",                'git push -o ci.skip origin master'),
    (False, "a URL, not a remote name",      'git push https://example.com/r.git master'),
    (False, "a path, not a remote name",     'git push ../other master'),
    (False, "a pattern refspec",             "git push origin 'refs/heads/*:refs/heads/*'"),
    (True,  "-uq cluster",                   'git push -uq origin feature-x'),
    (True,  "--dry-run",                     'git push --dry-run origin master'),
    (True,  "tags after the branch",         'git push origin master --follow-tags'),
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
    for allowed, desc, cmd in PUSH_CASES:
        why = ggh.push_refusal(cmd)
        got = why is None
        ok = "✓" if got == allowed else "✗"
        if got != allowed:
            fails += 1
        print(f"  {ok} expect={'GRANT' if allowed else 'BLOCK'}  "
              f"got={'GRANT' if got else 'BLOCK'}  push: {desc}")
        if got != allowed:
            print(f"      cmd={cmd!r}  why={why!r}")
    total = len(CASES) + len(PUSH_CASES)
    print()
    if fails:
        print(f"FAIL: {fails}/{total} cases")
        return 1
    print(f"OK: {total}/{total} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
