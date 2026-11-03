#!/bin/bash
# hq-session.sh — is a live HQ session of this project running on this machine?
#
# The owner, 2026-11-03: the sheet, tracking and what comes from outside go into
# a session of their own, `vdx ai --hq`, and while it lives the project's ordinary
# and focused sessions are working ones — those signals neither fill their context
# nor pull the thread away. A hook that prints such a signal asks `vdm_hq_quiet`
# first; what keeps a session safe stays: the rules, the guards, the list of active
# crystals. Only while it lives: with none, a session that works in focused alone
# is the only reader those signals have.
#
# Asked at every hook, with nothing stored: an HQ session may start or close in
# the middle of a working one, and a mark in a file could outlive it. The flag is
# read from the session's own process, as VDX_FOCUSED is.
#
# The order is the cost. Measured 2026-11-03 on 18 live session files at load
# 11–21: `ps -wwE` on one pid 5–8 ms, on all of them 0.7–1.0 s. So the session
# files are narrowed to this project first, and the environment is read only for
# the other live sessions found there: 1 git, 1 grep, 1 jq per file found, at most
# 1 ps — and no ps at all where this session is the project's only one.
#
# Fails open: without jq, or with no session files, nothing here says quiet, and
# the signals are printed as before. A reminder may fail open; a missed silence
# costs one line.
#
# Mirrored in every plugin that carries it: scripts/check-lib-sync.sh holds the
# copies equal. @see docs/tasks/hq-session-quiet/workitem.md — DL #1, #2, #6

# The variable is vdx's to name; this is the one line that knows it.
VDM_HQ_ENV=VDX_HQ

# vdm_hq_quiet — this is an ordinary or a focused session, and a live HQ session of
# its project runs on this machine. An intercom session keeps its own rules and an HQ
# session gets everything; started with either flag and focused, it is a focused one.
vdm_hq_quiet() {
  if [ "${VDX_FOCUSED:-}" != 1 ]; then
    [ "${VDX_INTERCOM:-}" = 1 ] && return 1
    [ "${!VDM_HQ_ENV:-}" = 1 ] && return 1
  fi
  vdm_hq_live
}

# vdm_hq_live — a session other than this one, started with the HQ flag, lives on
# this machine with its working directory in this project. Live means what it
# means for every session here: not a sync conflict, its socket exists, its pid
# answers. The caller's project is the git toplevel of CLAUDE_PROJECT_DIR or the
# working directory. $HOME and / are not projects.
vdm_hq_live() {
  local dir root f pid cwd sock sid pids="" found="" hit
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  [ -d "$dir" ] || return 1
  root="${CLAUDE_PROJECT_DIR:-$PWD}"
  root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || (cd "$root" 2>/dev/null && pwd -P))"
  case "$root" in ''|/|"$HOME") return 1 ;; esac
  while IFS= read -r f; do
    case "${f##*/}" in *.sync-conflict-*) continue ;; esac
    # Unit separator, not TAB: TAB is whitespace to `read`, and an empty field
    # would shift the ones after it.
    IFS=$'\037' read -r pid cwd sock sid < <(
      jq -r '[(.pid // "" | tostring), (.cwd // ""), (.messagingSocketPath // ""), (.sessionId // "")] | join("\u001f")' "$f" 2>/dev/null
    ) || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || [ "$sid" != "$CLAUDE_CODE_SESSION_ID" ] || continue
    # The harness writes the physical path, as git prints the toplevel: 18 of 18 live
    # session files and 26 of 26 transcript directories, 2026-11-03.
    case "$cwd/" in "$root"/*) ;; *) continue ;; esac
    [ -n "$sock" ] && [ -S "$sock" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    pids="${pids:+$pids,}$pid"
    found="${found}${pid}"$'\037'"${cwd}"$'\n'
  done < <(grep -l -F "\"$root" "$dir"/*.json 2>/dev/null)
  [ -n "$pids" ] || return 1
  # A session below the root may belong to a repository of its own, nested in
  # this one. Only a session that carries the flag costs that one more git.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    cwd="$(printf '%s' "$found" | awk -F '\037' -v p="$hit" '$1 == p { print $2; exit }')"
    [ "$cwd" = "$root" ] && return 0
    [ "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] && return 0
  done < <(_vdm_hq_flagged "$pids")
  return 1
}

# _vdm_hq_flagged <pid,pid,…> — those of them started with the HQ flag and neither
# focused nor intercom: a session started with both is what those modes make it.
# One read of all of them: Linux exposes each in /proc, macOS shows them to `ps -E`
# for the owner's own processes.
_vdm_hq_flagged() {
  {
    if [ -r "/proc/${1%%,*}/environ" ]; then
      local p
      for p in ${1//,/ }; do
        printf '%s %s\n' "$p" "$(LC_ALL=C tr '\0' ' ' < "/proc/$p/environ" 2>/dev/null)"
      done
    else
      ps -wwE -p "$1" -o pid=,command= 2>/dev/null
    fi
  } | awk -v hq="$VDM_HQ_ENV=1" '{
        h = o = 0
        for (i = 2; i <= NF; i++) {
          if ($i == hq) h = 1
          if ($i == "VDX_FOCUSED=1" || $i == "VDX_INTERCOM=1") o = 1
        }
        if (h && !o) print $1
      }'
}
