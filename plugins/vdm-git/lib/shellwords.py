# -*- coding: utf-8 -*-
# shellwords.py — a Bash command read the way the shell reads it.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-comms/lib/shellwords.py.
# The mirror is checked by scripts/check-lib-sync.sh in the dev repo; any change
# here MUST be applied to the vdm-comms copy in the same commit.
"""Split a Bash command into the simple commands the shell will run.

Two guards decide from a command's text what it will do: `git-guard` looks for
`git commit` and `git push`, `comms-eml-guard` for a raw `.eml` copied into
comms/. Each used to read the command its own way, and each way had holes the
shell does not have:

  * text the shell does not read as words — a heredoc body, a comment — was
    read as words, and an apostrophe in it broke the whole reading;
  * a `<<` that no line closes (`$((1<<2))`, `<<<"msg"`) was taken for a
    heredoc, and everything after it was thrown away unread;
  * quotes were stripped by patterns that did not follow them, so an
    apostrophe inside "…" paired with the next '…'.

What a reader does with text it could not classify decides which way its guard
errs: throwing the text away lets through whatever stood after it. So a heredoc
is cut only when a line closes it, and a command whose quotes do not close
raises ValueError rather than being guessed at — each guard decides what "could
not read" means for it.

Not modelled: `$'…'` quoting, aliases and functions. A newline is whitespace
here, not a command separator.
"""
import shlex

# Tokens that end a simple command. Redirections (`>`, `<`, `<<`) do not: they
# stay in the argv, where a guard can read them.
_SEPARATORS = set(";&|()`")


def _heredoc_word(command, j):
    """The delimiter that follows `<<` at `j`: (index past it, word, tabs
    stripped?). Quotes and backslashes come off, as the shell takes them off."""
    n = len(command)
    strip = command.startswith("-", j)
    if strip:
        j += 1
    while j < n and command[j] in " \t":
        j += 1
    word, quote = [], None
    while j < n:
        c = command[j]
        if quote:
            if c == quote:
                quote = None
            else:
                word.append(c)
        elif c in "'\"":
            quote = c
        elif c == "\\" and j + 1 < n:
            j += 1
            word.append(command[j])
        elif c in " \t\n;&|()<>":
            break
        else:
            word.append(c)
        j += 1
    return j, "".join(word), strip


def _past_bodies(command, i, heredocs):
    """Where the bodies of `heredocs` end, read one after another from `i`, as
    the shell reads them. A body that no line closes cuts nothing: `$((1<<2))`
    looks like a heredoc, and taking the rest of the command for its body would
    hide every command after it."""
    n, j = len(command), i
    for word, strip in heredocs:
        while True:
            if j >= n:
                return i
            k = command.find("\n", j)
            line = command[j:] if k < 0 else command[j:k]
            j = n if k < 0 else k + 1
            if (line.lstrip("\t") if strip else line) == word:
                break
    return j


def shell_text(command):
    """`command` without what the shell does not read as words: heredoc bodies
    and comments. A line continuation (backslash-newline) is joined, outside
    quotes and inside double quotes, as the shell joins it. Quoting is followed,
    so a `<<` or a `#` inside quotes stays text, and a `#` starts a comment only
    where a word would start."""
    out, heredocs = [], []
    i, n = 0, len(command)
    quote, word_start = None, True
    while i < n:
        c = command[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                if command[i + 1] != "\n":
                    out.append(command[i:i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if command[i + 1] != "\n":
                out.append(command[i:i + 2])
                word_start = False
            i += 2
            continue
        if c == "#" and word_start:
            k = command.find("\n", i)
            i = n if k < 0 else k
            continue
        if command.startswith("<<", i):
            j, word, strip = _heredoc_word(command, i + 2)
            if word:
                heredocs.append((word, strip))
            out.append(command[i:j])
            i, word_start = j, False
            continue
        if c in "'\"":
            quote = c
        out.append(c)
        i += 1
        if c == "\n" and heredocs:
            i = _past_bodies(command, i, heredocs)
            heredocs = []
        word_start = quote is None and c in " \t\n;&|()<>`"
    return "".join(out)


def simple_commands(command):
    """The simple commands in `command`, each as its argv, quotes removed.
    Redirection operators stay in the argv. Raises ValueError when the quotes do
    not close — nothing can be said then about where one word ends."""
    lex = shlex.shlex(shell_text(command), posix=True, punctuation_chars=";&|()<>`")
    lex.whitespace_split = True
    lex.commenters = ""
    cmds, cur = [], []
    for tok in lex:
        if tok and set(tok) <= _SEPARATORS:
            if cur:
                cmds.append(cur)
            cur = []
            continue
        cur.append(tok)
    if cur:
        cmds.append(cur)
    return cmds
