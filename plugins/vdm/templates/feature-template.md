# {Feature Name}

<!--
  Template for docs/features/{feature}.md
  Copy this file and replace placeholders with actual content.
  Remove this comment block after filling in.

  ─────────────────────────────────────────────────────────────────
  LAWS OF EVERY LONG-LIVED DOCUMENT IN THIS SUITE
  ─────────────────────────────────────────────────────────────────
  1. Current state FIRST; history separate and optional (here: the
     Changelog section at the BOTTOM, never woven into Overview/Usage).
  2. ABSOLUTE DATES ONLY — YYYY-MM-DD. "Recently" / "last release" lie
     silently a year on, because nobody re-reads a doc to re-anchor them.
  3. Identifiers live in exactly ONE place; everything else references it.
  4. Call things by name, not by a volatile number.

  A feature doc is a FRAGMENT. It says nothing about how the whole fits
  together — that is the synthesis layer's job (/vdm:docs-distill). If a
  synthesis document lists this file in its `covers:`, writing here makes
  that synthesis stale by construction: hand off.
-->

## Overview

Brief description of what this feature does for users. Focus on the value it provides, not technical implementation details.

## Usage

### Basic Usage

```
{command or interaction example}
```

### Parameters / Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--example` | What this parameter does | `value` |

### Examples

**Example 1: {Use case description}**
```
{example command or interaction}
```

**Example 2: {Another use case}**
```
{example}
```

## Configuration

<!-- Remove this section if not applicable -->

Any settings or configuration options users can adjust.

| Setting | Description | Values |
|---------|-------------|--------|
| `setting_name` | What it controls | `option1`, `option2` |

## Limitations

<!-- Remove this section if not applicable -->

- Known limitation 1
- Known limitation 2

## Implementation

Key files (for developer reference):
- `path/to/main/implementation.ext` — Main logic
- `path/to/supporting/file.ext` — Supporting functionality

## Related Features

<!-- Remove this section if not applicable -->

- [Related Feature 1](related-feature-1.md)
- [Related Feature 2](related-feature-2.md)

## Changelog

<!--
  Format: YYYY-MM-DD: Brief description of change
  Most recent entries at top
-->

- {DATE}: Initial implementation
