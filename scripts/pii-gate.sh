#!/bin/bash
# pii-gate.sh — the PII gate of this repository (crystal public-repo-cleanup).
#
#   scripts/pii-gate.sh index           .githooks/pre-commit, gate 13: what the commit adds
#   scripts/pii-gate.sh message <file>  .githooks/commit-msg: the message and the signature
#
# Both run scripts/pii-scan.py --gate. The scanner declares its two dependencies
# in its own header and runs through uv, which installs them into its cache on
# the first run, so nothing lands in the work tree (DL #12). A gate that cannot
# look blocks, and says what to install (DL #10).
#
# @see tests/pii-scan.test.sh — the red tests

set -u

if ! command -v uv >/dev/null 2>&1; then
  echo "pii: uv is not on PATH, so nothing checked what this commit publishes — blocked." >&2
  echo "     Install it once per machine: brew install uv (CLAUDE.md → Dev setup)." >&2
  exit 1
fi
exec uv run --quiet --script "$(dirname "$0")/pii-scan.py" "$@" --gate
