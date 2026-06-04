#!/usr/bin/env bash
# race.sh — same-task best-of-N. Provision N isolated attempts at ONE task, compare them, keep one.
#
# When a task is high-stakes or open-ended, one agent's first answer isn't necessarily the best.
# Race mode dispatches N workers at the SAME task on DISJOINT throwaway branches
# (agent/<id>-<slug>-r1..rN), each with the same claim. Because only ONE attempt is ever merged, the
# shared claim is safe here — the attempts never combine. You compare and keep the winner; the rest
# are torn down.
#
# Usage:
#   race.sh create  <id> <slug> <N> [base-ref] [claim-prefix ...]   # provision N attempts
#   race.sh compare <id> <slug> <N> [base-ref]                      # diffstat + commits per attempt
#   race.sh keep    <id> <slug> <N> <winner>                        # remove all attempts except <winner>
#
# After `keep`, the surviving branch agent/<id>-<slug>-r<winner> goes through the normal
# validate → human-gate → merge-train lifecycle like any other task branch.
set -eo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wt="$here/worktree.sh"

repo_root() { git rev-parse --show-toplevel; }
wt_dir_for() { local r n p; r="$(repo_root)"; n="$(basename "$r")"; p="$(dirname "$r")"; printf '%s/%s-worktrees/%s' "$p" "$n" "$1"; }

cmd="${1:-}"
case "$cmd" in
  create)
    id="${2:?id}"; slug="${3:?slug}"; n="${4:?N (number of attempts)}"; base="${5:-HEAD}"
    shift $(( $# < 5 ? $# : 5 )); claim=( "$@" )
    printf '['
    sep=""
    i=1
    while [ "$i" -le "$n" ]; do
      out="$(bash "$wt" create "$id" "${slug}-r${i}" "$base" "${claim[@]}" 2>/dev/null | tail -1)"
      # worktree.sh already prints a complete {...}; splice "variant" in after the opening brace.
      printf '%s{"variant":%s,%s' "$sep" "$i" "${out#\{}"
      sep=","
      i=$(( i + 1 ))
    done
    printf ']\n'
    echo "race: provisioned $n attempts of $id-$slug. Dispatch the SAME brief to each agent/${id}-${slug}-rN." >&2
    ;;
  compare)
    id="${2:?id}"; slug="${3:?slug}"; n="${4:?N}"; base="${5:-HEAD}"
    printf '%-6s %-34s %7s %8s  %s\n' "ATTEMPT" "BRANCH" "COMMITS" "DIFF" "STATE"
    i=1
    while [ "$i" -le "$n" ]; do
      br="agent/${id}-${slug}-r${i}"
      d="$(wt_dir_for "${id}-${slug}-r${i}")"
      if git show-ref --verify --quiet "refs/heads/$br"; then
        commits="$(git rev-list --count "$base..$br" 2>/dev/null || echo 0)"
        stat="$(git diff --shortstat "$base...$br" 2>/dev/null | sed 's/^ *//')"
        state="clean"
        [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && state="uncommitted"
        printf '%-6s %-34s %7s %8s  %s\n' "r$i" "$br" "$commits" "${stat:-—}" "$state"
      else
        printf '%-6s %-34s %7s %8s  %s\n' "r$i" "$br" "-" "-" "MISSING"
      fi
      i=$(( i + 1 ))
    done
    echo "Tip: 'git diff $base...agent/${id}-${slug}-rK' (or review.sh) to read an attempt before choosing." >&2
    ;;
  keep)
    id="${2:?id}"; slug="${3:?slug}"; n="${4:?N}"; win="${5:?winner attempt number}"
    i=1
    while [ "$i" -le "$n" ]; do
      if [ "$i" -ne "$win" ]; then
        bash "$wt" remove "$id" "${slug}-r${i}" >/dev/null 2>&1 || true
        # Race losers are deliberately-discarded throwaways, so FORCE-drop the branch even with
        # unmerged commits (worktree.sh's safe -d preserves them — right for real tasks, not here).
        git branch -D "agent/${id}-${slug}-r${i}" >/dev/null 2>&1 || true
      fi
      i=$(( i + 1 ))
    done
    printf '{"kept":"agent/%s-%s-r%s"}\n' "$id" "$slug" "$win"
    echo "race: kept r$win; losing attempts torn down. Send the winner through validate → gate → merge." >&2
    ;;
  *)
    echo "usage: race.sh {create <id> <slug> <N> [base] [claim...] | compare <id> <slug> <N> [base] | keep <id> <slug> <N> <winner>}" >&2
    exit 2
    ;;
esac
