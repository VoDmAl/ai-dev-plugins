#!/bin/bash

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[docs-sync] ⚠️ BEFORE completing user-facing changes:\n1. Identify affected feature: docs/features/{feature}.md\n2. Update documentation to reflect current behavior\n3. Add changelog entry with date\n\nNo docs/features/? Create structure first. Run /vdm:docs-sync for full protocol."
  }
}
EOF
