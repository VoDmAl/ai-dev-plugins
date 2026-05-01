# cc-vdm-plugins — Project Notes

Two plugins (`vdm`, `vdm-git`) live under `plugins/`. They run under multiple AI coding harnesses — Claude Code (primary) and Qwen Code (via `qwen-extension.json`). Their `lib/` folders are duplicated and must stay byte-identical (modulo cross-reference comments). A pre-commit hook enforces this.

## Authoring standard: agent-agnostic skill text

When writing prompts, hook output, or instructions inside `plugins/**/skills/**/SKILL.md` and `plugins/**/scripts/**`:

- **Don't hardcode the assistant's name** ("Claude", "Qwen", "GPT", etc.). The same files load under multiple harnesses, and naming one model implicitly tells the others "this isn't for you."
- **Use generic terms** instead: "the assistant", "the AI assistant", "you (the assistant)", or `Assistant:` as a label prefix.
- **OK to mention by name:** product-level harness names (`Claude Code`, `Qwen Code`) when describing where files live or which install path is used — e.g. `.claude/` vs `.qwen/`. That's harness, not agent identity.

**Why:** plugins ship through multiple marketplaces; agent-agnostic text means a single source of truth and no per-harness forks. Caught during the v2.2.0 work — fix touched 5 files (guard SKILL.md, learn SKILL.md, learn-reminder.sh, hook output) where "Claude" had crept in.

## Dev setup (one-time per clone)

Activate `.githooks/` so the lib-sync pre-commit check runs locally:

```bash
git config core.hooksPath .githooks
```

A SessionStart hook in `.claude/settings.json` warns if this isn't set, but does **not** auto-fix `.git/config` — the activation gesture is left to the user.

If you see `[vdm-dev] Dev hooks not active in this clone…`, run the command above.

## Where things live

- `plugins/vdm/` — core plugin (docs-sync, learn, changelog skills)
- `plugins/vdm-git/` — optional git safety plugin (guard skill)
- `plugins/{vdm,vdm-git}/lib/` — **mirrored** config helpers (drift-checked by `scripts/check-lib-sync.sh`)
- `scripts/check-lib-sync.sh` — manual run of the drift check
- `.githooks/pre-commit` — runs the drift check before any commit that stages `plugins/{vdm,vdm-git}/lib/**`
- `scripts/ensure-githooks.sh` — SessionStart warner (warn-only check that `core.hooksPath=.githooks`)

See `README.md` → Development for the full developer protocol.
