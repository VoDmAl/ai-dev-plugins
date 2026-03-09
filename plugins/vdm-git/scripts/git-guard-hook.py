#!/usr/bin/env python3
"""
Pre-Tool-Use Hook: Block dangerous git operations
Protects against accidental commits, pushes, merges, and other
history-modifying operations by Claude Code AI assistant.

Part of vdm-git:guard skill.
"""
import json
import sys
import re


BLOCKED_PATTERNS = [
    (r"git\s+commit", "git commit — modifies history"),
    (r"git\s+push", "git push — affects remote"),
]


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("Error: Invalid JSON input", file=sys.stderr)
        sys.exit(1)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    # Only validate Bash tool
    if tool_name != "Bash":
        sys.exit(0)

    command = tool_input.get("command", "")

    for pattern, description in BLOCKED_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            error_msg = (
                f"\n"
                f"git-guard: BLOCKED — {description}\n"
                f"\n"
                f"Command: {command}\n"
                f"\n"
                f"This operation requires explicit user permission.\n"
                f"Ask the user to confirm, then retry.\n"
                f"\n"
                f"Allowed: status, diff, log, show, branch, add, stash, fetch\n"
            )
            print(error_msg, file=sys.stderr)
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
