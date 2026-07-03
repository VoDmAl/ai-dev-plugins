---
title: "Intercom — central cross-agent/cross-session message store as /vdm:intercom"
slug: intercom-skill
description: "Ship /vdm:intercom: central mailbox outside repos, remote-slug identity, self-registering registry, receiver-side reminder"
status: in-progress
session-type: prd-work
created: 2026-07-03
last-updated: 2026-07-03
---

# Intercom — central cross-agent/cross-session message store

> Package the cross-repo "handoff" convention as a first-class `vdm` skill,
> but redesigned: a **single machine-level message store outside all repos**
> (no per-repo `.gitignore`), addressed by **git-remote-derived canonical
> identity** (not directory basename). Triggered by an incoming handoff brief
> from the t23b-content workspace (see References); the brief's per-repo
> `_outbox/` mechanism was rejected during design and superseded by this crystal.

## Назначение

Let any agent — in another repo, or a fresh session of the same repo — leave a
task brief / context note for another target, without polluting any repo's git
history and without per-repo setup. Success criteria:

- `/vdm:intercom send <target> "<title>"` writes a self-describing message into
  a central store; `check` lists what's addressed to the current project;
  `pickup` consumes it.
- Routing survives the "one project, many names" problem (this repo alone is
  `cc-vdm-plugins` / `ai-dev-plugins` / `vodmal`).
- Zero `.gitignore` edits, zero auto-commits, zero per-repo ceremony.
- Ships in the `vdm` plugin; reuses existing hook infra (`lib/config-read.sh`,
  `lib/reminder-throttle.sh`) unmodified so the vdm↔vdm-git mirror is untouched.

## Decision Log

### #1 / 2026-07-03 / Central store, not per-repo `_outbox/` + `.gitignore`

**Source:** user
**Context:** the incoming brief proposed `_outbox/<recipient>/<slug>.md` inside
each repo, git-ignored, with a per-repo `.gitignore` rule and an auto-commit of
that rule.
**Why:** user rejected per-repo `.gitignore` as «геммор адский» — it does not
scale; every participating repo needs setup and its history/ignore file touched.
A single machine-level store *outside* all repos keeps every repo clean with no
per-repo ceremony.
**Implication:** no `.gitignore` edits, no auto-commit, no per-repo infra. The
"only commit the .gitignore change" acceptance criterion from the brief is
dropped entirely. Storage path is fixed by DL #3.

### #2 / 2026-07-03 / Name `intercom`, not `handoff`

**Source:** user
**Context:** brief proposed `/vdm:handoff`.
**Why:** the frequent case is a note to the *same* agent on a clean session
(self-handoff), not only cross-agent delegation. "intercom" spans send-to-other
*and* send-to-future-self; "handoff" reads cross-only. Nuance acknowledged: this
is async store-and-forward (a mailbox), not realtime — name kept for memorability.
**Implication:** skill = `/vdm:intercom`; the on-disk store carries the name.

### #3 / 2026-07-03 / Store location — env-first, global-config fallback, default `~/.claude/vdm/intercom`

**Source:** both
**Context:** where the central store lives and how it's configured (must be
user/global, not per-project).
**Why:** resolution order — (1) `$VDM_INTERCOM_ROOT` from `~/.claude/settings.json`
env block (user's stated mechanism, harness-native); (2) `~/.claude/vdm-plugins.json`
→ `intercom.root`; (3) default `~/.claude/vdm/intercom`. Namespaced under `vdm/`
so it never collides inside `~/.claude` and becomes the home for future
machine-level vdm state. The configured value is the **full store path** (no
append magic); tilde expanded in scripts.
**Implication:** with the namespaced default, the user leaves settings untouched.

### #4 / 2026-07-03 / Identity = git-remote slug, NOT directory basename

**Source:** user (the pivotal catch)
**Context:** routing an inbox by `basename $(git rev-parse --show-toplevel)` is
fragile — this repo alone has four names: dir `cc-vdm-plugins`, remote slug
`ai-dev-plugins`, marketplace clone `vodmal`, and the sender addressed it as
`ai-dev-plugins`. Basename routing → sender writes `ai-dev-plugins/`, receiver
checks `cc-vdm-plugins/` → **silent miss**.
**Why:** the git remote slug is stable across clones (working clone and
marketplace clone share it) and is what a human naturally addresses. Canonical
resolution: (1) explicit `.claude/vdm-plugins.json` → `intercom.identity`;
(2) `git remote get-url origin` → last path segment, strip `.git`, lowercase;
(3) basename of toplevel; (4) basename of `$PWD`. Fallbacks 3–4 keep it working
in non-git dirs.
**Implication:** routing folder = `<store>/<canonical>/`; dir basename becomes a
registry *alias*, not the routing key.

### #5 / 2026-07-03 / Envelope carries explicit from/to; folder is routing only

**Source:** user («надо чтобы было четко из протокола ясно кто и кому»)
**Context:** who-sent-to-whom must be unambiguous from the protocol, not inferred
from a folder that can be renamed.
**Why:** mandatory frontmatter (`intercom: v1`, `from`, `to`, `created`, `slug`,
`status`) is the machine truth; the human FROM→TO banner is rendered from it so
they never drift. `from` is auto-computed in the sender's repo via the identity
resolver; `to` is the typed/resolved target.
**Implication:** a message is self-describing even if moved. The template owns the
envelope format.

### #6 / 2026-07-03 / Self-registering registry with aliases — in v1

**Source:** assistant (recommended), user greenlit
**Context:** a sender may address a project by any of its names; the receiver
checks only its canonical inbox.
**Why:** on first `check`/`send`, a project writes `<store>/_registry/<identity>.json`
= `{identity, aliases, remote, paths, updated}`. `send` resolves any alias →
canonical → correct inbox and warns on unknown targets. This self-heals the
multi-name problem. Registry write needs `jq`; **fails open** (skip registration;
canonical routing still works).
**Implication:** extra surface, but prevents a recurring silent-miss. Deferring it
was offered and declined.

### #7 / 2026-07-03 / Canonical granularity = repo-slug (last segment)

**Source:** both
**Context:** canonical = repo-name only vs `owner/repo`.
**Why:** single-machine use → repo-slug is unique and matches what the sender
typed (`ai-dev-plugins`). `owner/repo` and dir-basename are retained as registry
aliases for disambiguation.
**Implication:** cross-owner slug collisions handled via registry alias /
owner-qualified fallback — captured as Sidetrack #4, not built in v1.

### #8 / 2026-07-03 / Receiver-side reminder, reuse hook infra; no auto-commit

**Source:** assistant, user-aligned
**Context:** what automation, and does the skill commit anything?
**Why:** the useful nudge is receiver-side — "you have N pending messages" — fired
by a `UserPromptSubmit` hook that checks the current identity's inbox; naturally
low-noise (silent when empty). Reuses `lib/config-read.sh` +
`lib/reminder-throttle.sh` **unmodified** (→ no vdm-git mirror touched). Nothing
is committed: the store is outside all repos. Realtime push deferred (Sidetrack #1).
**Implication:** per-project `on/off/silent` via `.claude/vdm-plugins.json` →
`intercom`; global root via env / global config (DL #3).

### #9 / 2026-07-03 / v1 shipped & verified; crystal kept open for 4 enhancement побеги

**Source:** assistant
**Context:** all 11 Next-action items implemented and verified (17/17 core smoke; reminder fire/throttle/empty paths confirmed by a separate controlled test). Sidetracks #1–#4 (inotify realtime, legacy `_outbox` migration, cross-harness store, cross-owner slug collision) are genuine future enhancements, not v1 blockers.
**Why:** forcing `status: done` would require cancelling or hiding real open obligations; the completion discipline (and the orphan-sidetracks gate) correctly resist that. v1 ships as a complete, verified feature while the crystal stays `in-progress` with the four побеги as visible pending work.
**Consequence:** a `## Pending sidetracks` block carries inline `- [ ] см. Sidetrack #N` markers (DL #14 compliance). Closure path — keep open / promote-to-stem / defer — left to the user. `crystal-migrate` stays dormant until intercom closes or the user resumes it.

## Sidetracks

### #1. Realtime inotify notification

**Возникло в:** user — «дойдём потом и до realtime — будем inotify агенту
подсказывать если что-то обновилось для него».
**Описание:** instead of per-prompt polling, actively surface a new inbox message
mid-session via a filesystem watch. Future enhancement on top of the v1 poll.

**Status:** open

### #2. Migrate & retire the legacy t23b `_outbox/` prototype

**Возникло в:** reference prototype (t23b-content).
**Описание:** two real handoffs live in `~/AI Projects/t23b-content/_outbox/`
(this intercom brief + a Sulu media-metadata brief), plus a memory note and a
`.gitignore` rule. Once intercom ships: migrate them into the store and retire
the `_outbox` convention + note.

**Status:** open

### #3. Cross-harness store visibility (Claude Code vs Qwen)

**Возникло в:** DL #3.
**Описание:** a default store under `~/.claude/` is invisible to Qwen agents
(`~/.qwen/`). Consider a harness-neutral default (`~/.vdm/intercom`) or a shared
pointer so agents under different harnesses share one mailbox.

**Status:** open

### #4. Slug collision across different remote owners

**Возникло в:** DL #7.
**Описание:** two repos whose remote last-segment slug is identical (different
owners/hosts) collide on the same inbox dir. Registry aliases mitigate; consider
an opt-in owner-qualified canonical for the ambiguous case.

**Status:** open

## Next actions

v1 — реализовано и проверено (17/17 core smoke; reminder fire/throttle/empty пути
подтверждены отдельной контролируемой проверкой).

- [x] `scripts/intercom-common.sh` — sourced resolvers: `store_root`, `identity`,
      `aliases`, `resolve_target`(alias→canon), inbox enumeration, registry
      read/write. Fail-open (works without git and without jq).
- [x] `scripts/intercom.sh` — dispatcher CLI: `identity | store | register |
      check [--count] | send <to> <slug> [--title …] [--from-agent …] |
      pickup <slug> [--grow]`.
- [x] `scripts/intercom-reminder.sh` — `UserPromptSubmit` inbox reminder; reuse
      `config-read` + `reminder-throttle`; smart default + throttle; silent when
      inbox empty.
- [x] `templates/intercom-brief-template.md` — envelope frontmatter + FROM→TO
      banner + body placeholder.
- [x] `skills/intercom/SKILL.md` — convention spec, subcommand behaviors, config
      sub-commands table, config-path detection, patching rules.
- [x] `hooks/hooks.json` — register `intercom-reminder.sh` under `UserPromptSubmit`.
- [x] `plugin.json` — 2.9.0 → 2.10.0; add `intercom` to `description` + `keywords`.
- [x] `marketplace.json` — vdm entry version 2.9.0 → 2.10.0 + description.
- [x] `README.md` — document `/vdm:intercom` in the skills section.
- [x] `PROJECT_CHANGELOG.md` — ✨ FEATURE entry.
- [x] Smoke test — identity resolves to `ai-dev-plugins`; `send`→`check`→`pickup`
      round-trip against a scratch store; reminder fires only when inbox non-empty.

## Pending sidetracks

Блокирующий tail — открытые побеги: будущие улучшения, не блокеры v1. Каждый несёт
inline-маркер (DL #14), чтобы обязательство было видно completion-гейту.

- [ ] см. Sidetrack #1 — realtime inotify-нотификация (poll → watch)
- [ ] см. Sidetrack #2 — миграция + ретайр legacy t23b `_outbox/` (2 реальных брифа)
- [ ] см. Sidetrack #3 — cross-harness store (Claude Code `~/.claude` vs Qwen `~/.qwen`)
- [ ] см. Sidetrack #4 — slug-коллизия при одинаковом remote-slug у разных owner

## References

- Incoming brief (trigger; superseded design): `~/AI Projects/t23b-content/_outbox/ai-dev-plugins/handoff-skill.md`
- Prototype: t23b `_outbox/README.md` + `.claude/memory/cross-repo-handoff-convention.md`
- Shape refs: `plugins/vdm/skills/changelog/SKILL.md` (config sub-commands), `plugins/vdm/scripts/changelog-reminder.sh` (reminder shape)
- Reuses: `plugins/vdm/lib/config-read.sh`, `plugins/vdm/lib/reminder-throttle.sh`
