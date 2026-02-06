#!/bin/bash

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[git-guard] Git safety active. git commit and git push are blocked until user confirms.\n- Need to commit/push? Ask user first or invoke /vdm:git-guard for pre-commit review."
  }
}
EOF
