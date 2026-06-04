#!/usr/bin/env bash
# claim-guard.sh — the ONE blocking orchestration hook. During parallel multi-agent work each
# worker is given a path-claim: the set of globs it may edit. This PreToolUse hook DENIES an
# Edit/Write/MultiEdit whose target is outside the claim, deterministically — so a worker can't be
# talked (or hallucinate its way) into straying out of its lane.
#
# The claim comes from (first that is set):
#   1. $AGENT_CLAIM                          — newline/colon-separated globs (set per worker)
#   2. <worktree>/.agent-claim               — one glob per line (written by worktree.sh on provision)
#   3. $CLAUDE_PROJECT_DIR/.claude/claim      — one glob per line
# The .agent-claim file (#2) is the normal path: worktree.sh drops it in each worker's worktree so
# the hook enforces the claim with no env wiring. We look for it both at the project root AND walking
# up from the edited file, because the hook may run with CLAUDE_PROJECT_DIR set to the main checkout
# while the edit targets a worktree that carries its own .agent-claim.
# If NONE is present, there is no active claim → ALLOW (exit 0). This makes the hook a no-op for
# ordinary single-agent work and ordinary sessions; it only bites when a claim is actively set.
# (So it is always SAFE to install: it does nothing until you opt a worker in with a claim.)
#
# Exit codes: 0 = allow · 2 = deny (Claude Code shows stderr to the model and blocks the edit).
# Dependencies: bash + node only. No jq, no python, no framework. macOS bash 3.2 safe.
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-.}"

# Pull the edited file path early so we can find a worktree-local .agent-claim near it.
file=$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write((j.tool_input&&j.tool_input.file_path)||"")}catch{process.stdout.write("")}})' 2>/dev/null)

# Walk up from a starting dir looking for a .agent-claim file; print "<dir>" (its location) if found.
find_agent_claim_dir() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.agent-claim" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Walk up from a starting dir to the worktree/checkout root — the nearest dir holding a .git entry
# (a linked worktree carries a .git FILE, the main checkout a .git DIR). Print it if found.
find_worktree_root() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -e "$d/.git" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# claim_base = the directory the claim's path prefixes are relative to (a worktree or the project
# root). The edited file is made relative to THIS dir before matching, so a claim like "src/" works
# whether the worker's worktree is the project root or a sibling worktree dir. Claim prefixes are
# ALWAYS relative to the edited file's own worktree root, regardless of which source the claim string
# comes from — so resolve that first (CLAUDE_PROJECT_DIR may point at the main checkout while the edit
# targets a sibling worktree). The .agent-claim branch below refines it to the exact claim dir.
claim=""
claim_base="$root"
if [[ -n "$file" && "$file" == /* ]] && wr="$(find_worktree_root "$(dirname "$file")")"; then
  claim_base="$wr"
fi
if [[ -n "${AGENT_CLAIM:-}" ]]; then
  claim="$AGENT_CLAIM"
elif [[ -n "$file" ]] && cb="$(find_agent_claim_dir "$(dirname "$file")")"; then
  claim="$(cat "$cb/.agent-claim")"; claim_base="$cb"
elif [[ -f "$root/.agent-claim" ]]; then
  claim="$(cat "$root/.agent-claim")"
elif [[ -f "$root/.claude/claim" ]]; then
  claim="$(cat "$root/.claude/claim")"
fi
# No claim → nothing to enforce.
[[ -z "${claim//[$'\n':[:space:]]/}" ]] && exit 0
[[ -z "$file" ]] && exit 0  # no target path to check (file extracted near the top)

# Glob match in node: convert each claim glob to a regex and test the path made relative to
# claim_base (and the absolute form). The claim string is passed via env to node.
export _CG_CLAIM="$claim"
node - "$file" "$claim_base" <<'NODE'
// node may keep "-" (read-from-stdin marker) in argv; drop it before destructuring.
const args = process.argv.slice(2).filter(a => a !== '-');
const [file, root] = args;
const claim = process.env._CG_CLAIM || '';
const globs = claim.split(/[\n:]+/).map(s => s.trim()).filter(Boolean);
// Boundary-aware prefix strip: only treat `root` as a parent when it matches at a path
// boundary, so a sibling worktree dir (e.g. "<repo>-worktrees/…") isn't mistaken for being
// under "<repo>/" just because the string prefix matches.
const base = root.replace(/\/+$/, '');
const rel = (file === base || file.startsWith(base + '/')) ? file.slice(base.length).replace(/^\/+/, '') : file;
// A claim is a PATH PREFIX (per the skill docs):
//   - "src/" or "src" (a directory) matches everything under it: src/foo.ts, src/a/b.ts
//   - "src/ranges.ts" (a file) matches exactly that file
//   - glob chars (* / **) are honored: "src/**", "cli/*.ts", etc.
function matches(g, p) {
  g = g.trim();
  if (!g) return false;
  const hasGlob = /[*?[\]]/.test(g);
  if (!hasGlob) {
    // plain prefix: exact file OR directory-prefix match
    const d = g.replace(/\/+$/, '');
    return p === d || p.startsWith(d + '/');
  }
  let re = g.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*\*/g, ' ').replace(/\*/g, '[^/]*').replace(/ /g, '.*').replace(/\?/g, '[^/]');
  return new RegExp('^' + re + '$').test(p);
}
const ok = globs.some(g => matches(g, rel) || matches(g, file));
if (!ok) {
  process.stderr.write(`claim-guard: BLOCKED edit to "${rel}" — outside your path-claim [${globs.join(', ')}]. Edit only files inside your claim, or ask the orchestrator to widen it.\n`);
  process.exit(2);
}
process.exit(0);
NODE
