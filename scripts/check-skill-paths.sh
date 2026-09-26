#!/bin/bash
# check-skill-paths.sh — lint user-time files for paths that do not resolve at
# user time: dev-tree leaks, dangling repo-doc refs, and commands whose
# ${CLAUDE_PLUGIN_ROOT} is unquoted (see Gate 3 below).
#
# Files in plugins/*/skills/**/SKILL.md and plugins/*/templates/*.md are
# the plugin's contract with user projects. Their paths must resolve at user
# time — i.e. through `${CLAUDE_PLUGIN_ROOT}` or via abstract reference.
# Direct strings like `plugins/vdm/scripts/foo.sh` only resolve in this dev
# clone; in a user project that path doesn't exist (the plugin is installed
# wherever Claude Code put it).
#
# Pattern flagged: plugins/<any-plugin>/(scripts|lib|hooks|templates|skills)/...
# Bare plugin names (e.g. "the vdm plugin") are NOT flagged — only concrete
# subpaths that the dev tree resolves but a user project doesn't.
#
# One carve-out, and it is about the rule rather than an exemption from it: the
# same substring rooted at an INSTALL directory — `.claude/plugins/…` or
# `.qwen/plugins/…` — is a user-time path by construction, not a dev-tree path.
# It resolves on the user's machine and nowhere in this clone, which is the
# exact inverse of what the gate exists to catch. It appears in guard/SKILL.md
# because the crystal pre-commit snippet runs in a plain shell where
# ${CLAUDE_PLUGIN_ROOT} is undefined — the harness sets it for skills, not for
# git hooks — so that snippet has to resolve the install path itself.
# The carve-out is deliberately narrow: only when the install root appears
# BEFORE the match on the same line. A bare `plugins/vdm/scripts/…` is still a
# leak, wherever it sits.
#
# Used by .githooks/pre-commit alongside check-lib-sync.sh and
# check-version-bump.sh. Scope: dev-time only — the plugins do not see
# this script at user time.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# Build the target list. Single find with combined predicate; works in bash
# 3.2 (macOS) without `mapfile` / `readarray`.
targets=()
while IFS= read -r f; do
  [ -n "$f" ] && targets+=("$f")
done < <(
  find plugins -type f \( \
       -name 'SKILL.md' \
    -o \( -path '*/templates/*' -name '*.md' \) \
  \) 2>/dev/null
)

if [ ${#targets[@]} -eq 0 ]; then
  echo "skill-paths: no SKILL.md or templates/*.md found — nothing to lint"
  exit 0
fi

# Pattern: concrete dev-tree subpath that doesn't resolve at user time.
#
# Any plugin name, not a hardcoded list: a gate whose scope is an enumeration
# silently narrows the day a plugin is added, and the narrowing looks exactly
# like a clean run. Generalised 2026-09-21, before the third plugin landed.
pattern='plugins/[A-Za-z0-9_-]+/(scripts|lib|hooks|templates|skills)/'

# Install-root anchored form — the one shape of this substring that DOES resolve
# at user time (see the header note). Anchor must precede the match on the line.
install_rooted='\.(claude|qwen)/plugins/.*'"$pattern"

# Every gate below reads all targets in ONE awk pass and prints one record per
# finding, `<file>\t<name>\t<lineno>:<line>`, already in report order; the shell
# only groups consecutive records into blocks. It used to run `grep | grep` per
# file here and per (file, doc) pair in Gate 2 — ~2100 processes a run for 21
# files and 33 docs, which made this the costliest gate in the repo and nine
# tenths of tests/gates.test.sh, which runs it once per red test. The cost must
# not grow with the number of files or docs; tests/gates.test.sh counts it.
#
# Patterns reach awk through ENVIRON, not -v: -v processes backslash escapes,
# and `\.` would stop meaning a literal dot.

# report_blocks <records> <header-fn> <footer-fn> — one block per run of
# records that share file and name. A process only when there is a finding.
tab=$(printf '\t')
nl='
'
report_blocks() {
  local records="$1" header="$2" footer="$3" rec prev_f="" prev_n="" f name hit hits=""
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    f=${rec%%"$tab"*}; rec=${rec#*"$tab"}
    name=${rec%%"$tab"*}; hit=${rec#*"$tab"}
    if [ -n "$hits" ] && { [ "$f" != "$prev_f" ] || [ "$name" != "$prev_n" ]; }; then
      "$header" "$prev_f"; printf '%s\n' "$hits" | sed 's/^/  /'; "$footer" "$prev_n"
      hits=""
    fi
    prev_f=$f; prev_n=$name
    hits="${hits:+$hits$nl}$hit"
  done <<EOF
$records
EOF
  if [ -n "$hits" ]; then
    "$header" "$prev_f"; printf '%s\n' "$hits" | sed 's/^/  /'; "$footer" "$prev_n"
  fi
}

leak_header() {
  printf '\n'
  printf 'skill-paths: 🚨 dev-tree path leak in user-time file: %s\n' "$1"
  printf '\n'
}
leak_footer() {
  printf '\n'
  printf '  These paths only resolve inside this dev clone. At user time the\n'
  printf '  plugin lives at ${CLAUDE_PLUGIN_ROOT} (resolved by Claude Code).\n'
  printf '  Replace plugins/X/<subdir>/ with ${CLAUDE_PLUGIN_ROOT}/<subdir>/.\n'
}

drift=0
leaks=$(PATTERN="$pattern" INSTALL_ROOTED="$install_rooted" awk '
  $0 ~ ENVIRON["PATTERN"] && $0 !~ ENVIRON["INSTALL_ROOTED"] { print FILENAME "\t\t" FNR ":" $0 }
' "${targets[@]}" 2>/dev/null || true)
if [ -n "$leaks" ]; then
  drift=1
  report_blocks "$leaks" leak_header leak_footer >&2
fi

# ---------------------------------------------------------------------------
# Gate 2: citations of THIS repo's own docs/ files.
#
# The plugin ships as a git-subdir of `plugins/vdm` — the repo's `docs/` tree
# is NOT part of the package. So a user-time reference to `docs/tasks/<slug>/`
# or `docs/llm/<file>` resolves to nothing: not in the user's project, and not
# under ${CLAUDE_PLUGIN_ROOT} either. Worst case a SKILL.md instructs the
# assistant to *Read* a file that cannot exist.
#
# The check is against the filesystem, not a heuristic — that's what makes it
# precise enough to be a gate rather than a nag:
#
#   FLAG a docs/tasks/<slug>/ or docs/llm/<file> reference  ⟺  that slug/file
#   ACTUALLY EXISTS in this repo  AND  the line does not name the repo.
#
# Consequences of that rule, all intended:
#   - `docs/llm/{topic}.md`, `docs/features/{feature}.md` — placeholders for the
#     USER's tree (learn / docs-sync write there). No such file here → never flagged.
#     This is the plugin's whole job; flagging it would be backwards.
#   - `docs/tasks/auth-refactor/workitem.md` — invented example slug. Doesn't
#     exist here → never flagged.
#   - `docs/tasks/crystal-design/workitem.md` — a real crystal of ours. Flagged,
#     unless written as a citation naming the repo:
#         `cc-vdm-plugins → docs/tasks/crystal-design/workitem.md`
#     which turns a broken local path into an honest pointer at another repo.
#
# Repo name must be on the SAME line as the path (this check is line-based).
# ---------------------------------------------------------------------------

repo_name='cc-vdm-plugins'

# Enumerate what actually exists here, so "does this resolve?" is a fact. The
# names are cut from the paths by one sed, not by a basename per entry.
own_docs=$(
  { [ -d docs/tasks ] && find docs/tasks -mindepth 1 -maxdepth 1 -type d ;
    [ -d docs/llm ]   && find docs/llm   -mindepth 1 -maxdepth 1 -type f -name '*.md' ;
  } 2>/dev/null | sed 's#.*/##' | sort -u
)

dangling_header() {
  printf '\n'
  printf 'skill-paths: 🚨 dangling repo-doc reference in user-time file: %s\n' "$1"
  printf '\n'
}
dangling_footer() {
  printf '\n'
  printf '  `%s` exists in THIS repo but is not shipped: the plugin package is\n' "$1"
  printf '  plugins/vdm only, so docs/ is absent both from the user project and\n'
  printf '  from ${CLAUDE_PLUGIN_ROOT}. As written, that path resolves to nothing.\n'
  printf '\n'
  printf '  Either drop the reference, or make it an explicit cross-repo citation\n'
  printf '  by naming the repo on the same line:\n'
  printf '      `%s → docs/tasks/<slug>/workitem.md`\n' "$repo_name"
}

# Match `docs/tasks/<name>/` or `docs/llm/<name>` (name already carries .md for
# llm files). Skip lines that name the repo — those are citations. A file's
# findings are held until the file ends, so they come out grouped by name in
# the order of the list, exactly as the per-pair loop printed them.
dangling=$(OWN_DOCS="$own_docs" REPO="$repo_name" awk '
  function flush(   i) {
    for (i = 1; i <= n; i++) if (hit[i] != "") { printf "%s", hit[i]; hit[i] = "" }
  }
  BEGIN { n = split(ENVIRON["OWN_DOCS"], name, "\n") }
  FNR == 1 { flush() }
  !/docs\/(tasks|llm)\// || index($0, ENVIRON["REPO"]) { next }
  {
    for (i = 1; i <= n; i++)
      if (name[i] != "" && $0 ~ ("docs/(tasks/" name[i] "/|llm/" name[i] ")"))
        hit[i] = hit[i] FILENAME "\t" name[i] "\t" FNR ":" $0 "\n"
  }
  END { flush() }
' "${targets[@]}" 2>/dev/null || true)
if [ -n "$dangling" ]; then
  drift=1
  report_blocks "$dangling" dangling_header dangling_footer >&2
fi

# ---------------------------------------------------------------------------
# Gate 3: an INVOCATION of a plugin file must quote the root.
#
# The root is substituted into the text the assistant reads, and the assistant
# copies a command into a shell. Unquoted, a plugin installed under a path with
# a space (`~/AI Projects/…`, a clone used as a marketplace) splits there:
# `/Users/…/AI: No such file or directory`. Found 2026-09-25 by echelon in
# hooks.json, where it switched the blocking hooks off silently; the same form
# sat in 29 commands across the SKILL.md files.
#
# What counts as an invocation, deliberately narrow:
#   - any occurrence inside a fenced code block;
#   - a line that BEGINS with the root (an indented code block);
#   - an inline code span in which the path is followed by an argument.
# A name-only span in prose — "Script: `${CLAUDE_PLUGIN_ROOT}/scripts/x.sh`",
# "Read the template at `…`" — is a name, not a command: it is read, or opened
# with a file tool, and a space harms neither. Quoting names would only teach
# the file tool to receive a path with quotes in it.
#
# Quoted = the character before `$` is `"` or `'`. That covers `"${…}/x.sh" args`
# and `command='bash "${…}/x.sh"'`.
# ---------------------------------------------------------------------------
unquoted=$(awk '
  FNR == 1 { fence = 0 }
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  {
    if (fence || $0 ~ /^[[:space:]]*\$\{CLAUDE_PLUGIN_ROOT\}\//) {
      if ($0 ~ /(^|[^"'"'"'\\])\$\{CLAUDE_PLUGIN_ROOT\}\//) print FILENAME ":" FNR ": " $0
      next
    }
    n = split($0, part, "`")
    for (i = 2; i <= n; i += 2)
      if (part[i] ~ /(^|[^"'"'"'\\])\$\{CLAUDE_PLUGIN_ROOT\}\/[^ ]+ +[^ ]/) { print FILENAME ":" FNR ": " $0; break }
  }
' "${targets[@]}" 2>/dev/null || true)

if [ -n "$unquoted" ]; then
  drift=1
  {
    printf '\n'
    printf 'skill-paths: 🚨 unquoted ${CLAUDE_PLUGIN_ROOT} in a command:\n'
    printf '\n'
    printf '%s\n' "$unquoted" | sed 's/^/  /'
    printf '\n'
    printf '  The assistant runs this in a shell. Installed under a path with a space,\n'
    printf '  the root splits there and the command fails. Quote the path, keep the\n'
    printf '  arguments outside: "${CLAUDE_PLUGIN_ROOT}/scripts/x.sh" --flag\n'
  } >&2
fi

if [ "$drift" -eq 0 ]; then
  echo "skill-paths: ✓ user-time files use \${CLAUDE_PLUGIN_ROOT}, quoted where invoked; no dangling repo-doc refs"
fi

exit "$drift"
