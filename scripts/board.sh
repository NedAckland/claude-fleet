#!/usr/bin/env bash
# board.sh — one-line-per-agent status of every agent/* worktree vs a base branch.
# Pair this with your task list (status/owner) to render the full board.
#
# Usage: board.sh [--watch [secs]] [base-branch] [stale-minutes]
#   --watch [secs]  re-render every <secs> (default 3) until Ctrl-C — a live fleet view
#   base-branch     default: current HEAD branch
#   stale-minutes   default: $FLEET_STALE_MINUTES or 10 — a worker whose last heartbeat is older than
#                   this (and whose tree isn't clean-and-merged) is flagged STALL? so you can probe it.
#
# The HB column shows "<age> #<cycles>" from each worktree's .agent-heartbeat (stamped by the
# heartbeat PostToolUse hook). PID/branch liveness alone misses a worker that's busy-but-not-
# committing or stuck in a loop; heartbeat age is the progress signal that catches the zombie case.
set -eo pipefail

watch=""; interval=3
if [ "${1:-}" = "--watch" ]; then
  watch=1; shift
  case "${1:-}" in (''|*[!0-9]*) ;; (*) interval="$1"; shift ;; esac
fi

base="${1:-}"
if [ -z "$base" ]; then
  base="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)"
fi
stale_min="${2:-${FLEET_STALE_MINUTES:-10}}"

human_age() { # <seconds>
  local s="$1"
  if   [ "$s" -lt 60 ]   2>/dev/null; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ] 2>/dev/null; then printf '%dm' "$((s/60))"
  else printf '%dh' "$((s/3600))"; fi
}

render() {
  local now; now="$(date +%s)"
  printf '%-22s %-30s %5s %5s %-10s %s\n' "WORKTREE" "BRANCH" "AHEAD" "BHND" "HB" "STATE"
  git worktree list --porcelain | awk '
    /^worktree /{wt=$2}
    /^branch /{print wt"\t"$2}
  ' | while IFS=$'\t' read -r wt ref; do
    br="${ref#refs/heads/}"
    case "$br" in
      agent/*) ;;
      *) continue ;;
    esac
    counts="$(git rev-list --left-right --count "$base...$br" 2>/dev/null || printf '0\t0')"
    behind="$(printf '%s' "$counts" | awk '{print $1}')"
    ahead="$(printf '%s' "$counts" | awk '{print $2}')"
    state="clean"
    dirty=""
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      state="uncommitted"; dirty="1"
    fi

    hb="-"; stale=""
    if [ -f "$wt/.agent-heartbeat" ]; then
      ts="$(awk '{print $1}' "$wt/.agent-heartbeat" 2>/dev/null)"
      cyc="$(awk '{print $2}' "$wt/.agent-heartbeat" 2>/dev/null)"
      case "$ts" in (*[!0-9]*|"") ts="" ;; esac
      if [ -n "$ts" ]; then
        age=$(( now - ts ))
        hb="$(human_age "$age") #${cyc:-0}"
        [ "$age" -gt $(( stale_min * 60 )) ] && stale="1"
      fi
    fi
    # In-flight (has work or dirty) but heartbeat is stale → likely zombie.
    if [ -n "$stale" ] && { [ -n "$dirty" ] || [ "${ahead:-0}" -gt 0 ]; }; then
      state="STALL? ($state)"
    fi

    printf '%-22s %-30s %5s %5s %-10s %s\n' "$(basename "$wt")" "$br" "${ahead:-0}" "${behind:-0}" "$hb" "$state"
  done
}

if [ -n "$watch" ]; then
  while :; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    printf 'claude-fleet board — base %s — every %ss — %s (Ctrl-C to stop)\n\n' "$base" "$interval" "$(date '+%H:%M:%S')"
    render
    sleep "$interval"
  done
else
  render
fi
