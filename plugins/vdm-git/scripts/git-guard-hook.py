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


BLOCKED_OPERATIONS = [
    ("commit", "git commit", "modifies history"),
    ("push",   "git push",   "affects remote"),
]


# Heredoc opener: <<EOF, <<-EOF, <<'EOF', <<"EOF" (with optional spaces).
_HEREDOC_RE = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")
# Line-comment: `#` to end of line, when at start-of-string or after whitespace.
_COMMENT_RE = re.compile(r"(?:^|(?<=\s))#[^\n]*")
# Single-quoted strings: no escapes inside.
_SQ_RE = re.compile(r"'[^']*'")
# Double-quoted strings: backslash escapes recognised.
_DQ_RE = re.compile(r'"(?:\\.|[^"\\])*"')


def _strip_inert_text(command):
    """Remove regions where `git <op>` would not actually run as a command:
    heredoc bodies, line comments, and quoted strings. Approximate (not a
    full shell parser) but enough to drop the common false-positives:

      grep "git commit" file       # quoted argument
      cat <<EOF ... git commit ... # heredoc body
      # git commit triggers here   # line comment

    Order matters: heredocs first (their markers can be quoted), then
    comments, then quotes.
    """
    s = command

    # Heredoc bodies. Repeatedly find <<MARKER ... ^MARKER$ blocks and excise.
    while True:
        m = _HEREDOC_RE.search(s)
        if not m:
            break
        marker = m.group(1)
        body_start = m.end()
        end = re.search(
            rf"^\s*{re.escape(marker)}\s*$",
            s[body_start:],
            re.MULTILINE,
        )
        if not end:
            # Malformed / unterminated — drop from `<<` to end of string so
            # we don't leave heredoc body matching as live code.
            s = s[:m.start()]
            break
        s = s[:m.start()] + s[body_start + end.end():]

    s = _COMMENT_RE.sub("", s)
    s = _SQ_RE.sub("", s)
    s = _DQ_RE.sub("", s)
    return s


# Command boundary: start-of-string, whitespace, or shell separator/grouping.
# Backtick covers ``…`` command substitution; `(` covers `$(…)` and subshells.
_BOUNDARY_CLASS = r"\s;&|()`"


def _command_invokes(command, op_subcommand):
    """True iff `command` would actually invoke `git <op_subcommand>`.

    Catches direct invocations and chained / substituted forms:
        git commit -m foo
        cd /repo && git commit
        if git commit; then …
        $(git commit)

    Ignores false-positives where `git commit` appears as data:
        grep "git commit" file
        echo 'git commit'
        cat <<EOF ... git commit ... EOF
        # git commit
    """
    cleaned = _strip_inert_text(command)
    pattern = rf"(?:^|[{_BOUNDARY_CLASS}])git\s+{re.escape(op_subcommand)}\b"
    return bool(re.search(pattern, cleaned))


def run_git(args, cwd=None):
    """Run a git command quickly; return stdout on success, '' on failure.

    Uses rstrip rather than strip so that callers parsing column-aligned output
    (e.g. `git status --porcelain` where status XY is in the first two columns
    and the worktree-modified flag lives at column 1, prefixed by a space) see
    the leading whitespace intact.
    """
    try:
        r = subprocess.run(
            ["git"] + args,
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
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
    staged = []
    out = run_git(["diff", "--cached", "--name-status"], cwd=repo_root)
    if out:
        for line in out.split("\n"):
            if "\t" in line:
                status, path = line.split("\t", 1)
                # Renames look like: `R100\told\tnew` — keep the destination.
                if "\t" in path:
                    path = path.split("\t", 1)[1]
                staged.append((status, path))

    unstaged = []
    out = run_git(["status", "--porcelain"], cwd=repo_root)
    for line in out.split("\n"):
        if not line:
            continue
        # Porcelain XY: X = index, Y = worktree. `??` = untracked.
        # Anything with X != ' ' is already counted in `staged` above.
        x = line[0]
        y = line[1] if len(line) > 1 else " "
        path = line[3:].lstrip()
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
            "     It writes ${TMPDIR:-/tmp}/<repo>-<branch>-commit.txt and prints"
        )
        lines.append("     a single-line `git commit -F <path>` command.")
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
            "       - the `git commit -F <path>` line as INLINE CODE (single"
        )
        lines.append(
            "         backticks), on its own line — never inside a fenced (```)"
        )
        lines.append("         block, never as a heredoc, never with -m.")
        lines.append("")
        lines.append(
            "  5. Do not execute `git commit` yourself. The user runs it."
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

    if tool_name != "Bash":
        sys.exit(0)

    command = tool_input.get("command", "")

    for op_subcommand, op_name, reason in BLOCKED_OPERATIONS:
        if _command_invokes(command, op_subcommand):
            print(build_block_message(op_name, reason, command), file=sys.stderr)
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
