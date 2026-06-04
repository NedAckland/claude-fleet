#!/usr/bin/env bash
# SubagentStop hook — a NON-BLOCKING breadcrumb for the orchestrator.
#
# Fires in the PARENT (orchestrator) session's cwd whenever ANY subagent finishes. Skills are
# model-driven and a shell hook cannot invoke one, so this does NOT run any wrap-up step itself — it
# just leaves a reminder/trace. The real guarantees that a finishing worker wraps up are:
#   1. the worker brief (references/protocols.md) tells each worker to commit + clean before reporting, and
#   2. the orchestrator's own lifecycle (SKILL.md step 6) validates + checks the branch when re-invoked.
#
# Self-scoping: does nothing unless the repo opted into orchestration (a fleet config exists at
# .fleet/config.json) AND there is at least one agent/* worktree with uncommitted work (the tell-tale
# sign a worker stopped without shipping to its branch). This keeps it silent for ordinary subagents
# (research, exploration, etc.) everywhere.
#
# Always exits 0 (never blocks a subagent from stopping).

input=$(cat 2>/dev/null)

# Only act inside an orchestrator-enabled repo.
[ -f ".fleet/config.json" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

dirty=""
# Walk every linked worktree; flag agent/* branches that still have uncommitted changes.
while IFS= read -r line; do
  case "$line" in
    worktree\ *) wt="${line#worktree }" ;;
    branch\ refs/heads/agent/*)
      br="${line#branch refs/heads/}"
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        dirty="${dirty}\n  - ${br} (${wt}) has uncommitted changes"
      fi
      ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)

[ -z "$dirty" ] && exit 0

# Durable trace + debug-visible nudge (stdout on exit 0 surfaces in transcript/debug, not blocking).
log="${FLEET_LOG:-.fleet/wrapup.log}"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
{
  echo "[wrap-up reminder] A subagent finished but some worker branches look un-shipped:"
  printf '%b\n' "$dirty"
  echo "  → Ensure each worker committed to its agent/* branch with a clean tree before you validate/merge."
} | tee -a "$log"

exit 0
