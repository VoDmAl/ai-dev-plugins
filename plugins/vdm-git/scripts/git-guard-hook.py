#!/usr/bin/env python3
"""
Pre-Tool-Use Hook: Block dangerous git operations.

When `git commit` is intercepted, also detect the project's commit message
convention (commit.template, .gitmessage, commitlint config, CONTRIBUTING.md /
CLAUDE.md sections, or pattern-detection from `git log`) and emit instructions
asking the assistant to compose a ready-to-paste command using its session
context.

Part of vdm-git:guard skill.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from shellwords import simple_commands  # noqa: E402


BLOCKED_OPERATIONS = [
    ("commit", "git commit", "modifies history"),
    ("push",   "git push",   "affects remote"),
]

# Every harness tool whose `command` is handed to a shell. Monitor runs its
# command "in the same shell environment as Bash", so a commit sent there is the
# same string by another door — not an indirection the guard cannot see, only a
# door it was not watching (Sidetrack #1, docs/tasks/hook-timeout-fail-open).
# The matcher in hooks.json and the fail-closed grep in git-guard-hook.sh name
# the same tools; tests/hook-commands.test.sh and tests/hook-fail-closed.test.sh
# read this tuple and hold both to it.
SHELL_TOOLS = ("Bash", "Monitor")


# git's own options that take the next word as their value: `git -C <dir> commit`.
_GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                        "--config-env", "--super-prefix", "--attr-source"}
_SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
_MAX_DEPTH = 4


def _git_subcommands(argv):
    """The subcommand after every `git` in one simple command. `git`, `\\git`,
    `'git'` and `/usr/bin/git` are the same program to the shell, and git's own
    options (`-C <dir>`, `-c k=v`, `--no-pager`) stand before the subcommand.
    Every position is looked at, not only the first, so `sudo git commit`,
    `if git commit` and `xargs git commit` are read the same way."""
    for i, word in enumerate(argv):
        if os.path.basename(word) != "git":
            continue
        j = i + 1
        while j < len(argv) and argv[j].startswith("-"):
            j += 2 if argv[j] in _GIT_OPTS_WITH_VALUE else 1
        if j < len(argv):
            yield argv[j]


def _substitutions(word):
    """Command text inside `$( … )` and backticks in one word. Unquoted, the
    reader has split them into their own commands already; inside "…" they are
    still one word, and the shell runs them all the same."""
    found, i = [], 0
    while True:
        k = word.find("$(", i)
        if k < 0:
            break
        depth, j = 1, k + 2
        while j < len(word) and depth:
            depth += {"(": 1, ")": -1}.get(word[j], 0)
            j += 1
        found.append(word[k + 2:j - 1] if depth == 0 else word[k + 2:])
        i = j
    found.extend(word.split("`")[1::2])
    return found


def _inner_scripts(argv):
    """Command text the shell will run from inside this command: the script of
    `bash -c '…'` (also `-lc`, `-ec`, `-o pipefail -c`), the words of `eval`,
    and substitutions inside quoted words."""
    for i, word in enumerate(argv):
        if os.path.basename(word) in _SHELLS:
            j = i + 1
            while j < len(argv) and argv[j][:1] in "-+" and argv[j] not in ("-", "--"):
                flag = argv[j]
                if flag in ("-o", "+o"):
                    j += 2
                    continue
                if not flag.startswith("--") and "c" in flag[1:]:
                    if j + 1 < len(argv):
                        yield argv[j + 1]
                    break
                j += 1
        elif word == "eval":
            yield " ".join(argv[i + 1:])
        for script in _substitutions(word):
            yield script


def _mentions(command, op_subcommand):
    """`git` followed somewhere by the subcommand, as words: what is left to go
    on when the command cannot be read."""
    op = re.escape(op_subcommand)
    return re.search(rf"(?<![\w.-])git(?![\w-])[\s\S]*?(?<![\w-]){op}(?![\w-])",
                     command) is not None


def _command_invokes(command, op_subcommand, depth=0):
    r"""True iff `command` would run `git <op_subcommand>`, read the way the
    shell reads it (lib/shellwords.py): split into simple commands, quotes
    removed, heredoc bodies and comments cut. Blocks

        git commit -m foo · cd /repo && git commit · if git commit; then …
        $(git commit) · git -C /repo commit · \git commit · bash -c 'git commit'

    and lets through `git commit` as data:

        grep "git commit" file · echo 'git commit' · # git commit
        cat <<EOF … git commit … EOF

    The subcommand is compared as a whole word, so `git commit-tree` (writes an
    object, moves no ref) and `git commit-graph` are not `git commit`. The old
    `\b` boundary matched them: it read a string prefix where it meant to read
    a subcommand (v2.7.2).

    Until vdm-git 2.15.10 the matcher cut "inert" text with regexes that did not
    follow the quoting, and each cut could throw away the commit after it: a
    `<<` no line closes (`<<<"msg"`, `$((1<<2))`), a `#` inside quotes, an
    apostrophe inside "…" pairing with the next '…'. `git -C <dir> commit`,
    `'git' commit` and `bash -c 'git commit'` were never matched at all
    (Sidetrack #18, docs/tasks/crystal-wake/workitem.md). A command whose quotes
    do not close cannot be split into words; then a mention is enough to stop.
    """
    if depth > _MAX_DEPTH:
        return _mentions(command, op_subcommand)
    try:
        commands = simple_commands(command)
    except ValueError:
        return _mentions(command, op_subcommand)
    for argv in commands:
        if op_subcommand in _git_subcommands(argv):
            return True
        for script in _inner_scripts(argv):
            if _command_invokes(script, op_subcommand, depth + 1):
                return True
    return False


# Every git call in this hook is a read, and a read must not rewrite
# .git/index: `git status` refreshes stat data and writes the index back, and
# on a repo Syncthing carries between two machines that write is a conflict
# copy (vdx, 2026-09-30). Does NOT cover `git diff` without a revision — see
# tests/hook-index-writes.test.sh.
_GIT_ENV = dict(os.environ)
_GIT_ENV["GIT_OPTIONAL_LOCKS"] = "0"


def run_git(args, cwd=None):
    """Run a git command quickly; return stdout on success, '' on failure.

    Uses rstrip rather than strip so that callers parsing column-aligned output
    (e.g. `git status --porcelain` where status XY is in the first two columns
    and the worktree-modified flag lives at column 1, prefixed by a space) see
    the leading whitespace intact.
    """
    try:
        # UTF-8 with replacement, not the locale's codec in strict mode: paths
        # come back raw now (-z below), and one name that is not UTF-8 — a git
        # index can hold such names, APFS cannot — raised here and was caught
        # as "no output", emptying the whole list.
        r = subprocess.run(
            ["git"] + args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=2,
            cwd=cwd,
            env=_GIT_ENV,
        )
        return r.stdout.rstrip("\n") if r.returncode == 0 else ""
    except Exception:
        return ""


def find_repo_root():
    return run_git(["rev-parse", "--show-toplevel"]) or os.getcwd()


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def extract_commit_section(content):
    """Extract a 'Commit Message Format' / 'Commits' section from markdown."""
    headers = [
        r"##+\s+commit\s+message(?:s|\s+format)?",
        r"##+\s+commits?\b",
        r"##+\s+git\s+(?:workflow|commit)",
        r"##+\s+conventional\s+commits?",
    ]
    for pattern in headers:
        m = re.search(pattern, content, re.IGNORECASE)
        if not m:
            continue
        rest = content[m.end():]
        next_section = re.search(r"\n##+\s+", rest)
        end = next_section.start() if next_section else min(700, len(rest))
        section = rest[:end].strip()
        if section:
            return section
    return ""


def detect_prefixes(log):
    """Return a list of common prefixes seen in recent commit subjects."""
    counts = {}
    for line in log.split("\n"):
        if " " not in line:
            continue
        subject = line.split(" ", 1)[1]
        # Bracket prefixes: [+], [-], [*], [!], [?]
        m = re.match(r"^(\[[+\-*!?]\])", subject)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
            continue
        # Conventional Commits: feat:, fix:, chore(scope):, …
        m = re.match(
            r"^(feat|fix|chore|docs|style|refactor|test|build|ci|perf|revert)"
            r"(\([^)]+\))?:",
            subject,
        )
        if m:
            key = f"{m.group(1)}:"
            counts[key] = counts.get(key, 0) + 1
            continue
        # gitmoji: :sparkles:, :bug:
        m = re.match(r"^(:[a-z_]+:)", subject)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    return [p for p, c in sorted(counts.items(), key=lambda x: -x[1]) if c >= 2]


def detect_format(repo_root):
    """Return {'rules': str, 'source': str} describing the project's commit format."""
    # 1. git config commit.template → file
    template_path = run_git(["config", "--get", "commit.template"], cwd=repo_root)
    if template_path:
        full = os.path.expanduser(template_path)
        if not os.path.isabs(full):
            full = os.path.join(repo_root, full)
        content = read_file(full)
        if content.strip():
            return {
                "rules": content.strip(),
                "source": f"git config commit.template ({template_path})",
            }

    # 2. .gitmessage and friends in repo root
    for name in (".gitmessage", ".gitmessage.txt", ".git-commit-template"):
        path = os.path.join(repo_root, name)
        if os.path.isfile(path):
            content = read_file(path)
            if content.strip():
                return {"rules": content.strip(), "source": name}

    # 3. commitlint config → signals Conventional Commits
    for name in (
        "commitlint.config.js",
        "commitlint.config.ts",
        "commitlint.config.cjs",
        "commitlint.config.mjs",
        ".commitlintrc",
        ".commitlintrc.json",
        ".commitlintrc.yaml",
        ".commitlintrc.yml",
        ".commitlintrc.js",
    ):
        if os.path.isfile(os.path.join(repo_root, name)):
            return {
                "rules": (
                    "Conventional Commits (commitlint config detected).\n"
                    "Format: <type>(<scope>): <subject>\n"
                    "Types: feat, fix, chore, docs, style, refactor, test, "
                    "build, ci, perf, revert.\n"
                    "Subject under 72 chars, imperative mood.\n"
                    "Body separated by a blank line; `BREAKING CHANGE:` "
                    "footer if applicable."
                ),
                "source": name,
            }

    # 4. Commit section in known docs. AI-harness context files first
    # (CLAUDE.md / QWEN.md / AGENTS.md / GEMINI.md), then generic dev docs.
    # Different harnesses load different files — scan them all so a project
    # only needs one declaration regardless of which harness the user runs.
    candidate_docs = (
        "CLAUDE.md",
        "QWEN.md",
        "AGENTS.md",
        "GEMINI.md",
        "CONTRIBUTING.md",
        "docs/CONTRIBUTING.md",
        "README.md",
    )
    for doc in candidate_docs:
        path = os.path.join(repo_root, doc)
        if not os.path.isfile(path):
            continue
        section = extract_commit_section(read_file(path))
        if section:
            return {"rules": section, "source": f"{doc} (Commit section)"}

    # 5. Pattern detection from recent log
    log = run_git(["log", "--oneline", "-30", "--no-merges"], cwd=repo_root)
    suggestion = (
        "\n\nNo `## Commit Message Format` section in any AI-context file "
        "(CLAUDE.md / QWEN.md / AGENTS.md / CONTRIBUTING.md). If commit-style "
        "mistakes recur, suggest the user add one — that's the durable fix."
    )
    if log:
        prefixes = detect_prefixes(log)
        examples = "\n".join(f"  {line}" for line in log.split("\n")[:5])
        if prefixes:
            return {
                "rules": (
                    f"Detected from `git log` — common prefixes: "
                    f"{', '.join(prefixes)}\n\nRecent examples:\n{examples}\n\n"
                    "Match the local style: if recent commits are subject-only "
                    "single-line, do NOT write a body."
                    + suggestion
                ),
                "source": "git log -30 (pattern detection)",
            }
        return {
            "rules": (
                "No prefix convention detected. Recent examples:\n"
                + examples
                + suggestion
            ),
            "source": "git log -30",
        }

    # 6. Generic fallback
    return {
        "rules": (
            "No project commit convention detected. "
            "Use a brief imperative subject (≤ 50 chars)."
            + suggestion
        ),
        "source": "fallback",
    }


def get_changed_files(repo_root):
    """Return ({"staged": [(status, path), ...], "unstaged": [...]}) split.

    `staged` is what `diff --cached` reports — what `git commit` would actually
    record. `unstaged` is everything else in the working tree (modified-but-not-
    staged, untracked) so the assistant can see what *could* be staged.
    """
    # Both lists are read with -z. In line form git quotes a path holding any
    # byte outside ASCII — `"docs/\320\227…"` — and the assistant was handed
    # that string as a path to stage, which `git add` refuses (Sidetrack #9,
    # cc-vdm-plugins → docs/tasks/crystal-wake/workitem.md).
    staged = []
    out = run_git(["diff", "--cached", "--name-status", "-z"], cwd=repo_root)
    # -z: STATUS\0PATH\0, and a rename or copy is STATUS\0OLD\0NEW\0 — keep
    # the destination.
    fields = out.split("\0")
    i = 0
    while i < len(fields):
        status = fields[i]
        if not status:
            i += 1
            continue
        if status[0] in "RC":
            path = fields[i + 2] if i + 2 < len(fields) else ""
            i += 3
        else:
            path = fields[i + 1] if i + 1 < len(fields) else ""
            i += 2
        if path:
            staged.append((status, path))

    unstaged = []
    out = run_git(["status", "--porcelain", "-z"], cwd=repo_root)
    # -z: `XY PATH\0`, and after a rename or copy the original path follows as
    # a field of its own.
    fields = out.split("\0")
    i = 0
    while i < len(fields):
        entry = fields[i]
        i += 1
        if len(entry) < 4:
            continue
        # Porcelain XY: X = index, Y = worktree. `??` = untracked.
        # Anything with X != ' ' is already counted in `staged` above.
        x, y, path = entry[0], entry[1], entry[3:]
        if x in "RC":
            i += 1
        if x == "?" and y == "?":
            unstaged.append(("??", path))
        elif x == " " and y != " ":
            unstaged.append((y, path))
    return {"staged": staged, "unstaged": unstaged}


def build_block_message(op_name, reason, command):
    """Compose the stderr message printed when a blocked command is intercepted."""
    repo_root = find_repo_root()
    is_commit = op_name == "git commit"

    lines = [
        "",
        f"git-guard: BLOCKED — {op_name} — {reason}",
        "",
        f"Command: {command}",
        "",
    ]
    if is_commit:
        lines.extend([
            "Switch to the prep-and-hand-off workflow below — do not retry the",
            "command and do not announce that git-guard is blocking. The user",
            "knows; saying it is noise.",
            "",
        ])
    else:
        lines.extend([
            "Hand the user the exact command to run themselves — do not retry",
            "from Bash and do not announce that git-guard is blocking.",
            "",
        ])

    if is_commit and repo_root:
        fmt = detect_format(repo_root)
        changes = get_changed_files(repo_root)
        staged = changes["staged"]
        unstaged = changes["unstaged"]

        lines.append("─" * 60)
        lines.append("PROJECT COMMIT FORMAT (detected)")
        lines.append(f"Source: {fmt['source']}")
        lines.append("")
        for raw in fmt["rules"].split("\n"):
            lines.append(f"  {raw}" if raw else "")
        lines.append("")

        if staged:
            shown = staged[:20]
            lines.append(f"STAGED ({len(staged)} file(s)) — these will be committed:")
            for status, path in shown:
                lines.append(f"  {status:<3} {path}")
            if len(staged) > len(shown):
                lines.append(f"  … and {len(staged) - len(shown)} more")
            lines.append("")
        else:
            lines.append(
                "STAGED: none — run `git add <file1> <file2>` (explicit list,"
            )
            lines.append("        never `-A` / `.`) before preparing.")
            lines.append("")

        if unstaged:
            shown = unstaged[:10]
            lines.append(
                f"UNSTAGED in working tree ({len(unstaged)} file(s)) — pick the"
            )
            lines.append("ones relevant to this task; leave others alone:")
            for status, path in shown:
                lines.append(f"  {status:<3} {path}")
            if len(unstaged) > len(shown):
                lines.append(f"  … and {len(unstaged) - len(shown)} more")
            lines.append("")

        lines.append("INSTRUCTIONS FOR THE ASSISTANT")
        lines.append(
            "  1. Stage explicit files only:  git add <file1> <file2> ..."
        )
        lines.append(
            "     Untracked files from other tasks must stay unstaged; report"
        )
        lines.append('     them under "not staged (other tickets)".')
        lines.append("")
        lines.append(
            "  2. Compose a subject that follows the PROJECT COMMIT FORMAT above."
        )
        lines.append("")
        lines.append(
            "  3. Write the message via the helper (on PATH from the plugin's"
        )
        lines.append("     bin/ directory):")
        lines.append("")
        lines.append('       git-guard-prepare "<subject>"')
        lines.append("")
        lines.append(
            "     It writes a per-prep message file under ${TMPDIR:-/tmp} and"
        )
        lines.append(
            "     prints a single-line `git commit -F <path> -- <paths>`"
        )
        lines.append(
            "     command. The pathspec is what keeps a parallel session's"
        )
        lines.append("     staged files out of your commit.")
        lines.append("")
        lines.append(
            "     One line per finished block. While a line you handed off is"
        )
        lines.append(
            "     still waiting, the helper refuses a new one: hand off nothing"
        )
        lines.append(
            "     new. Only if the user reported it failed, or the block changed"
        )
        lines.append(
            "     in substance, run it with --supersede — the earlier line then"
        )
        lines.append("     dies; tell the user it is void.")
        lines.append("")
        lines.append(
            "     To commit a subset of what is staged, name it explicitly:"
        )
        lines.append('       git-guard-prepare "<subject>" -- <path>...')
        lines.append("")
        lines.append(
            "     It exits 1 if nothing is staged, or if the working tree"
        )
        lines.append(
            "     differs from the index on those paths — reconcile with"
        )
        lines.append(
            "     `git add` / `git checkout --` and re-run. Do not work around"
        )
        lines.append("     it; the refusal is preventing a wrong commit.")
        lines.append("")
        lines.append(
            "     Multi-line subject + body? Pipe via `-`:"
        )
        lines.append(
            "       printf '%s\\n\\n%s\\n' \"<subject>\" \"<body>\" | "
            "git-guard-prepare -"
        )
        lines.append("")
        lines.append(
            "  4. Hand off to the user. Your message should contain:"
        )
        lines.append("       - what was staged;")
        lines.append("       - what is intentionally not staged (other tickets);")
        lines.append(
            "       - the `git commit -F <path> -- <paths>` line as INLINE CODE"
        )
        lines.append(
            "         verbatim — never trim the pathspec off it (single"
        )
        lines.append(
            "         backticks), on its own line — never inside a fenced (```)"
        )
        lines.append("         block, never as a heredoc, never with -m.")
        lines.append("")
        lines.append(
            "  5. Amending? `git commit --amend` WITHOUT `-- <paths>` takes the"
        )
        lines.append(
            "     whole index and sweeps in whatever a neighbouring session"
        )
        lines.append(
            "     staged. Name the paths explicitly, every time:"
        )
        lines.append("")
        lines.append(
            "       git commit --amend -F <path> -- <path1> <path2> ..."
        )
        lines.append("")
        lines.append(
            "  6. One commit per turn. For several commits, repeat steps 1-4"
        )
        lines.append(
            "     sequentially — stage, prepare, hand off, WAIT for the user —"
        )
        lines.append(
            "     rather than stacking them into one recipe. Skipping the wait"
        )
        lines.append(
            "     is how a superseded line ends up next to a current one."
        )
        lines.append("")
        lines.append(
            "  7. Do not execute `git commit` yourself. The user runs it."
        )
        lines.append("")
        lines.append(
            "  Forbidden framings: \"git-guard blocks me\", \"say 'commit' and"
        )
        lines.append(
            "  I will…\", \"permission to commit?\". Just prepare and hand off."
        )
        lines.append("─" * 60)
        lines.append("")

    lines.append("Allowed git ops: status, diff, log, show, branch, add, stash, fetch")
    lines.append("")

    return "\n".join(lines)


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("Error: Invalid JSON input", file=sys.stderr)
        sys.exit(1)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    if tool_name not in SHELL_TOOLS:
        sys.exit(0)

    # Monitor may carry a WebSocket instead of a command — nothing to parse then.
    command = tool_input.get("command") or ""

    for op_subcommand, op_name, reason in BLOCKED_OPERATIONS:
        if _command_invokes(command, op_subcommand):
            print(build_block_message(op_name, reason, command), file=sys.stderr)
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
