#!/usr/bin/env bash
# trail.sh — show the recent ACTION TRAIL of a worker (what it actually did, not just "is it alive").
# Reads the bounded .agent-trail the heartbeat hook maintains in each claimed worktree.
#
# Usage:
#   trail.sh <id> <slug> [n]     # last n actions for worktree <id>-<slug> (default 20)
#   trail.sh <worktree-path> [n]
#
# Pairs with board.sh: board.sh tells you a worker is STALL?; trail.sh tells you what it was doing
# when it stalled (e.g. stuck re-running the same Bash, or looping edits on one file).
set -eo pipefail

repo_root() { git rev-parse --show-toplevel; }
wt_dir_for() { local r n p; r="$(repo_root)"; n="$(basename "$r")"; p="$(dirname "$r")"; printf '%s/%s-worktrees/%s' "$p" "$n" "$1"; }

if [ -d "${1:-}" ]; then
  wt="$1"; n="${2:-20}"
else
  id="${1:?usage: trail.sh <id> <slug> [n] | <worktree-path> [n]}"; slug="${2:?slug required}"; n="${3:-20}"
  wt="$(wt_dir_for "${id}-${slug}")"
fi

trail="$wt/.agent-trail"
[ -f "$trail" ] || { echo "no action trail at $trail (worker hasn't acted yet, or isn't a claimed worktree)"; exit 0; }

printf '%-8s  %-12s %s\n' "AGO" "TOOL" "TARGET"
now="$(date +%s)"
tail -n "$n" "$trail" | while IFS=$'\t' read -r ts tool target; do
  case "$ts" in (*[!0-9]*|"") age="?" ;; (*) d=$(( now - ts ))
    if   [ "$d" -lt 60 ];   then age="${d}s"
    elif [ "$d" -lt 3600 ]; then age="$((d/60))m"
    else age="$((d/3600))h"; fi ;;
  esac
  printf '%-8s  %-12s %s\n' "$age" "$tool" "$target"
done
