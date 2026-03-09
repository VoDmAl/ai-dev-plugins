---
name: guard
description: "Git safety guard. Blocks git commit and push via pre-tool-use hook. Requires explicit user permission before executing. Invoke manually for pre-commit review."
license: MIT
---

# git-guard - Git Safety Guard

## Purpose

Prevents Claude from executing git commit and push without explicit user permission. Everything else (merge, rebase, reset, checkout, add, diff, status, etc.) is allowed freely.

## Blocked Operations

| Operation | Reason |
|-----------|--------|
| `git commit` | Modifies history |
| `git push` | Affects remote |

## Commit Message Format

Start with a prefix, then a short imperative sentence. Max 50 characters total.

| Prefix | Meaning |
|--------|---------|
| `[+]` | New feature |
| `[-]` | Bugfix |
| `[*]` | Other change |

**Examples:**
```
[+] Add git-guard skill with pre-tool-use hook
[-] Fix token expiry in auth middleware
[*] Update dependencies to latest versions
[*] Refactor user service into separate module
```

Avoid verbose descriptions or unnecessary details.

## When Blocked

When the hook blocks a command, Claude should:

1. Acknowledge the block
2. Tell the user what was attempted
3. Suggest a commit message (following the format above)
4. Ask for permission to proceed
5. Execute only after explicit confirmation

**Example:**
```
Claude: Changes staged. Suggested message: "[-] Fix token expiry handling"
        Should I commit, or will you do it manually?
User: go ahead
Claude: [executes git commit]
```

## Manual Invocation

`/vdm-git:guard` — run pre-commit review:

### Phase 1: Status

Run in parallel:
1. `git status`
2. `git diff --cached --stat`
3. `git log --oneline -5`
4. `git branch --show-current`

Report:
```
Git Guard Review:
   Branch: {branch}
   Staged: {N files}
   Last commit: {hash} {message}
```

### Phase 2: Safety Checks

```
Safety Checks:
   [ ] No sensitive files staged (.env, credentials, keys)
   [ ] Staged changes are intentional
```

### Phase 3: User Decision

Ask user: commit with suggested message, show full diff, or abort.

## Configuration

Hook script: `scripts/git-guard-hook.py`. Edit `BLOCKED_PATTERNS` to customize.
