#!/bin/bash
# distill-scan.sh — resolver + drift detector for the synthesis tier (docs-distill).
#
# The synthesis tier is the layer that answers "how is this put together, as a
# whole, right now". Fragments accumulate on their own (feature docs, decision
# logs); synthesis has to be REBUILT, and nothing rebuilds it because nobody
# asks. This script is the asking part: it finds the synthesis documents and
# reports which of them have fallen behind the things they claim to cover.
#
# Discovery contract — `covers:` in frontmatter, NOT a fixed path and NOT `type:`
# (DL #12 in docs/tasks/docs-distill/workitem.md):
#   - The project decides WHERE the tier lives and WHAT it synthesizes. The suite
#     dictates the relation, not the artifact (DL #5).
#   - `covers:` is the machine contract because it is the field the drift signal
#     is computed FROM. A document without `covers:` cannot be drift-checked at
#     all, so it cannot participate — which makes it the honest discovery key.
#     `type: model` remains a human-facing label with no mechanical role.
#
# Expected frontmatter of a synthesis document:
#   ---
#   type: model                       # human label (optional, no mechanical role)
#   question: "what this doc answers"  # the identity rule — see DL #5
#   covers:                            # REQUIRED — globs/paths, relative to repo root
#     - docs/features/*.md
#     - src/analytics/
#   observed: 2026-07-14               # absolute date of last verification
#   ---
#
# Usage:
#   distill-scan.sh            # same as --drift
#   distill-scan.sh --drift    # only documents whose inputs are newer than they are
#   distill-scan.sh --list     # every synthesis document found, with question/observed
#
# Exit codes:
#   0 — success (empty stdout = nothing to report). Hooks depend on this.
#   2 — usage error.
# Never exits non-zero on "drift found" — callers read stdout. A scanner that
# fails closed would block work, and the whole suite's rule is that a broken
# hook must never do that.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/config-read.sh" 2>/dev/null || exit 0

MODE="drift"
case "${1:-}" in
  ""|--drift) MODE="drift" ;;
  --list)     MODE="list" ;;
  -h|--help)  printf 'usage: %s [--drift|--list]\n' "$(basename "$0")"; exit 0 ;;
  *)          printf 'usage: %s [--drift|--list]\n' "$(basename "$0")" >&2; exit 2 ;;
esac

project_root=$(git rev-parse --show-toplevel 2>/dev/null) || project_root=$(pwd)
cd "$project_root" 2>/dev/null || exit 0

# ---------------------------------------------------------------------------
# Frontmatter helpers
# ---------------------------------------------------------------------------

_fm_scalar() {
  # _fm_scalar <file> <key> — prints a scalar frontmatter value, or nothing.
  awk -v key="$2" '
    BEGIN { count = 0 }
    /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
    count == 1 {
      if (match($0, "^"key"[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", val)
        gsub(/^["\047]|["\047]$/, "", val)
        print val
        exit
      }
    }
  ' "$1" 2>/dev/null
}

_fm_list() {
  # _fm_list <file> <key> — prints list items, one per line. Handles both YAML
  # shapes people actually write:
  #     covers:            |   covers: [a, b]
  #       - a              |
  #       - b              |
  # Nothing else — this is frontmatter, not a YAML engine.
  awk -v key="$2" '
    BEGIN { count = 0; inlist = 0 }
    /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
    count != 1 { next }
    {
      if (match($0, "^"key"[[:space:]]*:[[:space:]]*")) {
        rest = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", rest)
        if (rest ~ /^\[.*\]$/) {                    # inline flow list
          gsub(/^\[|\]$/, "", rest)
          n = split(rest, parts, ",")
          for (i = 1; i <= n; i++) {
            v = parts[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            gsub(/^["\047]|["\047]$/, "", v)
            if (v != "") print v
          }
          exit
        }
        inlist = 1                                   # block list follows
        next
      }
      if (inlist) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
          v = $0
          sub(/^[[:space:]]*-[[:space:]]*/, "", v)
          sub(/[[:space:]]+$/, "", v)
          gsub(/^["\047]|["\047]$/, "", v)
          if (v != "") print v
        } else if ($0 ~ /^[^[:space:]]/) {
          exit                                       # next top-level key
        }
      }
    }
  ' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Tier resolution (mirrors crystal-path.sh strategy — DL #12)
#   1. distill.paths (array of globs) — explicit opt-in
#   2. auto-scan every tracked *.md, keep those declaring `covers:`
# ---------------------------------------------------------------------------

_expand_glob() {
  # _expand_glob <glob> — prints matching paths (files and dirs), one per line,
  # repo-relative. Runs in a subshell so nullglob doesn't leak.
  #
  # Deliberately does NOT rely on globstar: the system bash on macOS is 3.2,
  # which predates it, and there `**` silently degrades to `*`. Recursion is
  # therefore done by the CALLER walking any directory this returns — which
  # behaves identically on bash 3.2 and 5.x instead of quietly covering less on
  # one of them. A covers-glob that under-matches is the worst possible failure
  # here: it reports "no drift" on a document that has drifted.
  (
    shopt -s nullglob 2>/dev/null
    local expanded e
    case "$1" in
      /*) expanded=( $1 ) ;;
      *)  expanded=( ./$1 ) ;;
    esac
    # `${arr[@]+"${arr[@]}"}` — NOT decoration. With nullglob, a glob that
    # matches nothing yields an empty array, and on bash 3.2 (the system bash on
    # macOS) `"${arr[@]}"` under `set -u` then aborts with "unbound variable".
    # Bash 4.4+ does not. Left unguarded, a covers-glob pointing at a path that
    # does not exist yet would kill the expansion silently and the document
    # would be reported as having no drift.
    for e in ${expanded[@]+"${expanded[@]}"}; do
      printf '%s\n' "${e#./}"
    done
  )
}

_candidate_markdown() {
  local globs glob e
  globs=$(vdm_config_read_array "distill" "paths" 2>/dev/null)

  if [ -n "$globs" ]; then
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ -d "$e" ]; then
          find "$e" -type f -name '*.md' 2>/dev/null | sed 's|^\./||'
        elif [ -f "$e" ]; then
          printf '%s\n' "$e"
        fi
      done < <(_expand_glob "${glob%/}")
    done <<<"$globs" | sort -u
    return 0
  fi

  # Auto-scan. git ls-files is fast and already excludes ignored trees; the
  # find fallback keeps non-git projects working (same split as crystal-path.sh).
  #
  # `--others --exclude-standard` is load-bearing, not a flourish: a synthesis
  # document is untracked for its entire first session, and a scanner that only
  # sees the index would stay silent exactly when the tier is being born — the
  # one moment the signal has to work.
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard '*.md' 2>/dev/null
  else
    find . \
      \( -path '*/.*' -o -name 'node_modules' -o -name 'vendor' \) -prune -o \
      -type f -name '*.md' -print 2>/dev/null | sed 's|^\./||'
  fi | grep -vE '(^|/)(node_modules|vendor)/' | sort -u
}

_is_template() {
  # A template is not an instance. `synthesis-template.md` carries `covers:` in
  # its frontmatter by construction — that is what it is teaching — so without
  # this it gets discovered as a real synthesis document and the skill dutifully
  # tries to "rebuild" a file full of placeholders. Caught by running the scanner
  # against this plugin's own repo.
  #
  # Excluded by PATH, not by a frontmatter marker such as `template: true`. A
  # marker would invert the failure: a user who copies the template and forgets
  # to delete the marker gets a synthesis document that is silently invisible to
  # the drift signal — rot with no signal, the worst outcome available. Path
  # exclusion has no such footgun, because the copy lands at its real address.
  case "/$1" in
    */templates/*|*/template/*) return 0 ;;
    *) return 1 ;;
  esac
}

find_synthesis_docs() {
  # Prints paths of documents that declare `covers:` — i.e. the synthesis tier.
  #
  # Two passes, because this runs from a UserPromptSubmit hook on a 5s budget
  # and a vault can hold thousands of markdown files (the same scale that forced
  # memoization into crystal-path.sh):
  #   1. one grep across all candidates — cheap, and narrows to a handful;
  #   2. frontmatter parse only on what survived.
  # A body-text mention of `covers:` survives pass 1 and dies in pass 2, since
  # _fm_list reads the frontmatter block only. False positives cost one awk run;
  # skipping pass 1 costs an awk run per file in the repo.
  local candidates hits f
  candidates=$(_candidate_markdown)
  [ -z "$candidates" ] && return 0

  hits=$(printf '%s\n' "$candidates" | tr '\n' '\0' \
           | xargs -0 grep -l -E '^covers:[[:space:]]*' 2>/dev/null)
  [ -z "$hits" ] && return 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    _is_template "$f" && continue
    head -n 1 "$f" 2>/dev/null | grep -q '^---[[:space:]]*$' || continue
    [ -n "$(_fm_list "$f" covers)" ] && printf '%s\n' "$f"
  done <<<"$hits"
  return 0
}

# ---------------------------------------------------------------------------
# Drift: is any covered input newer than the synthesis that claims to cover it?
#
# mtime, not content hash. The suite already uses this exact comparison in
# crystal-capture-reminder.sh ("sources newer than the workitem"); DL #4 says to
# aim the existing form at a new pair of files rather than invent a mechanism.
# A better detector exists for systems that expose a fingerprint — that is the
# decay-detector ladder, still open as Sidetrack #5. Do not silently promote
# this heuristic into the general rule.
# ---------------------------------------------------------------------------

newer_inputs() {
  # newer_inputs <synthesis-file> [max]
  # Prints covered files whose mtime is newer than the synthesis. Stops at `max`
  # (default 3) — the caller wants evidence, not an inventory.
  local synth="$1" max="${2:-3}"
  local emitted=0 glob e hit

  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    [ "$emitted" -ge "$max" ] && break
    glob="${glob%/}"

    # Expand in a subshell so globstar/nullglob don't leak into the caller.
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ "$emitted" -ge "$max" ] && break
      # The synthesis document must never count as its own input — a doc listed
      # under a glob it also matches (e.g. `docs/*.md` covering a sibling) would
      # otherwise report itself as perpetually stale.
      [ "$e" = "$synth" ] && continue
      if [ -d "$e" ]; then
        while IFS= read -r hit; do
          [ -n "$hit" ] || continue
          [ "$hit" = "$synth" ] && continue
          printf '%s\n' "$hit"
          emitted=$((emitted + 1))
          [ "$emitted" -ge "$max" ] && break
        done < <(find "$e" -type f -newer "$synth" \
                   -not -path '*/.git/*' -not -path '*/node_modules/*' \
                   -not -path '*/vendor/*' 2>/dev/null | sort)
      elif [ -f "$e" ] && [ "$e" -nt "$synth" ]; then
        printf '%s\n' "$e"
        emitted=$((emitted + 1))
      fi
    done < <(_expand_glob "$glob")
  done < <(_fm_list "$synth" covers)
  return 0
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

synth_docs=$(find_synthesis_docs)
[ -z "$synth_docs" ] && exit 0

if [ "$MODE" = "list" ]; then
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    q=$(_fm_scalar "$doc" question)
    obs=$(_fm_scalar "$doc" observed)
    printf '%s\n' "$doc"
    [ -n "$q" ]   && printf '  question: %s\n' "$q"
    [ -n "$obs" ] && printf '  observed: %s\n' "$obs"
    printf '  covers:   %s\n' "$(_fm_list "$doc" covers | paste -sd', ' - 2>/dev/null)"
  done <<<"$synth_docs"
  exit 0
fi

# --drift
while IFS= read -r doc; do
  [ -n "$doc" ] || continue
  newer=$(newer_inputs "$doc" 3)
  [ -z "$newer" ] && continue
  printf '%s\n' "$doc"
  while IFS= read -r n; do
    [ -n "$n" ] && printf '  ← %s\n' "$n"
  done <<<"$newer"
done <<<"$synth_docs"

exit 0
