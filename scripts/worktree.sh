#!/usr/bin/env bash
# worktree.sh — provision/teardown a per-task git worktree + agent/* branch.
# Worktrees live in a sibling "<repo>-worktrees/" dir so the main checkout stays clean.
#
# Usage:
#   worktree.sh create <id> <slug> [base-ref] [claim-prefix ...]   # base-ref defaults to HEAD
#   worktree.sh claim  <id> <slug> <claim-prefix> [claim-prefix ...]
#   worktree.sh remove <id> <slug>
#   worktree.sh list
#
# create/remove print one line of JSON for the orchestrator to parse.
#
# The claim prefixes (if given) are written to "<worktree>/.agent-claim" — one prefix per line —
# and git-excluded so they never commit. The claim-guard PreToolUse hook reads that file to ENFORCE
# the claim (deny Edit/Write outside it; best-effort for Bash), turning the path-claim from advisory
# prose into a real guardrail (authoritatively backstopped by the merge-validator's scope check).
set -eo pipefail

repo_root() { git rev-parse --show-toplevel; }

wt_dir_for() { # <key>
  local root name parent
  root="$(repo_root)"
  name="$(basename "$root")"
  parent="$(dirname "$root")"
  printf '%s/%s-worktrees/%s' "$parent" "$name" "$1"
}

branch_for() { printf 'agent/%s' "$1"; }

write_claim() { # <worktree> <prefix...>
  local wt="$1"; shift
  [ "$#" -eq 0 ] && return 0
  : > "$wt/.agent-claim"
  local p
  for p in "$@"; do printf '%s\n' "$p" >> "$wt/.agent-claim"; done
  # Keep orchestration scratch files out of the worker's diff (per-worktree exclude).
  local excl
  excl="$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$excl" ]; then
    local f
    for f in .agent-claim .agent-heartbeat .agent-trail .agent-trail.tmp; do
      grep -qxF "$f" "$excl" 2>/dev/null || echo "$f" >> "$excl"
    done
  fi
}

cmd="${1:-}"
case "$cmd" in
  create)
    id="${2:?id required}"; slug="${3:?slug required}"; base="${4:-HEAD}"
    shift $(( $# < 4 ? $# : 4 )); claim_prefixes=( "$@" )   # any args after base are claim prefixes
    key="${id}-${slug}"
    wt="$(wt_dir_for "$key")"
    br="$(branch_for "$key")"
    mkdir -p "$(dirname "$wt")"
    if git show-ref --verify --quiet "refs/heads/$br"; then
      # branch already exists (e.g. re-dispatch onto prior work) — attach a worktree to it
      git worktree add "$wt" "$br" >&2
    else
      git worktree add "$wt" -b "$br" "$base" >&2
    fi
    [ "${#claim_prefixes[@]}" -gt 0 ] && write_claim "$wt" "${claim_prefixes[@]}"
    printf '{"worktree":"%s","branch":"%s","base":"%s"}\n' "$wt" "$br" "$base"
    ;;
  claim)
    id="${2:?id required}"; slug="${3:?slug required}"; shift 3
    [ "$#" -ge 1 ] || { echo "claim: at least one path prefix required" >&2; exit 2; }
    wt="$(wt_dir_for "${id}-${slug}")"
    [ -d "$wt" ] || { echo "claim: no worktree at $wt" >&2; exit 2; }
    write_claim "$wt" "$@"
    printf '{"worktree":"%s","claim":[%s]}\n' "$wt" "$(printf '"%s",' "$@" | sed 's/,$//')"
    ;;
  remove)
    id="${2:?id required}"; slug="${3:?slug required}"
    key="${id}-${slug}"
    wt="$(wt_dir_for "$key")"
    br="$(branch_for "$key")"
    git worktree remove "$wt" --force 2>/dev/null || true
    git worktree prune
    # Remove the shared parent dir only if now empty (rmdir refuses if other worktrees remain).
    rmdir "$(dirname "$wt")" 2>/dev/null || true
    deleted="false"
    if git branch -d "$br" 2>/dev/null; then
      deleted="true"
    else
      echo "note: branch $br not deleted (unmerged commits). Use 'git branch -D $br' if you are sure." >&2
    fi
    printf '{"removed":"%s","branch":"%s","branchDeleted":%s}\n' "$wt" "$br" "$deleted"
    ;;
  list)
    git worktree list
    ;;
  *)
    echo "usage: worktree.sh {create <id> <slug> [base] [claim...] | claim <id> <slug> <prefix...> | remove <id> <slug> | list}" >&2
    exit 2
    ;;
esac
