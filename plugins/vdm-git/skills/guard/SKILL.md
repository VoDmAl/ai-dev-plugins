---
name: guard
description: "Git safety guard. Blocks git commit and push via pre-tool-use hook. The assistant prepares each commit (stage explicit files, write message to a temp file, hand off `git commit -F <path>`) without announcing the gate. Invoke manually for pre-commit review."
license: MIT
---

# git-guard - Git Safety Guard

## Purpose

Keeps `git commit` and `git push` under explicit user control. Everything else (merge, rebase, reset, checkout, add, diff, status, etc.) is allowed freely.

The user installed git-guard knowingly. The point of the gate is the **review** step, not the announcement. The assistant's job, when work is done, is to *prepare* the commit cleanly and hand the user a single copy-paste command — never to halt-and-ask "may I commit?" or to declare "git-guard is blocking me." See [Auto-prep workflow](#auto-prep-workflow) below.

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

## Auto-prep workflow

When the assistant has finished work that warrants a commit — implementation done, type-check / tests passing where applicable — **prepare the commit and hand off a single command**, without waiting for verbal "go ahead." Do not stop at "should I commit?" — the user can decline by simply not running the command.

### Steps

1. **Stage explicit files.** `git add <file1> <file2> ...`. Never `git add -A`. Never `git add .`. Untracked files belonging to other tasks must stay unstaged; report them separately under "not staged (other tickets)" so the user knows they exist.

2. **Compose the subject** in the project's commit format. The PreToolUse hook would emit format rules if `git commit` were attempted directly — prefer that source. Otherwise infer from session context: a `## Commit Message Format` section in the project's AI-context file (CLAUDE.md, QWEN.md, AGENTS.md, GEMINI.md — whichever harness the project uses), or in `CONTRIBUTING.md` / `README.md`; failing those, `commitlint*`, `.gitmessage*`, or recent `git log` patterns. **Match the local style: if recent commits are subject-only single-line, do not write a body** — the body, if any, belongs in `PROJECT_CHANGELOG.md` or equivalent. Only fall through to the [default table](#default-fallback-table-when-nothing-else-detected) when nothing else is detected.

3. **Write the message via the helper.** The plugin ships `git-guard-prepare` on the PATH:

       git-guard-prepare "[+] Add foo helper"

   It writes the message to `${TMPDIR:-/tmp}/<repo>-<branch>-commit.txt` and prints a single-line `git commit -F <path>` command on stdout. Capture it.

   For a multi-line message (subject + body), pipe via `-`:

       printf '%s\n\n%s\n' "[+] Add foo helper" "Why: needed for X." | git-guard-prepare -

4. **Hand off to the user.** Your end-of-work message should contain:
   - what was staged (file list);
   - what is intentionally not staged (other tickets);
   - **the commit message itself** as a quoted preview, so the user can review it without opening the file;
   - the one-line command from step 3, **as inline code** (single backticks) on its own line — never inside a fenced code block, never inside a heredoc.

   Write the full path verbatim — never abbreviate it with `…` or `/var/folders/<hash>/T/...` in your narration. On macOS the temp path is long (`/var/folders/<id>/T/<repo>-<branch>-commit.txt`) and that is fine; the user copies the command line, they don't retype it.

   Example:

   > Implementation done. Type-check passes.
   >
   > Staged: `src/auth.ts`, `tests/auth.test.ts`
   > Not staged (other ticket): `notes/scratch.md`
   >
   > Message:
   > > [+] Add token expiry handling
   >
   > `git commit -F /tmp/limeflow-feat-auth-commit.txt`

5. **Do not execute the commit yourself.** The user runs the command (or aborts) — the gate is theirs.

### Forbidden framings

The user installed git-guard knowingly. Announcing the gate is pure noise. Never emit any variant of:

- "git-guard blocks me from committing"
- "say 'commit' and I will prepare a commit"
- "I cannot commit because git-guard is active"
- "Permission to commit?"

If work is done, prepare. If work is not done, finish it. There is no third state.

### Forbidden command shapes

Commits handed off as anything other than `git commit -F <path>` invite paste failures. Never use:

- `git commit -m "..."` with embedded backticks, quotes, dollar signs, or multi-line subjects — these trigger zsh's `dquote cmdsubst heredoc>` continuation prompts mid-paste.
- Heredoc forms (`git commit -m "$(cat <<'EOF' ... EOF)"`) — same paste fragility.
- Markdown fenced code blocks (```` ``` ````) around the command — leading whitespace breaks copy-paste.

Always emit `git commit -F <path>`, written via `git-guard-prepare`, presented as inline code (single backticks).

### Manual fallback

If `git-guard-prepare` is not on the PATH (older install / alternate harness), reproduce its convention manually:

    repo=$(basename "$(git rev-parse --show-toplevel)")
    branch=$(git symbolic-ref --short HEAD 2>/dev/null \
      | sed -e 's|[^A-Za-z0-9_-]|-|g' -e 's|-\{2,\}|-|g' -e 's|^-||' -e 's|-$||')
    path="${TMPDIR:-/tmp}/${repo}-${branch:-detached}-commit.txt"

Use the Write tool to put the message at `$path` (not a heredoc), then hand off `git commit -F $path` as inline code.

### Edge cases

- **Untracked files from other tickets**: list under "not staged (other tickets)" and exclude from `git add`. Never bundle multiple tickets into one commit unless the user explicitly asks.
- **Multiple commits in one session**: the helper rotates suffixes (`-2`, `-3`, ...) automatically when HEAD has not moved since the last prep — your prior message file is preserved, not overwritten.
- **No type-check available locally** (corepack/yarn not set up, missing deps): take the cheapest verification path (linter, single-file `tsc`, one test file) and report what couldn't be verified, rather than skipping verification silently.
- **Pre-commit hook fails after the user runs your command**: do not retry blindly and do not suggest `--no-verify`. Investigate, fix, re-stage, prepare a fresh message file, hand off again.
- **User explicitly says "commit"**: same flow. Don't announce the gate; don't bypass it. Prepare the file, hand off the command.

### Suggesting a project-level format declaration

If no commit-format source is detected (the hook reports `Source: fallback` or `Source: git log -30`) **and** the user signals dissatisfaction with the commit-message style ("shorter", "no body", "doesn't match our style", correcting prefix choice), suggest **once**:

> "Want me to add a `## Commit Message Format` section to your project's AI-context file (CLAUDE.md / QWEN.md / AGENTS.md / CONTRIBUTING.md, whichever this project uses) so future commits follow this style automatically?"

If they decline, drop it — don't repeat. Don't add the section unilaterally; it's project-level convention, not a fix for the current commit. Until they add one, infer style from `git log` and match it (subject-only stays subject-only; with-body stays with-body).

### Recovery: if the assistant ran `git commit` directly

The PreToolUse hook intercepts `git commit` and `git push` and emits PROJECT COMMIT FORMAT, STAGED CHANGES, and recovery instructions. Treat that output as a soft reminder to switch to the prep workflow above — do not retry `git commit` from Bash. Instead, prepare a message file via `git-guard-prepare` (using the format rules the hook just emitted) and hand off `git commit -F <path>`.

### Format detection priority (used by the hook)

When the hook intercepts `git commit`, it detects the project's commit convention in this order (all built into `git-guard-hook.py`):

1. `git config commit.template` (Git's native template system)
2. `.gitmessage`, `.gitmessage.txt`, or `.git-commit-template` in the repo root
3. `commitlint.config.*` / `.commitlintrc*` → signals Conventional Commits
4. Commit section in `CLAUDE.md`, `CONTRIBUTING.md`, `docs/CONTRIBUTING.md`, or `README.md`
5. Pattern detection from `git log -30` (recognizes `[+]/[-]/[*]`, `feat:/fix:`, gitmoji)
6. Generic fallback (brief imperative ≤ 50 chars)

The fallback table below applies only when nothing else can be detected (fresh repo, no log, no docs, no config — rare).

### Default fallback table (when nothing else detected)

| Prefix | Meaning |
|--------|---------|
| `[+]` | New feature |
| `[-]` | Bugfix |
| `[*]` | Other change |

Examples:

```
[+] Add git-guard skill with pre-tool-use hook
[-] Fix token expiry in auth middleware
[*] Update dependencies to latest versions
```

Brief imperative, ≤ 50 characters total.

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

Prepare the message via `git-guard-prepare "<subject>"` and present the `git commit -F <path>` line as inline code (see [Auto-prep workflow](#auto-prep-workflow)). Surface anything unexpected in the diff so the user can decide whether to run it, adjust the wording, or abort.

## Configuration

Helper: `git-guard-prepare` (on PATH via the plugin's `bin/` directory).
Block hook: `${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-hook.py` — edit `BLOCKED_PATTERNS` to customize.
Reminder: `${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-reminder.sh` — gated by `enabled` / `mode` in `.claude/vdm-plugins.json`.
