#!/bin/bash
# git-path-lists.test.sh — every list of paths read from git is read
# NUL-separated, and turned back into lines in the C locale.
#
# Why this is a rule with a check and not a habit: the same defect was fixed
# three times in three places, each time as if new. In line form git quotes any
# path holding a byte outside ASCII — `"docs/\320\224…"` — and the quoted form is
# no path: it fails `[ -f ]`, matches no pattern, breaks JSON. docs-sync learned
# -z in 2.35.3; the drift scanner next door did not until 2.36.3; the census
# after that found eight more readers, among them two gates that let a Cyrillic
# workitem through unchecked (Sidetrack #9, docs/tasks/crystal-wake/workitem.md).
#
# The second half is the trap in the fix itself. Raw names reach `tr`, and in a
# UTF-8 locale macOS `tr` stops at the first byte that is not UTF-8 — APFS will
# not store such a name, a git index will, and one repository on this machine
# holds several. So a NUL-to-line `tr` runs in the C locale: on its own line
# (`LC_ALL=C tr`), or in a script that exports it.
#
# Line-based on purpose, and blind on purpose to what it cannot see: a git
# command split over several lines is judged by the line that names git.
#
# Run: bash tests/git-path-lists.test.sh   (exit 0 = all pass)

set -u

# Scrub git's per-invocation environment, as every harness here does. This one
# runs no git today; the scrub is an invariant of harnesses, not of the ones
# that happen to call git now (tests/gates-harness-isolation.test.sh).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gitpathlists)
trap 'rm -rf "$TMP"' EXIT

# lint <file...> — one line per violation: `file:line: what`.
lint() {
  LC_ALL=C awk '
    FNR == 1 { exported = 0; py = (FILENAME ~ /\.py$/) }
    /^[[:space:]]*export LC_ALL=C([[:space:];]|$)/ { exported = 1 }
    /^[[:space:]]*#/ { next }
    {
      if (py) is_git = ($0 ~ /run_git\(|"git"/)
      else    is_git = ($0 ~ /(^|[^A-Za-z0-9_.-])git[[:space:]]/)
      lists = ($0 ~ /ls-files|--name-only|--name-status|--porcelain|diff-tree|ls-tree/)
      has_z = ($0 ~ /(^|[[:space:]"\047(\[,])-z([[:space:]"\047)\],]|$)/)
      discarded = ($0 ~ />[[:space:]]*\/dev\/null/ && $0 !~ /2>[[:space:]]*\/dev\/null/) \
                  || $0 ~ /[^2]>[[:space:]]*\/dev\/null/
      if (is_git && lists && !has_z && !discarded)
        printf "%s:%d: git lists paths without -z\n", FILENAME, FNR
      if ($0 ~ /tr[[:space:]]+(\047|")\\0(\047|")/ && $0 !~ /LC_ALL=C/ && !exported)
        printf "%s:%d: NUL-to-line tr outside the C locale\n", FILENAME, FNR
    }' "$@"
}

# ---------------------------------------------------------------------------
printf '\nthe detector sees what it is for\n'
# ---------------------------------------------------------------------------
# Its own red cases first: a detector that reports nothing passes every tree,
# and the tree below would then prove nothing.
cat > "$TMP/bad.sh" <<'EOF'
#!/bin/bash
staged=$(git diff --cached --name-only)
list=$(git ls-files -z --cached | tr '\0' '\n')
EOF
cat > "$TMP/good.sh" <<'EOF'
#!/bin/bash
# git diff --cached --name-only   (a comment is not a call)
staged=$(git diff --cached --name-only -z | LC_ALL=C tr '\0' '\n')
git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || exit 0
while IFS= read -r -d '' f; do :; done < <(git ls-files -z -co --exclude-standard)
EOF
cat > "$TMP/exported.sh" <<'EOF'
#!/bin/bash
export LC_ALL=C
list=$(git ls-files -z --cached | tr '\0' '\n')
EOF
cat > "$TMP/bad.py" <<'EOF'
out = run_git(["status", "--porcelain"], cwd=root)
EOF
cat > "$TMP/good.py" <<'EOF'
"""e.g. `git status --porcelain` in a docstring is not a call"""
out = run_git(["status", "--porcelain", "-z"], cwd=root)
EOF

out=$(lint "$TMP/bad.sh")
case "$out" in *"bad.sh:2: git lists paths without -z"*) ok "canary: a line-form path list is caught" ;;
  *) bad "canary: a line-form path list is caught" "$out" ;; esac
case "$out" in *"bad.sh:3: NUL-to-line tr outside the C locale"*) ok "canary: a tr in the user's locale is caught" ;;
  *) bad "canary: a tr in the user's locale is caught" "$out" ;; esac
out=$(lint "$TMP/bad.py")
case "$out" in *"bad.py:1: git lists paths without -z"*) ok "canary: a python call in line form is caught" ;;
  *) bad "canary: a python call in line form is caught" "$out" ;; esac
out=$(lint "$TMP/good.sh" "$TMP/exported.sh" "$TMP/good.py")
if [ -z "$out" ]; then ok "the right forms pass: -z, C locale, a comment, discarded output, a docstring"
else bad "the right forms pass: -z, C locale, a comment, discarded output, a docstring" "$out"; fi

# ---------------------------------------------------------------------------
printf '\nthe tree\n'
# ---------------------------------------------------------------------------
files=()
for f in "$REPO_ROOT"/plugins/*/scripts/* "$REPO_ROOT"/plugins/*/lib/* \
         "$REPO_ROOT"/plugins/*/bin/* "$REPO_ROOT"/scripts/* "$REPO_ROOT"/.githooks/*; do
  [ -f "$f" ] && files+=("$f")
done
if [ "${#files[@]}" -gt 20 ]; then ok "the tree is read (${#files[@]} files)"
else bad "the tree is read" "only ${#files[@]} files — the globs have gone wrong"; fi
out=$(lint "${files[@]}" | sed "s|^$REPO_ROOT/||")
if [ -z "$out" ]; then ok "RED: every path list from git in the shipped and dev scripts is read with -z, in the C locale"
else bad "RED: every path list from git in the shipped and dev scripts is read with -z, in the C locale" "$out"; fi

printf '\ngit-path-lists: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
