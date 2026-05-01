---
name: guard
description: "Git safety guard. Blocks git commit and push via pre-tool-use hook. Requires explicit user permission before executing. Invoke manually for pre-commit review."
license: MIT
---

# git-guard - Git Safety Guard

## Purpose

Prevents Claude from executing git commit and push without explicit user permission. Everything else (merge, rebase, reset, checkout, add, diff, status, etc.) is allowed freely.

## Configuration Sub-commands

`/vdm-git:guard [subcommand]` recognizes these as the first word of arguments. When no subcommand matches, behave as the regular guard skill (pre-commit review, see below).

| Subcommand | Effect on `.claude/vdm-plugins.json` → `git-guard` section |
|------------|------------------------------------------------------------|
| `off` / `disable` | Set `enabled = false` (UserPromptSubmit reminder stays silent) |
| `on` / `enable` | Set `enabled = true` |
| `proactive` | Set `mode = "proactive"` (fires every prompt — default safety reminder) |
| `conditional` | Set `mode = "conditional"` (fires only when tree has changes) |
| `quiet` | Set `mode = "quiet"` (same as conditional today; tightened in fase 3) |
| `silent` | Set `mode = "silent"` (never fires) |
| `config` / `status` | Read and display the current section |
| `reset` | Remove the `git-guard` key (revert to defaults) |

**Defaults when the section is missing:** `enabled: true`, `mode: "proactive"`.

> **Important:** these subcommands only affect the **UserPromptSubmit reminder** (the visible text). The PreToolUse blocking hook that intercepts `git commit` / `git push` is **not** affected by config and remains active. To fully disable git-guard in a project, uninstall the plugin.

### Config file path detection

1. `project_root` = `git rev-parse --show-toplevel` (fallback: `pwd`)
2. If `<project_root>/.claude/` exists → `<project_root>/.claude/vdm-plugins.json`
3. Else if `<project_root>/.qwen/` exists → `<project_root>/.qwen/vdm-plugins.json`
4. Else create `<project_root>/.claude/` and write to `<project_root>/.claude/vdm-plugins.json`

### Patching rules

1. Read the file (if missing, start with `{}`).
2. Modify only the `git-guard` key — preserve `learn`, `changelog`, `docs-sync` verbatim.
3. For `reset`, delete the `git-guard` key (do not leave `"git-guard": {}`).
4. Use the Edit/Write tool — **do not** invoke `jq`; users may not have it.
5. Final file must be valid JSON, 2-space indent, trailing newline.

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
