---
name: intercom
description: "Central cross-agent/cross-session message store with an agent directory. Leave a task brief or note for another repo's agent — or for a future clean session of your own — with /vdm:intercom send; list and consume your inbox with check/pickup. Every repo registers itself in a machine-level directory under its canonical identity PLUS the names the user actually says (\"vdm\", \"the intercom agent\"), so a brief addressed by any of them lands on the first try; a SessionStart hook keeps that registration complete. The store lives OUTSIDE all repos (no per-repo .gitignore), routed by git-remote-derived identity. Checking your inbox is an explicit action (/vdm:intercom check); an optional receiver-side reminder exists but is OFF by default."
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
  remote slug is the stable one.
- **The directory knows every name a project goes by.** Machine-derived aliases
  (directory basename, `owner/repo`) are recorded automatically; the names the
  **user says** ("vdm", "the intercom agent") are recorded by the agent living
  in that repo, at session start, because nothing derived from a remote URL will
  ever produce them. A sender addresses any of those and the message lands in
  the one canonical inbox.
- **An unresolved address is a hard stop, not a fresh inbox.** A brief that
  lands in an inbox nobody reads looks exactly like one that was delivered.
  `send` refuses an unknown or ambiguous target, shows the nearest agents and
  names the next command; creating a brand-new inbox needs an explicit
  `--first-contact`.
- **The user's answer is recorded at the moment it is given.** When the user
  says which agent they meant, the resend carries it — `send "<hint>" <slug>
  --to <identity>` — and the hint becomes that agent's name in the same
  command. No separate "remember this" step to forget.
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

Print it with `/vdm:intercom identity`; see everything the directory knows
about you with `/vdm:intercom whoami`.

## Agent directory (the registry)

`<store>/_registry/<identity>.json` — one entry per project, maintained by the
scripts, readable by every sender:

| Field | Who writes it | What it is |
|-------|---------------|------------|
| `identity` | script | canonical inbox name (see § Identity resolution) |
| `aliases` | script | machine-derived: directory basename(s), `owner/repo` — accumulated across clones |
| `names` | **agent, from the user's words** | how the user refers to this project: `"vdm"`, `"intercom"`, `"the plugins repo"` … |
| `description` | agent | one line: what the repo is / which agent lives here — also searched when a name does not match |
| `remote`, `remotes` | script | primary remote + every remote confirmed as the same project |
| `paths` | script | every local checkout seen |
| `registered`, `updated` | script | timestamps |

A registration is **complete** when it has at least one human `name` and a
`description`. The canonical id and the auto-aliases are always there — but
they are the names a *machine* derives, and the user does not say
`vodmal/ai-dev-plugins`, the user says "vdm".

**One name routes to exactly one agent.** `register --name` and `names add`
refuse a name that already routes elsewhere (the message says where); free it
there first with `names rm --for <identity> <name>`. If two entries ever claim
the same name (hand-edited registry), resolution reports *ambiguous* and `send`
refuses until it is fixed.

Names are compared after **folding**: lowercase, whitespace and `_` → `-`. So
`"VDM Plugins"`, `vdm_plugins` and `vdm-plugins` are the same name; `www.t23b.org`
and `owner/repo` survive unchanged. Lowercasing is ASCII-only on both sides, so a
non-ASCII name (`интерком`) matches case-exactly — register it lowercase. The
fold has one implementation (in `jq`, inside `intercom-common.sh`); without `jq`
there is no directory at all and routing degrades to the canonical identity.

### How an address resolves (`resolve`, and inside `send`)

1. Exact match (after folding) against every agent's `identity`, `aliases`,
   `names` → **resolved** if exactly one agent matches; **ambiguous** (exit 3)
   if several do.
2. Otherwise **unknown** (exit 2) — with suggestions: agents whose identity /
   alias / name *contains* the input (or is contained in it), or whose
   `description` mentions it. "the intercom agent" → folded `the-intercom-agent`
   → contains the name `intercom` → suggests `ai-dev-plugins`.

### The negative scenario, step by step

The user says "напиши агенту плагинов". `send "агенту плагинов" <slug>` does not
resolve. What happens next is driven by the script's own refusal text, not by
memory:

1. **One suggestion that is clearly the one** → resend as
   `send "агенту плагинов" <slug> --to ai-dev-plugins`. The message is delivered
   there, `to_input` keeps the hint, and the hint is recorded as a name of
   `ai-dev-plugins` — next time it resolves directly.
2. **Several suggestions, or none** → `directory`, then **ask the user** which
   agent they mean. Never guess a recipient. Then resend with `--to` as above.
3. **The hint is circumstantial** ("the one from yesterday") → it is not a
   name; resend with the identity alone (`send ai-dev-plugins <slug>`) and
   nothing is recorded.
4. **The hint already routes to a different agent** and the user insists on
   another → `--to` delivers as told but does **not** move the name; the output
   says how to move it (`names rm --for … && names add --for …`) if the
   directory is wrong.
5. **The recipient has genuinely never registered** → `--first-contact` creates
   inbox `<hint>`. When that repo later registers a name that folds to `<hint>`,
   its session-start check reports an *unclaimed inbox* and offers
   `claim <hint>`, which moves the messages into its canonical inbox (rewriting
   `to:`, keeping `to_input` as the trace) and records the name.

### Second remote: mirror or collision?

Two clones of one project often have different remotes (working clone on a
private host, marketplace clone on GitHub). The registry cannot tell that apart
from two *different* projects that share a slug — but the user can. While a
clone's remote is unconfirmed, `register` warns and the session-start check
surfaces it:

- same project → `/vdm:intercom register --same-project` (adds the remote to
  `remotes`; the warning stops);
- different project → give one of them a distinct `intercom.identity`.

The primary `remote` is never overwritten by a later clone.

## Session-start identity check (hook)

`scripts/intercom-identity-check.sh` runs on `SessionStart` (**on by default**,
`intercom.identity-check: true`). It is *not* the inbox reminder: it fires once,
at session start, and says nothing mid-session. What it does:

1. **Registers the mechanical part** of this repo deterministically — identity,
   remote, auto-aliases, path. No assistant involvement, no memory to rely on.
2. **Complete registration** → one line: *"You are `<identity>` — aka: <names>"*
   plus the pending-message count. That line is the answer to "what's your
   name?" — an agent that knows its own names can also tell a sender which to use.
3. **Incomplete registration** (no `names` and/or no `description`) → the
   assistant is told to complete it **before other work**:
   - infer the names from the README title, product / plugin / skill names, the
     directory name, and how the user refers to the project in chat;
   - if they cannot be inferred with confidence, **ask the user once** — never
     invent names;
   - then `/vdm:intercom register --name "<name>" [--name "<another>"] --describe "<one line>"`
     and verify with `/vdm:intercom whoami`.
   The notice repeats every session until the registration is complete.
4. **Unclaimed inbox** whose name folds to one of this agent's names/aliases
   (a `--first-contact` send addressed to you under a name you registered
   later) → offers `/vdm:intercom claim <inbox>`.
5. **Unconfirmed second remote** → appended, with the two ways to resolve it
   (see above).

Skipped in `$HOME` and `/` (not projects — their basename would register as an
agent). Works without git (basename identity). Silent without `jq`. Opt out per
project with `/vdm:intercom identity-check off`.

## Subcommands

All routing/scaffolding is done by the dispatcher script — invoke it, don't
re-derive its logic:

```
${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh <subcommand> [args]
```

| Subcommand | Behavior |
|------------|----------|
| `identity` | Print this repo's canonical identity. |
| `whoami` | Identity + source, names, aliases, description, remotes, inbox, registration status (complete / what is missing / unconfirmed remote). |
| `store` | Print the resolved store root. |
| `register [--name N]… [--describe D] [--same-project]` | Record this repo in the directory. Without flags: the mechanical part only. `--name` (repeatable) and `--describe` supply the human part; `--same-project` confirms this clone's remote. Refuses a name that routes to another agent. |
| `names [add\|rm] [--for ID] <name>…` | List (no args) or edit human names — own entry by default, `--for <identity>` for another agent's. |
| `directory [-v]` (aka `who`, `list`, `agents`) | Every registered agent: identity, names + aliases, description, pending count; `⚠ unnamed` where the human part is missing; plus inboxes that exist with no registered agent (unclaimed first-contact sends). `-v` adds remotes and paths. |
| `resolve <name>` | Print the canonical identity `<name>` addresses; on failure list the nearest agents (exit 2 unknown, 3 ambiguous). |
| `check [--count]` | List (or count) pending messages for this repo; also registers it. |
| `send <to> <slug> [--title T] [--from-agent A] [--to ID] [--first-contact]` | Scaffold an envelope message addressed to `<to>` (identity, alias or name) and print its path. Unknown / ambiguous target = **hard stop** with suggestions and the next command. `--to <identity>` delivers there and records `<to>` as that agent's name (the resend after the user said whom they meant). `--first-contact` creates a fresh inbox for a recipient that has never registered. |
| `claim <inbox> [--force]` | Move an unclaimed inbox (no registered agent) whose name matches one of your names/aliases into your own inbox; `to:` is rewritten to your identity, `to_input` stays as the trace, the name is recorded. `--force` for an orphan that matches none of your names. |
| `pickup <slug> [--grow]` | Archive a message to `_done/` (or, with `--grow`, hand it to `/vdm:crystal-grow`). |

### Sending a message

0. Not sure who the user means? `intercom.sh directory` lists every agent with
   its names, or `intercom.sh resolve "<what the user said>"`.
1. Run `intercom.sh send <target> <slug> [--title …] [--from-agent …]`. The
   script resolves `<target>` to a canonical identity (via the directory),
   creates `<store>/<canonical>/<slug>.md` from the template with the envelope
   + banner filled in, registers the sender, and prints the path.
2. **Edit that file's body**: replace the placeholder comment with the actual
   brief — what to do, why it matters, acceptance criteria, reference paths. Do
   **not** touch `from`/`to`; they are resolved.
3. Report the path to the user. **Do not commit anything** — the store is
   outside all repos.

If `send` refuses with *no agent is registered as "<target>"*, follow the
refusal text (§ The negative scenario, step by step): resend with
`--to <identity>` once the recipient is clear — it delivers **and** records the
user's word as that agent's name; ask the user if it is not clear; use the
identity alone for a hint that is not a name. Only when the recipient genuinely
has never registered (a brand-new repo) use `--first-contact`.

### Receiving / picking up

When the session-start line (or the opt-in reminder, or the user) reports
pending messages:

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
| `identity-check on` / `identity-check off` | Set `identity-check = true/false` — the SessionStart registration check (**default `true`**) |
| `config` / `status` | Read and display the current `intercom` section |
| `reset` | Remove the `intercom` key (revert to defaults) |

**Defaults when the section is missing:** `enabled: false` (opt-in), `mode: "smart"`,
`identity-check: true`. The two defaults differ on purpose: the *reminder*
interrupts ongoing work, so it is opt-in (see § Automatic activation); the
*identity check* fires once at session start and never mid-session, so it is on.
Once the reminder is on: throttle window `intercom.throttle` seconds (default
`600`), and it stays silent whenever the inbox is empty.

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

**Inbox reminder: off by default.** Checking the inbox is an **explicit action**
(`/vdm:intercom check`) or something you ask for directly. A message that lands
mid-session is almost always meant for a *new* session, so an automatic
"you have mail" nudge would interrupt active work rather than help it.

An opt-in `UserPromptSubmit` reminder (`scripts/intercom-reminder.sh`) is
available for those who want it — enable with `/vdm:intercom on`. When enabled it
reuses the shared `config-read` + `reminder-throttle` helpers and fires only when
the current project's inbox is non-empty.

**Identity check: on by default** (§ Session-start identity check) — it is the
new session itself, not an interruption of one, and it carries the pending count
for exactly that reason.

## Examples

### Send a brief by the name the user used

```
# user: "напиши агенту vdm, что …"  /  "tell the intercom agent that …"
/vdm:intercom resolve vdm                    # → ai-dev-plugins
/vdm:intercom send vdm gates-axis-verdict --title "Gates: strength vs reach"
# → staged <store>/ai-dev-plugins/gates-axis-verdict.md  (to: ai-dev-plugins, resolved from "vdm")
```

### Register this repo's names (what the session-start check asks for)

```
/vdm:intercom register --name "vdm" --name "vdm plugins" --name "intercom" \
    --describe "Claude Code plugin suite: vdm (docs-sync, crystal-*, intercom) + vdm-git (guard)"
/vdm:intercom whoami
```

### The user's name for an agent is not in the directory yet

```
/vdm:intercom send "агенту плагинов" gates-note --title "Gates note"
# ✗ no agent is registered as "агенту плагинов" — not sending.
#   Did you mean one of these?   • ai-dev-plugins   aka: vdm, intercom, …
#   Next step: … intercom send "агенту плагинов" gates-note --to <identity>
/vdm:intercom send "агенту плагинов" gates-note --to ai-dev-plugins
# ✉️  staged … to: ai-dev-plugins (resolved from "агенту плагинов")
#     📇 recorded "агенту плагинов" as a name of `ai-dev-plugins` — next time it resolves directly.
```

### Send a cross-repo brief

```
/vdm:intercom send www.t23b.org media-metadata --title "Render 4 media fields" --from-agent "content agent"
# → staged <store>/www.t23b.org/media-metadata.md ; then edit the body, report the path.
```

### Note to a future clean session of your own repo

```
/vdm:intercom send <this-repo-identity> resume-here --title "Where I left off"
# self-addressed; the next session in this repo sees it in the session-start line and via check.
```

### Consume your inbox

```
/vdm:intercom check
/vdm:intercom pickup media-metadata          # archive after acting
/vdm:intercom pickup big-refactor --grow      # promote into a workitem
```

### Who is out there?

```
/vdm:intercom directory
# 📇 intercom directory — 18 agent(s)
#   • ai-dev-plugins   aka: vdm, intercom, cc-vdm-plugins, vodmal/ai-dev-plugins   — Claude Code plugin suite …   [📬 2 pending]
#   • nas-info   — (no description)   ⚠ unnamed
```

## Integration with other skills

| Other skill | Interaction |
|-------------|-------------|
| `/vdm:crystal-grow` | `pickup --grow` promotes a message into a workitem |
| `/vdm:changelog` | The recipient logs the actual work in its own repo's changelog, not the sender's |
