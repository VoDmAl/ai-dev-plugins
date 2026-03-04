# Plugin Release Checklist

When modifying skills, hooks, or plugin behavior — ALWAYS verify before commit:

1. **Version bump**: `.claude-plugin/plugin.json` → increment version (semver)
2. **Changelog**: `PROJECT_CHANGELOG.md` → add dated entry with refs
3. **README**: `README.md` → update if skill description/behavior changed
4. **Skill description**: `skills/{name}/SKILL.md` frontmatter `description` field — update if purpose changed
5. **Hook output**: Verify hook scripts produce valid JSON (`bash scripts/{name}.sh`)

## Version Convention
- PATCH (x.x.+1): bug fixes, minor tweaks
- MINOR (x.+1.0): new features, enhanced behavior (e.g., smart discovery)
- MAJOR (+1.0.0): breaking changes, removed features
