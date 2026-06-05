#!/usr/bin/env bash
# heartbeat.sh — PostToolUse hook, ADVISORY (always exits 0). Stamps a per-worktree liveness marker
# + a bounded action trail so the orchestrator can tell a *progressing* worker from a zombie.
#
# Writes (inside the CLAIMED worktree, not the main checkout):
#   .agent-heartbeat  →  "<epoch> <cycle-count>"   (board.sh reads this for the HB column / STALL?)
#   .agent-trail      →  last 30 "<epoch>\t<tool>\t<target>" lines   (trail.sh reads this)
#
# Wired on the matcher Edit|Write|MultiEdit|Bash. Which worktree gets stamped?
#   - Edit/Write/MultiEdit: walk up from the edited file's dir to the nearest .agent-claim.
#   - Bash (no file path): derive a dir from a leading `cd <dir> && …` in the command (the worker's
#     recommended pattern), else the hook's JSON cwd, else the project root — then walk up the same way.
# This is the SAME worktree-resolution precedence claim-guard uses, so the two hooks never disagree
# about which worktree an action belongs to. KEEP IT IN SYNC WITH hooks/claim-guard.sh.
#
# Self-scoping: only acts inside a CLAIMED worktree (a .agent-claim is present — written by
# worktree.sh on provision). No claim → no-op, so it's silent in the main checkout and ordinary
# sessions. No framework dependency. Always exits 0.
set -uo pipefail
in="$(cat 2>/dev/null)"
root="${CLAUDE_PROJECT_DIR:-.}"

# Pull everything single-line we need in one node pass (program via heredoc, data via env to avoid a
# stdin clash). command may be multiline, so we only take its FIRST line (display) and any leading-cd
# dir (resolution) — both single-line, so newline-delimited output is safe.
tool=""; file=""; cwd=""; cmdline=""; cddir=""
if command -v node >/dev/null 2>&1 && [[ -n "$in" ]]; then
  export _HB_IN="$in"
  # node -e (NOT a heredoc) so this is safe inside $() on macOS bash 3.2, where heredocs-in-
  # substitution are buggy. \x27 = single quote, so the program holds no literal ' and stays inside
  # one bash '...'. Data comes via env, not stdin. Output = 5 newline-separated fields.
  _hb_fields="$(node -e 'const s=process.env._HB_IN||"";let j={};try{j=JSON.parse(s)}catch{}const ti=j.tool_input||{};const cmd=String(ti.command||"");const m=cmd.match(/^\s*cd\s+("([^"]+)"|\x27([^\x27]+)\x27|([^\s;&|]+))\s*(?:&&|;)/);const cddir=m?(m[2]||m[3]||m[4]):"";process.stdout.write([j.tool_name||"",ti.file_path||"",j.cwd||"",cmd.split("\n")[0],cddir].join("\n"))' 2>/dev/null)"
  { read -r tool; read -r file; read -r cwd; read -r cmdline; read -r cddir; } <<< "$_hb_fields"
fi
[[ -z "$tool" ]] && tool="${CLAUDE_TOOL_NAME:-}"
[[ -z "$tool" ]] && tool="?"

# Trail target: the edited file for edits, the command's first line for Bash. Keep it tidy + tab-safe.
target="$file"; [[ -z "$target" ]] && target="$cmdline"
target="${target//$'\t'/ }"; target="${target:0:200}"

# Walk up from a starting dir to the nearest .agent-claim — that dir is the claimed worktree.
find_agent_claim_dir() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.agent-claim" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# start_dir: edited file's dir (edits) → leading-cd dir (Bash) → JSON cwd → project root.
start_dir=""
if [[ -n "$file" && "$file" == /* ]]; then
  start_dir="$(dirname "$file")"
elif [[ -n "$cddir" ]]; then
  if [[ "$cddir" == /* ]]; then start_dir="$cddir"; else start_dir="${cwd%/}/$cddir"; fi
elif [[ -n "$cwd" ]]; then
  start_dir="$cwd"
else
  start_dir="$root"
fi

wtroot=""
if [[ -n "$start_dir" ]] && wd="$(find_agent_claim_dir "$start_dir")"; then
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
