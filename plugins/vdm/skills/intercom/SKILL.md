---
name: intercom
description: "Central cross-agent/cross-session message store with an agent directory. Leave a task brief or note for another repo's agent — or for a future clean session of your own — with /vdm:intercom send; list and consume your inbox with check/pickup, and close a brief with its outcome — what was done, the link, whose ball — with /vdm:intercom reply. Every repo registers itself in a machine-level directory under its canonical identity PLUS the names the user actually says (\"vdm\", \"the intercom agent\"), so a brief addressed by any of them lands on the first try; a SessionStart hook keeps that registration complete. The store lives OUTSIDE all repos (no per-repo .gitignore), routed by git-remote-derived identity. Checking your inbox is an explicit action (/vdm:intercom check); an optional receiver-side reminder exists but is OFF by default."
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
4. **in `$HOME` or `/` — the machine**, `scutil --get LocalHostName` (macOS) or
   `hostname -s`, never the basename;
5. basename of the working directory.

Print it with `/vdm:intercom identity`; see everything the directory knows
about you with `/vdm:intercom whoami`.

### Why `$HOME` gets the machine name

`$HOME` is not a project, and its basename is not an identity — on one machine
in the field `basename $HOME` was literally `vdm`, a registered **name** of
`ai-dev-plugins`, so a single `send` from the home directory would have created
a second entry claiming that name and left `resolve vdm` ambiguous. Routing to a
repo would have been broken by standing in the wrong directory.

What such a session actually *is*, is **this machine** — and the OS already
knows its name in slug form. `LocalHostName` is machine-local **by
construction**: it lives in the system, not in `~/.claude`, which for a user who
syncs settings is shared across every machine they own. That is why the
documented `intercom.identity` override cannot express "this computer" even in
principle — the key would follow the sync and every machine would answer to one
name. Nothing to install, nothing to configure, and correct per-machine on its
own.

### Completing someone else's entry, and removing one

A registration is complete when it has at least one human `name` and a
`description`, and both are normally written by the agent that lives in that
repo. That does not scale to a directory that already has twenty entries: it
would need a session opened in each of twenty repositories, and until then the
listing cannot tell an unfinished onboarding from an accidental entry. So
`names add --for` and `describe --for` exist to finish another agent's entry
from outside.

**Names cannot be derived — only descriptions partly can.** Field pass,
2026-09-10: eleven entries were named in one sweep, and eight of the names came
from each repository's own README title. The other three came only from the user
(the short name the user gave a demo project appears in no file anywhere). Plan the step as
a confirmation pass with the user, not as automation; propose what the
repositories say about themselves and let the user correct it.

**Removal is per-item and refuses anything that looks alive.** `unregister` takes
one identity, and there is deliberately no `--prune` / `--all`. An entry that
turns out to be real is not recoverable from the listing it vanished from: the
next sender is told *no agent is registered as …*, which reads as their own typo
rather than as a deletion. A human name is the strong signal of alive — names
exist only because somebody said them — so the command refuses while any remain
and points at `names rm --for` first. The inbox is left untouched; messages are
data, and an inbox without an agent already has a name (§ orphan inboxes) and a
recovery path (`claim`).

**The order that makes removal safe is naming first.** Completing the directory
turns "which of these is a ghost?" from a guess into a residue: after the eleven
were named, exactly the two entries that were not projects — a plugin-cache
version folder and a parent directory — were the ones left unnamed. No predicate
was needed, and none was written.

### Two guards on registration

**Implicit registration needs more than a cwd basename.** `check`, `send`,
`claim` and the session-start hook register along the way — the natural "I
exist" moments — but they run from wherever the shell or the session happens to
sit. When the identity rests on nothing
sturdier than that basename (source `cwd`), they now register **nothing**. This
is what stops a version folder or a browser-profile directory from becoming an
agent. Explicit `/vdm:intercom register` is unaffected and remains the way to
say "this really is a project" — the escape hatch for genuine non-git projects.

The session-start hook joined this rule late (vdx, 2026-09-28): sessions opened
in two empty scratch directories became agents, and so did a plugin's cache
folder, `…/claude-smart/0.2.42`, where that plugin launches its own sessions.
Registering was only half of it. With no entry, the hook then told the
assistant that the registration was *incomplete* and must be finished before any
work, so the assistant would have written the entry itself. Now a directory that
has nothing but its name, and that nobody registered, gets no word from the
hook. A non-git project registered on purpose is greeted as before.

**An identity that is already someone's name is refused.** Worse than a name
clash, because resolution answers from `<registry>/<input>.json` *before* it
looks at names: the new entry would not tie, it would **win**, and silently take
over routing that used to work. `register` refuses and writes nothing, naming
the agent that owns it. Machine-derived **aliases** get the softer treatment —
one that already routes elsewhere is dropped rather than refused, because a
clone sitting in a directory that happens to share another agent's name is the
user's filesystem, not their intent. A name is intent; an alias is a guess.

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
| `paths` | script | every local checkout seen. A folder moved away leaves its old path here; nothing removes it, because the registry is shared between machines. Where two agents hold one path, the folder itself says whose it is now (its identity, resolved as above) |
| `roles` | **agent, about itself** (or `roles add --for`) | the role it holds; the directory keeps one — see § Roles |
| `registered`, `updated` | script | timestamps; `updated` moves only when the entry changes |

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
`"VDM Plugins"`, `vdm_plugins` and `vdm-plugins` are the same name; `www.example.org`
and `owner/repo` survive unchanged. Lowercasing is ASCII-only on both sides, so a
non-ASCII name (`интерком`) matches case-exactly — register it lowercase. The
fold has one implementation (in `jq`, inside `intercom-common.sh`); without `jq`
there is no directory at all and routing degrades to the canonical identity.

The store is synced between the user's machines, and an entry edited on two of
them at once leaves Syncthing's copy of the losing side beside it,
`<id>.sync-conflict-*.json`. The scripts never read such a copy as an entry;
re-registering an unchanged entry does not rewrite it, which is what made two
machines edit one file at once.

### Roles

The directory keeps **one** role: `access-layer` — the agent through which the
user's projects reach external systems (trackers, chats, mail), and whose
command `hq <project root>` says which project is whose HQ. Code that needs it
asks the directory instead of naming that agent or a path on one machine:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh" role access-layer           # → its identity
"${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh" role access-layer --path    # → its checkout on this machine
```

Its command is `bin/<its identity>` in that checkout.

- **The holder declares it**: `register --role access-layer` in its own session,
  or `roles add --for <identity> access-layer` from any session. A role has one
  holder: a second claim is refused and names the current one (free it with
  `roles rm --for <identity> access-layer`).
- **HQ and hand are not roles here.** The access layer keeps them and answers
  for them; a copy in the directory would be the same fact in a second place.
  `roles add hq` is refused and says where the answer comes from.
- Descriptive roles (product, executor) are not kept: nothing reads them.

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
at session start, and says nothing mid-session. In a focused session it
registers and prints only who the agent is and that the session is focused —
none of the items from 2 on (§ Focused sessions); with a topic, also the topic
and how many letters on it wait (§ A focused session's topic). What it does:

1. **Registers the mechanical part** of this repo deterministically — identity,
   remote, auto-aliases, path. No assistant involvement, no memory to rely on.
   Implicitly, like `check` and `send`: an identity resting on nothing but the
   directory's name is not registered, and such a directory with no entry gets
   no word from the hook at all (§ Two guards on registration).
2. **Complete registration** → one line: *"You are `<identity>` on `<machine>` —
   aka: <names>"* plus the pending-message count. That line is the answer to
   "what's your name?" — an agent that knows its own names can also tell a sender
   which to use. The machine is there for the sender on the user's other machine:
   the harness keeps this line in the session's transcript, the transcript travels
   between the machines, and `sent` / `send` read from it where the session runs
   (§ Delivery is not receipt).
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

It also reports a brief that was **filed but never archived**: a message still in
your inbox whose envelope `slug:` appears in a `<crystal>/references/*.md` copy.
That pairing means the brief was taken into a crystal, so `pickup` was owed and
never happened — and until it does, every later session reads the brief as
untouched. The join key is the envelope `slug:`, not the filename, because a
brief is routinely renamed on its way into `references/`.

This exists because archiving is a separate gesture with nothing comparing it
against anything. Field case (2026-09-11, this repo): `intercom-home-guard-missing`
was implemented, shipped, and answered — and was found still pending by a manual
sweep at the end of the session. The notice names the slug and the command, and
it disappears the moment `pickup` runs, so it cannot settle into background the
way a standing "don't forget to archive" would.

Skipped in `$HOME` and `/` (not projects). This hook carried that guard alone
for a long time while `check` / `send` / `claim` registered from any directory —
the asymmetry is gone (§ Two guards on registration), and the predicate now
lives with identity resolution rather than in one caller. Works without git
once the project is registered on purpose; until then a bare directory is
silent. Silent without `jq`. Opt out per project with
`/vdm:intercom identity-check off`.

## Subcommands

All routing/scaffolding is done by the dispatcher script — invoke it, don't
re-derive its logic:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/intercom.sh" <subcommand> [args]
```

| Subcommand | Behavior |
|------------|----------|
| `identity` | Print this repo's canonical identity. |
| `whoami` | Identity + source, names, aliases, description, remotes, inbox, registration status (complete / what is missing / unconfirmed remote). |
| `store` | Print the resolved store root. |
| `register [--name N]… [--describe D] [--role R]… [--same-project]` | Record this repo in the directory. Without flags: the mechanical part only. `--name` (repeatable) and `--describe` supply the human part; `--role` declares the role this agent holds (§ Roles); `--same-project` confirms this clone's remote. Refuses a name that routes to another agent and a role another agent holds. |
| `names [add\|rm] [--for ID] <name>…` | List (no args) or edit human names — own entry by default, `--for <identity>` for another agent's. |
| `roles [add\|rm] [--for ID] <role>…` | List (no args) or edit an agent's role — own entry by default, `--for <identity>` for another's. Only `access-layer`; one holder. |
| `role <role> [--path]` | Print the one agent holding `<role>`, or with `--path` its working checkout on this machine — never the harness's copy of a plugin repository (exit 2 nobody, 3 several, 1 no checkout here). |
| `describe [--for ID] "<one-liner>"` | Set a description. Own entry by default; `--for` completes another agent's (see § Completing someone else's entry). |
| `unregister <identity> [--force]` | Remove **one** directory entry. Refuses while the agent is addressed by a human name; `--force` overrides. Never a sweep — there is no bulk form on purpose. |
| `directory [-v]` (aka `who`, `list`, `agents`) | Every registered agent: identity, names + aliases, description, pending count; `⚠ unnamed` where the human part is missing; plus inboxes that exist with no registered agent (unclaimed first-contact sends). `-v` adds remotes and paths. |
| `resolve <name>` | Print the canonical identity `<name>` addresses; on failure list the nearest agents (exit 2 unknown, 3 ambiguous). |
| `check [--count]` | List (or count) pending messages for this repo; also registers it. |
| `send <to> <slug> [--title T] [--from-agent A] [--reply-to REF] [--body FILE] [--topic "<topic>"] [--to ID] [--first-contact]` | Scaffold an envelope message addressed to `<to>` (identity, alias or name) and print its path. Unknown / ambiguous target = **hard stop** with suggestions and the next command. `--to <identity>` delivers there and records `<to>` as that agent's name (the resend after the user said whom they meant). `--reply-to <ref>` records which letter this one continues (§ The relay form). `--body <file>` makes the file the letter's body, byte for byte (§ Sending a message). `--topic` says the letter is on the topic of the recipient's focused session, which alone takes it and is woken (§ A focused session's topic). `--first-contact` creates a fresh inbox for a recipient that has never registered. |
| `chain <slug>` | The relay chain behind a letter — every link it continues, and where each one lives right now. |
| `claim <inbox> [--force]` | Move an unclaimed inbox (no registered agent) whose name matches one of your names/aliases into your own inbox; `to:` is rewritten to your identity, `to_input` stays as the trace, the name is recorded. `--force` for an orphan that matches none of your names. |
| `take <slug> [--force]` | Mark a letter in your inbox as taken by this session before working on it (§ Receiving). Refuses a letter taken by another session unless `--force`. A `deferred:` note left by `release` goes with the new mark. |
| `release <slug> [--note "<what it waits for>"] [--force]` | The reverse of `take` (§ Receiving). Drops this session's mark; with `--note`, writes `deferred: <time> <note>` in its place, which `check` shows beside the letter and `close` counts as handled. Refuses a letter taken by another session unless `--force`, and an empty note. |
| `pickup <slug> [--grow] [--force]` | Archive a message to `_done/` (or, with `--grow`, hand it to `/vdm:crystal-grow` — the letter stays in the inbox, marked taken). Refuses a letter taken by another session unless `--force`. When the sender has a live session on this machine, prints the receipt to send it (§ Delivery is not receipt). For a brief whose outcome has not gone back yet it prints the `reply` that closes it; with `--grow` it prints that as a Next action for the crystal (§ Closing a brief with its outcome). |
| `reply <letter> (--done "<what>" [--link <url>]… --ball "<who — what ⏰ date>" \| --body FILE) [--title T] [--slug S] [--force]` | Close a letter **you received** with its outcome. It goes to the letter's sender as a `reply-to` link; recipient and link come from the envelope. Works on a letter in the inbox (archived in the same step; refused while another session has it taken, unless `--force`) or in `_done/`. `--done` and `--ball` repeat; `--ball` is required — "nobody — closed" is an answer (§ Closing a brief with its outcome). |
| `sent` (aka `outbox`) | Every letter **you** wrote that still lies unpicked in someone's inbox, oldest first, with its age and whether the recipient has a live session to wake now — or an intercom session to start (§ Intercom sessions). |
| `close` | In an intercom session, once its inbox is handled: run `vdx ai --close --waiting <n>`, n being the letters it took and left for the user. Refused outside an intercom session and while a letter nobody took is in the inbox (§ Intercom sessions). |
| `topics [<agent>]` | The topics of that agent's live focused sessions on this machine — this repository's without an argument, this session included (§ A focused session's topic). |
| `topic <letter> "<topic>"` · `topic <letter> --miss "<why>"` · `topic <letter> --missed "<topic>" "<why>"` | Name a letter's topic afterwards (its sender, or its recipient handing it on); give back a letter off your topic; record a letter on a topic that went past. Each prints whom the letter goes to now and the wake for it (§ A focused session's topic). |
| `topic-misses [--since YYYY-MM-DD]` | Every `topic-miss:` and `topic-missed:` recorded in the store, inboxes and archives, beside the number of letters a topic routed. |

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

**Send from the project.** The sender in the envelope is this directory's
identity. Outside a project it falls back to the directory's name, and unless
that directory was registered on purpose no agent answers to it — a reply
could never come back. So `send` refuses there, the same way it refuses a
recipient nobody answers to: run it from the project's checkout, or register the
directory as a project first. Field case (2026-09-29): two letters signed
`from: letters`, sent from a directory of that name outside the checkout.

**The body already exists as a file?** — typically because the project keeps a
copy of every outgoing letter and audits against it. Then send it with
`--body <file>` instead of step 2: the letter's body is that file byte for byte,
the placeholder is gone, and `send` compares the written body against the file
before it reports success. Do not splice a file into the placeholder by hand:
that needs to know where the template's comment begins and ends, and a slip in
it is a divergence between "sent" and "kept" that neither side rereads.

An empty or unreadable file, or one that still holds the template placeholder,
is refused **and nothing is written** — a letter with no body looks sent. The
body is taken as written, with no token substitution. Works with `--reply-to`.
The body is read once, so a stream is a file like any other: `--body /dev/stdin`
with a heredoc or a pipe, or `--body <(…)`; an empty stream is refused the same
way.

**An outgoing text with `channel:` goes from below its line.** A file whose
frontmatter declares `channel:` — the form `/vdm-comms:meetings` gives every
outgoing draft: frontmatter, a service header for the sender, a `---` line, the
text — is sent as the text below that line, byte for byte; the frontmatter and
the notes above the line stay in the kept copy. Such a file with no `---` line
below its header is refused, nothing written: nothing marks where the letter
starts. Any other file is still the body as a whole. Field case (HQ,
2026-10-07): a brief sent from a kept draft arrived with its frontmatter and its
notes-to-self on top, and was fixed by hand before it was read.

**The heading.** A body whose first non-blank line is a `# heading` keeps it as
the letter's heading, and the template's `# <title>` is not written above it —
a kept copy usually starts with one, and measured 2026-09-30, 142 of the 344
letters sent since `--body` appeared carried two headings in a row. When
`--title` differs from the body's heading, `send` says which one the letter
shows. A body without its own heading gets the title from `--title`, as
before.

If `send` refuses with *no agent is registered as "<target>"*, follow the
refusal text (§ The negative scenario, step by step): resend with
`--to <identity>` once the recipient is clear — it delivers **and** records the
user's word as that agent's name; ask the user if it is not clear; use the
identity alone for a hint that is not a name. Only when the recipient genuinely
has never registered (a brand-new repo) use `--first-contact`.

**One slug names one letter in an inbox — archive included.** A reference
`<identity>/<slug>` is resolved in the inbox and its `_done/`, so `send` refuses
a slug the recipient already holds in either. The refusal names the archived
letter, offers a free slug, and gives `--reply-to <identity>/<slug>` in case the
new letter continues the old one. Field case (echelon, 2026-10-06): a sender
reused a slug a day later, and the reply to the new letter was refused as
ambiguous with nothing to qualify it by. A clash already on disk — left by an
older version — `reply` handles itself: it archives the brief first, where the
clash gives it a name of its own (`<slug>.<time>`), and links the outcome to
that name.

### The relay form — reference the previous letter, never paste it

A relay is a letter that travels: A writes to B, B adds facts and passes it to
C, C to D. Each hop adds something; none of them should re-transmit what came
before.

**Measured on the whole store, 2026-09-22: one relay in 318 letters** — and it
arrived as 64 KB with two levels of `>` quoting, 288 of its 550 lines being
text the last recipient had already been able to read. Nothing forced that.
The store is **one machine-level directory and every inbox is a sibling**, so
the previous letter was openable by path the entire time. What was missing was
a form for naming it.

```bash
intercom.sh send <to> <slug> --title "…" --reply-to <ref>
```

`<ref>` is `<identity>/<slug>`, or a bare `<slug>` when only one letter carries
it. Both the inbox and its `_done/` archive are searched, so a letter that has
already been picked up still resolves.

What it does, and deliberately no more:

- writes **`reply-to: <identity>/<slug>`** into the envelope — an address, not
  a copy;
- renders a `↩ **CONTINUES:**` line in the banner naming the previous letter
  and its title;
- makes `check` print what an incoming letter continues, and `chain <slug>`
  walk the whole way back.

**The chain is derived, never stored.** Each letter names only its immediate
predecessor; `chain` follows the links. So there is no list to keep in sync,
and a link that moves (inbox → `_done/`) cannot make a stored path lie. A
missing link and a cycle are both **reported by name** rather than ending the
walk quietly — a chain that stops early looks exactly like a chain that was
complete.

**An unresolvable `--reply-to` is a hard stop and nothing is written.** Same
law as an unresolvable recipient: a letter naming a letter that does not exist
is worse than no letter, because the reader cannot tell a broken link from an
unbroken one. Ambiguity refuses too, and names every candidate.

When you are the one continuing a relay: write **only what you are adding**,
and reference the rest. The recipient can open every link.

### Receiving / picking up

When the session-start line (or the opt-in reminder, or the user) reports
pending messages:

1. `intercom.sh check` → list what's waiting.
2. Read the message file(s). A letter `check` shows as **taken by** another
   session is that session's — leave it. Unless `check` says *that session is
   gone*: the mark names a session of this machine, and none by that name is
   live here — its pid answers nothing, or its socket is gone. Nobody removes
   the mark when a session ends, so the letter waits for no one: take it over
   with `intercom.sh take <slug> --force`. A mark from the user's other machine
   is not checked from here, and `check` says so; it stays that session's
   unless the user says that session is over.
3. Before you start on a letter, take it: `intercom.sh take <slug>` — the first
   step, before you read it in depth or touch anything; `check` prints the
   command beside every letter nobody has taken. The mark
   (`taken: <machine>/<session> <time>`) reaches the user's other machine within
   about a minute, so the list you read may already be stale: `take` refuses a
   letter taken elsewhere, and that refusal is the check that holds — leave the
   letter and tell the user. `pickup`, `reply` and the wake leave a letter taken
   elsewhere alone too, but by then the work is done twice (field case, echelon,
   2026-10-21: two works, six Syncthing conflicts). `--force` takes over from a
   session that is gone; `check`, `sent` and the refusal of `take` name it when
   that session is of this machine. A note you only archive needs no mark.
   A letter you took that waits for something outside the inbox — another
   agent's move, a deploy, the user's word — goes back with its reason:
   `intercom.sh release <slug> --note "<what it waits for>"`. The mark goes,
   `deferred: <time> <note>` takes its place, `check` shows the note and the
   `take` that picks it up again, and `close` counts it as handled. The note
   names what the letter waits for — an answer, a deploy, a date — not a
   session: a session ends, and a note waiting for it then says nothing (hq,
   2026-10-29: three letters released "for session X", X closed). Without
   `--note` the letter is simply given back. Field case (a demo project's agent, 2026-10-24): a
   letter asked for a change only after another agent's move, which had not
   happened; with no way back the mark of a closed session would have stayed on
   it and refused the next one, and it was removed by hand with `sed`.
   A note to yourself is read against the clock: `pickup` prints the local time
   beside it. A move the note binds to a later time («с утра», «завтра») is named
   deferred, not proposed — the note may have been written for the morning and
   picked up the same evening (field case, 2026-10-21). Two things are not a
   later time. A due date (`due:`, «по сроку», ⏰) is a deadline, not a start:
   the item can be done now. A move bound to an event («после сбора») is due once
   the event happened — check whether it has before calling it deferred. Field
   case (echelon, 2026-10-24): every dated item of a note was read as deferred
   and the owner was told «сегодня ничего»; one waited on an event two hours
   past, the others carried `due:`.
4. Then either:
   - **Act now** → do the work, then `intercom.sh reply <slug> --done … --ball …`:
     the outcome goes to the sender and the letter is archived in the same step.
     A letter that asks for nothing — a note, an answer to yours — is archived
     with `intercom.sh pickup <slug>` (status flips to `done`).
   - **Promote** → `intercom.sh pickup <slug> --grow`, then run
     `/vdm:crystal-grow <slug>`, seed the workitem from the message body, add the
     Next action it prints (the outcome owed to the sender), and archive with
     `intercom.sh pickup <slug>` once grown. Use this for a brief that defines
     real ongoing work.

     Seeding is retelling, not pasting: the workitem belongs to your repository,
     and the brief is another agent's text, addressed to you rather than to
     whoever reads your repository. Its address goes into `Basis-detail`. In a
     published repository, the retelling names people and other agents by role
     (crystal-grow → the provenance rule), and so does the printed
     `Outcome to <sender>` line. `reply` reads the recipient from the letter's
     envelope, so the name in that checkbox is only a label.

**The user's pending steps come first.** Mail that arrives mid-session — a
wake, the opt-in reminder, a receipt — is almost never urgent, and the user may
be in the middle of steps you handed them: a commit to run, a push, a decision
to make. Then, in that turn:

- do only what needs no user: read the letter, `pickup`, a one-line receipt or
  reply;
- leave the full review — memory, docs, answers, new work — until the user has
  closed their steps or tells you to switch;
- **mail that comes in while the user is in the conversation gets one line**, at
  the end: "letter X is waiting". That holds for the arrival line on the user's
  message (§ Delivery is not receipt) and for a wake that started a turn anyway.
  No retelling of the open steps or questions: they stand on the screen right
  above, and a table of them only pushes the user's own text away;
- repeat the user's open steps, as ready commands, only when the turn went
  into the mail and the steps scrolled out of sight. A step that scrolled out of
  sight is a step the user has to go and find.

Field case (product, 2026-09-25): the user had been handed a commit, a push,
an MR and a Jira comment; a mail reminder arrived, the session switched to the
mail, and the steps ended up far up the screen. The owner: *"if something
important is expected from the user — don't grab it; or do, but briefly, and
only what needs no human."* That is why every wake pointer and the opt-in
reminder end with "not urgent: the user's pending steps come first".

The second field case runs the other way (echelon, 2026-10-01): the user was
answering a round of questions, a wake made a turn, and the turn ended with a
table of the open questions — the very ones the user was answering, already on
the screen. The user: *"you are busy with me, you can't answer automatically
anyway — you just keep me from focusing."* Retelling the steps is for steps that
are out of sight, not for a conversation in progress.

### Closing a brief with its outcome

A brief is closed by its **outcome** reaching the sender, not by being picked
up. Field case (product, 2026-09-29): a brief said "return nothing if you close
it in the tickets"; the item was closed by a comment in the ticket, posted
through the external-access tool, and the sender was told nothing. The sender's
track kept the obligation on the owner, who had done their part. A collector
that gathers ticket comments would have brought it in hours later, and not tied
to the obligation it closed.

So:

- **An action here that closes an item of a brief** — a comment, a merge, a
  deploy, an answer to a person — sends the outcome back **in the same turn**,
  even when the brief asked for nothing back. A collector is the fallback, not
  the channel.
- **Partly done is still an outcome**: what is done, what remains, and whose
  ball the rest is.
- The outcome states three things: **what was done, where** (the link), and
  **whose ball it is now, by when**. The last one is the one that gets forgotten,
  and it is the one the sender's track needs.

```bash
intercom.sh reply <slug> --done "<what was done>" --link <url> \
  --ball "<who holds the ball — what ⏰ YYYY-MM-DD>"
intercom.sh reply <slug> --body <file>          # an outcome you wrote out in full
```

The recipient and the `reply-to` link come from the letter's own envelope, so
there is nothing to look up. The letter may still be in the inbox (then it is
archived in the same step) or already in `_done/` (the crystal path). `--done`
and `--ball` repeat, one per item. Each `--ball` is rendered as an open item,
`- [ ] <who — what ⏰ date>`, the shape of a pending line, so the sender can
move it into its track as it stands. When nothing is left: `--ball "nobody —
closed"`. A second outcome of the same brief gets a slug of its own.

The outcome is named `<slug>-outcome`, and `<slug>-outcome-<your identity>` when
the same brief also lies in another agent's inbox or archive — one brief sent to
several agents. Whether a name is free is checked on this machine only; two
agents answering one brief from two machines got one name, and Syncthing kept
the second answer as `<slug>-outcome.sync-conflict-…` (2026-10-09). `check`
lists such a copy as the second letter it is and offers its `pickup` by the
copy's own file name.

**One answer closing several briefs** names each of them in its text. `reply-to`
holds one link, and intercom counts a brief as answered when **a letter from you
to its sender names its slug** — measured on the store 2026-09-29, a third of the
briefs that no `reply-to` pointed at had been answered in exactly that way.

Where intercom sees a brief taken without its outcome, it says so:

- **`pickup`** of a letter from someone else that is not itself an answer, and
  that no letter of yours back to its sender names, prints the `reply` that closes
  it.
- **`pickup --grow`** prints the outcome as a Next action for the new crystal:
  the work starts after the letter is archived, and a named checkbox is held by
  the crystal's completion gate, not by memory.
- **`reply`** whose ball you hold yourself — an item `<you> — <what>`, under any
  name the directory knows you by — prints that item to write into your
  crystal's Next actions, unless an open item of a crystal here already holds
  it. The letter goes to the sender's store and nothing in your repository
  reminds you. Field case (2026-10-23): a promise made in a reply was found
  undone two weeks later, when the fault it was about came back.

`reply` answers **your own inbox** only. Continuing someone else's letter is a
relay: `send <to> <slug> --reply-to <ref>` (§ The relay form). A letter whose
envelope names a sender no agent answers to is refused with its own message,
nothing archived: find out who wrote it, then answer with `send <identity> …
--reply-to <you>/<slug>`.

### Delivery is not receipt

A letter in an inbox is read only when somebody runs `check`. Field case
(hq → product, 2026-09-14): a reply lay unread while the recipient's
session was alive and working next to it; a brief beside it lay three days; the
sender counted both as delivered. Measured on the whole store 2026-09-24: about
110 letters unpicked, 20 from one sender, the oldest 19 days — and nobody saw
it, because `check` shows only what came in.

So three things happen on top of the inbox, and none of them replaces it:

- **`send` names the recipient's live sessions on this machine** — sessions of
  the harness whose working directory lies inside one of the recipient's
  registered checkouts, with a live process and socket — and **which one to
  wake**. When it prints `→ wake one: <session>`, wake that one session in the
  same turn with your cross-session message tool (Claude Code: `SendMessage`),
  using the text it printed. That text is a **pointer**: its first line names
  the slug and the sender, and it ends with how to read the letter. Never paste
  the brief into it — the inbox stays the truth. After a scaffolding `send`,
  wake only once the body is written; with `--body` the letter is complete and
  you wake at once. When it prints `→ do not wake here`, wake nobody: the
  letter waits, and the line says for what. When it prints `📮 … start it`,
  run the command it names instead, and wake nobody (§ Intercom sessions).
- **Not a session the user may be at.** A message into an idle session starts a
  turn at once, and into a busy one it lands in the middle of the work — either
  way on the screen the user is reading or typing into. So the session is woken
  only after standing **idle for 15 minutes** or longer — `idle`, or `shell`
  (the turn is over, a background task of the session still runs); `busy` (a
  turn is running), `waiting` (a question or a permission on its screen) and any
  other status make the letter wait. Measured 2026-10-13 on 4327 of the user's turns:
  half came within 3.3 minutes of the turn before them, 78% within 15. A letter
  that waits reaches that session as **one line with the user's next message**
  there (below) — no turn of its own. A session file without a status, or idle
  with no time stamp, gives no verdict and is woken as before.
- **One session, where the user typed last.** A project may have sessions on
  two of the user's machines, and a cross-session message reaches only this
  one. The harness marks every turn the user typed (`"turnOrigin":"human"` in
  the session's transcript under `projects/`, which travels between the
  machines). `send` wakes the live session here that holds the user's last turn
  in the recipient's project; if that turn is in a session not on this machine,
  nobody is woken here; with no turn of the user's in the last 12 hours, it
  wakes one session here, the most recently active of those nobody may be at.
  The session where the user typed last is not swapped for another when the
  user may be at it: the letter waits for it.
- **The arrival line — on by default.** On the user's next message in a
  session, the `UserPromptSubmit` hook names every letter that came into the
  inbox after that session started and has not been named in it yet — each
  once, none that a session has taken — as context of that message:
  `📬 Arrived while the user was in this session …`. Letters that were there
  at the start were named by the session-start line. This is how a letter that
  was not woken still reaches the session within minutes; answer it by the rule
  in § Receiving / picking up → "The user's pending steps come first": one line at the end. Off per project
  with `intercom.arrival-line: false`.
- **`pickup` offers a receipt**: when the sender has a live session, it prints
  `→ send a receipt to one: <session>` and the text
  `✅ intercom: <slug> picked up by <you>` — send it the same way, by the same
  rule.
- **`sent` shows your side**: every letter you wrote that is still unpicked,
  its age, and who can be woken right now. The session-start line adds
  `📤 N of your letters lie unpicked for 3+ days` when there are any. A
  recipient with no live session can only be reached by their next `check` —
  or by the user, who can be told.
- **No live session here is not none anywhere.** When the recipient has no
  live session on this machine, `sent` — and `send`, when there is something to
  say — names where one was last active: *"on `<machine>` one was active 3 min
  ago; it cannot be woken from here"*, from the transcripts, which travel between
  the user's machines and carry the session-start line with the machine in it. A
  focused one is named as focused; a session started before that line named its
  machine is *"not recorded"*; nothing in the last 12 hours is said as such. It
  says *active*, never *live*: a transcript does not record that its session
  closed. Field case (2026-10-20): `sent` said "no live session" for a recipient
  whose session had been open on the user's other machine for two days, its
  transcript written that minute.

A harness without cross-session messages, or a machine where the recipient has
no live session and none is seen elsewhere, behaves as before: nothing is
printed by `send`, and nothing is required. Live sessions are read from the harness's own session files
(`${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/`); a copy synced from another
machine, a dead process or a missing socket never counts as live, and your own
session is never listed.

### Focused sessions — deaf to mail

A session started with `vdx ai --focused` carries `VDX_FOCUSED=1` and works on
its own task. The user's words: a mode in which the session does not go reading
letters on its own and nobody nudges it. Field case (2026-10-08): a session the
user had opened as "isolated, without intercom" was woken twice, because it was
where the user had typed last; after the first pointer it went off to read what
nobody had asked it to.

- **Nobody wakes it** — except with a letter on its topic (§ A focused session's
  topic). `send`, `sent` and the receipt after `pickup` leave it out
  of the live sessions entirely. A turn the user typed into it is passed over,
  and the turn before it decides whom to wake; when the recipient has no other
  live session here, nothing is printed, as for a recipient with none.
- **It is not called to its inbox.** Its session-start line says who it is and
  that it is focused, with no count of pending letters, no letters of its own to
  chase, no request to finish the registration first. The opt-in reminder stays
  silent in it.
- **Letters still arrive.** They lie in the inbox and are read when the user
  asks: `/vdm:intercom check` works as always. A focused session may send too —
  it is deaf, not mute.

The flag is read from the session's own process, not from a mark in the store:
the environment a process was started with cannot outlive the session, nor
follow a resume that started without the flag. Guards such as git-guard are not
nudges and keep working.

### A focused session's topic — the letters on it are its own

The user (2026-10-27): focused mode keeps a session on its topic and stops it
drifting; a letter on that topic the session may read and be woken with, and
the other sessions of the project leave it alone. Misses both ways are expected
— they are to be seen and made fewer.

vdx gives the topic (0.41.0): `vdx ai --focused "<topic>"`, or the agent sets it
from the user's first message, and it may change during the session. It is the
tmux option `@vdx_topic` of the agent's tmux session, read through the session's
process environment (`TMUX`, `TMUX_PANE`); nothing is stored here. No tmux, or no
option: a focused session with no topic, deaf as above.

- **The sender judges.** The letter is at hand on the sender's side; a focused
  session that read every letter to decide whether it is its own would be the
  leak the mode is for. `intercom.sh topics <agent>` prints the topics of that
  agent's live focused sessions on this machine; `send … --topic "<topic>"`
  writes `topic:` into the envelope. A `send` without `--topic` names the topics
  there are, before any wake, with the line that names one afterwards:
  `intercom.sh topic <identity>/<slug> "<topic>"` — run it before waking anyone.
- **The measure is the session's subject** — the options, people and tasks of
  its crystal — not which session or channel started the exchange. Field case
  (2026-10-27): a focused HQ session called a correspondence another session's
  work because the neighbouring session had started it, while its subject was an
  option from its own crystal; the user corrected it — a letter on the topic that
  went past.
- **Intercom only compares.** The field against the option of a live focused
  session of the recipient on this machine, whole, after one cleaning on both
  sides (one line, single spaces). A session on another machine compares with
  its own tmux; the field travels with the letter.
- **A letter on a live session's topic is that session's**, as a taken letter
  is, with no mark written. `take`, `pickup`, `reply` and `release` in any other
  session refuse it (`--force` only on the user's word); `check` there says to
  leave it; `close` does not count it as open. `send` and `sent` wake that
  session alone, by the rule of any session the user may sit at: not while it is
  busy, waiting, or idle under 15 minutes — then the letter reaches it as one line
  with the user's next message there. No intercom session is started or woken for
  it. The topic changes or the session ends, and the letter is ordinary again.
- **In the focused session** the start line names the topic and counts the
  letters on it; the arrival line names only letters on its topic; `check` marks
  such a letter as its own.
- **Corrections are misses, and are counted.** A letter given to it off its topic
  the focused session gives back: `topic <slug> --miss "<why>"` drops `topic:`,
  writes `topic-miss: <session> <time> «<topic>» — <why>`, and prints whom the
  now ordinary letter goes to. An intercom session that finds a letter on a
  focused session's topic hands it on: `topic <slug> "<topic>"`. A letter on a
  topic that went past is recorded by its recipient or its sender:
  `topic <letter> --missed "<topic>" "<why>"`, in the inbox or the archive — one
  still in the inbox and taken by nobody is handed over too. `topic-misses
  [--since YYYY-MM-DD]` lists both marks across the store beside the number of
  letters a topic routed: the material for the review of misses with vdx.

### Intercom sessions — the inbox is their work

A session started with `vdx ai --intercom` carries `VDX_INTERCOM=1` (the name is
vdx's to settle) and is the project's intercom session: the one that takes its
letters. The user's words (2026-10-20): the agent is not interrupted by
messages, and everybody gets messages faster and answers each other. The
user's own session runs `--focused` beside it and stays quiet. Read from the
process, like focused; a session started with both is focused. Before vdm
2.65.0 it was the "mail session", and older letters and transcripts say so.
The user read that as a session for their e-mail (2026-10-28), so the name in
anything the user reads is "intercom session" ("сессия intercom").

- **Woken at once.** When the recipient has a live intercom session on this
  machine, `send`, `sent` and the receipt after `pickup` wake that one, ahead
  of the session where the user typed last and without the 15-minute window:
  nobody sits at it. Its pointer says what to do — *"You are the intercom session:
  take it and handle it — /vdm:intercom check"* — with no "not urgent". The
  live list marks it `(idle, mail)`. On the user's other machine it is named
  from its transcript, like any session: *"its intercom session was active 2 min
  ago"*.
- **The inbox is the work.** Its session-start line says so instead of the
  pending count: check now and at every wake, then each letter in turn — take,
  read, act, close with `reply` or `pickup`, or `release --note` one that waits
  for something outside the inbox.
- **What stays out of it.** Work that changes the code is left for the user's
  main session as a crystal (`/vdm:crystal-grow`, or `/vdm:crystal-bud` on an
  active one): the two sessions share one working tree, and an edit here rides
  into the other's commit. A question for the user is not asked in its pane,
  which nobody reads: one line goes to the user's list at HQ (the access
  layer's `hq <project root> --obligations` names it), and the session takes
  the next letter without waiting for the answer.
- **A chain between intercom sessions stops.** A letter written in an intercom session
  carries `session: mail` in its envelope. When an intercom session continues a
  chain (`send --reply-to`, `reply`) whose last 3 links all carry it, the
  link is refused with exit 4 and nothing is written; the question goes to
  the user at HQ instead, and `reply` leaves the brief in the inbox. A link
  from any other session — one the user works in — ends the run. The user
  accepted the rule as a condition of the mode, since agents answering each
  other fast may agree on what is the user's to decide; the count of 3 is ours.
- **Started by the sender, where it is switched on.** A letter that arrives by
  sync starts nothing by itself, so the sender starts the recipient's mail
  session on its own machine. That happens when three things hold: the
  recipient's checkout here has `intercom.session: true` in its
  `vdm-plugins.json` (the older key `intercom.mail-session` is still read;
  when both are set, `session` decides), no intercom session of it is live here, and the vdx here is
  0.36 or later. A checkout is a working clone: the harness's own copy of a
  plugin's repository (`…/plugins/marketplaces/<name>`, `…/plugins/cache/…`)
  gets the committed key too and is passed over — nobody works there, and the
  harness does not trust it. `role --path` passes it over the same way. Then `send` (and `reply`) prints `📮 … start it with your shell
  tool` and the command, `vdx ai --intercom --detach '<checkout>'`. Run it in
  the same turn — after the body is written, as with a wake. vdx keeps one mail
  session per project and machine, so a second start does nothing. Its first
  turn is `/vdm:intercom check`, so no wake follows the start and no other
  session is woken: two sessions would only do the letter twice. `sent` names
  the same start for a letter still lying there. With vdx missing or older, a
  line says so and the letter goes as without it. The key is off by default
  and is set by hand, because every intercom session is a whole agent session. The
  user's word (2026-10-22): only where it was switched on. And (2026-10-27):
  where mail piles up, the key is offered. With five letters from other agents
  in the inbox, the oldest three days old, and no key, the session-start line
  says so (`📨`): offer the intercom session to the user once, in one line; the key
  is the project's own commit. The sender's `sent` names such recipients in one
  line after the list. A note to oneself is not counted, nor is a recipient
  with no working checkout here. One case where the
  start does not happen: a checkout Claude Code does not trust yet on this
  machine (a new folder, or one that moved). From vdx 0.39 nothing starts
  there: the command exits 4 and prints the one to run at a terminal. Hand that
  command to the user, who runs it once and answers the trust prompt; the
  letter waits in the inbox meanwhile. An older vdx answers `✓ running`, and
  the session waits at that prompt with nobody at it. `send` says so beside
  the start.
- **A note to its own project is not its mail.** A letter from the project to
  itself, a note for its next session (`/vdm:wrap`), neither starts nor wakes
  the intercom session. Its start line tells it to leave such a letter untaken: if
  the intercom session archived the note, it would never reach the session it was
  written for.
- **It ends itself with `close`.** Once the inbox is handled, the intercom session
  says what was done and runs `/vdm:intercom close`. That is refused outside an
  intercom session, and while a letter nobody took is in the inbox (one may have
  come in after the last check); one released with a note is handled. Otherwise it runs `vdx ai --close --waiting
  <n>`, n being the letters in the inbox it took and left for the user — and
  those a session of this machine took and is gone, which wait for the user
  too — read from `taken:` and kept nowhere. vdx marks the project's other tmux sessions on
  this machine with that n and closes the intercom session's pane; the turn ends on
  its result.

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
`identity-check: true`, `arrival-line: true`, `session: false` (no subcommand for the last two: set them in the file). The two defaults differ on purpose: the *reminder*
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

**Arrival line: on by default** (§ Delivery is not receipt). It is not the inbox
reminder: it names only letters that came in *during* this session, each once,
and only because the sender did not wake the session — the user may have been at
it. It rides on the user's own message and starts no turn.

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
/vdm:intercom send www.example.org media-metadata --title "Render 4 media fields" --from-agent "content agent"
# → staged <store>/www.example.org/media-metadata.md ; then edit the body, report the path.
```

### Note to a future clean session of your own repo

```
/vdm:intercom send <this-repo-identity> resume-here --title "Where I left off"
# self-addressed; the next session in this repo sees it in the session-start line and via check.
```

Leaving for a clean session? `/vdm:wrap` decides whether the note is needed at
all, and what goes into the crystal instead. The note is one of its three
carriers, and it points to the crystal rather than retelling it.

### Consume your inbox

```
/vdm:intercom check
/vdm:intercom reply media-metadata --done "Tags written for 214 photos" \
  --link https://example.org/mr/42 --ball "sender — review the tag list ⏰ 2026-10-03"
                                              # close a brief with its outcome
/vdm:intercom pickup release-note             # archive a letter that asks for nothing
/vdm:intercom pickup big-refactor --grow      # promote into a workitem
```

### Who is out there?

```
/vdm:intercom directory
# 📇 intercom directory — 18 agent(s)
#   • ai-dev-plugins   aka: vdm, intercom, cc-vdm-plugins, vodmal/ai-dev-plugins   — Claude Code plugin suite …   [📬 2 pending]
#   • home-server   — (no description)   ⚠ unnamed
```

## Integration with other skills

| Other skill | Interaction |
|-------------|-------------|
| `/vdm:crystal-grow` | `pickup --grow` promotes a message into a workitem |
| `/vdm:changelog` | The recipient logs the actual work in its own repo's changelog, not the sender's |
