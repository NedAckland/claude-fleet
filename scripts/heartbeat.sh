#!/usr/bin/env bash
# heartbeat.sh — PostToolUse hook, ADVISORY (always exits 0). Stamps a per-worktree liveness
# marker + a bounded action trail so the orchestrator can tell a *progressing* worker from a zombie.
#
# Writes (inside the CLAIMED worktree, not the main checkout):
#   .agent-heartbeat  →  "<epoch> <cycle-count>"   (board.sh reads this for the HB column / STALL?)
#   .agent-trail      →  last 30 "<epoch>\t<tool>\t<target>" lines   (trail.sh reads this)
#
# Which worktree? PostToolUse can run with CLAUDE_PROJECT_DIR pointing at the MAIN checkout even when
# the edit targeted a sibling worktree. So we locate the claimed worktree the SAME way claim-guard
# does: walk up from the edited file's directory to the nearest .agent-claim, and stamp THERE. This
# keeps the heartbeat/trail in the exact dir board.sh and trail.sh read — they always talk to each
# other. We fall back to $CLAUDE_PROJECT_DIR only when no file path is available.
#
# Self-scoping: only acts inside a CLAIMED worktree (a .agent-claim file is present — written by
# worktree.sh when the worker was provisioned). No claim file → no-op. So it is silent in the main
# checkout and in every ordinary session/repo, and only stamps while a worker is actually working.
# No framework dependency. Always exits 0.
set -uo pipefail
in="$(cat 2>/dev/null)"
root="${CLAUDE_PROJECT_DIR:-.}"

# Best-effort: tool name + target file from the hook's JSON stdin (via node).
tool="${CLAUDE_TOOL_NAME:-}"
target=""
file=""
if command -v node >/dev/null 2>&1 && [[ -n "$in" ]]; then
  read -r tool2 file < <(printf '%s' "$in" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const t=j.tool_name||"";const f=(j.tool_input&&(j.tool_input.file_path||j.tool_input.command))||"";process.stdout.write(t+" "+String(f).split("\n")[0])}catch{process.stdout.write("")}})' 2>/dev/null)
  [[ -z "$tool" ]] && tool="$tool2"
  target="$file"
fi
[[ -z "$tool" ]] && tool="?"

# Walk up from the edited file's dir to the nearest .agent-claim — that dir is the claimed worktree.
find_agent_claim_dir() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.agent-claim" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

wtroot=""
if [[ -n "$file" && "$file" == /* ]] && wd="$(find_agent_claim_dir "$(dirname "$file")")"; then
  wtroot="$wd"
elif [[ -f "$root/.agent-claim" ]]; then
  wtroot="$root"
fi
# No claimed worktree resolved → nothing to stamp.
[[ -n "$wtroot" ]] || exit 0

hb="$wtroot/.agent-heartbeat"
cyc=0
[[ -f "$hb" ]] && cyc="$(awk '{print $2+0}' "$hb" 2>/dev/null || echo 0)"
printf '%s %s\n' "$(date +%s)" "$((cyc + 1))" >"$hb" 2>/dev/null || true

trail="$wtroot/.agent-trail"
printf '%s\t%s\t%s\n' "$(date +%s)" "$tool" "$target" >>"$trail" 2>/dev/null || true
if [[ -f "$trail" ]]; then
  tail -n 30 "$trail" >"$trail.tmp" 2>/dev/null && mv "$trail.tmp" "$trail" 2>/dev/null || true
fi
exit 0
