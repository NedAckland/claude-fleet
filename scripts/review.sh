#!/usr/bin/env bash
# review.sh — render a feature branch's diff for human review at the merge gate, with stable
# per-file + hunk anchors you can attach comments to. Turns the gate from binary approve/hold into
# a "leave comments → worker revises" loop.
#
# Usage:
#   review.sh <id> <slug> [base-ref]        # default base: current HEAD branch
#   review.sh <branch>    [base-ref]
#
# Output: a files summary, then each file's diff. Comment by referring to "FILE n" / a hunk's @@ line.
# Collect the user's comments and re-dispatch the SAME worker (its worktree still exists) with a
# revision brief — see references/protocols.md "Revision loop".
set -eo pipefail

base="${3:-}"
if git show-ref --verify --quiet "refs/heads/${1:-}"; then
  br="$1"; base="${2:-}"
else
  id="${1:?usage: review.sh <id> <slug> [base] | <branch> [base]}"; slug="${2:?slug required}"
  br="agent/${id}-${slug}"
fi
[ -n "$base" ] || base="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)"

git show-ref --verify --quiet "refs/heads/$br" || { echo "no such branch: $br" >&2; exit 2; }
[ "$base" = "$br" ] && { echo "base == branch ($br); pass an explicit base-ref" >&2; exit 2; }

echo "# Review — $br  →  $base"
echo
echo "## Files (merge-base diff)"
git diff --stat "$base...$br" | sed 's/^/  /'
echo
echo "## Commits"
git log --oneline "$base..$br" | sed 's/^/  /'
echo
echo "## Diff (comment by FILE # and @@ hunk header)"
n=0
while IFS= read -r f; do
  n=$(( n + 1 ))
  echo
  echo "===== FILE $n: $f ====="
  git -c core.quotePath=false diff "$base...$br" -- "$f"
done < <(git -c core.quotePath=false diff --name-only "$base...$br")
[ "$n" -eq 0 ] && echo "  (no changes between $base and $br)"
echo
echo "# To request changes: list comments as 'FILE n / @@hunk: <what to change>' and re-dispatch the"
echo "# worker on $br with them (Revision loop). To accept: send $br through the merge-validator + gate."
