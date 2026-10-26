#!/bin/bash
# crystal-lint.sh — structural validator for crystal workitems.
#
# Answers the question no existing mechanism asked: "is this file a workitem,
# or does it merely look like one?" The crystal-completion-guard checks open
# `- [ ]` at done-transition; nothing checked the SHAPE at creation. A workitem
# written without invoking crystal-grow — the common case when an assistant
# parks a backlog item as a side artifact of other work — passed every gate.
#
# Field report that produced this (2026-08-22, repo `executor`): an agent
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
#   [--summary]                            machine-readable: path<TAB>label<TAB>n
#   crystal-lint.sh --hook                 PostToolUse payload on stdin: new sidetracks without a checkbox
#   crystal-lint.sh --pre-hook             PreToolUse payload on stdin: the canon gate — blocks the edit
#   crystal-lint.sh --bash-hook            PostToolUse (Bash) payload on stdin: workitems a shell command
#                                          changed, checked against HEAD after the fact
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

# Both hooks run on every Write and Edit in every project, and nearly none of
# those is a workitem. Drop them before the libraries load and the crystal roots
# are walked, which is the costly part: a workitem is a `.md` written by one of
# three tools. The full scope test comes later; this one only has to be wider.
case " $* " in
  *" --hook "*|*" --pre-hook "*)
    payload=$(cat)
    [ -z "$payload" ] && exit 0
    printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || exit 0
    printf '%s' "$payload" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*\.md"' 2>/dev/null || exit 0
    ;;
  *" --bash-hook "*)
    # Every shell command in every project comes here, and a command that
    # names no workitem is not ours: dropped without a process.
    payload=$(cat)
    case "$payload" in *workitem*) ;; *) exit 0 ;; esac
    printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' 2>/dev/null || exit 0
    ;;
esac

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/crystal-path.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "crystal" || exit 0

# Warm the root cache in THIS shell before anything fans out into subshells.
# The memo inside resolve_crystal_roots is process-scoped, and every use of it
# below sits inside `$(...)`, `< <(...)` or a pipeline — a subshell inherits the
# cache but cannot fill it. Without this line the tree is rescanned once per
# call site (measured: 7× per hook run on an 11-root vault).
if command -v vdm_prime_crystal_roots >/dev/null 2>&1; then
  vdm_prime_crystal_roots
fi
fi

TEMPLATE="$SELF_DIR/../templates/workitem-template.md"
LINTER="$SELF_DIR/crystal-lint.py"
[ -f "$TEMPLATE" ] || exit 0
[ -f "$LINTER" ] || exit 0

mode="files"
quiet=""
summary=""
project_root=""
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all)          mode="all" ;;
    --staged)       mode="staged" ;;
    --print-canon)  mode="canon" ;;
    --hook)         mode="hook" ;;
    --pre-hook)     mode="pre-hook" ;;
    --bash-hook)    mode="bash-hook" ;;
    --quiet)        quiet="--quiet" ;;
    --summary)      summary="--summary" ;;
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
    python3 "$LINTER" ${quiet:+$quiet} ${summary:+$summary} "$@"
}

# --- --pre-hook / --hook: the two hook surfaces --------------------------------
# --pre-hook is the canon gate, on PreToolUse: exit 2 there stops the edit. It
# was on PostToolUse until 2026-10-15, where exit 2 only reports an edit that
# has already landed — 87 Decision Log entries written off canon after
# 2026-08-31 (canon-gate-scope DL #5). It blocks only what the edit may not
# leave behind: the file's structure in full, and in the Decision Log and the
# promises only what is new (DL #2, #6).
#
# --hook stays on PostToolUse for one thing: an open sidetrack this change
# introduced without a checkbox. That is advice, and it arrives within one tool
# call, whether or not the skill was ever invoked.
# is_workitem_path <path> <root>
#
# True only for the two shapes `find_workitems` enumerates:
#   <root>/<slug>/workitem.md   folder-stem, canonical
#   <root>/<slug>.md            flat, legacy
#
# Everything deeper is NOT a workitem. That exclusion is the whole reason this
# predicate exists: a crystal legitimately holds `<slug>/references/*.md` —
# intercom briefs, exported specs, transcripts — and those carry whatever
# frontmatter their origin gave them. An intercom brief arrives with
# `status: pending`, which is not in the workitem taxonomy and never should be.
# Linting them reports a stack of violations against files that were never
# claiming the canon, and a linter that fires on legitimate files gets switched
# off — which costs the real violations too.
#
# Keep in step with find_workitems() in lib/crystal-path.sh; that function walks
# the filesystem, this one tests a path string, and both encode the same shape.
# Resolve a path through symlinks without requiring the file to exist: the
# directory is canonicalised, the basename is kept. Both sides of the scope
# comparison below go through this — a root comes from `git rev-parse
# --show-toplevel` and is already real, while the path in a hook payload is
# whatever the harness was handed, and on macOS a project under /tmp or /var
# arrives as /var/… against a root of /private/var/…. Comparing those as
# strings puts the file outside every root, so the linter says nothing about a
# file it should have checked — the same silence a clean file produces.
canonicalize_path() {
  local p="$1" dir base real
  dir=$(dirname "$p")
  base=$(basename "$p")
  real=$(cd "$dir" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return; }
  printf '%s/%s' "$real" "$base"
}

is_workitem_path() {
  local path="$1" root="$2" rel
  path=$(canonicalize_path "$path")
  # `|| root="$2"`, not `|| root="$root"`: the failed `$(…)` has already
  # emptied `$root`. A root that is not on disk yet is the first workitem's.
  root=$(cd "$root" 2>/dev/null && pwd -P) || root="$2"
  case "$path" in
    "$root"/*) rel="${path#"$root"/}" ;;
    *) return 1 ;;
  esac
  case "$rel" in
    */*/*)          return 1 ;;   # deeper than <slug>/<file> — references/, attachments/, …
    */workitem.md)  return 0 ;;   # <slug>/workitem.md
    */*)            return 1 ;;   # <slug>/anything-else.md
    *.md)           return 0 ;;   # <slug>.md, flat legacy
    *)              return 1 ;;
  esac
}

# orphans_at_head <workitem> — the orphan sidetracks of the version committed at
# HEAD. Nothing for a file HEAD does not have (new, untracked) or outside git:
# then every orphan in the file is one this change introduced.
orphans_at_head() {
  local f="$1" dir prefix top snap
  dir=$(dirname "$f")
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  prefix=$(git -C "$dir" rev-parse --show-prefix 2>/dev/null) || return 0
  snap=$(mktemp 2>/dev/null) || return 0
  if git -C "$top" show "HEAD:${prefix}$(basename "$f")" >"$snap" 2>/dev/null; then
    audit_sidetracks_without_markers "$snap"
  fi
  rm -f "$snap"
}

# only_new_orphans <now> <at-head> — the lines of <now> whose card number is not
# an orphan at HEAD. Compared by number: a retitled card is the same card.
only_new_orphans() {
  local now="$1" was="$2" line n
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%.*}"
    case "
$was" in
      *"
$n."*) continue ;;
    esac
    printf '%s\n' "$line"
  done <<EOF
$now
EOF
}

if [ "$mode" = "hook" ] || [ "$mode" = "pre-hook" ]; then

  # Dependency-free scope prefilter — the answer is available precisely when
  # the linter is not. See lib/gate-guard.sh for why an unrunnable check
  # blocks rather than returning silence.
  lint_in_scope() {
    printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
    printf '%s' "$payload" | grep -qE 'workitem\.md|/tasks/' 2>/dev/null || return 1
    return 0
  }

  lint_unverified() {
    lint_in_scope || exit 0
    if command -v vdm_gate_unverified >/dev/null 2>&1; then
      vdm_gate_unverified "crystal-lint" "$1" \
        "a workitem was just written — whether it matches the canonical shape was never checked" \
        "install python3 — the linter is a python script — then re-run: \"\${CLAUDE_PLUGIN_ROOT}/scripts/crystal-lint.sh\" <file>" \
        "or compare the file against templates/workitem-template.md by hand"
    else
      printf '\n[crystal-lint] NOT CHECKED — %s\n  A workitem was written and the canon check could not run.\n\n' "$1" >&2
    fi
    exit 2
  }

  read_field() {
    if command -v vdm_json_field >/dev/null 2>&1; then
      vdm_json_field "$payload" "$1"
      return 0
    fi
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
  # Every hook payload carries `tool_name`, so an empty value means the payload
  # was not read — no parser on the machine, or a parser that is present and
  # broken. Both are "the check did not run", and the prefilter inside
  # lint_unverified decides whether this call was ours to check. Testing for
  # parser *availability* here instead would miss the broken-parser case
  # exactly the way the original code missed the missing-parser one.
  [ -z "$tool_name" ] && lint_unverified "could not read \`tool_name\` from the hook payload"
  case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
  esac

  file_path=$(read_field "tool_input.file_path")
  [ -z "$file_path" ] && exit 0

  # Only workitems, and only in one of the two canonical shapes — a stray .md
  # outside a crystal root, or a reference artifact inside one, is not linted.
  under_root=""
  if command -v resolve_crystal_roots >/dev/null 2>&1; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if is_workitem_path "$file_path" "$r"; then under_root="yes"; break; fi
    done < <(resolve_crystal_roots)
  fi
  # A repository's first workitem is written before its root exists: roots are
  # found by their files. On PostToolUse the file was there by then; here the
  # lib names the root the write would make (vdm_first_root_for).
  if [ -z "$under_root" ] && [ "$mode" = "pre-hook" ] && [ ! -e "$file_path" ] \
     && command -v vdm_first_root_for >/dev/null 2>&1; then
    p=$(vdm_real_path_of "$file_path")
    r=$(vdm_first_root_for "$p")
    [ -n "$r" ] && is_workitem_path "$p" "$r" && under_root="yes"
  fi
  [ -z "$under_root" ] && exit 0

  if [ "$mode" = "pre-hook" ]; then
    # The linter itself is python, so jq alone parses the payload but cannot lint.
    command -v python3 >/dev/null 2>&1 || lint_unverified "python3 is not on PATH"
    out=$(printf '%s' "$payload" | run_linter --pre-tool-use "$file_path" 2>&1 >/dev/null)
    rc=$?
    # 0 clean / 1 findings. A 1 that names no finding is a crash that happened
    # to exit 1, and anything else is no verdict; neither may read as clean,
    # and neither may read as a finding.
    case "$rc" in
      0) exit 0 ;;
      1) printf '%s\n' "$out" | grep -q '^  ✗ ' \
           || lint_unverified "the linter exited 1 without naming a finding" ;;
      *) lint_unverified "the linter exited $rc without reaching a verdict" ;;
    esac
    printf '%s\n' "$out" >&2
    cat >&2 <<'EOF'

[crystal-lint] Blocked: after this edit the workitem would be off canon. The
edit did not happen. What is owed:

  - the STRUCTURE in full, at every edit: required sections and frontmatter
    keys. An empty section is enough — adding one asserts nothing. Add them in
    this same edit (or one before it) and repeat the change.
  - in the Decision Log, only the entries this edit ADDS carry every field
    and a `Basis` from the taxonomy. Entries already in the file are not
    checked: the log is append-only, and writing a Basis into someone's past
    entry would be inventing it.

Print the canon:
  "${CLAUDE_PLUGIN_ROOT}/scripts/crystal-lint.sh" --print-canon

Do NOT infer a workitem's shape from a neighbouring file: a repo may hold files
imported by /vdm:crystal-migrate and files written under an older canon. The
only sources are the template and /vdm:crystal-grow. Extra sections and keys
are always fine.
EOF
    exit 2
  fi

  [ -f "$file_path" ] || exit 0

  # Open sidetracks without a checkbox — only the ones THIS change introduced.
  # The rule is crystal-multi-root DL #14, and until now it was enforced at one
  # moment only, the done-transition, when the reason is sessions old. Census of
  # the machine this plugin is developed on (2026-09-25): 276 such orphans in 64
  # of 134 live workitems, 235 of them with no checkbox at all and the rest with
  # a marker the parser cannot see. Two were written in this repo that day and
  # went into a commit. Measured against HEAD so that the backlog stays with the
  # done gate: a hook that recited it on every edit would pull it into sessions
  # that came for something else.
  orphans_new=""
  if command -v audit_sidetracks_without_markers >/dev/null 2>&1; then
    orphans_now=$(audit_sidetracks_without_markers "$file_path")
    if [ -n "$orphans_now" ]; then
      orphans_new=$(only_new_orphans "$orphans_now" "$(orphans_at_head "$file_path")")
    fi
  fi

  [ -z "$orphans_new" ] && exit 0

  if [ -n "$orphans_new" ]; then
    first_n=$(printf '%s\n' "$orphans_new" | head -n 1)
    first_n="${first_n%%.*}"
    first_n="${first_n#\#}"
    {
      printf '\n[crystal-lint] Open sidetracks this change introduced have no checkbox:\n'
      printf '%s\n' "$orphans_new" | sed 's/^/  /'
      cat <<EOF

An open sidetrack is an obligation, and only a \`- [ ]\` line counts as one: the
done-transition refuses the workitem while such a card has none, and by then
the reason is sessions old. Give each card its own checkbox, with the number
on the checkbox line itself:
  - [ ] Sidetrack #${first_n}: <what closes it>
Not seen: the number on a wrapped continuation line, "Sidetracks #1 и #2" (one
checkbox per number), "побег #${first_n}". If a card is not actually open,
change its **Status:** instead. Sidetracks committed before this change are
left to the done gate.
EOF
    } >&2
  fi
  exit 2
fi

# --- --bash-hook: the shell surface -------------------------------------------
# PostToolUse on Bash. The gates above hold Write, Edit and MultiEdit before they
# run; a shell command they never see. In the field seven of nine sessions looked
# at closely wrote their workitem with python or `sed -i`, one flipping the status
# to done that way (late-grow DL #6, Sidetrack #3). What a command will leave on
# disk is not in its text, so this looks after it: every workitem that differs
# from HEAD or is not committed yet is checked against HEAD by the rules the
# write gates apply — the canon, an open sidetrack this change introduced without
# a checkbox, and a terminal status with obligations left (crystal-completion-
# guard's checker, fed the file as a Write of what is on disk). The same move as
# comms-sent-check for letters (outgoing-ladder DL #6).
#
# After the fact it cannot stop the write. It names it while the file can still
# be fixed, before the commit and before "done" is reported.
#
# Exit: 0 nothing to say / 2 named (stderr returns to the assistant).
if [ "$mode" = "bash-hook" ]; then
  command -v git >/dev/null 2>&1 || exit 0
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  cd "$repo_root" 2>/dev/null || exit 0
  roots=$(resolve_crystal_roots 2>/dev/null)
  [ -z "$roots" ] && exit 0

  bash_unverified() {
    if command -v vdm_gate_unverified >/dev/null 2>&1; then
      vdm_gate_unverified "crystal-lint" "$1" \
        "a shell command named a workitem — whether what it left matches the canon and keeps its obligations was never checked" \
        "install python3 — the linter is a python script — then re-run: \"\${CLAUDE_PLUGIN_ROOT}/scripts/crystal-lint.sh\" <file>" \
        "or compare the file against templates/workitem-template.md by hand"
    else
      printf '\n[crystal-lint] NOT CHECKED — %s\n  A shell command named a workitem and the check could not run.\n\n' "$1" >&2
    fi
    exit 2
  }
  command -v python3 >/dev/null 2>&1 || bash_unverified "python3 is not on PATH"

  # What differs from HEAD, and what is not committed yet; without a HEAD all of
  # it is new. diff-index, not diff: `git diff <rev>` refreshes the index, and a
  # hook leaves the index alone (tests/hook-index-writes.test.sh). -z and `tr`
  # in the C locale for the reason --staged gives below.
  has_head=""
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    has_head="yes"
    cands=$( { git diff-index --name-only -z HEAD -- 2>/dev/null
               git ls-files --others --exclude-standard -z 2>/dev/null; } | LC_ALL=C tr '\0' '\n')
  else
    cands=$(git ls-files --cached --others --exclude-standard -z 2>/dev/null | LC_ALL=C tr '\0' '\n')
  fi
  cands=$(printf '%s\n' "$cands" | LC_ALL=C grep -E '(^|/)workitem\.md$' | LC_ALL=C sort -u)
  [ -z "$cands" ] && exit 0

  # The completion rule's terminal sets: the canonical status and every alias
  # the project maps to it — what crystal-completion-guard.sh hands its checker.
  done_csv="done"; superseded_csv="superseded"
  if [ -n "$aliases_csv" ]; then
    while IFS='=' read -r a target; do
      [ -n "$a" ] || continue
      case "$target" in
        done)       done_csv="${done_csv},${a}" ;;
        superseded) superseded_csv="${superseded_csv},${a}" ;;
      esac
    done <<<"$(printf '%s' "$aliases_csv" | tr ',' '\n')"
  fi
  roots_colon=$(printf '%s\n' "$roots" | LC_ALL=C tr '\n' ':' | LC_ALL=C sed 's/:$//')
  checker="$SELF_DIR/crystal-completion-guard.py"

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t crystallint) || exit 0
  trap 'rm -rf "$tmp"' EXIT

  report=""
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    abs="$repo_root/$f"
    [ -f "$abs" ] || continue
    under=""
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if is_workitem_path "$abs" "$r"; then under="yes"; break; fi
    done <<<"$roots"
    [ -z "$under" ] && continue

    n=$((n + 1))
    before=""
    if [ -n "$has_head" ] && git cat-file -e "HEAD:$f" 2>/dev/null; then
      # The same bytes as committed: a touch, or a rewrite that changed nothing.
      [ "$(git hash-object -- "$abs" 2>/dev/null)" = "$(git rev-parse -q --verify "HEAD:$f" 2>/dev/null)" ] && continue
      before="$tmp/$n.before"
      git show "HEAD:$f" >"$before" 2>/dev/null || before=""
    fi

    found=""
    # 1. The canon, as the pre-commit surface asks it: the structure in full,
    #    Decision Log entries and promises only where the change adds them.
    out=$(run_linter --against "$before" "$abs" 2>&1)
    case "$?" in
      0) ;;
      1) printf '%s\n' "$out" | grep -q '^  ✗ ' \
           || bash_unverified "the linter exited 1 without naming a finding"
         found="${found}${out}"$'\n' ;;
      *) bash_unverified "the linter ended without a verdict" ;;
    esac

    # 2. Open sidetracks without a checkbox — only those this change brought.
    if command -v audit_sidetracks_without_markers >/dev/null 2>&1; then
      orphans_now=$(audit_sidetracks_without_markers "$abs")
      if [ -n "$orphans_now" ]; then
        was=""
        [ -n "$before" ] && was=$(audit_sidetracks_without_markers "$before")
        orphans_new=$(only_new_orphans "$orphans_now" "$was")
        if [ -n "$orphans_new" ]; then
          found="${found}Open sidetracks this change introduced have no checkbox — one \`- [ ] Sidetrack #N: <what closes it>\` line each:"$'\n'
          found="${found}$(printf '%s\n' "$orphans_new" | sed 's/^/  /')"$'\n'
        fi
      fi
    fi

    # 3. A terminal status with obligations left, whether or not this change
    #    made it terminal — as the pre-commit completion gate asks it. The
    #    checker says nothing about any other status.
    if [ -f "$checker" ]; then
      out=$(python3 -c 'import json, sys
p = sys.argv[1]
print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": p, "content": open(p, encoding="utf-8", errors="replace").read()}}))' "$abs" \
        | CRYSTAL_ROOTS="$roots_colon" CRYSTAL_GATE_DONE="$done_csv" CRYSTAL_GATE_SUPERSEDED="$superseded_csv" \
          python3 "$checker" 2>&1 >/dev/null)
      case "$?" in
        0) ;;
        2) found="${found}${out}"$'\n' ;;
        *) bash_unverified "the completion checker ended without a verdict" ;;
      esac
    fi

    [ -n "$found" ] && report="${report}"$'\n'"── ${f}"$'\n'"${found}"
  done <<<"$cands"

  [ -z "$report" ] && exit 0
  {
    cat <<'EOF'

[crystal-lint] A shell command changed a workitem, and the write gates never saw
it — they hold Write, Edit and MultiEdit. Checked against HEAD after the fact:
the change is already on disk. Fix the file before it is committed or reported
done — with Edit, so the gates see the fix. A workitem changed by someone else's
session is theirs: name it to the user rather than rewrite it.
EOF
    printf '%s' "$report"
  } >&2
  exit 2
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

  # -z: in line form git quotes a path holding any byte outside ASCII, and a
  # quoted line is no workitem path — a non-canonical workitem under a Cyrillic
  # slug went through unlinted. `tr` in the C locale, because in a UTF-8 one
  # macOS `tr` stops at the first name that is not UTF-8 (Sidetrack #9,
  # docs/tasks/crystal-wake/workitem.md).
  staged_files=$(git diff --cached --name-only -z 2>/dev/null | LC_ALL=C tr '\0' '\n')
  [ -z "$staged_files" ] && exit 0

  roots=$(resolve_crystal_roots 2>/dev/null)
  [ -z "$roots" ] && exit 0

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t crystallint) || exit 0
  trap 'rm -rf "$tmp"' EXIT

  rc=0
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Must be a workitem, in one of the two canonical shapes, under a root.
    abs="$repo_root/$f"
    under=""
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if is_workitem_path "$abs" "$r"; then under="yes"; break; fi
    done <<<"$roots"
    [ -z "$under" ] && continue

    blob=$(git show ":$f" 2>/dev/null) || continue

    n=$((n + 1))
    holder="$tmp/$n"
    mkdir -p "$holder"
    # Preserve the basename: `workitem.md` is itself the claim to the canon.
    target="$holder/$(basename "$f")"
    printf '%s\n' "$blob" >"$target"

    # The state before is the blob at HEAD — the same comparison the PreToolUse
    # gate makes against the disk (canon-gate-scope DL #7). A file HEAD does not
    # have is new, and then everything in it is checked, whatever its status.
    before=""
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
      before="$holder/before"
      git show "HEAD:$f" >"$before" 2>/dev/null || before=""
    fi

    out=$(run_linter --against "$before" "$target" 2>&1)
    lrc=$?
    if [ "$lrc" -ne 0 ]; then
      rc=1
      # Map the scratch path back to the path the committer recognizes. The
      # real path goes in as the replacement, where `&`, `|` and `\` mean
      # something to sed — escaped, so a name holding one reads as itself.
      f_rep=$(printf '%s' "$f" | LC_ALL=C sed 's/[\\&|]/\\&/g')
      printf '%s\n' "$out" | LC_ALL=C sed "s|$target|$f_rep|g" >&2
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
  Compared with HEAD: the structure is owed in full, Decision Log entries and
  promises only where this commit adds them. A file new to HEAD owes all of it.

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
