# cc-vdm-plugins — Project Notes

Two Claude Code plugins (`vdm`, `vdm-git`) live under `plugins/`. Their `lib/` folders are duplicated and must stay byte-identical (modulo cross-reference comments). A pre-commit hook enforces this.

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
