#!/bin/bash

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[changelog] 📋 After completing significant work:\n- Feature/bug/arch change? → Update PROJECT_CHANGELOG.md\n- Keep entries compact: title + 1-2 sentences + refs\n- Link to docs/tasks/, docs/llm/, .serena/memories/ for details\n\nNo PROJECT_CHANGELOG.md? Run /vdm:changelog to create."
  }
}
EOF
