#!/bin/bash
# check-llm-orphans.sh — audit docs/llm/*.md files for discovery hooks.
#
# A discovery hook is a back-reference from somewhere a future LLM session can
# realistically find: CLAUDE.md (the only auto-loaded file), source-code
# comments, docs/features/ entries, or other docs/llm/ siblings.
# PROJECT_CHANGELOG.md mentions are intentionally excluded — they describe
# history, not a discovery path.
#
# Source of truth for the orphan-audit contract. The /vdm:docs-sync skill and
# the orphan-guard PostToolUse hook both shell out to this script rather than
# reimplementing the logic, so behavior stays consistent.
#
# Usage:
#   check-llm-orphans.sh                     # audit every docs/llm/*.md
#   check-llm-orphans.sh --file PATH         # audit one file (used by hook)
#   check-llm-orphans.sh --project-root DIR  # override repo root
#   check-llm-orphans.sh --quiet             # suppress 'all clean' line
#
# Exit codes:
#   0  clean — no orphans, or no docs/llm/ to audit
#   1  at least one orphan found
#   2  usage error

set -eu

usage() {
  cat >&2 <<EOF
Usage: $0 [--file PATH] [--project-root DIR] [--quiet]

Audits docs/llm/*.md for discovery hooks. A file is "orphan" when nothing
outside it (and outside PROJECT_CHANGELOG.md) references it.

  --file PATH       Audit only this file (relative or absolute)
  --project-root D  Project root (default: git rev-parse --show-toplevel || pwd)
  --quiet           Skip the "✓ no orphans" success message
  -h, --help        Show this help

Exit codes: 0=clean, 1=orphans found, 2=usage error.
EOF
}

mode_single=false
single_file=""
quiet=false
project_root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      mode_single=true
      single_file="${2:-}"
      [ -z "$single_file" ] && { usage; exit 2; }
      shift 2
      ;;
    --project-root)
      project_root="${2:-}"
      [ -z "$project_root" ] && { usage; exit 2; }
      shift 2
      ;;
    --quiet|-q)
      quiet=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'check-llm-orphans: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

# Resolve project root.
if [ -z "$project_root" ]; then
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    project_root="$root"
  else
    project_root="$(pwd)"
  fi
fi

cd "$project_root"

if [ ! -d "docs/llm" ]; then
  $quiet || echo "check-llm-orphans: no docs/llm/ in $project_root — nothing to audit"
  exit 0
fi

# Source-file extensions that legitimately host a "see docs/llm/..." comment.
# We restrict source-code grep to these so binaries / lockfiles / minified
# artifacts can't accidentally count as a hook.
SRC_EXTS="sh bash zsh fish ps1 py rb pl lua \
js mjs cjs ts tsx jsx vue svelte astro \
go rs java kt kts scala swift m mm c h cc cpp hpp cs \
php twig blade jinja jinja2 j2 \
html htm xml svg \
yaml yml toml conf ini \
tf hcl sql graphql \
nim zig dart elm ex exs erl \
makefile mk dockerfile"

build_include_args() {
  local args=() ext
  for ext in $SRC_EXTS; do
    args+=("--include=*.$ext")
  done
  printf '%s\n' "${args[@]}"
}

# Build the list of files to audit.
files=()
if $mode_single; then
  # Normalize the path to repo-relative form.
  case "$single_file" in
    /*)
      case "$single_file" in
        "$project_root"/*) single_file="${single_file#"$project_root"/}" ;;
        *)
          # Absolute path outside the project — nothing we can audit.
          $quiet || echo "check-llm-orphans: $single_file is outside $project_root" >&2
          exit 0
          ;;
      esac
      ;;
    ./*) single_file="${single_file#./}" ;;
  esac
  case "$single_file" in
    docs/llm/*.md) ;;
    *)
      # Not a docs/llm/ markdown file — silently no-op.
      exit 0
      ;;
  esac
  if [ ! -f "$single_file" ]; then
    # Defensive: PostToolUse fires after Write so the file should exist;
    # exit 0 quietly if not (e.g. test harness, dry-run).
    exit 0
  fi
  files+=("$single_file")
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(find docs/llm -type f -name '*.md' 2>/dev/null | sort)
fi

if [ ${#files[@]} -eq 0 ]; then
  $quiet || echo "check-llm-orphans: docs/llm/ has no .md files — nothing to audit"
  exit 0
fi

# Pre-build the --include argument list once.
include_args=()
while IFS= read -r line; do
  include_args+=("$line")
done < <(build_include_args)

# Locate hooks for one target file. Echoes a comma-separated list of hook
# *categories* on stdout (empty string if orphan).
find_hooks() {
  local target="$1"
  local needle="$target"
  local labels=()

  # 1. CLAUDE.md (auto-loaded by every Claude Code session).
  if [ -f CLAUDE.md ] && grep -Fq -- "$needle" CLAUDE.md 2>/dev/null; then
    labels+=("CLAUDE.md")
  fi

  # 2. Source-code references — anywhere outside docs/ and the meta dirs,
  #    restricted to known source extensions so binaries don't count.
  local source_hits
  source_hits=$(grep -rlF -- "$needle" \
    "${include_args[@]}" \
    --exclude-dir=.git \
    --exclude-dir=node_modules \
    --exclude-dir=vendor \
    --exclude-dir=.serena \
    --exclude-dir=.claude \
    --exclude-dir=.qwen \
    --exclude-dir=docs \
    --exclude=PROJECT_CHANGELOG.md \
    --exclude=CLAUDE.md \
    . 2>/dev/null | sed 's|^\./||' | sort -u || true)
  [ -n "$source_hits" ] && labels+=("source-code")

  # 3. docs/features/ references.
  if [ -d docs/features ]; then
    local features_hits
    features_hits=$(grep -rlF -- "$needle" docs/features 2>/dev/null \
      | sed 's|^\./||' | sort -u || true)
    [ -n "$features_hits" ] && labels+=("docs/features")
  fi

  # 4. Sibling docs/llm/ references (excluding the file itself).
  local sibling_hits
  sibling_hits=$(grep -rlF -- "$needle" docs/llm 2>/dev/null \
    | sed 's|^\./||' | grep -vF "$target" | sort -u || true)
  [ -n "$sibling_hits" ] && labels+=("sibling docs/llm")

  if [ ${#labels[@]} -eq 0 ]; then
    echo ""
  else
    (IFS=,; printf '%s\n' "${labels[*]}")
  fi
}

orphans=()
for f in "${files[@]}"; do
  hooks=$(find_hooks "$f")
  if [ -z "$hooks" ]; then
    orphans+=("$f")
  fi
done

if [ ${#orphans[@]} -eq 0 ]; then
  if ! $quiet; then
    if $mode_single; then
      echo "check-llm-orphans: ✓ ${files[0]} has at least one discovery hook"
    else
      echo "check-llm-orphans: ✓ all ${#files[@]} docs/llm/ file(s) have discovery hooks"
    fi
  fi
  exit 0
fi

# Orphan(s) found — write a remediation message to stderr.
if $mode_single; then
  cat >&2 <<EOF
check-llm-orphans: 🚨 orphan — ${orphans[0]} has no discovery hook.

This file is invisible to future LLM sessions: only CLAUDE.md is auto-loaded,
and nothing outside the file itself references it. Pick ONE of:

  (a) Add a brief rule + link in CLAUDE.md
      (preferred for cross-cutting rules / anti-patterns)

  (b) Add a language-appropriate comment in the relevant source file:
        Bash/Python:        # See ${orphans[0]}
        JS/TS/Go/PHP/Java:  // @see ${orphans[0]}
        HTML/XML:           <!-- @see ${orphans[0]} -->

  (c) Retire — delete the file if the knowledge is stale.

PROJECT_CHANGELOG.md mentions do not count as a discovery hook.
EOF
else
  printf 'check-llm-orphans: 🚨 %d orphan(s) found in docs/llm/:\n' "${#orphans[@]}" >&2
  for f in "${orphans[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  cat >&2 <<EOF

Each orphan needs ONE of: (a) CLAUDE.md back-ref, (b) source-code comment,
or (c) retirement. Run with --file PATH to focus on a single file.
PROJECT_CHANGELOG.md mentions do not count as a discovery hook.
EOF
fi

exit 1
