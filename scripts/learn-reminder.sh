#!/bin/bash

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[learn] 💡 After resolving issues or discovering patterns:\n- Found solution after struggling? → /vdm:learn to capture the journey\n- Discovered effective pattern? → /vdm:learn to preserve it\n- Made a mistake worth preventing? → /vdm:learn for safety rules\n\nClaude: PROACTIVELY invoke /vdm:learn when these situations occur."
  }
}
EOF
