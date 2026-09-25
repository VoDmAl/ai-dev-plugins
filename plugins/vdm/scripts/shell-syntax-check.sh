#!/bin/bash
# shell-syntax-check.sh — does the shell file that was just written parse under
# the interpreter that will run it?
#
# The incident that produced it (2026-09-25, this repo): a `case` pattern
# written `R*|C*)` inside `$( )` in docs-sync-reminder.sh. bash 3.2 — /bin/bash
# on every Mac — takes that `)` for the end of the substitution and stops
# parsing; bash 4+ accepts it. The edit "succeeded", nothing said otherwise, and
# the error surfaced only when a test ran the script. In a session it would not
# have surfaced at all: a hook that does not parse fails without a word, and the
# reminder composer simply goes on without it. `bash -n` answers in
# milliseconds; nothing asked it.
#
# Usage:
#   shell-syntax-check.sh <file>...   check the named files (exit 1 on a failure)
#   shell-syntax-check.sh --hook      PostToolUse payload on stdin (exit 2 on a
#                                     failure — stderr goes back to the assistant)
#   shell-syntax-check.sh --staged    the STAGED blob of every staged shell file,
#                                     for a pre-commit hook (exit 1 on a failure)
#
# Which interpreter. The one the file will meet — not the newest one around,
# which is exactly the one that accepted the incident:
#   #!/bin/bash, #!/bin/sh, #!/bin/zsh …   that binary
#   #!/usr/bin/env bash                    `bash` as PATH resolves it
#   no shebang, *.sh or *.bash             `bash` from PATH (a sourced lib)
#   no shebang, *.zsh                      `zsh` from PATH
# A bash script is checked with the PATH `bash` as well when that is a
# different binary, because `bash script.sh` ignores the shebang — and that is
# how reminders.sh starts every one of its children. An interpreter this machine
# does not have is skipped: the file cannot run here either, so there is nothing
# to predict.
#
# extglob. `bash -n` executes nothing, so a script's own `shopt -s extglob` never
# takes effect and every `+(a|b)` after it reads as a syntax error — a false
# positive on a correct script, the kind that gets a check switched off. A file
# that enables extglob is parsed with `-O extglob`. A file that uses the syntax
# without enabling it is still reported: it fails at run time too.
#
# Configuration: `.claude/vdm-plugins.json` → `shell-syntax.enabled` (default
# true). Fail-closed where it matters (lib/gate-guard.sh): a hook payload that
# could not be read, about a file that looks like shell, is reported as NOT
# CHECKED instead of passing.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1091
. "$SELF_DIR/../lib/config-read.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$SELF_DIR/../lib/gate-guard.sh" 2>/dev/null || true

if command -v vdm_is_enabled >/dev/null 2>&1; then
  vdm_is_enabled "shell-syntax" || exit 0
fi

mode="files"
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hook)   mode="hook" ;;
    --staged) mode="staged" ;;
    --)       ;;
    *)        files+=("$1") ;;
  esac
  shift
done

# shell_of <path> <first-line> — the interpreter the file declares (a name or a
# path), or nothing when it is not a shell file. The shebang outranks the name:
# a python script called x.sh is a python script.
shell_of() {
  local path="$1" line="$2" cmd=""
  case "$line" in
    '#!'*)
      line="${line#"#!"}"
      set -f
      # shellcheck disable=SC2086
      set -- $line
      set +f
      cmd="${1:-}"
      if [ "${cmd##*/}" = "env" ]; then
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -*|*=*) shift ;;
            *)      break ;;
          esac
        done
        cmd="${1:-}"
      fi
      ;;
    *)
      case "$path" in
        *.sh|*.bash) cmd="bash" ;;
        *.zsh)       cmd="zsh" ;;
        *)           return 0 ;;
      esac
      ;;
  esac
  case "${cmd##*/}" in
    sh|bash|zsh|dash|ksh) printf '%s\n' "$cmd" ;;
  esac
}

# resolve <name-or-path> — the executable it names on this machine, or nothing.
resolve() {
  case "$1" in
    */*) if [ -x "$1" ]; then printf '%s\n' "$1"; fi ;;
    *)   command -v "$1" 2>/dev/null | head -n 1 ;;
  esac
}

# interpreters_for <path> <first-line> — every interpreter the file will meet
# here, one per line: the declared one, and for bash also the PATH `bash`.
interpreters_for() {
  local declared first second
  declared=$(shell_of "$1" "$2")
  [ -n "$declared" ] || return 0
  first=$(resolve "$declared")
  if [ -n "$first" ]; then printf '%s\n' "$first"; fi
  if [ "${declared##*/}" = "bash" ]; then
    second=$(resolve bash)
    if [ -n "$second" ]; then
      if [ -z "$first" ] || ! [ "$first" -ef "$second" ]; then
        printf '%s\n' "$second"
      fi
    fi
  fi
}

# version_of <interpreter> — "bash 3.2.57" / "zsh 5.9", or nothing.
version_of() {
  local v b z
  v=$("$1" -c 'echo "${BASH_VERSION:-}|${ZSH_VERSION:-}"' 2>/dev/null) || return 0
  b="${v%%|*}"
  z="${v#*|}"
  if [ -n "$b" ]; then
    printf 'bash %s' "${b%%(*}"
  elif [ -n "$z" ]; then
    printf 'zsh %s' "$z"
  fi
}

first_line() {
  LC_ALL=C head -c 256 "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

# parse_check <label> <file> — prints a diagnostic and returns 1 when <file>
# does not parse under every interpreter it will meet. <label> is the path the
# message NAMES and the one whose extension counts; <file> is what is parsed
# (the same file, or a staged blob's copy).
parse_check() {
  local label="$1" f="$2" interps interp opts out ver rc=0 extglob="" hint=""
  [ -f "$f" ] || return 0
  interps=$(interpreters_for "$label" "$(first_line "$f")")
  [ -n "$interps" ] || return 0
  if grep -qE '^[[:space:]]*shopt[[:space:]].*-s[[:space:]].*extglob' "$f" 2>/dev/null; then
    extglob="yes"
  fi
  while IFS= read -r interp; do
    [ -n "$interp" ] || continue
    opts=""
    case "${interp##*/}" in
      bash) if [ -n "$extglob" ]; then opts="-O extglob"; fi ;;
      zsh)  opts="-f" ;;
    esac
    # shellcheck disable=SC2086
    if out=$(BASH_ENV='' ENV='' "$interp" $opts -n "$f" 2>&1); then
      continue
    fi
    rc=1
    ver=$(version_of "$interp")
    printf '%s does not parse under %s%s:\n' "$label" "$interp" "${ver:+ ($ver)}"
    printf '%s\n' "$out" | head -n 6 | sed 's/^/    /'
    case "$ver" in
      "bash 3."*)
        if printf '%s' "$out" | grep -qE "unexpected token .(;;|\\)|esac)"; then hint="yes"; fi ;;
    esac
  done <<EOF
$interps
EOF
  if [ -n "$hint" ]; then
    printf '    bash 3.2 is the stock /bin/bash on macOS and rejects some constructs newer\n'
    printf '    bash accepts. The usual one: a case pattern written `pat)` inside $( … ) —\n'
    printf '    bash 3.2 takes that `)` for the end of the substitution. Write `(pat)`.\n'
  fi
  return "$rc"
}

# --- --hook: PostToolUse payload on stdin -------------------------------------
if [ "$mode" = "hook" ]; then
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0

  # Dependency-free prefilter, consulted only when the payload could not be
  # read: is this a write of something named like a shell file? Narrow on
  # purpose — a machine without a JSON parser must not have every write blocked.
  shell_in_scope() {
    printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"' 2>/dev/null || return 1
    printf '%s' "$payload" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*\.(sh|bash|zsh)"' 2>/dev/null || return 1
  }
  shell_unverified() {
    shell_in_scope || exit 0
    if command -v vdm_gate_unverified >/dev/null 2>&1; then
      vdm_gate_unverified "shell-syntax" "$1" \
        "a shell file was just written — whether it parses was never checked" \
        "install python3 or jq so the hook can read its payload, then write again, or" \
        "check it by hand: \"\${CLAUDE_PLUGIN_ROOT}/scripts/shell-syntax-check.sh\" <file>"
    else
      printf '\n[shell-syntax] NOT CHECKED — %s\n  A shell file was written and could not be checked.\n\n' "$1" >&2
    fi
    exit 2
  }
  read_field() {
    if command -v vdm_json_field >/dev/null 2>&1; then vdm_json_field "$payload" "$1"; fi
  }

  # Every payload carries `tool_name`: empty means the payload was not read.
  tool_name=$(read_field "tool_name")
  [ -n "$tool_name" ] || shell_unverified "could not read \`tool_name\` from the hook payload"
  case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
  esac
  file_path=$(read_field "tool_input.file_path")
  [ -n "$file_path" ] || exit 0
  [ -f "$file_path" ] || exit 0

  if diag=$(parse_check "$file_path" "$file_path"); then
    exit 0
  fi
  {
    printf '\n[shell-syntax] %s\n' "$diag"
    cat <<'EOF'

A shell file that does not parse fails on every run — and inside a hook it
fails without a word. Fix it before this turn ends. Re-check by hand with:
  "${CLAUDE_PLUGIN_ROOT}/scripts/shell-syntax-check.sh" <file>
EOF
  } >&2
  exit 2
fi

# --- --staged: the pre-commit surface ------------------------------------------
# Parses the STAGED content, never what happens to sit on disk: an unstaged fix
# does not travel with the commit. Each blob is copied under a scratch root at
# its own relative path and parsed from there, so the interpreter's message
# names the path the committer knows.
if [ "$mode" = "staged" ]; then
  command -v git >/dev/null 2>&1 || exit 0
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  cd "$repo_root" || exit 0

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t shellsyntax) || exit 0
  trap 'rm -rf "$tmp"' EXIT

  rc=0
  n=0
  report=""
  while IFS= read -r -d '' f; do
    # Regular files only: a symlink's blob is its target's name, a submodule
    # has none.
    kind=$(git ls-files -s -- ":(literal)$f" 2>/dev/null | awk '{ print $1; exit }')
    case "$kind" in
      100644|100755) ;;
      *) continue ;;
    esac
    mkdir -p "$tmp/$(dirname "$f")" 2>/dev/null || continue
    git show ":$f" > "$tmp/$f" 2>/dev/null || continue
    [ -n "$(interpreters_for "$f" "$(first_line "$tmp/$f")")" ] || continue
    n=$((n + 1))
    rel="$f"
    case "$rel" in -*) rel="./$rel" ;; esac
    if ! diag=$(cd "$tmp" && parse_check "$f" "$rel"); then
      rc=1
      report="${report}${diag}
"
    fi
  done < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)

  if [ "$rc" -eq 0 ]; then
    if [ "$n" -gt 0 ]; then
      echo "shell-syntax: ✓ ${n} staged shell file(s) parse under the interpreter they declare"
    fi
  else
    printf '%s' "$report" >&2
    printf '\nshell-syntax: 🚨 a staged shell file does not parse under the interpreter it declares.\n' >&2
    printf '  This gate reads the STAGED content, so fix the file AND re-stage it.\n' >&2
    printf '  Re-check by hand: bash "%s" <file>\n' "$SELF" >&2
  fi
  exit "$rc"
fi

# --- explicit files -------------------------------------------------------------
[ ${#files[@]} -eq 0 ] && exit 0
rc=0
for f in "${files[@]}"; do
  case "$f" in -*) f="./$f" ;; esac
  parse_check "$f" "$f" || rc=1
done
exit "$rc"
