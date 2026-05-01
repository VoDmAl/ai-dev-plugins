# Phase 3: Hook firing extensions (deferred)

**Status:** deferred
**Created:** 2026-05-01
**Owner:** —
**Trigger to revisit:** see [Decision criteria](#decision-criteria) below

## Context

Phases 1 and 2 of the hook noise reduction (shipped in `vdm` v2.1.1 and v2.2.0) introduced:
- Silent reminders on a clean working tree (phase 1).
- Per-project `.claude/vdm-plugins.json` with `enabled` + `mode` (`proactive` / `conditional` / `quiet` / `silent`) for every reminder hook (phase 2).
- Skill subcommands (`/vdm:learn off`, etc.) for managing config without manual JSON edits.

Phase 3 was scoped during phase 2 design but **deferred** because its added gradient (`quiet` distinct from `conditional`, finer triggers) only earns its keep if real-session feedback shows that the phase 2 baseline is still too noisy.

## Problem

Even with phase 2, three classes of noise can remain:

1. **`learn` is proactive by default and fires on every prompt.** That's intentional (knowledge moments are easy to miss), but means the reminder shows in 100% of turns. Some users may want it to fire only when session signals suggest a real capture moment (struggle, "fixed it" keywords).
2. **`docs-sync` and `changelog` fire whenever the tree is dirty**, including for unrelated diffs (e.g. `.serena/project.yml` churn, lockfile updates, config tweaks). Conditional firing is too coarse — it ignores *which* files changed.
3. **No deduplication.** If the same reminder fired last turn and the user already acted, it keeps firing. Habituation returns.

## Proposed extensions

### 3a. `triggers.prompt_keywords`

Per-section opt-in keyword list. When `mode=conditional|quiet`, the hook fires only if `$CLAUDE_USER_PROMPT` (or equivalent env exposed by the harness) matches at least one keyword.

```json
{
  "learn": {
    "mode": "conditional",
    "triggers": {
      "prompt_keywords": ["готово", "done", "fix", "fixed", "finally", "разобрался"]
    }
  }
}
```

**Open question:** Claude Code exposes the user prompt to hooks via env vars or stdin in some events. Need to verify which `UserPromptSubmit` payload field carries it before designing.

### 3b. `triggers.ignore_paths`

Per-section list of glob patterns. Files matching these globs don't count toward the conditional firing signal — useful for ignoring lockfile churn, IDE state files, etc.

```json
{
  "docs-sync": {
    "mode": "conditional",
    "triggers": {
      "ignore_paths": [".serena/", "*.lock", "package-lock.json"]
    }
  }
}
```

`docs-sync` already has hard-coded ignores (`.git/`, `node_modules/`, `vendor/`, `.claude/`, `.serena/`). Extension makes them user-editable.

### 3c. Real `quiet` mode with thresholds

Today `quiet` is a no-op alias for `conditional`. Phase 3 makes it actually narrower:

- `conditional`: fires when *any* relevant signal present.
- `quiet`: fires only on **strong** signals — at least N keyword matches, OR ≥ M relevant changed files (where N/M are configurable defaults).

```json
{
  "learn": {
    "mode": "quiet",
    "triggers": {
      "quiet_min_keywords": 2,
      "quiet_min_changed_files": 3
    }
  }
}
```

### 3d. (Optional) Cooldown / dedup

State file in `.claude/.vdm-state/` records last-firing timestamp per section. Hook suppresses re-firing within configurable cooldown (e.g. 5 turns or 10 minutes). Adds infrastructure (state files, cleanup), so weighed only if 3a–3c don't solve the problem.

## Decision criteria

**Revisit phase 3 when** one or more of these signals show up in real sessions:

1. **Specific complaint about `learn` proactivity:** "I'm tired of seeing the learn reminder when I'm just asking questions" → 3a (`prompt_keywords` filter).
2. **Changed-file noise:** "The `docs-sync` reminder fires every time my IDE writes `.serena/project.yml` even though I didn't touch code" → 3b (`ignore_paths`).
3. **Habituation despite phase 2:** "I'm starting to ignore the `[changelog]` reminder again because it shows up too often" → 3c (real `quiet` thresholds) or 3d (dedup).
4. **Specific feature flag needed:** user explicitly asks for prompt-aware or path-aware filtering.

**Drop phase 3 entirely when** after 3-4 weeks of phase 2 use:
- Reminders feel "right" (silent when irrelevant, present when useful).
- No habituation reports.
- Per-project `enabled: false` covers the rare full-disable cases.

## Dependencies / risks

- **Hook env access:** verifying the `$CLAUDE_USER_PROMPT` (or analogue) is reliably exposed in Claude Code and Qwen Code. If not, 3a needs an alternative signal.
- **State files:** 3d introduces persistence; needs cleanup-on-uninstall and shouldn't break if `.claude/` is gitignored.
- **Backward compatibility:** any new keys in `vdm-plugins.json` must default to current behavior — no surprises for existing users.

## Out of scope

- New hook *events* (e.g. `PostCommit`). Phase 3 stays within `UserPromptSubmit` reminders.
- Disabling the `git-guard` PreToolUse blocker. That's intentionally non-configurable for safety; if a user wants it gone, they uninstall the plugin.
- Centralized "vdm config UI" (web/TUI). YAGNI until config grows past 3-level depth.

## Implementation order (when work resumes)

1. Verify env-var availability for prompt access. **Blocker** for 3a.
2. Implement 3b (`ignore_paths`) — pure git-side logic, no env dependency. Lowest risk.
3. Implement 3a (`prompt_keywords`) if env access works.
4. Implement 3c (real `quiet` thresholds) on top of 3a + 3b.
5. Reassess whether 3d (cooldown/dedup) is still needed. Likely not.

## References

- Phase 1 commit: `daebf41` (`[!] Update changelog and docs-sync…`).
- Phase 2 PR: per-project config + skill self-config.
- Initial brainstorm: chat session 2026-05-01.
- `PROJECT_CHANGELOG.md` entries dated 2026-05-01.
