---
name: intercom
description: "Central cross-agent/cross-session message store. Leave a task brief or note for another repo's agent — or for a future clean session of your own — with /vdm:intercom send; list and consume your inbox with check/pickup. The store lives OUTSIDE all repos (no per-repo .gitignore), routed by git-remote-derived identity. Checking your inbox is an explicit action (/vdm:intercom check); an optional receiver-side reminder exists but is OFF by default."
license: MIT
---

# intercom — central cross-agent / cross-session message store

## Purpose

Let any agent leave a task brief or context note for another target — a
different repo's agent, or a **future clean session of the same repo** (the
common "note to future me" case) — without polluting any repo's git history and
without per-repo setup.

Messages live in a **single machine-level store outside all repositories**. A
message is addressed to a project's **canonical identity** (derived from its git
remote), so routing survives the "one project, many names" problem. Nothing is
committed and no `.gitignore` is touched — the store is not inside any repo.

This supersedes the older per-repo `_outbox/` + `.gitignore` handoff pattern
(rationale upstream: `cc-vdm-plugins → docs/tasks/intercom-skill/workitem.md` → Decision Log #1).

## The convention (self-contained spec)

- **Store, not repo.** One machine-level directory holds all messages. It is
  outside every repository, so no repo's history or `.gitignore` is affected.
- **Inbox = your canonical identity.** A project's inbox is
  `<store>/<identity>/`. To send, you write into the recipient's inbox; to
  receive, you read your own.
- **Identity = git-remote slug, never the directory basename.** The same project
  has several names across clones (working clone, marketplace clone, etc.). The
  remote slug is the stable one and is what a human naturally addresses.
- **Every message opens with an explicit envelope.** Machine-readable frontmatter
  (`from`, `to`, `created`, `slug`, `status`) is the truth; the human FROM→TO
  banner is rendered from it. `from` is auto-computed in the sender's repo; `to`
  is the resolved target. This keeps "who → whom" unambiguous from the protocol.
- **Consume, then archive.** The recipient reads a message and either archives it
  (`pickup`) or promotes it into a workitem (`pickup --grow`).

## Store location (global config)

The store root resolves in this order (`scripts/intercom-common.sh`):

1. `$VDM_INTERCOM_ROOT` — set it in `~/.claude/settings.json` under `env`.
2. `~/.claude/vdm-plugins.json` → `intercom.root` (global config file).
3. Default: `~/.claude/vdm/intercom` (namespaced under `vdm/`).

The configured value is the **full store path** (a leading `~` is expanded).
Show the resolved root with `/vdm:intercom root show`.

The default is a **fixed absolute path**, not harness-derived — any harness that
runs these scripts (Claude Code, Qwen Code, …) resolves the same store, so the
mailbox is shared across harnesses out of the box. (An env / global-config
*override* lives under `~/.claude/` and is therefore Claude-scoped.)

## Identity resolution

The current project's canonical identity resolves as (DL #4, #7):

1. `.claude/vdm-plugins.json` → `intercom.identity` (explicit per-project override);
2. `git remote get-url origin` → last path segment, minus `.git`, lowercased;
3. basename of the git toplevel (non-git fallback);
4. basename of the working directory.

Print it with `/vdm:intercom identity`. Directory basename and `owner/repo`
are kept as registry **aliases**, so a sender addressing any of a project's
names resolves to the same inbox. If two different repos ever resolve to the
same identity (same remote last-segment, different owner/host), `register`
warns on the collision — set a distinct `intercom.identity` in one of them.

## Subcommands

All routing/scaffolding is done by the dispatcher script — invoke it, don't
re-derive its logic:

```
${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh <subcommand> [args]
```

| Subcommand | Behavior |
|------------|----------|
| `identity` | Print this repo's canonical identity. |
| `store` | Print the resolved store root. |
| `register` | Record this repo (identity + aliases + remote + path) in `<store>/_registry/`. |
| `check [--count]` | List (or count) pending messages for this repo; also registers it. |
| `send <to> <slug> [--title T] [--from-agent A]` | Scaffold an envelope message addressed to `<to>` and print its path. |
| `pickup <slug> [--grow]` | Archive a message to `_done/` (or, with `--grow`, hand it to `/vdm:crystal-grow`). |

### Sending a message

1. Run `intercom.sh send <target> <slug> [--title …] [--from-agent …]`. The
   script resolves `<target>` to a canonical identity (via the registry),
   creates `<store>/<canonical>/<slug>.md` from the template with the envelope
   + banner filled in, registers the sender, and prints the path.
2. **Edit that file's body**: replace the placeholder comment with the actual
   brief — what to do, why it matters, acceptance criteria, reference paths. Do
   **not** touch `from`/`to`; they are resolved.
3. Report the path to the user. **Do not commit anything** — the store is
   outside all repos.

If the script warns "no project is registered as `<target>` yet", that's the
expected first-contact case: a fresh inbox is created. The recipient will see it
once their canonical identity matches `<target>` (they can verify with
`intercom identity`).

### Receiving / picking up

When the reminder reports pending messages (or the user asks):

1. `intercom.sh check` → list what's waiting.
2. Read the message file(s).
3. Then either:
   - **Act now** → do the work, then `intercom.sh pickup <slug>` to archive it
     to `_done/` (status flips to `done`).
   - **Promote** → `intercom.sh pickup <slug> --grow`, then run
     `/vdm:crystal-grow <slug>`, seed the workitem from the message body, and
     archive with `intercom.sh pickup <slug>` once grown. Use this for a brief
     that defines real ongoing work.

## Configuration Sub-commands

`/vdm:intercom [subcommand]` recognizes these as the first word of arguments.
When no subcommand matches one of these OR one of the dispatcher subcommands
above, behave as the regular skill described here.

| Subcommand | Effect on `.claude/vdm-plugins.json` → `intercom` (per-project) |
|------------|-----------------------------------------------------------------|
| `off` / `disable` | Set `enabled = false` (reminder stays silent) |
| `on` / `enable` | Set `enabled = true` |
| `smart` | Set `mode = "smart"` (reminder fires when inbox non-empty AND throttle elapsed; **default**) |
| `conditional` | Set `mode = "conditional"` (fires whenever inbox non-empty, no throttle) |
| `quiet` | Set `mode = "quiet"` (same as conditional today) |
| `proactive` | Set `mode = "proactive"` (fires every prompt while inbox non-empty) |
| `silent` | Set `mode = "silent"` (reminder never fires) |
| `config` / `status` | Read and display the current `intercom` section |
| `reset` | Remove the `intercom` key (revert to defaults) |

**Defaults when the section is missing:** `enabled: false` (opt-in), `mode: "smart"`.
The reminder is **off by default** by design (see § Automatic activation) — turn
it on with `/vdm:intercom on`. Once on: throttle window `intercom.throttle`
seconds (default `600`), and it stays silent whenever the inbox is empty.

Store-location management (writes the **global** `~/.claude/vdm-plugins.json`,
not the per-project file):

| Subcommand | Effect |
|------------|--------|
| `root show` | Print the resolved store root |
| `root <path>` | Set `intercom.root` in `~/.claude/vdm-plugins.json` |
| `root reset` | Remove `intercom.root` from the global config |

Per-project identity override:

| Subcommand | Effect on `.claude/vdm-plugins.json` → `intercom` |
|------------|----------------------------------------------------|
| `identity show` | Print the resolved identity (`intercom.sh identity`) |
| `identity <name>` | Set `intercom.identity` (override the remote-derived slug) |
| `identity reset` | Remove `intercom.identity` |

### Config file path detection (per-project keys)

1. `project_root` = `git rev-parse --show-toplevel` (fallback: `pwd`)
2. If `<project_root>/.claude/` exists → `<project_root>/.claude/vdm-plugins.json`
3. Else if `<project_root>/.qwen/` exists → `<project_root>/.qwen/vdm-plugins.json`
4. Else create `<project_root>/.claude/` and write there.

`root` writes the **global** `~/.claude/vdm-plugins.json` regardless of the
per-project detection above.

### Patching rules

1. Read the file (if missing, start with `{}`).
2. Modify only the `intercom` key — preserve `learn`, `docs-sync`, `changelog`,
   `crystal`, `git-guard` verbatim.
3. For `reset`, delete the `intercom` key (do not leave `"intercom": {}`).
4. Use the Edit/Write tool — **do not** invoke `jq`; users may not have it.
5. Final file must be valid JSON, 2-space indent, trailing newline.

## Automatic activation

**Off by default.** Checking the inbox is an **explicit action**
(`/vdm:intercom check`) or something you ask for directly. A message that lands
mid-session is almost always meant for a *new* session, so an automatic
"you have mail" nudge would interrupt active work rather than help it.

An opt-in `UserPromptSubmit` reminder (`scripts/intercom-reminder.sh`) is
available for those who want it — enable with `/vdm:intercom on`. When enabled it
reuses the shared `config-read` + `reminder-throttle` helpers and fires only when
the current project's inbox is non-empty.

## Examples

### Send a cross-repo brief

```
/vdm:intercom send www.t23b.org media-metadata --title "Render 4 media fields" --from-agent "content agent"
# → staged <store>/www.t23b.org/media-metadata.md ; then edit the body, report the path.
```

### Note to a future clean session of your own repo

```
/vdm:intercom send <this-repo-identity> resume-here --title "Where I left off"
# self-addressed; the next session in this repo sees it via check/reminder.
```

### Consume your inbox

```
/vdm:intercom check
/vdm:intercom pickup media-metadata          # archive after acting
/vdm:intercom pickup big-refactor --grow      # promote into a workitem
```

## Integration with other skills

| Other skill | Interaction |
|-------------|-------------|
| `/vdm:crystal-grow` | `pickup --grow` promotes a message into a workitem |
| `/vdm:changelog` | The recipient logs the actual work in its own repo's changelog, not the sender's |
