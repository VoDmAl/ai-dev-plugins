# {Topic Name}

<!--
  Template for docs/llm/{topic}.md
  Technical documentation for LLM/developer reference.
  Focus on HOW things work, not WHAT users can do.
  Remove this comment block after filling in.

  ─────────────────────────────────────────────────────────────────
  ⚠️  DISCOVERY HOOK CHECKLIST — required before this file is "done"
  ─────────────────────────────────────────────────────────────────
  Only CLAUDE.md is auto-loaded into every LLM session. Without a
  back-reference, this file is orphan: it sits on disk but future
  sessions can't reach it until someone happens to grep for the topic.

  Before declaring this doc complete, verify AT LEAST ONE exists:
    [ ] CLAUDE.md mentions this file (preferred for cross-cutting
        rules / anti-patterns the assistant must always know)
    [ ] A source-code comment points here, e.g.
          # See docs/llm/{this-file}.md    (shell / python)
          // @see docs/llm/{this-file}.md  (js / ts / go / php / …)
    [ ] A sibling docs/features/ or docs/llm/ doc links here
        (acceptable as a secondary hook, not the only one)

  Enforcement: the orphan-guard PostToolUse hook (Claude Code) runs the
  audit on this file immediately after Write/Edit and blocks with exit 2
  if no hook is present. /vdm:docs-sync Phase 1.5 runs the same audit as
  a periodic sweep. Both delegate to the audit script shipped with the
  vdm plugin.
-->

## Purpose

What problem does this solve? Why does this pattern/approach exist?

## Current Implementation

### Architecture Overview

Brief description of how this is structured.

```
{ASCII diagram or structure representation if helpful}
```

### Key Components

| Component | Responsibility |
|-----------|---------------|
| `ClassName` | What it does |
| `function_name()` | What it does |

### Code Patterns

**Pattern 1: {Pattern name}**

When to use:
- Condition 1
- Condition 2

```{language}
// Example code demonstrating the pattern
```

**Pattern 2: {Pattern name}**

When to use:
- Condition 1

```{language}
// Example code
```

## Integration Points

How this connects with other parts of the system:

- **{Component A}**: How they interact
- **{Component B}**: How they interact

## Common Operations

### {Operation 1}

```{language}
// How to perform this operation
```

### {Operation 2}

```{language}
// How to perform this operation
```

## Error Handling

How errors are handled in this area:

| Error Type | Handling Strategy |
|------------|------------------|
| `ExceptionType` | What happens |

## Testing

How to test this functionality:

```bash
# Test command if applicable
```

Key test files:
- `tests/path/to/test.ext`

## Gotchas / Warnings

<!-- Things that might trip up developers -->

- ⚠️ Warning 1: Explanation
- ⚠️ Warning 2: Explanation

## References

- [Related doc 1](path/to/doc.md)
- [External resource](https://example.com) — What it covers
