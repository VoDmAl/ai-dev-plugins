#!/bin/bash
# crystal-refscan.sh — inbound-reference scanner for /vdm:crystal-migrate link-integrity
# (crystal-migrate Decision Log #11). Migration renames workitems; a rename strands inbound
# references. There is no universal rewrite framework — each project links its own way — so
# this scanner does NOT rewrite. It surfaces the blast radius and classifies each hit by
# syntactic style; the skill applies the two-tier policy and the human confirms.
#
# Two modes:
#   detect [<dir>...]            Sample the tree, report which link styles are present and
#                                which dominates. Feeds the per-project link-integrity policy
#                                the migration crystal records.
#   find <identifier> [<dir>...] Locate inbound references to <identifier> (an old slug or old
#                                path about to be renamed). Each hit is bucketed:
#                                  frontmatter — reference-for/relates-to/superseded-by/
#                                                migrated-from/superseded keys (the crystal's
#                                                OWN graph → Tier 1, auto-rewrite)
#                                  wikilink    — [[...]] / ![[...]]
#                                  mdlink      — ](...) markdown / relative links
#                                  plain       — bare textual occurrence (code, prose, paths)
#                                The skill treats hits in files under a crystal root + graph
#                                syntax as Tier 1 (auto); everything else as Tier 2 (surface +
#                                per-project policy).
#
# Default target when none given: the git project root (else CWD). Link-integrity spans the
# WHOLE project (code + docs), not just tasks/. Exit 0 always — advisory.
set -u

_EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor
  --exclude-dir=.stversions --exclude-dir=.obsidian --exclude-dir=.trash
  --exclude-dir=.serena --exclude-dir=.claude)

_default_target() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  if [ -n "$root" ]; then printf '%s\n' "$root"; else printf '.\n'; fi
}

# _classify_hits — stdin: grep -In output "file:line:content"; stdout: "style<TAB>file:line".
# Named function (not inline) so the awk program is parser-safe regardless of call site.
_classify_hits() {
  awk '
    {
      i1 = index($0, ":"); rest = substr($0, i1 + 1);
      i2 = index(rest, ":");
      file = substr($0, 1, i1 - 1);
      lineno = substr(rest, 1, i2 - 1);
      content = substr(rest, i2 + 1);
      style = "plain";
      if (content ~ /^[[:space:]]*(reference-for|relates-to|superseded-by|superseded|migrated-from)[[:space:]]*:/)
        style = "frontmatter";
      else if (content ~ /\[\[/ && content ~ /\]\]/)
        style = "wikilink";
      else if (content ~ /\]\(/)
        style = "mdlink";
      print style "\t" file ":" lineno;
    }'
}

mode_find() {
  local id="$1"; shift
  local targets=("$@")
  [ "${#targets[@]}" -eq 0 ] && targets=("$(_default_target)")

  local hits
  hits=$(grep -rInF "${_EXCLUDES[@]}" -e "$id" -- "${targets[@]}" 2>/dev/null | _classify_hits | sort -u)

  local total
  total=$(printf '%s\n' "$hits" | grep -c '.' 2>/dev/null || echo 0)
  total=${total:-0}

  if [ "$total" -eq 0 ]; then
    printf 'inbound refs to `%s`: none\n' "$id"
    return 0
  fi

  printf 'inbound refs to `%s` (%d hits):\n' "$id" "$total"
  local style
  for style in frontmatter wikilink mdlink plain; do
    local rows n locs
    rows=$(printf '%s\n' "$hits" | awk -F'\t' -v s="$style" '$1==s {print $2}')
    n=$(printf '%s\n' "$rows" | grep -c '.' 2>/dev/null || echo 0)
    [ "${n:-0}" -eq 0 ] && continue
    locs=$(printf '%s\n' "$rows" | paste -sd' ' -)
    case "$style" in
      frontmatter) printf '  frontmatter (Tier1 graph, %d): %s\n' "$n" "$locs" ;;
      *)           printf '  %-11s (%d): %s\n' "$style" "$n" "$locs" ;;
    esac
  done
  return 0
}

mode_detect() {
  local targets=("$@")
  [ "${#targets[@]}" -eq 0 ] && targets=("$(_default_target)")

  # File counts per style marker — a coarse prevalence gauge.
  local fm wl ml
  fm=$(grep -rIlE "${_EXCLUDES[@]}" -e '^[[:space:]]*(reference-for|relates-to|superseded-by|superseded|migrated-from)[[:space:]]*:' -- "${targets[@]}" 2>/dev/null | grep -c '.' 2>/dev/null || echo 0)
  wl=$(grep -rIlF "${_EXCLUDES[@]}" -e '[[' -- "${targets[@]}" 2>/dev/null | grep -c '.' 2>/dev/null || echo 0)
  ml=$(grep -rIlF "${_EXCLUDES[@]}" -e '](' -- "${targets[@]}" 2>/dev/null | grep -c '.' 2>/dev/null || echo 0)
  fm=${fm:-0}; wl=${wl:-0}; ml=${ml:-0}

  printf 'link styles present (file counts):\n'
  printf '  frontmatter-graph : %d\n' "$fm"
  printf '  wikilink          : %d\n' "$wl"
  printf '  mdlink            : %d\n' "$ml"

  # Dominant among the non-graph body styles (wikilink vs mdlink) — the graph is always
  # handled Tier 1, so the policy question is really "how does prose link?".
  local dominant="none"
  if [ "$wl" -gt "$ml" ]; then dominant="wikilink"
  elif [ "$ml" -gt "$wl" ]; then dominant="mdlink"
  elif [ "$wl" -gt 0 ]; then dominant="wikilink|mdlink (tie)"
  fi
  printf 'dominant prose link style: %s\n' "$dominant"
  return 0
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  detect)
    shift
    mode_detect "$@"
    ;;
  find)
    shift
    [ "$#" -ge 1 ] || { echo "usage: crystal-refscan.sh find <identifier> [<dir>...]" >&2; exit 2; }
    id="$1"; shift
    mode_find "$id" "$@"
    ;;
  *)
    echo "usage: crystal-refscan.sh {detect [<dir>...] | find <identifier> [<dir>...]}" >&2
    exit 2
    ;;
esac
exit 0
