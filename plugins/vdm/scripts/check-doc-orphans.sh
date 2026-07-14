#!/bin/bash
# check-doc-orphans.sh — audit long-lived docs for discovery hooks.
#
# A doc is an ORPHAN when nothing a future session can realistically find
# references it. Only CLAUDE.md is auto-loaded; every other document has to be
# grep'd into context from some entry point. An unreferenced doc lives on disk
# and is unreachable — the worst state available, because it is simultaneously
# CURRENT and INVISIBLE.
#
# Audited set — two families, one rule:
#   1. docs/llm/*.md        — technical / LLM-facing docs.
#   2. Synthesis documents  — any .md declaring `covers:` in frontmatter, i.e.
#                             the docs-distill tier, wherever the project put it.
#
# Family 2 was added when the suite grew a synthesis layer and this audit
# silently did not cover it. The gap was not academic: a synthesis that never
# drifts never surfaces through the drift signal either, so an unreferenced one
# rots unseen. See docs/tasks/docs-distill/workitem.md → Sidetrack #8.
#
# Formerly check-llm-orphans.sh. Renamed rather than forked: the hook-finding
# logic is identical for both families, and a second copy would drift from this
# one. Callers shell out here instead of reimplementing the contract.
#
# Discovery-hook categories (any ONE suffices):
#   CLAUDE.md · source-code comment · docs/features/ ref · sibling docs/llm/ ref
#   · a synthesis document referencing it
# PROJECT_CHANGELOG.md mentions are intentionally excluded — they describe
# history, not a discovery path.
#
# Usage:
#   check-doc-orphans.sh                     # audit every doc in the set
#   check-doc-orphans.sh --file PATH         # audit one file (used by the hook)
#   check-doc-orphans.sh --project-root DIR  # override repo root
#   check-doc-orphans.sh --quiet             # suppress 'all clean' line
#
# Exit codes:
#   0  clean — no orphans, or nothing to audit
#   1  at least one orphan found
#   2  usage error

set -eu

usage() {
  cat >&2 <<EOF
Usage: $0 [--file PATH] [--project-root DIR] [--quiet]

Audits docs/llm/*.md and synthesis documents (frontmatter \`covers:\`) for
discovery hooks. A file is "orphan" when nothing outside it (and outside
PROJECT_CHANGELOG.md) references it.

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
      printf 'check-doc-orphans: unknown argument: %s\n' "$1" >&2
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$project_root"

# ---------------------------------------------------------------------------
# The audited set
# ---------------------------------------------------------------------------

synthesis_docs() {
  # distill-scan.sh OWNS the definition of "what is a synthesis document"
  # (frontmatter `covers:`; templates excluded). We do not re-derive it here — a
  # second definition is a second thing to keep in sync, and this repo's own law
  # is that the algorithm lives in exactly one script.
  #
  # --list emits `path` then indented detail lines; keep only the unindented ones.
  # Fails open: no scanner ⇒ audit docs/llm/ alone rather than blocking.
  [ -x "$HERE/distill-scan.sh" ] || return 0
  "$HERE/distill-scan.sh" --list 2>/dev/null | grep -v '^[[:space:]]' || true
}

is_synthesis_doc() {
  # is_synthesis_doc <repo-relative-path>
  local target="$1" d
  while IFS= read -r d; do
    [ "$d" = "$target" ] && return 0
  done < <(synthesis_docs)
  return 1
}

# Source-file extensions that legitimately host a "see docs/..." comment.
# We restrict the source-code grep to these so binaries / lockfiles / minified
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
          $quiet || echo "check-doc-orphans: $single_file is outside $project_root" >&2
          exit 0
          ;;
      esac
      ;;
    ./*) single_file="${single_file#./}" ;;
  esac

  # In scope iff it is a docs/llm/ markdown file OR a synthesis document.
  # Anything else: silent no-op — the guard hook routes every Write through here.
  in_scope=false
  case "$single_file" in
    docs/llm/*.md) in_scope=true ;;
    *.md) is_synthesis_doc "$single_file" && in_scope=true ;;
  esac
  $in_scope || exit 0

  if [ ! -f "$single_file" ]; then
    # Defensive: PostToolUse fires after Write so the file should exist;
    # exit 0 quietly if not (e.g. test harness, dry-run).
    exit 0
  fi
  files+=("$single_file")
else
  if [ -d "docs/llm" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && files+=("$f")
    done < <(find docs/llm -type f -name '*.md' 2>/dev/null | sort)
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(synthesis_docs)
fi

if [ ${#files[@]} -eq 0 ]; then
  $quiet || echo "check-doc-orphans: no docs/llm/ files and no synthesis documents — nothing to audit"
  exit 0
fi

# Dedupe — a synthesis document may legitimately live under docs/llm/.
files=($(printf '%s\n' "${files[@]}" | sort -u))

# Pre-build the --include argument list once.
include_args=()
while IFS= read -r line; do
  include_args+=("$line")
done < <(build_include_args)

# ---------------------------------------------------------------------------
# Hook detection
#
# The categories stay DELIBERATELY NARROW. The tempting generalization — "any
# .md under docs/ that mentions it" — would silently weaken the gate: a passing
# mention inside a closed crystal's workitem would then count as a discovery
# path, and a closed crystal is archaeology, not an entry point.
# ---------------------------------------------------------------------------

find_hooks() {
  local target="$1"
  local needle="$target"
  local labels=()

  # 1. CLAUDE.md (auto-loaded by every session).
  if [ -f CLAUDE.md ] && grep -Fq -- "$needle" CLAUDE.md 2>/dev/null; then
    labels+=("CLAUDE.md")
  fi

  # 2. Source-code references — anywhere outside docs/ and the meta dirs,
  #    restricted to known source extensions so binaries don't count.
  #
  #    Flags come BEFORE the pattern, and the pattern is passed via `-e`.
  #    The obvious-looking `grep -rlF -- "$needle" --include=... .` is WRONG and
  #    was shipped that way: `--` ends option parsing, so every --include /
  #    --exclude-dir / --exclude after it is handed to grep as a FILE OPERAND,
  #    not a filter. The call silently degrades to `grep -rlF "$needle" .` —
  #    the whole tree, docs/ and PROJECT_CHANGELOG.md included. That made the
  #    orphan gate accept a changelog mention as a discovery hook, which is the
  #    exact thing it exists to reject. `-e` keeps a leading-dash pattern safe
  #    without terminating option parsing.
  local source_hits
  source_hits=$(grep -rlF \
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
    -e "$needle" \
    -- . 2>/dev/null | sed 's|^\./||' | sort -u || true)
  [ -n "$source_hits" ] && labels+=("source-code")

  # 3. docs/features/ references.
  if [ -d docs/features ]; then
    local features_hits
    features_hits=$(grep -rlF -- "$needle" docs/features 2>/dev/null \
      | sed 's|^\./||' | sort -u || true)
    [ -n "$features_hits" ] && labels+=("docs/features")
  fi

  # 4. Sibling docs/llm/ references (excluding the file itself).
  if [ -d docs/llm ]; then
    local sibling_hits
    sibling_hits=$(grep -rlF -- "$needle" docs/llm 2>/dev/null \
      | sed 's|^\./||' | grep -vF "$target" | sort -u || true)
    [ -n "$sibling_hits" ] && labels+=("sibling docs/llm")
  fi

  # 5. A synthesis document referencing it. First-class discovery path —
  #    arriving at the whole is exactly how a reader finds the parts — and it
  #    could not exist before the suite grew a synthesis tier.
  #
  #    A `covers:` glob creates no false hook: grep is literal (-F), and the
  #    string `docs/features/*.md` does not contain `docs/features/x.md`.
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$d" = "$target" ] && continue
    if grep -Fq -- "$needle" "$d" 2>/dev/null; then
      labels+=("synthesis doc")
      break
    fi
  done < <(synthesis_docs)

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
      echo "check-doc-orphans: ✓ ${files[0]} has at least one discovery hook"
    else
      echo "check-doc-orphans: ✓ all ${#files[@]} audited doc(s) have discovery hooks"
    fi
  fi
  exit 0
fi

# Orphan(s) found — write a remediation message to stderr.
if $mode_single; then
  cat >&2 <<EOF
check-doc-orphans: 🚨 orphan — ${orphans[0]} has no discovery hook.

This file is invisible to future sessions: only CLAUDE.md is auto-loaded, and
nothing outside the file itself references it. It is CURRENT and UNREACHABLE.
Pick ONE of:

  (a) Add a brief rule + link in CLAUDE.md
      (preferred for cross-cutting rules, anti-patterns, and for a synthesis
       document — future sessions should read it BEFORE touching the subject)

  (b) Add a language-appropriate comment in the relevant source file:
        Bash/Python:        # See ${orphans[0]}
        JS/TS/Go/PHP/Java:  // @see ${orphans[0]}
        HTML/XML:           <!-- @see ${orphans[0]} -->

  (c) Reference it from a synthesis document (one declaring \`covers:\`).

  (d) Retire — delete the file if the knowledge is stale.

PROJECT_CHANGELOG.md mentions do not count as a discovery hook.
EOF
else
  printf 'check-doc-orphans: 🚨 %d orphan(s) found:\n' "${#orphans[@]}" >&2
  for f in "${orphans[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  cat >&2 <<EOF

Each orphan needs ONE of: (a) CLAUDE.md back-ref, (b) source-code comment,
(c) a reference from a synthesis document, or (d) retirement.
Run with --file PATH to focus on a single file.
PROJECT_CHANGELOG.md mentions do not count as a discovery hook.
EOF
fi

exit 1
