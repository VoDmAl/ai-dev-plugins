---
name: guard
description: "Git safety guard. Blocks git commit and push via pre-tool-use hook. Requires explicit user permission before executing. Invoke manually for pre-commit review."
license: MIT
---

# git-guard - Git Safety Guard

## Purpose

Prevents the AI assistant from executing `git commit` and `git push` without explicit user permission. Everything else (merge, rebase, reset, checkout, add, diff, status, etc.) is allowed freely.

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

Since v2.2.0, when the hook intercepts `git commit` it does the heavy lifting itself: detects the **project's** commit message convention, lists the staged files, and emits explicit instructions for the assistant to compose a ready-to-paste command.

**Format detection priority** (built into the Python hook):

1. `git config commit.template` (Git's native template system)
2. `.gitmessage`, `.gitmessage.txt`, or `.git-commit-template` in the repo root
3. `commitlint.config.*` / `.commitlintrc*` → signals Conventional Commits
4. Commit section in `CLAUDE.md`, `CONTRIBUTING.md`, `docs/CONTRIBUTING.md`, or `README.md`
5. Pattern detection from `git log -30` (recognizes `[+]/[-]/[*]`, `feat:/fix:`, gitmoji)
6. Generic fallback (brief imperative ≤ 50 chars)

When you (the assistant) see the block message:

1. Read the **PROJECT COMMIT FORMAT** section the hook emitted — that's the source of truth for this repo, not the in-skill table below.
2. Use your session context (what was actually changed and why) to compose a concise, accurate subject under those rules.
3. Combine into a single shell-safe command: `git commit -m "<prefix> <subject>"`.
4. **Present that command as INLINE CODE** (single backticks) on its own line. **Do NOT** wrap in a fenced code block — fenced blocks add leading whitespace that breaks copy-paste.
5. Wait for the user to confirm or run the command themselves.

**Example presentation to the user:**

> Changes look good. Suggested commit:
>
> `git commit -m "[-] Fix token expiry handling"`
>
> Run it, or want me to adjust the wording?

The fallback table below applies only when the hook's detection has nothing to go on (a fresh repo with no log, no docs, no config — rare in practice).

### Default fallback table (when nothing else detected)

| Prefix | Meaning |
|--------|---------|
| `[+]` | New feature |
| `[-]` | Bugfix |
| `[*]` | Other change |

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
