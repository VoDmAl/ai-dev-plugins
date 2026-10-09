#!/usr/bin/env python3
"""docs-pairs — the documents a change may leave behind, as pairs.

A pair is a document outside the change and what links it to the change:
identifiers that the change's code REMOVES OR REWRITES and the document names,
or an `@see <doc>` the changed code declares. A document can only describe what
already existed, so the identifiers come from the old side of the diff — a
line that went or was rewritten — never from lines that are only new.

Why pairs and not a list of "relevant" docs. The keyword list this replaces
matched the path components of every dirty file against every document: in a
project whose code sits in `<project>/`, the project's own name was a keyword,
48 documents of 48 named it, and the reminder printed the first ten by path on
all 94 turns it fired (docs/tasks/docs-sync-signal, 2026-10-08). A list that
does not change with the change teaches the reader to skip it.

What a pair is not: a verdict. A document can contradict itself with no code
involved — that one is found by reading (/vdm:docs-sync), not here. Silence
means "no pairs", not "the documents are right".

Usage:
  docs-pairs.py --staged [-- <path>...]   the index against HEAD (what a commit takes)
  docs-pairs.py --worktree                the work tree against HEAD
  docs-pairs.py --commit <rev>            a commit against its first parent
  docs-pairs.py --diff <file|->           a unified diff as git prints it, against
                                          the work tree's documents
Options: --max-docs N (3), --max-ids N (3).

Output: one line per document, ranked, then `+N more` when more qualified.
Nothing at all when there is no pair. Exit 0 whenever it ran; 2 on usage.

Shipped in the lib/ of both plugins that call it (the docs-sync reminder and
git-guard-prepare), byte for byte the same.
"""
import os
import re
import subprocess
import sys

# Identifiers worth a pair: a --flag, a compound (snake_case, kebab-case,
# dotted.name, path/like), camelCase, an ENV_VAR. A plain word is not one: it
# links everything to everything.
IDENT = re.compile(
    r"--[a-z][a-z0-9-]{2,}"
    r"|\b[A-Za-z_][A-Za-z0-9_]*(?:[._-][A-Za-z0-9_]+)+\b"
    r"|\b[a-z]+[A-Z][A-Za-z0-9]+\b"
    r"|\b[A-Z][A-Z\d]*_[A-Z\d_]+\b"
)
SEE = re.compile(r"@see[ \t]+([^\s,;)]+)")
VERSIONISH = re.compile(r"^v?\d|^[A-Za-z]?\d+([._-]\d+)+$")

# Never candidates and never counted: records of the past (crystals, their
# references, changelogs) and tool state. A changelog that names an identifier
# is history, not a description that can go stale.
SKIP_DIRS = {"tasks", "references", ".claude", ".serena", "node_modules", "vendor"}
# Every document git lists; doc_in_scope() alone decides which of them count —
# one rule, not a pathspec beside it that a test could not tell apart.
DOC_SPEC = [":(icase)*.md"]
# Tests: their removed lines are mostly fixture data (`README.md`, sample
# names), and a document describes the code, not its fixtures. Their @see
# still counts — that one is declared.
TEST_PATH = re.compile(r"(^|/)(tests?|__tests__|specs?|fixtures)/|(^|/)test_[^/]*$|_test\.[^/.]+$|\.(test|spec)\.[^/.]+$")
# Code files whose diff is data, not code.
SKIP_CODE = re.compile(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|[^/]*\.lock|[^/]*\.min\.js|[^/]*\.map)$")


def is_doc(path):
    return path.lower().endswith(".md")


def doc_in_scope(path):
    parts = path.split("/")
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return False
    base = parts[-1].lower()
    return base != "workitem.md" and "changelog" not in base


def git(args, cwd=None, binary=False):
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def nul_list(raw):
    return [p for p in (raw or "").split("\0") if p]


def unquote(path):
    """A path from a diff header: git C-quotes one that holds a quote, a
    backslash or a control byte, and strips nothing else."""
    path = path.rstrip("\t")
    if len(path) >= 2 and path[0] == '"' and path[-1] == '"':
        body = path[1:-1].encode("latin-1", "backslashreplace").decode("unicode_escape")
        path = body.encode("latin-1", "replace").decode("utf-8", "replace")
    return path


def parse_diff(text):
    """{path: [old-side lines]} and the set of every path the diff touches."""
    removed, touched = {}, set()
    cur, header, old = None, False, None
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            cur, header, old = None, True, None
            continue
        if header:
            if line.startswith("--- "):
                old = unquote(line[4:])
            elif line.startswith("+++ "):
                new = unquote(line[4:])
                side = new if new != "/dev/null" else old
                if side and side[:2] in ("a/", "b/"):
                    side = side[2:]
                if old and old != "/dev/null":
                    touched.add(old[2:] if old[:2] in ("a/", "b/") else old)
                if side:
                    touched.add(side)
                    cur = removed.setdefault(side, [])
                header = False
            continue
        if cur is not None and line.startswith("-"):
            cur.append(line[1:])
    return removed, touched


# A comment describes; what a document describes is what the code does. A pair
# made of a comment's words was the larger part of the noise on this
# repository's history: `re-run`, `self-contained`, `multi-byte`.
COMMENT = re.compile(r"^\s*(#|//|/\*|\*|\"\"\"|\'\'\'|<!--)")


# Inside a quoted string with spaces — a message, a usage line — a hyphenated
# word is English (`re-run`, `self-contained`), while a --flag, a snake_case or
# a dotted.name there is still a name the message refers to.
PROSE = re.compile(r'"[^"]*\s[^"]*"|\'[^\']*\s[^\']*\'')
PLAIN_KEBAB = re.compile(r"^[A-Za-z]+(?:-[A-Za-z]+)+$")


def identifiers(lines):
    found = set()

    def take(text, strong_only):
        for tok in IDENT.findall(text):
            tok = tok.strip("._-") if not tok.startswith("--") else tok
            if len(tok) < 4 or VERSIONISH.match(tok) or tok.lower().endswith(".md"):
                continue
            if strong_only and PLAIN_KEBAB.match(tok):
                continue
            found.add(tok)

    for line in lines:
        if COMMENT.match(line):
            continue
        # `\nBEFORE` in a string is an escape and a word, not `nBEFORE`.
        line = re.sub(r"\\[ntr]", " ", line)
        for m in PROSE.finditer(line):
            take(m.group(0), True)
        take(PROSE.sub(" ", line), False)
    return found


def see_targets(text):
    return [t[2:] if t.startswith("./") else t for t in SEE.findall(text or "")]


def main(argv):
    mode, rev, diff_src, paths = None, None, None, []
    max_docs, max_ids = 3, 3
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--staged", "--worktree"):
            mode = a[2:]
        elif a in ("--commit", "--diff", "--max-docs", "--max-ids"):
            if i + 1 >= len(argv):
                print(f"docs-pairs: {a} needs a value", file=sys.stderr)
                return 2
            v = argv[i + 1]
            i += 1
            if a == "--commit":
                mode, rev = "commit", v
            elif a == "--diff":
                mode, diff_src = "diff", v
            elif a == "--max-docs":
                max_docs = int(v)
            else:
                max_ids = int(v)
        elif a == "--":
            paths = argv[i + 1:]
            break
        else:
            print(f"docs-pairs: unknown argument {a!r}", file=sys.stderr)
            return 2
        i += 1
    if mode is None:
        print(__doc__.split("Usage:")[1].split("Options:")[0].rstrip(), file=sys.stderr)
        return 2

    top = (git(["rev-parse", "--show-toplevel"]) or "").strip()
    if not top:
        return 0
    has_head = git(["rev-parse", "--verify", "-q", "HEAD"]) is not None

    # The change: its old-side lines, and every path it touches.
    if mode == "diff":
        try:
            text = sys.stdin.read() if diff_src == "-" else open(diff_src, encoding="utf-8", errors="replace").read()
        except OSError:
            return 0
        removed, touched = parse_diff(text)
    elif mode == "commit":
        parent = git(["rev-parse", "--verify", "-q", rev + "^"])
        base = parent.strip() if parent else "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        text = git(["diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", base, rev], cwd=top)
        if text is None:
            return 0
        removed, touched = parse_diff(text)
    else:
        if not has_head:
            return 0
        # Every call here is a read, and none may write .git/index. `git diff HEAD`
        # does — on a stat-dirty file, even with optional locks switched off
        # (tests/hook-index-writes.test.sh) — so the work tree is read through
        # the plumbing, `diff-index`, which never refreshes.
        spec = ["--", *paths] if paths else []
        if mode == "staged":
            diff_args = ["diff", "--cached", "--no-color", "--no-ext-diff"]
        else:
            diff_args = ["diff-index", "-p", "HEAD"]
        text = git([*diff_args, "-U0", "--no-renames", *spec])
        if text is None:
            return 0
        removed, touched = parse_diff(text)
        if mode == "worktree":
            touched |= set(nul_list(git(["ls-files", "-z", "-o", "--exclude-standard"], cwd=top)))

    # A changed file's own name is not taken: a document that names a script is
    # not thereby describing the lines that changed in it, and every version bump
    # would pair the manifest with every document that mentions manifests.
    code = {p for p in touched
            if not is_doc(p) and not SKIP_CODE.search(p)
            and not any(d in SKIP_DIRS for d in p.split("/")[:-1])}
    ids = set()
    for p in code:
        if not TEST_PATH.search(p):
            ids |= identifiers(removed.get(p, []))

    # The documents, and their text as this change will meet them.
    if mode == "commit":
        docs = nul_list(git(["ls-tree", "-r", "-z", "--name-only", rev], cwd=top))
    elif mode == "staged":
        docs = nul_list(git(["ls-files", "-z", "--", *DOC_SPEC], cwd=top))
    else:
        docs = nul_list(git(["ls-files", "-z", "-co", "--exclude-standard", "--", *DOC_SPEC], cwd=top))
    docs = sorted(d for d in docs if is_doc(d) and doc_in_scope(d))
    doc_set = set(docs)
    if not doc_set:
        return 0

    # Declared links: `@see <doc>` in the changed code, read as the change has it.
    # Staged code is read from the work tree, not the index: one process per file
    # is the cost the reminder was rewritten to shed, and git-guard-prepare has
    # already refused a path whose work tree differs from what is staged.
    see = {}
    for p in sorted(code):
        if mode == "commit":
            body = git(["show", f"{rev}:{p}"], cwd=top)
        else:
            try:
                body = open(os.path.join(top, p), encoding="utf-8", errors="replace").read()
            except OSError:
                body = None
        for t in see_targets(body):
            for cand in (t, os.path.normpath(os.path.join(os.path.dirname(p), t))):
                if cand in doc_set and cand not in touched:
                    see.setdefault(cand, set()).add(p)
                    break

    # Who names what: one grep over every document for every identifier.
    named = {}
    if ids:
        pat = "\n".join(sorted(ids)) + "\n"
        where = [rev] if mode == "commit" else (["--cached"] if mode == "staged" else ["--untracked"])
        try:
            r = subprocess.run(
                ["git", "grep", "-z", "-o", "-I", "-F", "-w", "-f", "-", *where, "--", *DOC_SPEC],
                cwd=top, input=pat.encode("utf-8"), capture_output=True)
            out = r.stdout.decode("utf-8", "replace") if r.returncode in (0, 1) else ""
        except OSError:
            out = ""
        for line in out.split("\n"):
            if "\0" not in line:
                continue
            doc, tok = line.split("\0", 1)
            if mode == "commit" and doc.startswith(rev + ":"):
                doc = doc[len(rev) + 1:]
            if doc in doc_set:
                named.setdefault(tok, set()).add(doc)

    # A name most documents use links nothing: the project's own name was in
    # 48 of 48. Kept only when at most a fifth of the documents name it — and
    # never fewer than two, so a small project still gets its pairs.
    ceiling = max(2, len(docs) // 5)
    pairs = {}
    for tok, holders in named.items():
        if len(holders) > ceiling:
            continue
        for d in holders:
            if d not in touched:
                pairs.setdefault(d, []).append((len(holders), tok))
    for d in see:
        pairs.setdefault(d, [])

    ranked = sorted(pairs, key=lambda d: (-len(see.get(d, ())), -len(pairs[d]), d))
    for d in ranked[:max_docs]:
        bits = []
        if d in see:
            bits.append("@see in " + ", ".join(sorted(see[d])[:max_ids]))
        toks = [t for _, t in sorted(pairs[d])][:max_ids]
        if toks:
            more = len(pairs[d]) - len(toks)
            bits.append(", ".join(f"`{t}`" for t in toks) + (f" (+{more})" if more > 0 else ""))
        print(f"{d} — " + "; ".join(bits))
    if len(ranked) > max_docs:
        print(f"+{len(ranked) - max_docs} more")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
