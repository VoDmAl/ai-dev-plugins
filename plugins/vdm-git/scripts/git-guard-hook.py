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


BLOCKED_PATTERNS = [
    (r"git\s+commit", "git commit", "modifies history"),
    (r"git\s+push", "git push", "affects remote"),
]


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

    # 4. Commit section in known docs
    for doc in ("CLAUDE.md", "CONTRIBUTING.md", "docs/CONTRIBUTING.md", "README.md"):
        path = os.path.join(repo_root, doc)
        if not os.path.isfile(path):
            continue
        section = extract_commit_section(read_file(path))
        if section:
            return {"rules": section, "source": f"{doc} (Commit section)"}

    # 5. Pattern detection from recent log
    log = run_git(["log", "--oneline", "-30", "--no-merges"], cwd=repo_root)
    if log:
        prefixes = detect_prefixes(log)
        examples = "\n".join(f"  {line}" for line in log.split("\n")[:5])
        if prefixes:
            return {
                "rules": (
                    f"Detected from `git log` — common prefixes: "
                    f"{', '.join(prefixes)}\n\nRecent examples:\n{examples}"
                ),
                "source": "git log -30 (pattern detection)",
            }
        return {
            "rules": (
                "No prefix convention detected. Recent examples:\n" + examples
            ),
            "source": "git log -30",
        }

    # 6. Generic fallback
    return {
        "rules": (
            "No project commit convention detected. "
            "Use a brief imperative subject (≤ 50 chars)."
        ),
        "source": "fallback",
    }


def get_staged_files(repo_root):
    """Return list of (status_code, path) for staged files; falls back to porcelain."""
    out = run_git(["diff", "--cached", "--name-status"], cwd=repo_root)
    if out:
        result = []
        for line in out.split("\n"):
            if "\t" in line:
                status, path = line.split("\t", 1)
                # Renames look like: `R100\told\tnew` — keep the destination.
                if "\t" in path:
                    path = path.split("\t", 1)[1]
                result.append((status, path))
        return result

    # Nothing staged → look at porcelain so the assistant still sees what's modified.
    out = run_git(["status", "--porcelain"], cwd=repo_root)
    return [
        (line[:2].strip() or "?", line[3:].lstrip())
        for line in out.split("\n")
        if line
    ]


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
        "This operation requires explicit user permission.",
        "Ask the user to confirm, then retry.",
        "",
    ]

    if is_commit and repo_root:
        fmt = detect_format(repo_root)
        files = get_staged_files(repo_root)

        lines.append("─" * 60)
        lines.append("PROJECT COMMIT FORMAT (detected)")
        lines.append(f"Source: {fmt['source']}")
        lines.append("")
        for raw in fmt["rules"].split("\n"):
            lines.append(f"  {raw}" if raw else "")
        lines.append("")

        if files:
            shown = files[:20]
            lines.append(f"STAGED CHANGES ({len(files)} file(s)):")
            for status, path in shown:
                lines.append(f"  {status:<3} {path}")
            if len(files) > len(shown):
                lines.append(f"  … and {len(files) - len(shown)} more")
            lines.append("")
        else:
            lines.append("STAGED CHANGES: none — `git add` first?")
            lines.append("")

        lines.append("INSTRUCTIONS FOR THE ASSISTANT")
        lines.append(
            "  1. Use your current session context (what was actually changed and"
        )
        lines.append(
            "     why) to compose a concise, accurate commit subject that follows"
        )
        lines.append("     the format rules above.")
        lines.append(
            "  2. If the format uses prefixes (e.g. [+]/[-]/[*], feat:/fix:),"
        )
        lines.append("     pick the right one based on the staged changes.")
        lines.append("  3. Combine into a single shell-safe command, e.g.:")
        lines.append('       git commit -m "<prefix> <subject>"')
        lines.append(
            "  4. Present that command to the user as INLINE CODE (single"
        )
        lines.append(
            "     backticks), on its own line. Do NOT wrap in a fenced (```)"
        )
        lines.append(
            "     code block — fenced blocks add leading whitespace that"
        )
        lines.append("     breaks copy-paste.")
        lines.append("  5. Wait for the user to confirm or run the command.")
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

    for pattern, op_name, reason in BLOCKED_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            print(build_block_message(op_name, reason, command), file=sys.stderr)
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
