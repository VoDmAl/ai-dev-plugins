#!/bin/bash
# changelog reminder — fires only when there are uncommitted changes.
# Rationale: nothing to changelog when the working tree is clean.
# In non-git directories, fall through and emit (better safe than silent).

if git rev-parse --is-inside-work-tree &>/dev/null; then
  if git diff --quiet HEAD 2>/dev/null && git diff --quiet --cached 2>/dev/null; then
    exit 0
  fi
fi

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[changelog] 📋 After completing significant work:\n- Feature/bug/arch change? → Update PROJECT_CHANGELOG.md\n- Keep entries compact: title + 1-2 sentences + refs\n- Link to docs/tasks/, docs/llm/, .serena/memories/ for details\n\nNo PROJECT_CHANGELOG.md? Run /vdm:changelog to create."
  }
}
EOF
