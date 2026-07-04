#!/bin/bash
# crystal-migrate-scan.sh — mechanical pre-migration scan for /vdm:crystal-migrate.
#
# Enumerates candidate legacy docs under the target dir(s) and emits one
# tab-separated row of *signals* per file. The scanner never decides the final
# bucket and never invents a slug — it proposes a heuristic bucket guess; the
# skill (LLM) refines it from file content and the human confirms
# (crystal-migrate DL #4). Slug selection is a deliberate human decision at
# migration time (DL #2), never derived from the old filename here.
#
# Target resolution (DL #9):
#   1. explicit dir/glob args        → scan those
#   2. else resolve_crystal_roots    → scan discovered tasks/ roots
#   3. else (virgin, no root)         → empty output; the skill then asks the
#                                       user where the legacy docs live
#
# Output: a leading `# columns:` comment then one TSV row per file. Columns:
#   1  path          path as given (relative to the scanned dir / CWD)
#   2  created       YYYY-MM-DD (git add date | fs birthtime) — may be empty
#   3  updated       YYYY-MM-DD (git last touch | fs mtime)   — may be empty
#   4  has_fm        1 if the file opens with a `---` YAML frontmatter block
#   5  status        raw frontmatter `status:` value (empty if none)
#   6  tier          active|paused|pre-work|terminal|non-canonical|none
#   7  unchecked     count of `- [ ]` checkboxes
#   8  headings      count of markdown ATX headings (`#`..`######`)
#   9  name_hint     spec|asset|plain — filename-shape signal (not a decision)
#   10 bucket_guess  workitem|reference|out-of-scope|ambiguous (heuristic)
#
# Exit 0 always (scan is advisory; empty output is a valid answer).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/crystal-path.sh" 2>/dev/null || {
  echo "crystal-migrate-scan: lib/crystal-path.sh not found relative to $SCRIPT_DIR" >&2
  exit 1
}
# shellcheck disable=SC1091
. "$SCRIPT_DIR/crystal-dates.sh" 2>/dev/null || {
  echo "crystal-migrate-scan: crystal-dates.sh not found relative to $SCRIPT_DIR" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# Target directories (DL #9)
# ----------------------------------------------------------------------------

TARGETS=()
if [ "$#" -gt 0 ]; then
  for a in "$@"; do
    [ -d "$a" ] && TARGETS+=("$a")
  done
else
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] && TARGETS+=("$r")
  done < <(resolve_crystal_roots)
fi

# No target → virgin project with no tasks/ root. Emit the header only; the
# skill reads the empty body and asks the user where legacy docs live.
printf '# columns: path\tcreated\tupdated\thas_fm\tstatus\ttier\tunchecked\theadings\tname_hint\tbucket_guess\n'
[ "${#TARGETS[@]}" -eq 0 ] && exit 0

# ----------------------------------------------------------------------------
# Per-file signal extraction
# ----------------------------------------------------------------------------

enumerate() {
  # Print every `.md` file under the dir, hidden segments + deps pruned, one
  # path per line, prefixed back with the dir so paths are usable from CWD.
  local dir="$1"
  [ -d "$dir" ] || return 0
  ( cd "$dir" 2>/dev/null && \
    find . \( -path '*/.*' -o -name node_modules -o -name vendor \) -prune -o \
      -type f -name '*.md' -print 2>/dev/null
  ) | awk -v r="$dir/" '/./{ sub(/^\.\//, r); print }'
}

has_frontmatter() {
  # 1 if the first non-empty line is a `---` fence, else 0.
  local f="$1" first
  first=$(awk 'NF{print; exit}' "$f" 2>/dev/null)
  case "$first" in
    '---') printf '1\n' ;;
    *)     printf '0\n' ;;
  esac
}

count_headings() {
  local f="$1" n
  n=$(grep -cE '^#{1,6}[[:space:]]' "$f" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

name_hint() {
  # Filename-shape signal only — NOT a bucket decision. spec = looks like a
  # specification/plan doc; asset = looks like a reusable prompt/agent artifact
  # (out-of-scope candidate, DL #4); plain = no strong shape signal.
  local base lower
  base=$(basename "$1" .md)
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    prompt-*|subagent-*|agent-*|*-prompt|*.prompt|snippet-*|template-*)
      printf 'asset\n' ;;
    prd|spec|*-prd|*-spec|prd-*|spec-*|design|*-design|rfc|*-rfc)
      printf 'spec\n' ;;
    readme|changelog|contributing|license|index|todo|notes)
      # generic doc-type tags — not task work; treat as spec-shaped so the
      # skill leans reference/out-of-scope rather than fabricating a workitem
      printf 'spec\n' ;;
    *)
      printf 'plain\n' ;;
  esac
}

guess_bucket() {
  # guess_bucket <name_hint> <has_fm> <unchecked> <headings>
  # Heuristic proposer only. The skill overrides from content; human confirms.
  # Order matters — earlier rules win:
  local hint="$1" has_fm="$2" unchecked="$3" headings="$4"

  # 1. Reusable assets never get force-migrated into tasks/ (DL #4).
  if [ "$hint" = "asset" ]; then
    printf 'out-of-scope\n'; return
  fi
  # 2. Open obligations dominate — even a spec with live TODOs is real work.
  if [ "${unchecked:-0}" -gt 0 ]; then
    printf 'workitem\n'; return
  fi
  # 3. Spec-shaped name with no open tasks → reference (DL #3 default: a PRD is
  #    an artifact, not a work-unit — this beats the frontmatter test below so a
  #    frontmatter'd PRD still lands in references/).
  if [ "$hint" = "spec" ]; then
    printf 'reference\n'; return
  fi
  # 4. Frontmatter present → it was being tracked as a unit. A non-canonical
  #    status doesn't change the bucket; the `tier` column carries that drift
  #    signal independently for the DL #5 status-audit.
  if [ "$has_fm" = "1" ]; then
    printf 'workitem\n'; return
  fi
  # 5. Structured prose, no frontmatter, no tasks → most likely reference doc.
  if [ "${headings:-0}" -ge 1 ]; then
    printf 'reference\n'; return
  fi
  # 6. Nothing to go on — defer to the skill's content read.
  printf 'ambiguous\n'
}

emit_row() {
  local f="$1"
  local dates created updated has_fm status tier unchecked headings hint bucket
  dates=$(derive_dates "$f")
  created="${dates%%$'\t'*}"
  updated="${dates#*$'\t'}"
  has_fm=$(has_frontmatter "$f")
  status=$(extract_frontmatter_field "$f" status)
  if [ -n "$status" ]; then
    tier=$(derive_status_tier "$status")
  else
    tier="none"
  fi
  unchecked=$(count_unchecked "$f")
  headings=$(count_headings "$f")
  hint=$(name_hint "$f")
  bucket=$(guess_bucket "$hint" "$has_fm" "$unchecked" "$headings")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$f" "$created" "$updated" "$has_fm" "$status" "$tier" \
    "$unchecked" "$headings" "$hint" "$bucket"
}

# ----------------------------------------------------------------------------
# Scan
# ----------------------------------------------------------------------------

# Collect, dedupe across targets (overlapping globs), stable sort by path.
ALL=""
for dir in "${TARGETS[@]}"; do
  ALL="${ALL}$(enumerate "$dir")
"
done

printf '%s\n' "$ALL" | sort -u | while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  emit_row "$f"
done

exit 0
