#!/bin/bash
# crystal-lint.sh — structural validator for crystal workitems.
#
# Answers the question no existing mechanism asked: "is this file a workitem,
# or does it merely look like one?" The crystal-completion-guard checks open
# `- [ ]` at done-transition; nothing checked the SHAPE at creation. A workitem
# written without invoking crystal-grow — the common case when an assistant
# parks a backlog item as a side artifact of other work — passed every gate.
#
# Field report that produced this (2026-08-22, repo `obsidianvault`): an agent
# inferred the workitem shape from a NEIGHBOURING file instead of the template.
# The result had no `## Назначение`, no `## Текущая модель`, no `## Sidetracks`,
# and a Decision Log written as four lines of prose with none of the fields.
# The loss that only surfaced on rewrite: the `Basis:` field forced the author
# to admit the conclusion rested on filenames and hashes, since the PDFs were
# never opened. Free prose never asks that question — so the DL format is the
# FIRST thing lost when the template is bypassed, and it is the part that was
# carrying the epistemic weight.
#
# The canon lives in the TEMPLATE, not in this script — see crystal-lint.py.
#
# Usage:
#   crystal-lint.sh <file>...              lint the named files
#   crystal-lint.sh --all                  lint every non-terminal workitem
#   crystal-lint.sh --staged               lint the STAGED version of staged workitems
#   crystal-lint.sh --print-canon          print the derived canon
#   crystal-lint.sh --hook                 read a hook JSON payload on stdin
#   [--quiet]                              suppress per-file OK lines
#   [--project-root <path>]                root for resolving relative paths
#
# `--staged` is the pre-commit surface, and it lives HERE rather than in a
# dev-repo `scripts/check-*.sh` for a reason worth stating: the canon is a FILE
# (`templates/workitem-template.md`), not a regex. The completion gate could be
# copied into vdm-git for downstream projects because its rule fits in one
# check; this one cannot, because copying it would mean copying the template —
# a second copy of the canon, which is exactly what deriving it was meant to
# prevent. So the gate ships in the plugin that owns the canon, and any project
# wires it into its own hook:
#     ${CLAUDE_PLUGIN_ROOT}/scripts/crystal-lint.sh --staged
# Same shape as check-doc-orphans.sh, which is likewise both a hook and a gate.
#
# Exit: 0 clean / 1 violations found.
#
# Fail-open everywhere: a linter bug must never block real work.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/crystal-path.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0
fi

TEMPLATE="$SELF_DIR/../templates/workitem-template.md"
LINTER="$SELF_DIR/crystal-lint.py"
[ -f "$TEMPLATE" ] || exit 0
[ -f "$LINTER" ] || exit 0

mode="files"
quiet=""
project_root=""
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all)          mode="all" ;;
    --staged)       mode="staged" ;;
    --print-canon)  mode="canon" ;;
    --hook)         mode="hook" ;;
    --quiet)        quiet="--quiet" ;;
    --project-root) shift; project_root="${1:-}" ;;
    --)             ;;
    -*)             ;;
    *)              files+=("$1") ;;
  esac
  shift
done

if [ "$mode" = "canon" ]; then
  CRYSTAL_TEMPLATE="$TEMPLATE" python3 "$LINTER" --print-canon
  exit $?
fi

# --- taxonomy, resolved once and handed to Python via env --------------------
terminal_csv="done,cancelled,superseded"
canonical_csv=""
if command -v crystal_tier >/dev/null 2>&1; then
  terminal_csv=$(crystal_tier terminal | tr '\n' ',' | sed 's/,$//')
fi
if command -v crystal_canonical_statuses >/dev/null 2>&1; then
  canonical_csv=$(crystal_canonical_statuses | tr '\n' ',' | sed 's/,$//')
fi

aliases_csv=""
if command -v jq >/dev/null 2>&1 && command -v resolve_config_path >/dev/null 2>&1; then
  cfg=$(resolve_config_path 2>/dev/null) || cfg=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    aliases_csv=$(jq -r '
      .crystal["status-aliases"] // {} | to_entries[] | "\(.key)=\(.value)"
    ' "$cfg" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  fi
fi

run_linter() {
  CRYSTAL_TEMPLATE="$TEMPLATE" \
  CRYSTAL_TERMINAL="$terminal_csv" \
  CRYSTAL_CANONICAL="$canonical_csv" \
  CRYSTAL_ALIASES="$aliases_csv" \
    python3 "$LINTER" ${quiet:+$quiet} "$@"
}

# --- --hook: PostToolUse payload on stdin ------------------------------------
# Informational, never blocking the write itself (PostToolUse fires after the
# edit landed). exit 2 routes stderr back to the assistant as feedback — which
# is the whole point: the correction arrives within one tool call, whether or
# not the skill was ever invoked. THIS is the trigger on the ACTION rather than
# on the shape of the session.
if [ "$mode" = "hook" ]; then
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
    cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None:
        break
if cur is not None:
    print(cur)
' <<<"$payload" 2>/dev/null
  }

  tool_name=$(read_field "tool_name")
  case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
  esac

  file_path=$(read_field "tool_input.file_path")
  [ -z "$file_path" ] && exit 0

  # Only workitems. Folder-stem (<root>/<slug>/workitem.md) is canonical; the
  # flat legacy form is matched by the roots check below instead.
  case "$file_path" in
    */workitem.md) ;;
    *.md) ;;
    *) exit 0 ;;
  esac

  # Confirm the file actually sits under a resolved crystal root — otherwise
  # any stray .md would be linted.
  under_root=""
  if command -v resolve_crystal_roots >/dev/null 2>&1; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$file_path" in
        "$r"/*) under_root="yes"; break ;;
      esac
    done < <(resolve_crystal_roots)
  fi
  [ -z "$under_root" ] && exit 0
  [ -f "$file_path" ] || exit 0

  out=$(run_linter "$file_path" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out" >&2
    cat >&2 <<'EOF'

[crystal-lint] This file is a workitem, so it owes the canonical shape. The
canon is derived from the template — print it with:
  ${CLAUDE_PLUGIN_ROOT}/scripts/crystal-lint.sh --print-canon

Do NOT infer a workitem's shape from a neighbouring file: a repo may hold
files imported by /vdm:crystal-migrate from a pre-crystal era, and files
written under an older canon. Neither is authoritative. The only sources of
truth are the template and /vdm:crystal-grow.

Canon is a FLOOR: extra sections and extra frontmatter keys are fine — only
the missing ones above are the problem. Fix them before this turn ends.
EOF
    exit 2
  fi
  exit 0
fi

# --- --staged: the pre-commit surface -----------------------------------------
# Lints the STAGED content, never what happens to sit on disk. That distinction
# is the whole point of a pre-commit gate: an unstaged fix does not travel with
# the commit, and an unstaged breakage is not part of it either. Same rule
# check-crystal-completion.sh follows.
#
# Each blob is materialized under a directory whose basename is preserved as
# `workitem.md`, because the linter uses that name to decide whether a file
# claims the canon at all. Violations are reported against the REAL path — a
# gate that names a temp file is a gate people learn to ignore.
if [ "$mode" = "staged" ]; then
  command -v git >/dev/null 2>&1 || exit 0
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  cd "$repo_root" 2>/dev/null || exit 0

  staged_files=$(git diff --cached --name-only 2>/dev/null) || exit 0
  [ -z "$staged_files" ] && exit 0

  roots=$(resolve_crystal_roots 2>/dev/null)
  [ -z "$roots" ] && exit 0

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t crystallint) || exit 0
  trap 'rm -rf "$tmp"' EXIT

  rc=0
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */workitem.md|*.md) ;;
      *) continue ;;
    esac

    # Must live under a resolved crystal root.
    abs="$repo_root/$f"
    under=""
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$abs" in "$r"/*) under="yes"; break ;; esac
    done <<<"$roots"
    [ -z "$under" ] && continue

    blob=$(git show ":$f" 2>/dev/null) || continue

    n=$((n + 1))
    holder="$tmp/$n"
    mkdir -p "$holder"
    # Preserve the basename: `workitem.md` is itself the claim to the canon.
    target="$holder/$(basename "$f")"
    printf '%s\n' "$blob" >"$target"

    out=$(run_linter "$target" 2>&1)
    lrc=$?
    if [ "$lrc" -ne 0 ]; then
      rc=1
      # Map the scratch path back to the path the committer recognizes.
      printf '%s\n' "$out" | sed "s|$target|$f|g" >&2
    fi
  done <<<"$staged_files"

  if [ "$rc" -eq 0 ]; then
    echo "crystal-canon: ✓ staged workitems match the canon"
  else
    cat >&2 <<'EOF'

crystal-canon: 🚨 a staged workitem does not match the canonical shape.

  Print the canon:  bash plugins/vdm/scripts/crystal-lint.sh --print-canon
  The canon is derived from plugins/vdm/templates/workitem-template.md.
  Only MISSING items are reported — extra sections and keys are always legal.

  This gate reads the STAGED content, so fix the file AND re-stage it.
EOF
  fi
  exit "$rc"
fi

# --- --all: every workitem across resolved roots ------------------------------
if [ "$mode" = "all" ]; then
  if ! command -v find_workitems >/dev/null 2>&1; then
    exit 0
  fi
  mapfile_compat=()
  while IFS= read -r f; do
    [ -n "$f" ] && mapfile_compat+=("$f")
  done < <(find_workitems)
  [ ${#mapfile_compat[@]} -eq 0 ] && exit 0
  run_linter "${mapfile_compat[@]}"
  exit $?
fi

# --- explicit files ----------------------------------------------------------
[ ${#files[@]} -eq 0 ] && exit 0
resolved=()
for f in "${files[@]}"; do
  case "$f" in
    /*) resolved+=("$f") ;;
    *)  if [ -n "$project_root" ]; then resolved+=("$project_root/$f"); else resolved+=("$f"); fi ;;
  esac
done
run_linter "${resolved[@]}"
exit $?
