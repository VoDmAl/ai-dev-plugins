#!/bin/bash
# config-path.test.sh — where a project's vdm-plugins.json is looked for, and
# what finding it costs.
#
# The assertion this file exists for: a config read costs no process.
# `resolve_config_path` asked git for the project root on every call, and every
# `vdm_config_read` makes that call — a hook reads its config a dozen times and
# more. One crystal-capture run on the first prompt of a session made 41
# `git rev-parse` calls, and an ordinary prompt spent 27 of its 98 launches on
# them (Sidetrack #8, docs/tasks/crystal-wake/workitem.md). The root is asked
# for once, when the library is sourced; the rest of the file checks that the
# remembered answer is never given where it would be wrong.
#
# Run: bash tests/config-path.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment first: the fixtures below run
# `git init`, and as a child of a live `git commit` the inherited
# GIT_INDEX_FILE would point them at that commit's index (tests/gates.test.sh,
# 2026-09-03: eight files swept into an unrelated commit).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READ_LIB="$REPO_ROOT/plugins/vdm/lib/config-read.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t configpath)
trap 'rm -rf "$TMP"' EXIT
# The real path: git answers with symlinks resolved, and /var is /private/var.
REAL=$(cd "$TMP" && pwd -P)

# git launches, counted by a shim ahead of the real one on PATH.
SHIM="$REAL/shim"
mkdir -p "$SHIM"
real_git=$(type -P git)
cat > "$SHIM/git" <<EOF
#!/bin/bash
printf x >> "\$LAUNCH_LOG"
exec "$real_git" "\$@"
EOF
chmod +x "$SHIM/git"

A="$REAL/a"
B="$REAL/b"
N="$REAL/nogit"
mkdir -p "$A/.claude" "$A/deep/er" "$B/.qwen" "$N"
( cd "$A" && git init -q . ) >/dev/null 2>&1
( cd "$B" && git init -q . ) >/dev/null 2>&1

# git_launches <dir> <reads> — git launches for sourcing the library in <dir>
# and reading the config <reads> times, each from inside `$(...)`, as every
# caller does.
git_launches() {
  : > "$REAL/log"
  ( cd "$1" && LAUNCH_LOG="$REAL/log" PATH="$SHIM:$PATH" bash -c '
      . "$1"
      i=0
      while [ "$i" -lt "$2" ]; do v=$(vdm_config_read crystal enabled true); i=$((i + 1)); done
    ' _ "$READ_LIB" "$2" )
  wc -c < "$REAL/log" | tr -d ' '
}
# where <dir> [<then>] — resolve_config_path from a shell that sourced the
# library in <dir> and then, if given, moved to <then>.
where() {
  ( cd "$1" && bash -c '. "$1"; [ -n "$2" ] && cd "$2"; resolve_config_path' _ "$READ_LIB" "${2:-}" )
}

# ---------------------------------------------------------------------------
printf '\na config read costs no process\n'
# ---------------------------------------------------------------------------
one=$(git_launches "$A" 1)
ten=$(git_launches "$A" 10)
# The canary first: a counter that sees nothing makes every comparison equal.
if [ "${one:-0}" -gt 0 ]; then ok "canary: the counter sees git ($one launch for one read)"
else bad "canary: the counter sees git" "no launch counted"; fi
eq "RED: ten reads cost what one does" "$one" "$ten"

# ---------------------------------------------------------------------------
printf '\nthe answer is the project it is asked from\n'
# ---------------------------------------------------------------------------
eq "a repository with .claude/" "$A/.claude/vdm-plugins.json" "$(where "$A")"
eq "…asked from a subdirectory" "$A/.claude/vdm-plugins.json" "$(where "$A/deep/er")"
eq "a repository with only .qwen/" "$B/.qwen/vdm-plugins.json" "$(where "$B")"
eq "outside git: the working directory" "$N/.claude/vdm-plugins.json" "$(where "$N")"
eq "sourced in one repository, asked from another: not the first one's answer" \
  "$B/.qwen/vdm-plugins.json" "$(where "$A" "$B")"
got=$( cd "$N" && bash -c '
    . "$1"
    GIT_DIR="$2/.git"; GIT_WORK_TREE="$2"; export GIT_DIR GIT_WORK_TREE
    resolve_config_path
  ' _ "$READ_LIB" "$A" )
eq "GIT_DIR and GIT_WORK_TREE set after sourcing: git's answer, not the remembered one" \
  "$A/.claude/vdm-plugins.json" "$got"

printf '\nconfig-path: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
