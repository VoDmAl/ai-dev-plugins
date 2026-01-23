---
name: learn
description: "PROACTIVELY capture knowledge. Auto-invoke when: (1) finding solutions after struggling with issues - the struggle itself is valuable to document, (2) discovering effective patterns worth preserving, (3) making mistakes that should never repeat, (4) establishing new project standards. Claude SHOULD invoke this automatically after resolving complex problems WITHOUT waiting for user request."
license: MIT
---

# learn - Universal Knowledge Integration

## Purpose

Systematically capture and preserve project knowledge for future LLM sessions. Automatically detects scenario type and routes through appropriate analysis before integrating knowledge across multiple storage locations.

**Integration with docs-sync**: This skill complements `/vdm:docs-sync` — while docs-sync focuses on `docs/features/` (user-facing), learn focuses on `docs/llm/` (technical/LLM-facing) and cross-cutting knowledge preservation.

## Usage

```bash
/vdm:learn "Knowledge to capture or situation to analyze"
/vdm:learn "Database migration failed and deleted tables"      # Problem → troubleshoot
/vdm:learn "Found excellent caching pattern for API calls"     # Discovery → document
/vdm:learn "API errors should follow RFC 7807 format"          # Standard → systematic
```

## EXECUTION INSTRUCTIONS

**YOU MUST follow these tool invocation rules:**

### For PROBLEM scenarios:
```
Use Skill tool: skill="sc:troubleshoot", args="--systematic"
```
After troubleshoot completes, extract insights and proceed to knowledge integration.

### For DISCOVERY scenarios:
```
Use Task tool: subagent_type="technical-writer", prompt="Document the following pattern/discovery for docs/llm/: {user input}. Follow llm-template.md structure. Focus on: Purpose, When to Use, Implementation with code examples, Gotchas."
```

### For STANDARD scenarios:
```
Use Task tool: subagent_type="technical-writer", prompt="Create systematic documentation for this standard: {user input}. Determine if safety-critical (→ CLAUDE.md) or operational (→ docs/llm/)."
```

### For Serena Memory operations:
```
Use mcp__serena__write_memory tool: memory_file_name="{topic}_procedure", content="..."
```

### For docs/llm/ file creation/updates:
```
Use Write or Edit tools targeting docs/llm/{topic}.md
```

## Automatic Scenario Detection

The skill analyzes input to determine the best processing route:

### Problem Indicators → Troubleshoot Route

**Triggers**: error, failed, broken, disaster, problem, issue, bug, crashed, "went wrong", "didn't work", unexpected

**Process**:
1. Invoke `/sc:troubleshoot --systematic --root-cause-analysis`
2. Extract root cause and resolution insights
3. Route findings to appropriate knowledge locations

**Example**:
```
/vdm:learn "Auth tokens keep expiring unexpectedly"
→ Detected: Problem scenario
→ Route: /sc:troubleshoot
→ Output: Root cause analysis → knowledge integration
```

### Discovery Indicators → Technical Writer Route

**Triggers**: pattern, best practice, standard, approach, found, discovered, learned, observed, "working solution", "effective method"

**Process**:
1. Activate technical-writer mindset
2. Document pattern with context and examples
3. Update `docs/llm/` with structured documentation

**Example**:
```
/vdm:learn "Alpine.js x-effect works great for reactive dashboards"
→ Detected: Discovery scenario
→ Route: Technical documentation
→ Output: docs/llm/frontend-patterns.md update
```

### Standard Indicators → Systematic Documentation Route

**Triggers**: rule, convention, requirement, guideline, establish, define, "must always", "never do"

**Process**:
1. Analyze standard for scope and criticality
2. Determine appropriate storage locations
3. Create cross-references for discoverability

**Example**:
```
/vdm:learn "All API responses must include request-id header"
→ Detected: Standard scenario
→ Route: Systematic documentation
→ Output: CLAUDE.md rule + docs/llm/api-conventions.md
```

## Knowledge Routing Decision Matrix

**CRITICAL PRINCIPLE**: Keep CLAUDE.md lean — only truly critical safety rules.

### → CLAUDE.md Critical Rules

**Criteria** (ALL must apply):
- Safety violations that can cause data loss or unauthorized actions
- Historical disasters that must never repeat
- Absolute prohibitions: "NEVER do X under any circumstances"

**Limit**: Maximum 2-3 new rules per learn execution

**Format**:
```markdown
## Critical Rules
N. **Rule title** — Brief explanation (historical context if applicable)
```

### → Serena Memory (write_memory)

**Best for TRANSIENT knowledge that may become outdated**:
- Current environment configuration (may change with infrastructure updates)
- Session workflows (processes that evolve over time)
- Cross-session context (project-specific state that changes)
- Temporary workarounds (until proper fix is implemented)

**NOT for permanent technical knowledge**:
- ❌ Version conflicts (e.g., PHPUnit 9.6 vs 10.5) → use docs/llm/ instead
- ❌ API constraints that won't change → use docs/llm/ instead
- ❌ Tool incompatibilities → use docs/llm/ instead

**Key question**: "Will this knowledge become stale if I don't update it?"
- YES → Serena Memory (ephemeral, needs maintenance)
- NO → docs/llm/ + CLAUDE.md Quick Access (permanent)

**Format**:
```bash
write_memory("{topic}_procedure", "Step-by-step operational knowledge")
```

### → docs/llm/ Technical Documentation

**Best for**:
- Technical patterns with code examples
- Framework-specific best practices
- Detailed multi-step procedures
- Integration guidelines and anti-patterns
- Architecture decisions and rationale

**Format**: Use `templates/llm-template.md` structure

### Routing Decision Tree

```
Is this a SAFETY-CRITICAL rule that prevents disasters?
├─ YES → CLAUDE.md (brief rule) + docs/llm/ (details)
└─ NO
   ├─ Is this PERMANENT technical knowledge (version conflicts, API behaviors, tool quirks)?
   │  └─ YES → docs/llm/ + CLAUDE.md Quick Access (permanent, won't become stale)
   ├─ Is this TRANSIENT operational procedure (current env setup, workflow that may change)?
   │  └─ YES → Serena Memory (session-persistent, may become outdated)
   └─ Is this TECHNICAL pattern knowledge (patterns, architecture)?
      └─ YES → docs/llm/
```

**Key distinction**:
- **PERMANENT** = Version conflicts, API constraints, tool incompatibilities → docs/llm/ (won't change without code change)
- **TRANSIENT** = Environment variables, current workflow steps, session context → Serena Memory (may need updates)

## Integration with Technical Writer Principles

When documenting discoveries and patterns, apply these principles:

**Audience Focus**: Write for future LLM sessions, not humans. Include context that helps LLM understand when/how to apply knowledge.

**Clear Structure**: Use consistent headings: Purpose → When to Use → Implementation → Examples → Gotchas

**Working Examples**: Always include code samples that can be directly used or adapted.

**Anti-Patterns**: Document what NOT to do alongside correct approaches.

## Integration with docs-sync

| Aspect | docs-sync | learn |
|--------|-----------|-------|
| Focus | `docs/features/` (user-facing) | `docs/llm/` (technical) |
| Trigger | Code changes | Knowledge capture |
| Output | Product documentation | Technical patterns |
| Audience | Users, stakeholders | LLMs, developers |

**Complementary Usage**:
```bash
# After implementing a feature
/vdm:docs-sync              # Update user-facing docs
/vdm:learn "Pattern used"   # Capture technical knowledge
```

## SuperClaude Integration

### Agent Routing — EXPLICIT TOOL CALLS

| Scenario | Tool Call |
|----------|-----------|
| Problem | `Skill(skill="sc:troubleshoot", args="--systematic")` |
| Discovery | `Task(subagent_type="technical-writer", prompt="Document pattern...")` |
| Standard | `Task(subagent_type="technical-writer", prompt="Create standard docs...")` |

### MCP Server Usage — EXPLICIT TOOL CALLS

| Purpose | Tool |
|---------|------|
| Write operational knowledge | `mcp__serena__write_memory(memory_file_name, content)` |
| Read existing memories | `mcp__serena__read_memory(memory_file_name)` |
| List memories | `mcp__serena__list_memories()` |
| Create/update docs/llm/ | `Write` or `Edit` tools |

## Execution Protocol

### Phase 1: Scenario Detection

Analyze user input for keywords:

```
🔍 Analyzing input for scenario type...

PROBLEM keywords: error, failed, broken, disaster, problem, issue, bug, crashed, "went wrong", "didn't work", unexpected
DISCOVERY keywords: pattern, best practice, approach, found, discovered, learned, observed, "working solution"
STANDARD keywords: rule, convention, requirement, guideline, establish, define, "must always", "never do"

📋 Detected: {Problem|Discovery|Standard}
   Indicators: {matched keywords}
   Route: {tool to invoke}
```

### Phase 2: Execute Route

**IF Problem detected:**
```
→ Invoke: Skill(skill="sc:troubleshoot", args="--systematic")
→ Wait for troubleshoot results
→ Extract: root cause, resolution, prevention measures
```

**IF Discovery detected:**
```
→ Invoke: Task(subagent_type="technical-writer", prompt="Document this pattern for docs/llm/: {input}. Use llm-template structure.")
→ Wait for documentation draft
```

**IF Standard detected:**
```
→ Invoke: Task(subagent_type="technical-writer", prompt="Analyze this standard for documentation: {input}. Determine criticality level.")
→ Wait for analysis and documentation
```

### Phase 3: Knowledge Routing

Based on analysis results, determine storage locations:

```
📍 Knowledge routing decision:
   CLAUDE.md: {Yes/No — only if safety-critical, max 2-3 rules}
   Serena Memory: {Yes/No — if operational procedure}
   docs/llm/: {Yes/No — if technical pattern/details}
```

### Phase 4: Integration — ACTUAL TOOL CALLS

**For CLAUDE.md updates:**
```
→ Read(file_path="CLAUDE.md")
→ Edit(file_path="CLAUDE.md", old_string="...", new_string="...with new rule...")
```

**For Serena Memory:**
```
→ mcp__serena__write_memory(memory_file_name="{topic}_procedure", content="...")
```

**For docs/llm/:**
```
→ Check if file exists: Glob(pattern="docs/llm/{topic}*.md")
→ If exists: Edit(file_path="docs/llm/{topic}.md", ...)
→ If not: Write(file_path="docs/llm/{topic}.md", content="...from template...")
```

### Phase 5: Verification

```
✅ Knowledge integrated:
   - CLAUDE.md: {rule added, if any}
   - Memory: {key written, if any}
   - docs/llm/: {file updated/created, if any}

🔗 Cross-references verified
```

## Examples

### Example 1: Problem → Multi-Location Knowledge

**Input**: `/vdm:learn "Unauthorized git commits happened, broke production"`

**Detection**: Problem (keywords: "unauthorized", "broke")

**Output**:
```markdown
# CLAUDE.md (NEW RULE)
N. **ALWAYS ask before git commits** — Prevents unauthorized commits to production

# Serena Memory: git_safety_protocol
"Pre-commit checklist: 1. Confirm user wants commit 2. Review staged files 3. Verify branch"

# docs/llm/git-safety.md
## Git Commit Safety Protocol
[Full documentation with context, examples, recovery procedures]
```

### Example 2: Discovery → Pattern Documentation

**Input**: `/vdm:learn "Found that Alpine.js x-data with $watch handles form state elegantly"`

**Detection**: Discovery (keywords: "found", "elegantly")

**Output**:
```markdown
# docs/llm/alpine-patterns.md (UPDATED)
## Form State Management with x-data and $watch

### When to Use
- Complex forms with interdependent fields
- Real-time validation requirements

### Implementation
[Code example with explanation]

### Gotchas
- Watch callbacks run on initial mount
- Deep watching requires specific syntax
```

### Example 3: Standard → Systematic Documentation

**Input**: `/vdm:learn "All database migrations must be reviewed before execution"`

**Detection**: Standard (keywords: "must be", implies requirement)

**Output**:
```markdown
# CLAUDE.md (if safety-critical)
N. **Review all migrations before execution** — Prevents data loss from auto-generated SQL

# Serena Memory: migration_checklist
"1. Generate migration 2. Review SQL for DROP/DELETE 3. Test on dev 4. Execute"

# docs/llm/database-migrations.md
[Full migration safety protocol with examples]
```

### Example 4: Permanent vs Transient Knowledge

**Input**: `/vdm:learn "Use composer test:unit:phpunit, not bin/phpunit — version conflict"`

**Detection**: Discovery (keyword: "use"), but requires PERMANENCE analysis

**Analysis**:
- Is this transient? NO — PHPUnit version conflict (9.6 vs 10.5) is baked into project structure
- Will it become stale? NO — won't change unless composer.json or Symfony Bridge changes
- Conclusion: PERMANENT technical knowledge

**Output**:
```markdown
# docs/llm/testing-standards.md (PERMANENT)
⚠️ PHPUnit Version Conflict Warning
- bin/phpunit uses Symfony Bridge with PHPUnit 9.6
- composer.json requires PHPUnit 10.5
- ALWAYS use: composer test:unit:phpunit

# CLAUDE.md Quick Access (PERMANENT reference)
- **PHPUnit Tests**: `composer test:unit:phpunit` (NEVER use bin/phpunit — version conflict!)

# ❌ NOT Serena Memory — this is permanent, not transient
```

**Contrast with transient knowledge**:
```
/vdm:learn "Current dev server uses port 8080 instead of 8000"
→ This IS transient (may change with next docker-compose update)
→ Route to Serena Memory
```

## Manual Override Flags

When automatic detection needs adjustment:

```bash
/vdm:learn "topic" --force-problem      # Force troubleshoot route
/vdm:learn "topic" --force-discovery    # Force direct documentation
/vdm:learn "topic" --force-standard     # Force systematic establishment
```

Routing control:
```bash
/vdm:learn "topic" --critical-only      # Only CLAUDE.md update
/vdm:learn "topic" --memory-focus       # Prioritize Serena Memory
/vdm:learn "topic" --docs-focus         # Prioritize docs/llm/
```

## Quality Gates

**Knowledge integration is NOT complete until:**

- [ ] Scenario correctly detected and routed
- [ ] Appropriate agents/analysis completed
- [ ] Knowledge routed to correct location(s)
- [ ] CLAUDE.md updated ONLY if truly critical (max 2-3 rules)
- [ ] docs/llm/ follows template structure
- [ ] Cross-references enable future discoverability
- [ ] No knowledge orphaned or made inaccessible

## Templates

Use templates from this plugin for consistent documentation:

- `templates/llm-template.md` — For `docs/llm/{topic}.md` files

When creating new `docs/llm/` files, copy the template and fill in:
- Purpose (why this knowledge exists)
- Current Implementation (how it works)
- Code Patterns (with examples)
- Gotchas/Warnings (what to avoid)
