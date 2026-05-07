#!/bin/bash
# orphan-guard-hook.sh — PostToolUse hook for Write/Edit/MultiEdit operations.
#
# Fires after the assistant writes to docs/llm/*.md. If the just-written file
# has no discovery hook (CLAUDE.md back-ref, source-code comment, sibling doc,
# or feature-doc reference), surfaces a blocking error so the assistant has to
# add a hook before declaring the turn complete.
#
# Source of truth for the orphan-audit contract is plugins/vdm/scripts/
# check-llm-orphans.sh — this hook just routes a single file path into it.
#
# Hook protocol (Claude Code):
#   stdin   JSON {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
#   exit 0  no-op (nothing to flag)
#   exit 2  stderr surfaces as feedback to the assistant — used here when
#           the just-written docs/llm/ file is orphan
#
# Configuration: respects .claude/vdm-plugins.json → docs-sync.enabled flag,
# since this is conceptually part of the docs-sync invariant. Fail-open on any
# unexpected error: never block the assistant on a hook bug.

set -u
# Note: deliberately NOT using `set -e` or an ERR trap. We want to swallow
# unexpected failures (fail-open) only at known boundaries — not at every
# expected non-zero exit from the audit script.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || true

# Honor the docs-sync enable flag if config-read is available. If config-read
# isn't loaded (graceful degradation), default to enabled.
if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "docs-sync" || exit 0
fi

# Read tool-use payload. Use python for robust JSON parsing — the alternative
# (sed/awk on JSON) is fragile when content contains escaped quotes/newlines.
payload=$(cat)
[ -z "$payload" ] && exit 0

read_field() {
  FIELD_PATH="$1" python3 -c '
import json, os, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
cur = data
for part in os.environ.get("FIELD_PATH", "").split("."):
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if cur is not None:
    print(cur)
' <<<"$payload" 2>/dev/null
}

tool_name=$(read_field "tool_name")
[ -z "$tool_name" ] && exit 0

# We care about file-creating/modifying tools. Edit/MultiEdit may also touch
# docs/llm/ files; treat them the same way.
case "$tool_name" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(read_field "tool_input.file_path")
[ -z "$file_path" ] && exit 0

# Match docs/llm/*.md only. The path may be absolute (typical for Write) or
# relative; check-llm-orphans.sh handles both.
case "$file_path" in
  *docs/llm/*.md) ;;
  *) exit 0 ;;
esac

# Resolve project root the same way the audit script does. Canonicalize via
# cd+pwd -P so that macOS /tmp ↔ /private/tmp (and similar symlinks) don't
# break the prefix comparison the audit script does for path normalization.
cwd=$(read_field "cwd")
[ -z "$cwd" ] && cwd="$(pwd)"

if root=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); then
  project_root=$(cd "$root" 2>/dev/null && pwd -P) || project_root="$root"
else
  project_root=$(cd "$cwd" 2>/dev/null && pwd -P) || project_root="$cwd"
fi

# Convert the absolute file_path into a project-relative form to side-step any
# remaining symlink-vs-real-path mismatches. If the file lives outside the
# project root, fall through with a no-op exit.
case "$file_path" in
  /*)
    file_dir=$(dirname "$file_path")
    file_base=$(basename "$file_path")
    file_dir_real=$(cd "$file_dir" 2>/dev/null && pwd -P) || file_dir_real=""
    if [ -z "$file_dir_real" ]; then
      exit 0
    fi
    case "$file_dir_real" in
      "$project_root"|"$project_root"/*)
        rel_dir="${file_dir_real#"$project_root"}"
        rel_dir="${rel_dir#/}"
        if [ -n "$rel_dir" ]; then
          relative_path="$rel_dir/$file_base"
        else
          relative_path="$file_base"
        fi
        ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    relative_path="$file_path"
    ;;
esac

audit_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-llm-orphans.sh"
[ -x "$audit_script" ] || exit 0

# Run the audit on this single file. Capture stderr for the feedback message.
# We deliberately let exit 1 propagate without triggering set -e (we don't
# have it set) and capture it via $?.
audit_stderr=$("$audit_script" --file "$relative_path" --project-root "$project_root" --quiet 2>&1 >/dev/null)
audit_exit=$?

if [ "$audit_exit" -eq 1 ]; then
  # Orphan detected. Re-emit the audit's remediation message on stderr and
  # return exit 2 so the assistant sees it as actionable feedback.
  printf '%s\n' "$audit_stderr" >&2
  cat >&2 <<EOF

[orphan-guard] /vdm:learn Phase 4 requires a discovery hook for every NEW
docs/llm/*.md. Without one, the file is invisible to future LLM sessions.
Add the hook (CLAUDE.md back-ref OR source-code @see comment) BEFORE this
turn ends.
EOF
  exit 2
fi

exit 0
