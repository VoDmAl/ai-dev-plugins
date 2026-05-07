# Soft Guidance vs Deterministic Gates

## Purpose

This repo's most repeated lesson: when an invariant matters, putting it in
`CLAUDE.md` or `SKILL.md` ("the assistant should …") is **necessary but not
sufficient**. Soft guidance is read by an LLM whose context, fatigue, and
self-justification can route around it. Without a deterministic gate, the
invariant drifts.

The right pattern: write the rule down for orientation **and** add a gate that
enforces it without relying on LLM compliance.

## When to promote a soft rule to a gate

Promote when **all** are true:

1. **The invariant is structural** — a property of the repo, the build, or the
   release that should hold for every contributor in every commit. Not a
   stylistic preference.
2. **Drift has concrete downstream cost** — broken consumer, shipped behavior
   without notice, knowledge invisible to future sessions, etc. The cost
   shows up somewhere measurable.
3. **The rule has been violated at least once despite being documented** —
   hindsight is the cheapest signal that soft guidance has reached its
   ceiling.

If only (1) and (2) hold but the rule is brand new, *try soft guidance first*.
Don't preempt with friction the project hasn't earned. But once you see (3),
ship the gate — adding more text to the same surface that just failed is the
canonical anti-fix.

## Precedents in this repo

### lib-sync (mirrored config helpers)

**Soft form that failed.** "Keep `plugins/vdm/lib/` and `plugins/vdm-git/lib/`
byte-identical." Lived in CLAUDE.md and README.

**Deterministic form that holds.** `scripts/check-lib-sync.sh` does a `diff`
modulo cross-reference comments; `.githooks/pre-commit` invokes it whenever
the commit stages anything under `plugins/{vdm,vdm-git}/lib/**`. Drift blocks
the commit with a precise report.

### Plugin version bump on any plugin file change

**Soft form that failed (round 1).** Implicit pattern visible only in
`PROJECT_CHANGELOG.md` titles (`vdm v2.1.1`, `vdm-git v2.1.0`). Not enforced;
not even named as a rule. An agent edited three files in `plugins/vdm/`
without bumping `plugin.json` — caught only by user RCA after the fact.

**First gate (incomplete).** `scripts/check-version-bump.sh` was added with
just the bump check: any file staged under `plugins/X/**` requires a version
diff in `git show :plugins/X/.claude-plugin/plugin.json` vs HEAD. The same
agent then bumped `plugin.json` correctly but left `.claude-plugin/marketplace.json`
at the old version — same class of error, one layer down. The catalog still
advertised the previous version, so downstream consumers wouldn't even see the
update.

**Deterministic form that holds (round 2).** Same script, two checks:

1. *Bump check (conditional, as before).*
2. *Marketplace parity (unconditional).* For each plugin, the
   `plugins[].version` in `.claude-plugin/marketplace.json` must equal the
   `version` in `plugins/X/.claude-plugin/plugin.json`. Runs on every
   pre-commit invocation regardless of which files are staged — the parity
   has to hold *always*, not just when those files happen to be touched.

The lesson behind round 2: when you ship a gate, ask "what's the smallest
state the gate doesn't see?" — the agent will find it. Here, the bump check
saw `plugin.json` but ignored `marketplace.json`. A gate is only as useful as
its smallest blind spot.

### Dev-tree paths in user-time files

**Soft form that failed.** Implicit understanding that `plugins/*/skills/**/SKILL.md`
and templates ship to user projects, so paths inside them must resolve at
user time. Not encoded as a rule. Same agent that produced the
marketplace-parity miss above also wrote `plugins/vdm/scripts/check-llm-orphans.sh`
into `docs-sync/SKILL.md` and `learn/SKILL.md` as if it were a path users
would have. At user time those paths don't resolve at all — the plugin lives
under `${CLAUDE_PLUGIN_ROOT}`, wherever Claude Code installed it.

**Deterministic form that holds.** `scripts/check-skill-paths.sh` runs
unconditionally on every commit, greps the user-time files for `plugins/(vdm|vdm-git)/(scripts|lib|hooks|templates|skills)/` substrings and fails with a remediation
message naming the specific lines. Bare plugin names ("the vdm plugin") are
not flagged — only concrete subpaths.

The lesson here is the same as the marketplace-parity round: the original
scope-confusion was named in `CLAUDE.md` ("this CLAUDE.md is dev-time only")
but the *symptom* — leaking dev paths into user-time text — wasn't itself
gated. Naming the rule isn't enough when the rule has a tractable
machine-detectable expression. Promote it.

### docs/llm/ discovery hook

**Soft form that failed.** SKILL.md text saying "Cross-references enable
future discoverability." Quality Gate: "No knowledge orphaned." An agent
created `docs/llm/feature-gated-modules.md` without any back-reference and
talked itself into the omission ("the abstract rule in CLAUDE.md already
covers it").

**Deterministic form that holds.**
- `plugins/vdm/scripts/check-llm-orphans.sh` — pure-shell audit. Looks for
  four hook categories (CLAUDE.md, source-code comment, `docs/features/` ref,
  sibling `docs/llm/` ref) and discounts `PROJECT_CHANGELOG.md` matches.
- `plugins/vdm/scripts/orphan-guard-hook.sh` — `PostToolUse` hook fired after
  every `Write`/`Edit`/`MultiEdit` to `docs/llm/*.md`; calls the audit on the
  one path; exit 2 with stderr if orphan, so the assistant cannot leave the
  orphan and finish the turn quietly.
- `/vdm:docs-sync` Phase 1.5 calls the same audit as a periodic sweep for
  files that already exist.

## Anti-patterns to avoid

**More text in the same surface that just failed.** When SKILL.md already
said "no orphans" and that failed, adding "no, REALLY no orphans" doesn't
change the failure mode. The fix isn't louder language; it's a layer that
doesn't depend on language.

**Hooks that only emit reminders.** A `UserPromptSubmit` reminder ("don't
forget to bump the version") is still soft guidance — it sits in context
alongside everything else and competes for attention. Use a reminder when
soft surfacing is genuinely sufficient (most are); use a gate when the cost
of drift earns the friction.

**Tying enforcement to a single harness.** A `PostToolUse` hook works in
Claude Code; it's silent in Qwen Code. A pre-commit hook works in any
contributor's shell regardless of harness. Layer the gates: pre-commit catches
every commit; harness-specific hooks add real-time feedback inside one IDE.

**Conflating dev-time gates and user-time hooks.** `.githooks/pre-commit` is
dev-time (only contributors to *this* repo see it; downstream users of the
published plugins don't). `plugins/vdm/hooks/hooks.json` is user-time (every
project that installs the plugin gets it). Place each gate where its
constraint actually applies — don't ship a dev-only gate inside the plugin,
and don't try to enforce a runtime user invariant via a contributor hook.

**Conflating dev-time CLAUDE.md with the plugin's user-time contract.** This
repo's `CLAUDE.md` is auto-loaded only when developing this repo. The plugins
do **not** ship `CLAUDE.md` to user projects — when a target project installs
the plugin, only `plugins/*/skills/**/SKILL.md` and the registered hooks
govern. Writing a user-time rule into this `CLAUDE.md` is invisible at the
place it's supposed to apply. Place user-time rules in `SKILL.md` (read by
the assistant when the skill is invoked) or in hook output (surfaced when
hooks fire). Reserve this `CLAUDE.md` for invariants that only matter while
working **on** the plugins themselves.

**Gating without a remediation message.** Exit 1 with no stderr is hostile.
Every gate's failure path must explain what to do — name the file, name the
fix, give the exact command if possible.

## Implementation template

When promoting a soft rule to a gate:

1. **Write a pure-shell audit script** at `scripts/check-{invariant}.sh` (repo
   level) or `plugins/vdm/scripts/check-{invariant}.sh` (plugin level). Exit
   codes: 0 clean, 1 violated (with remediation on stderr), 2 usage error.
   Avoid `jq`/`python3` for parsing if grep+sed will do — matches existing
   convention, keeps the script portable.
2. **Wire it into the right gate type:**
   - **Repo-level dev gate** → extend `.githooks/pre-commit` to call the
     script when relevant files are staged.
   - **User-level harness gate** → declare a `PostToolUse`/`PreToolUse`/
     `UserPromptSubmit` entry in `plugins/X/hooks/hooks.json` that runs a thin
     hook delegate (`*-guard-hook.sh`) which forwards into the audit script.
3. **Document the rule in CLAUDE.md.** The gate enforces; CLAUDE.md explains.
   They complement, not substitute. Without the gate the rule drifts; without
   the documentation the gate failure is mysterious.
4. **Add a `PROJECT_CHANGELOG.md` entry** when shipping. The repo records its
   own evolution; "we promoted this rule to a gate after incident X" is the
   exact thing future-you will need.

## References

- `scripts/check-lib-sync.sh` — first gate in this repo.
- `scripts/check-version-bump.sh` — manifest version gate.
- `plugins/vdm/scripts/check-llm-orphans.sh` — orphan audit, single source of
  truth shared by `/vdm:docs-sync` Phase 1.5 and the `PostToolUse` hook.
- `plugins/vdm/scripts/orphan-guard-hook.sh` — `PostToolUse` delegate.
- `.githooks/pre-commit` — dev-time gate router.
- `plugins/vdm/hooks/hooks.json` — user-time hook registration.
