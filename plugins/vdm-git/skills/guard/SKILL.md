---
name: guard
description: "Git safety guard. Blocks git commit and push via pre-tool-use hook. The assistant prepares each commit (stage explicit files, write message to a temp file, hand off `git commit -F <path> -- <paths>`) without announcing the gate. Invoke manually for pre-commit review."
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

### Why only these two

The list is not "dangerous git operations". `git update-ref` moves refs,
`git reset --hard` and `git branch -D` lose work, `git rebase` rewrites it —
none of them are here, deliberately.

What the list actually covers is **the operation the assistant is already being
pushed toward by its own instructions.** The `UserPromptSubmit` reminder asks it
to prepare a commit on every single turn; that is a standing pressure, and a
standing pressure is what earns a hard stop. Nothing pushes the assistant to run
`reset --hard`, and when it does run one it is usually because the work needs it.
Blocking there would add friction with no force to balance.

So the criterion for ever extending this list is not "could this lose work?" but
**"is something already pushing the assistant to do it?"** — which is why the
matcher reads a subcommand rather than a string prefix (v2.7.2): `git commit-tree`
writes an object and moves no ref, so it never belonged here, while `update-ref`,
which does move refs, was never on the list at all. The old `\b` boundary had
them exactly backwards.

### What this guard is — and is not

It is a **discipline**, not a boundary. The rule lived in the prompt first, proved
unreliable there, and moved up to a hook, which makes it markedly harder to forget.
It does not make it impossible to circumvent: the matcher inspects the command
string, so any commit reached indirectly — through a script, a wrapper, a test
harness — passes without being seen. And it holds only if the hook finishes: a
hook the harness cancels at its `timeout` does not block the call, it lets it
through. On a machine under heavy load a 0.2 s guard has been cancelled at a 5 s
ceiling, which is why the hook is registered with 60 s, and only on the tools that
hand a command to a shell — `Bash` and `Monitor`. A commit sent through `Monitor`
is the same string by another door, so the guard reads it the same way; a tool it
does not read is not a loophole to use, it is one more reason the guard is a
discipline.

That is stated plainly rather than left to be discovered, because the discovery is
cheap and the false impression is expensive. And it follows from something more
general: **any exemption the assistant can trigger is not a control.** The
assistant composes the whole command line and the whole environment, so no
env-var escape or path-based carve-out would preserve the guard while making it
convenient — there is nothing at this layer the assistant cannot fabricate.

The practical consequence is a rule about intent, not mechanism. When the guard
fires and you need a real commit to verify something — testing this helper, for
instance — **write it as a self-contained script under a `references/` directory
and hand the user the line to run it.** Do not repackage the command to slip past
the matcher. The cost of the honest path is one round-trip; the cost of the habit
is the guard. If the user explicitly asks you to run such a script, running it is
following their instruction, not routing around their guard — the distinction is
whose decision it was.

## Auto-prep workflow

When the assistant has finished work that warrants a commit — implementation done, type-check / tests passing where applicable — **prepare the commit and hand off a single command**, without waiting for verbal "go ahead." Do not stop at "should I commit?" — the user can decline by simply not running the command.

### Steps

1. **Stage explicit files.** `git add <file1> <file2> ...`. Never `git add -A`. Never `git add .`. Untracked files belonging to other tasks must stay unstaged; report them separately under "not staged (other tickets)" so the user knows they exist.

2. **Compose the subject** in the project's commit format. The PreToolUse hook would emit format rules if `git commit` were attempted directly — prefer that source. Otherwise infer from session context: a `## Commit Message Format` section in the project's AI-context file (CLAUDE.md, QWEN.md, AGENTS.md, GEMINI.md — whichever harness the project uses), or in `CONTRIBUTING.md` / `README.md`; failing those, `commitlint*`, `.gitmessage*`, or recent `git log` patterns. **Match the local style: if recent commits are subject-only single-line, do not write a body** — the body, if any, belongs in `PROJECT_CHANGELOG.md` or equivalent. Only fall through to the [default table](#default-fallback-table-when-nothing-else-detected) when nothing else is detected.

3. **Write the message via the helper.** The plugin ships `git-guard-prepare` on the PATH:

       git-guard-prepare "[+] Add foo helper"

   It writes the message to a per-prep file under `${TMPDIR:-/tmp}` and prints a single-line `git commit -F <path> -- <paths>` command on stdout, opening with a check that its message file still exists (`[ -f <path> ] || { echo …; false; } &&`). Capture it and hand it off **verbatim** — the explicit pathspec is the point (see [Why the pathspec](#why-the-pathspec-is-not-optional)), and the check in front is what stops a dead line before any hook runs (see [A line that is still waiting](#a-line-that-is-still-waiting)).

   For a multi-line message (subject + body), pipe via `-`:

       printf '%s\n\n%s\n' "[+] Add foo helper" "Why: needed for X." | git-guard-prepare -

   **One line per finished block.** Don't prepare while the user is still discussing the work or busy with a step of their own — a letter to send, a reply to wait for. A line handed off stands: edits to the paths it names ride with it, new files go with the next commit. While it waits, the helper refuses to prepare again and deletes nothing (see [A line that is still waiting](#a-line-that-is-still-waiting)); then hand off nothing new.

   **Superseding kills the earlier line — yours, not a neighbour's.** `git-guard-prepare --supersede "<subject>"` is for a line the user reported failed, or a block that changed in substance. It deletes the earlier line's message file, so that command fails instead of committing a message that has since been revised (see [Superseding a prepared line](#superseding-a-prepared-line)). The helper then reports `a prepared command for this branch was never run`; say so on hand-off: the user still has the dead line in their scrollback.

4. **Hand off to the user.** Your end-of-work message should contain:
   - what was staged (file list);
   - what is intentionally not staged (other tickets);
   - **the commit message itself** as a quoted preview, so the user can review it without opening the file;
   - the one-line command from step 3, **as inline code** (single backticks) on its own line — never inside a fenced code block, never inside a heredoc.

   Write the full path verbatim — never abbreviate it with `…` or `/var/folders/<hash>/T/...` in your narration. On macOS the temp path is long (`/var/folders/<id>/T/vdm-git-<uid>/<session>/<repo>-<branch>-commit-<token>.txt`) and that is fine; the user copies the command line, they don't retype it.

   Example:

   > Implementation done. Type-check passes.
   >
   > Staged: `src/auth.ts`, `tests/auth.test.ts`
   > Not staged (other ticket): `notes/scratch.md`
   >
   > Message:
   > > [+] Add token expiry handling
   >
   > `git commit -F /tmp/product-feat-auth-commit-1757520411-48213.txt -- 'src/auth.ts' 'tests/auth.test.ts'`

5. **Do not execute the commit yourself.** The user runs the command (or aborts) — the gate is theirs.

### Forbidden framings

The user installed git-guard knowingly. Announcing the gate is pure noise. Never emit any variant of:

- "git-guard blocks me from committing"
- "say 'commit' and I will prepare a commit"
- "I cannot commit because git-guard is active"
- "Permission to commit?"

If work is done, prepare. If work is not done, finish it. There is no third state.

### Why the pathspec is not optional

The index is shared per-repository, but the command is written by the assistant
and run by the human some time later. With several sessions or agents in one
repo, a neighbour can stage its own files in that gap — and a bare
`git commit -F <msg>` commits whatever is in the index *at run time*, not what
you staged. Field report (`command-center`, 2026-08-25): agent A staged six
files and handed off; agent B staged `gaps/INDEX.md`; the command committed
both, and the user could not run it without unpicking the index by hand.

The explicit pathspec makes the emitted command self-contained: what it commits
is decided when it is written. That is the whole point — so hand the line off
verbatim and never trim the tail.

**What it costs, and why the helper sometimes refuses.** `git commit -- <paths>`
commits the *working tree* version of those paths, not the staged one, and the
staged version is then gone rather than left behind in the index. For a
`git add -p` partial stage that is silent data loss. So `git-guard-prepare`
checks `git diff --name-only -- <paths>` at prep time and exits 1 when the two
differ, rather than emitting either form: the pathspec form would lose the
staged hunks, and falling back to the bare form would resurrect the defect
above. Both degradations are silent; the refusal is loud and is fixed by one
`git add` (or `git checkout --`). Do not work around it.

**Untracking with `git rm --cached` — the one line without a pathspec.** A file
removed from the index but still on disk (a directory just added to
`.gitignore`) cannot be committed by pathspec: git takes the listed path from the
working tree and commits the file back, and the staged removal is dropped
without a word. The worktree check above does not see it — `git diff` lists no
file the index no longer holds. Field case: executor, 2026-10-04, four files put
back into git. So when the prepared paths hold such an untracking, the helper
prints `git commit -F <msg>` **with no paths** and says why on stderr — but only
when the index holds nothing but this commit's paths. Anything else staged, it
refuses and names it: a pathspec would put the files back, a whole-index commit
would take the rest. A plain `git rm` (file gone from disk) keeps the pathspec.
Hand the line off verbatim as always; a line without `--` is correct here.

**Syncthing conflict copies inside `.git`.** When a repository is synced between
machines together with its `.git`, and both machines write the same file there,
one version stays and the other lies beside it as `*.sync-conflict-*`. Nothing
announces it: a copy of a branch ref can hold a commit that has dropped out of
the branch, a copy of the index means the live index lost an update. The helper
refuses while any such copy exists (outside `objects/`), and names each one. For
a copy of a branch ref it names the commit and says whether it is in the branch;
a commit that is not is a dropped commit — bring it back (`git cherry-pick`)
before a new commit lands on top of it. For a copy of the index: compare
`git status` with what was staged, fix the entry, delete the copy. Then prepare
again. Field cases and the owner's decision: vdx, 2026-09-30.

**A branch that arrived before its commit.** Syncthing carries `.git` file by
file, so a commit made on the other machine can land as its branch ref first and
as its object minutes later (executor, 2026-10-01: about fifteen). In
between, HEAD names a commit this repository does not have, and nothing about
the branch can be judged. The helper refuses with the commit's id and the check
that tells when it is here — `git cat-file -e <sha>` — and says how many
conflict copies wait for the next run. The branch is not gone and nothing is
lost: do not recreate it, do not reset it; wait, then prepare again. The same
holds for a conflict copy of another branch whose live ref is ahead of its
object — the helper says so instead of calling that branch gone.

**Committing a subset.** When you want fewer paths than are staged, name them:

    git-guard-prepare "[+] Add foo helper" -- src/foo.ts

Without an explicit list the helper snapshots the index with
`git diff --cached --name-only -z --no-renames`. `--no-renames` is load-bearing:
git reports a `git mv` as a single rename entry naming only the destination, and
a commit built from that list records the addition without the deletion, leaving
the old path in the tree.

### The detector: did the commit match what was prepared?

Every prep records the paths it intended to commit. The **next** prep — and
`git-guard-prepare --verify-last` on demand — compares that intent against what
the commit actually contains, and complains on stderr when they differ:

- **SWEPT IN** — a path in the commit that the prepared command never named.
  Always wrong: something wrote to the index or the tree between prepare and
  commit.
- **NOT COMMITTED** — a named path absent from the commit. A warning, because a
  named path whose content already matched HEAD legitimately drops out. When
  the commit is empty, that excuse does not apply and it is reported as such.
- **NOT UNTRACKED** — a path prepared to leave git (`git rm --cached`) that the
  commit still tracks, typically because it was staged back in between.
- **CHANGED SINCE PREP** — a path committed with other content than was staged
  when the line was prepared, while HEAD moved in between. A pathspec line takes
  its paths from disk when it runs: a line run late, after another session
  committed and rewrote the same files, commits that work under its own message
  (field case 2026-10-05; the names matched, so only the content shows it). Your
  own edits made after the prep ride along by design ([A line that is still
  waiting](#a-line-that-is-still-waiting)); another session's work does not. With
  HEAD unchanged a different
  blob is what a formatting pre-commit hook produces, and that is not reported.

If you see this output, **stop and look at the commit** before building on it:
`git show --stat <sha>`. Do not re-run the prepare and carry on.

It is not a git hook, and that is deliberate. A measurement across 12
repositories found git hooks wired in exactly one, so a check living in a
`post-commit` hook is a check that never runs. Inside the helper it runs
wherever the helper runs, with nothing to install. Anyone who wants the report
immediately rather than at the next prep can call `--verify-last` from their own
`post-commit` hook.

The prep's commit is found by its **message**, among the commits made on top of
the HEAD it was prepared against — not by "HEAD moved by one". So a neighbouring
session's commit landing in between neither hides yours from the audit nor gets
audited against your intent, and it does not make your unrun line look consumed.

The check fails open — an amend, a rebase onto something else, a reset, an
unreadable sidecar all produce silence. A detector that fires on ordinary git
usage gets ignored, and an ignored detector is worse than none.

Called by name, `--verify-last` states which of three things happened, on
stdout: `✓ <sha> matches what was prepared`, `nothing to verify` (with why — not
committed yet, history rewritten, nothing on record), or the mismatch report on
stderr. Silence would read the same for all three.

### Superseding a prepared line

A prepared line lives in the user's terminal scrollback, and scrollback does not
expire. Field report (`executor`, 2026-09-09): a line was prepared, the owner
sent corrections instead of running it, a second line was prepared — and the
first, still valid, was the one that ran. The commit went out carrying the
superseded message and needed an `--amend` to fix. The same session left
**nineteen** live message files in one `TMPDIR`, every one of them runnable.

So each prep now takes a name that is never issued twice **and** deletes the
previous prep's files. Both halves are needed: reusable names let an old line be
re-pointed at a newer message, and unique names alone leave every superseded line
runnable forever. Together the stale line stops on its own check — `git-guard:
this line is void` — a visible failure instead of a quiet wrong commit.

What this asks of you:

- Supersede only on purpose, with `--supersede` (next section says when).
- When the helper prints `⚠ a prepared command for this branch was never run`,
  **tell the user the earlier line is void** as you hand off the new one. They
  cannot see which of two lines in their scrollback is current; you can.
- Prepare **once per turn** and wait. Preparing twice before the user has run
  anything is what produces two lines side by side in the first place.

**The unit is a session, not the branch.** Trios live under
`${TMPDIR}/vdm-git-<uid>/<session>/` when the harness names its session
(`CLAUDE_CODE_SESSION_ID`), so two sessions on one repo and branch never touch
each other's lines. Until vdm-git 2.15.0 the unit was the branch. Field report
(`executor`, 2026-09-12, three sessions on trunk as a standing practice):
session B's prep deleted A's pending line three times in an hour; A's user found
out from git's `could not read log file` after pasting, and the "never run"
warning went to B, who had nothing to do with it.

Without a session id — a human running the helper at a terminal, or a harness
that exports none — the scope falls back to the repo and branch, as before. Not
`$PPID`: the helper's parent is the shell of one tool call, a new one each time,
so every prep would become its own scope and superseding would silently stop.

### A line that is still waiting

Superseding was once what every second prep did, and a notice after it said the
earlier line "was never run". Two field reports showed the cost. A session
interviewing the owner prepared four lines for one batch and none was run
(`executor`, 2026-10-03; the owner: the answers are still coming, a commit now
is wasted work). Another prepared about sixteen, seven were run, each extra one
after a note added to a crystal — two of them while the owner was still sending
a letter that would itself bring edits back (`echelon`, 2026-10-06). An unrun
line usually means the user is not done, not that the line is wrong. And the
notice came after the deletion: it reported each dead line and prevented none.

So while a line of this session has not been run, the helper refuses to prepare
again, deletes nothing, and says when and what was prepared. What that asks of
you:

- **Hand off nothing new.** Edits to the paths the waiting line names ride with
  it — a pathspec commit takes them from the working tree. New files go with the
  next commit.
- **Supersede when the line cannot stand:** the user reported it failed
  (pre-commit refused it — nothing on disk tells the helper that, the
  conversation does), or the block changed in substance (the message is no
  longer true, a file joins it, the user sent corrections). Then
  `git-guard-prepare --supersede "<subject>" [-- <path>...]`, and say the earlier
  line is void.

A dead line still gets run — from the scrollback, by a mistaken paste, in a
restored session where every old line looks current. Git runs pre-commit before
it reads `-F`, so such a line used to run the project's whole pre-commit on
whatever its paths held by then, and could be stopped by a gate complaining about
another session's work (2026-10-06: version-bump, about a neighbour's unbumped
plugin). Every line now opens with a check that its message file exists — the
file exists exactly while the line is live — and a dead one stops there with
`git-guard: this line is void`. Not a HEAD check: a waiting line has to survive a
neighbour's commit.

### Amending

`git commit --amend` **without** a pathspec takes the whole index — including
whatever a neighbouring session staged after your prep. That is the same defect
the pathspec exists to prevent, arriving through the one command shape that
looks too small to need it. Field report (`executor`, 2026-09-09): a foreign
staged file was swept into an amend exactly this way.

Name the paths, every time:

    git commit --amend -F <path> -- <path1> <path2>

The helper has no `--amend` mode: the detector deliberately ignores amends
(the commit the prep was made against is no longer in history), so an amend is
prepared like any other commit and `--amend` is added to the emitted line by
hand.

### Forbidden command shapes

Commits handed off as anything other than `git commit -F <path> -- <paths>` invite paste failures or wrong content. Never use:

- `git commit -m "..."` with embedded backticks, quotes, dollar signs, or multi-line subjects — these trigger zsh's `dquote cmdsubst heredoc>` continuation prompts mid-paste.
- Heredoc forms (`git commit -m "$(cat <<'EOF' ... EOF)"`) — same paste fragility.
- Markdown fenced code blocks (```` ``` ````) around the command — leading whitespace breaks copy-paste.
- Listing `git-guard-prepare` (or `git add`) in a copy-paste recipe for the user. The helper lives on the **assistant's** PATH (plugin `bin/` mounted by the harness); it is **not** on the user's shell PATH. If you put it in a numbered list of "run these in order", the user gets `zsh: command not found: git-guard-prepare`. Run `git add` and `git-guard-prepare` yourself in Bash, capture the `git commit -F <path> -- <paths>` line from stdout, and hand off only that line.

- Trimming the `-- <paths>` tail off the emitted line, or re-typing it as a bare `git commit -F <path>`. That silently re-opens the defect the pathspec exists to close: a parallel session's staged files get swept into your commit.
- Trimming the `[ -f <path> ] || { …; } &&` check off its front. Git runs pre-commit before it reads `-F`, so without the check a dead line runs the project's hooks on whatever its paths hold by then.

Always emit `git commit -F <path> -- <paths>` exactly as `git-guard-prepare` printed it, presented as inline code (single backticks).

### Manual fallback

If `git-guard-prepare` is not on the PATH (older install / alternate harness), reproduce its convention manually:

    repo=$(basename "$(git rev-parse --show-toplevel)")
    branch=$(git symbolic-ref --short HEAD 2>/dev/null \
      | sed -e 's|[^A-Za-z0-9_-]|-|g' -e 's|-\{2,\}|-|g' -e 's|^-||' -e 's|-$||')
    base="${TMPDIR:-/tmp}/${repo}-${branch:-detached}-commit"
    rm -f "$base"*.txt "$base"*.paths      # any earlier line is superseded — kill it
    path="${base}-$(date +%s)-$$.txt"      # a name that is never issued twice

This is the per-branch scope: in parallel sessions on one branch it kills a
neighbour's pending line too, so tell the user which line is current.

Use the Write tool to put the message at `$path` (not a heredoc). Then build the
pathspec yourself — the fallback owes the same guarantee as the helper:

    git diff --cached --name-only -z --no-renames   # the paths to append after --
    git diff --name-only -- <those paths>           # MUST be empty; abort if not

Hand off `git commit -F $path -- '<path>' '<path>'` as inline code, single-quoting
each path. If the second command prints anything, stop: the working tree differs
from the index on those paths and a pathspec commit would discard what is staged.
Reconcile with `git add` / `git checkout --` first.

### Edge cases

- **Untracked files from other tickets**: list under "not staged (other tickets)" and exclude from `git add`. Never bundle multiple tickets into one commit unless the user explicitly asks.
- **Detector output on the next prep**: read it before handing anything off. It means the previous commit is not what was prepared.
- **Multiple commits in one session**: each prep gets its own message file, never a name already issued, and **deletes the previous prep's files** of this session — a superseded line fails instead of committing a stale message (see [Superseding a prepared line](#superseding-a-prepared-line)). The `.paths` and `.meta` companions always share the message file's stem, so two preps cannot cross their pairs. What this costs you: prepare one commit per turn and wait, because the second prep kills the first line whether or not the user has run it.
- **Batch commits (multiple separate commits queued from one task)**: prepare each commit *sequentially in your own turn* — `git add <files>` → `git-guard-prepare "<subject>"` → present message preview + `git commit -F <path> -- <paths>` line → wait for the user. Do **not** bundle the sequence into a numbered shell script for the user (`git add ...` / `git-guard-prepare ...` / `# commit` lines stacked together) — `git-guard-prepare` is an assistant-PATH helper, the user's shell does not see it. Only the per-commit `git commit -F <path> -- <paths>` line crosses to the user's shell.
- **No type-check available locally** (corepack/yarn not set up, missing deps): take the cheapest verification path (linter, single-file `tsc`, one test file) and report what couldn't be verified, rather than skipping verification silently.
- **Pre-commit hook fails after the user runs your command**: do not retry blindly and do not suggest `--no-verify`. Investigate, fix, re-stage, prepare a fresh message file, hand off again.
- **User explicitly says "commit"**: same flow. Don't announce the gate; don't bypass it. Prepare the file, hand off the command.

### Suggesting a project-level format declaration

If no commit-format source is detected (the hook reports `Source: fallback` or `Source: git log -30`) **and** the user signals dissatisfaction with the commit-message style ("shorter", "no body", "doesn't match our style", correcting prefix choice), suggest **once**:

> "Want me to add a `## Commit Message Format` section to your project's AI-context file (CLAUDE.md / QWEN.md / AGENTS.md / CONTRIBUTING.md, whichever this project uses) so future commits follow this style automatically?"

If they decline, drop it — don't repeat. Don't add the section unilaterally; it's project-level convention, not a fix for the current commit. Until they add one, infer style from `git log` and match it (subject-only stays subject-only; with-body stays with-body).

### The subject has a ceiling, held by the helper

`git-guard-prepare` refuses a first line longer than the project's ceiling —
`git-guard.subject-max` in `.claude/vdm-plugins.json`, else **72** characters
(git's own documentation advises 50; a prefix and a scope need the margin).
Characters, not bytes. The refusal names the length and where the detail goes:
`PROJECT_CHANGELOG.md` when the project keeps one, otherwise a body after a blank
line. Nothing is prepared; shorten the subject and run it again.

A ceiling in words did not hold. Measured 2026-10-08 on the last 40 commits of
every repository on one machine: a median first line of 741 characters in one
project, 100–280 in nine more, 90 in a repository whose own rules said "≤ 80";
the shortest nine of 27 stayed at 39–63. The
mechanism is the format detection below: with no rule of its own, a project's
`git log` is the sample, so every long subject licenses the next. A project that
wants a different ceiling sets the number; there is no flag to pass one long
subject, because the escape would become the habit.

### Recovery: if the assistant ran `git commit` directly

The PreToolUse hook intercepts `git commit` and `git push` and emits PROJECT COMMIT FORMAT, STAGED CHANGES, and recovery instructions. Treat that output as a soft reminder to switch to the prep workflow above — do not retry `git commit` from Bash. Instead, prepare a message file via `git-guard-prepare` (using the format rules the hook just emitted) and hand off `git commit -F <path> -- <paths>`.

### Format detection priority (used by the hook)

When the hook intercepts `git commit`, it detects the project's commit convention in this order (all built into `git-guard-hook.py`):

1. `git config commit.template` (Git's native template system)
2. `.gitmessage`, `.gitmessage.txt`, or `.git-commit-template` in the repo root
3. `commitlint.config.*` / `.commitlintrc*` → signals Conventional Commits
4. Commit section in `CLAUDE.md`, `CONTRIBUTING.md`, `docs/CONTRIBUTING.md`, or `README.md`
5. Pattern detection from `git log -30` (recognizes `[+]/[-]/[*]`, `feat:/fix:`, gitmoji)
6. Generic fallback (brief imperative ≤ 50 chars)

Whatever the source says about style, the length is capped by the helper (see
[The subject has a ceiling](#the-subject-has-a-ceiling-held-by-the-helper)).

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

Prepare the message via `git-guard-prepare "<subject>"` and present the `git commit -F <path> -- <paths>` line as inline code (see [Auto-prep workflow](#auto-prep-workflow)). Surface anything unexpected in the diff so the user can decide whether to run it, adjust the wording, or abort.

## Crystal pre-commit backup

Companion to the `crystal-*` suite in the sibling `vdm` plugin. The
primary `crystal-completion-guard` is a PreToolUse hook — it catches the
assistant flipping a workitem to `status: done` with unchecked items
remaining. The backup catches the same drift from the **other** side: a
user editing the workitem directly in their IDE and committing it,
bypassing the assistant entirely.

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/crystal-precommit-check.sh`. Reads
the staged paths and checks each staged workitem (folder-style
`<root>/<slug>/workitem.md` or flat `<root>/<slug>.md`) under **every** crystal
root the suite resolves: the ones in `.claude/vdm-plugins.json`
(`crystal.paths`, or `crystal.path`), otherwise each `tasks/` directory found in
the repository — typically just `docs/tasks/`. Exits 1 with a diagnostic per
offending file when `status: done` ships with unchecked items.

### Activating in a downstream project

Add to your repo's `.githooks/pre-commit` (and activate the hooksPath once
with `git config core.hooksPath .githooks`). It takes two blocks: the
resolver, pasted **once per hook file** and shared with the
[U+FFFD guard](#ufffd-corruption-that-arrives-by-batch-write) below, and then
the gate itself.

```bash
# vdm-git gate resolver — shared by the vdm-git gates; paste it once per hook.
# Prints where vdm-git's <script> is: inside the marketplace checkout the
# harness has REGISTERED (known_marketplaces.json → installLocation). That
# checkout is unversioned, so the path survives plugin updates, and asking the
# registry means an abandoned second clone of the same marketplace is never
# picked — a glob over marketplaces/* returns clones by name, not by which one
# is live. With no registry to ask it falls back to that glob, and refuses to
# guess between two copies. On failure it prints nothing and says why on
# stderr; it never fails the hook by itself, so it is safe under `set -e`.
vdm_git_gate() {
  vdm_rel="vdm-git/scripts/$1"; vdm_found=""
  vdm_locs=$(for vdm_reg in "$HOME/.claude/plugins/known_marketplaces.json" \
                            "$HOME/.qwen/plugins/known_marketplaces.json"; do
      if [ -f "$vdm_reg" ]; then
        { grep -o '"installLocation"[[:space:]]*:[[:space:]]*"[^"]*"' "$vdm_reg" || true; } |
          sed 's/.*"\([^"]*\)"$/\1/'
      fi
    done) || true
  if [ -n "$vdm_locs" ]; then
    vdm_found=$(printf '%s\n' "$vdm_locs" | while IFS= read -r vdm_loc; do
        if [ -x "$vdm_loc/plugins/$vdm_rel" ]; then printf '%s\n' "$vdm_loc/plugins/$vdm_rel"; fi
      done) || true
  else
    vdm_found=$(for vdm_c in "$HOME"/.claude/plugins/marketplaces/*/plugins/"$vdm_rel" \
                             "$HOME"/.qwen/plugins/marketplaces/*/plugins/"$vdm_rel"; do
        if [ -x "$vdm_c" ]; then printf '%s\n' "$vdm_c"; fi
      done) || true
  fi
  if [ -z "$vdm_found" ]; then
    # Say so. A gate that cannot find itself must not look like a gate that
    # found nothing to report.
    echo "[vdm-git] $1 not found — is vdm-git installed?" >&2
  elif [ "$(printf '%s\n' "$vdm_found" | grep -c .)" -gt 1 ]; then
    echo "[vdm-git] several copies of $1 — not guessing which one is live:" >&2
    printf '%s\n' "$vdm_found" | sed 's/^/  /' >&2
  else
    printf '%s\n' "$vdm_found"
  fi
}
```

```bash
# Crystal completion-discipline backup gate (from vdm-git plugin).
# Needs the resolver above. CRYSTAL_PRECOMMIT_CHECK overrides it (CI, a
# non-standard install, a fork).
crystal_check="${CRYSTAL_PRECOMMIT_CHECK:-$(vdm_git_gate crystal-precommit-check.sh)}"
if [ -n "$crystal_check" ]; then
  "$crystal_check" || exit 1
fi
```

**Why the resolution, not a pinned variable.** The earlier form was
`[ -n "${CRYSTAL_PRECOMMIT_CHECK:-}" ] && …` — with the variable unset the
whole conjunction is false, the commit proceeds, and nothing is printed. The
gate then fails *indistinguishably from passing*, which is the exact defect
this suite keeps finding elsewhere. Measured 2026-09-03 (by the `vdx` agent,
across one machine and 12 repositories): the variable was set in no shell
profile and no settings file, so the distributed snippet was assembled in zero
repositories — while a count based on "the hook file exists" reported one.
Two consequences, both applied above: resolve the path instead of demanding it
be pinned by hand (install drops from three steps to two), and **be loud when
resolution fails** — an unresolvable gate is a broken gate, not a quiet one.

**Why the registry, not the first clone a glob finds.** Up to vdm-git 2.15.1 the
snippet took the first match of
`~/.claude/plugins/marketplaces/*/plugins/vdm-git/scripts/…`. Observed
2026-09-25 on the machine this suite is developed on: two clones of the same
marketplace side by side — the live one, and an abandoned one six months stale
(vdm 2.1.0) that the harness no longer referenced. A glob returns matches by
name, and the live clone happened to sort first. With the names the other way
round, every commit would have been checked by the stale copy, and nothing
would have said so. The harness's own registry names the live checkout, so the
resolver asks it first. The glob is only the fallback when there is no registry
to ask, and there it refuses to guess between two copies — it names both, so
the stale one can be removed.

The unversioned marketplace path is stable across plugin updates, unlike
`…/plugins/cache/<marketplace>/vdm-git/<version>/…`, whose version segment
moves on every release. Both harness roots (`.claude/`, `.qwen/`) and any
marketplace name are covered. The gate script itself still fails open on
internal errors, so this hook entry is safe in a repo that has no crystal
workitems yet. Both blocks are run exactly as written here by the upstream red
tests: `cc-vdm-plugins → tests/githook-snippets.test.sh`.

### Why three layers (DL #7)

| Layer       | Where it fires                 | What it catches                          |
|-------------|--------------------------------|------------------------------------------|
| PreToolUse  | Assistant Write/Edit/MultiEdit | Assistant typo / context-pressure drift  |
| Stop hook   | End of assistant turn          | Reminder to address open items           |
| pre-commit  | User's `git commit`            | Direct IDE edits bypassing the assistant |

No layer is sufficient alone. The pre-commit gate is the "last line of
defense" — by the time it fires, the assistant didn't catch the drift,
which is exactly when you want a deterministic check.

## U+FFFD: corruption that arrives by batch write

U+FFFD, the replacement character, is what a truncated multi-byte codepoint
decodes to. A batch write across many files is how it arrives: one interrupted
Cyrillic letter becomes two of these, everything around it looks intact, and
nothing reports it. Origin incident: 21 corruption points across 11 files,
found three weeks later.

It is checked on **two surfaces**, and the split matters more than the check:

| Surface | Covers | Installation |
|---------|--------|--------------|
| `git-guard-prepare` | every commit the assistant prepares — i.e. the side that produces the corruption | none |
| `${CLAUDE_PLUGIN_ROOT}/scripts/fffd-precommit-check.sh` | commits made by hand or from an IDE, which the helper never sees | once per clone |

The helper refuses before it writes the message file and names the offending
lines; nothing is emitted, so there is no stale command to run by mistake.

The pre-commit script reads the **staged blob** (`git show :path`), never the
working tree — an unstaged fix does not travel with the commit, and an unstaged
breakage is not part of it either. It also refuses when it cannot read the
index at all: an empty file list from a failed command is the exact shape of a
check that silently did not run.

What both surfaces do **not** read:

- **A file git treats as binary** — `-` in `git diff --numstat`, the same verdict
  that makes `git diff` print "Binary files differ". In a PDF or an image the
  bytes `EF BF BD` are data, and a gate that blocks a legitimate attachment
  trains everyone to go around it. A file that git reads as text but the project
  knows is not: mark it `binary` in `.gitattributes`, and git and this check
  agree by construction.

And what they do read, including the two cases they once missed:

- **A renamed file** — renames are split into delete + add, so a file moved and
  damaged in the same commit is read under its new name.
- **From any directory** — the helper reads the index's paths from the top of the
  work tree; run from a subdirectory it used to find no file and pass in silence.

### Activating in a downstream project

Paste the resolver from the [crystal backup above](#activating-in-a-downstream-project)
once per hook file — if the crystal gate is already in the hook, the resolver is
too — and then:

```bash
# U+FFFD guard (from vdm-git plugin). Needs the resolver above.
# FFFD_PRECOMMIT_CHECK overrides it.
fffd_check="${FFFD_PRECOMMIT_CHECK:-$(vdm_git_gate fffd-precommit-check.sh)}"
if [ -n "$fffd_check" ]; then
  "$fffd_check" || exit 1
fi
```

Whether that chain actually resolves is a property of the machine and the
clone, not of the repository — so it is not something this plugin can report
on. A gate is wired when the chain resolves, never when its file exists.

## Configuration

Helper: `git-guard-prepare` (on PATH via the plugin's `bin/` directory).
Block hook: `${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-hook.sh` — a thin wrapper that
keeps the guard fail-closed (a missing or crashing `python3` blocks a commit-shaped
command instead of letting it through silently); the guard itself, including
`BLOCKED_PATTERNS`, is `${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-hook.py`.
Reminder: `${CLAUDE_PLUGIN_ROOT}/scripts/git-guard-reminder.sh` — gated by `enabled` / `mode` in `.claude/vdm-plugins.json`.
Subject ceiling: `git-guard.subject-max` in `.claude/vdm-plugins.json` (default 72) — see [The subject has a ceiling](#the-subject-has-a-ceiling-held-by-the-helper).
Crystal backup: `${CLAUDE_PLUGIN_ROOT}/scripts/crystal-precommit-check.sh` — see [Crystal pre-commit backup](#crystal-pre-commit-backup) above.
U+FFFD guard: `${CLAUDE_PLUGIN_ROOT}/scripts/fffd-precommit-check.sh` — see [U+FFFD](#ufffd-corruption-that-arrives-by-batch-write) above; the same check runs inside `git-guard-prepare`, where it needs no installation.
