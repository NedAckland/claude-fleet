#!/usr/bin/env bash
# claim-guard.sh — the ONE blocking orchestration hook. During parallel multi-agent work each
# worker is given a path-claim: the set of globs it may edit. This PreToolUse hook DENIES an
# Edit/Write/MultiEdit whose target is outside the claim, deterministically — so a worker can't be
# talked (or hallucinate its way) into straying out of its lane.
#
# It ALSO makes a BEST-EFFORT pass at Bash (when wired on the Bash matcher): it parses obvious write
# targets out of the command (`>`/`>>` redirects and `tee`) and blocks ones that clearly resolve
# outside the claim. This is best-effort, NOT a guarantee — shell can write a thousand ways
# (sed -i, cp, mv, python -c, heredocs, variables…) and parsing a command string is undecidable, so
# when in doubt it ALLOWS. The AUTHORITATIVE claim enforcement is the merge-validator's diff-based
# outOfScope check at the merge gate (see docs/adr/0002). Treat this Bash pass as a tripwire for
# casual strays, not a wall.
#
# The claim comes from (first that is set):
#   1. $AGENT_CLAIM                          — newline/colon-separated globs (set per worker)
#   2. <worktree>/.agent-claim               — one glob per line (written by worktree.sh on provision)
#   3. $CLAUDE_PROJECT_DIR/.claude/claim      — one glob per line
# If NONE is present, there is no active claim → ALLOW (exit 0). So it is silent for ordinary
# single-agent work; it only bites when a claim is actively set.
#
# Exit codes: 0 = allow · 2 = deny (Claude Code shows stderr to the model and blocks the call).
# Dependencies: bash + node only. No jq, no python, no framework. macOS bash 3.2 safe.
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-.}"
input="$(cat 2>/dev/null)"

# Pull single-line fields (file_path, cwd) so we can locate the claim near the edit. The command
# string may be multiline, so it is parsed inside the main node block from the raw input instead.
read_field() { # <field>  (file_path is under tool_input; cwd is top-level)
  printf '%s' "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const k=process.argv[1];const v=(k==="cwd")?j.cwd:(j.tool_input&&j.tool_input[k]);process.stdout.write(v?String(v):"")}catch{process.stdout.write("")}})' "$1" 2>/dev/null
}
file="$(read_field file_path)"
cwd="$(read_field cwd)"

# Walk up from a starting dir looking for a .agent-claim file; print "<dir>" (its location) if found.
find_agent_claim_dir() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.agent-claim" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Walk up to the worktree/checkout root — the nearest dir holding a .git entry (linked worktree = a
# .git FILE, main checkout = a .git DIR). Print it if found.
find_worktree_root() { # <start-dir>
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -e "$d/.git" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Where to begin looking for the claim: the edited file's dir (Edit/Write) or the command's cwd (Bash).
if [[ -n "$file" && "$file" == /* ]]; then start_dir="$(dirname "$file")"
elif [[ -n "$cwd" ]]; then start_dir="$cwd"
else start_dir="$root"; fi

# claim_base = the directory the claim's prefixes are relative to (the worker's worktree root). The
# edited/written path is made relative to THIS dir before matching, so "src/" works whether the
# worktree is the project root or a sibling worktree dir.
claim=""
claim_base="$root"
if wr="$(find_worktree_root "$start_dir")"; then claim_base="$wr"; fi
if [[ -n "${AGENT_CLAIM:-}" ]]; then
  claim="$AGENT_CLAIM"
elif cb="$(find_agent_claim_dir "$start_dir")"; then
  claim="$(cat "$cb/.agent-claim")"; claim_base="$cb"
elif [[ -f "$root/.agent-claim" ]]; then
  claim="$(cat "$root/.agent-claim")"
elif [[ -f "$root/.claude/claim" ]]; then
  claim="$(cat "$root/.claude/claim")"
fi
# No claim → nothing to enforce.
[[ -z "${claim//[$'\n':[:space:]]/}" ]] && exit 0

# Match in node: convert claim globs to regexes and test the target made relative to claim_base.
# For Edit/Write the target is tool_input.file_path; for Bash we extract write targets from the
# command (best-effort) and resolve each against the command's effective cwd.
export _CG_CLAIM="$claim" _CG_INPUT="$input"
node - "$claim_base" "$cwd" <<'NODE'
const args = process.argv.slice(2).filter(a => a !== '-');
const [claimBase, jsonCwd] = args;
const claim = process.env._CG_CLAIM || '';
let j = {}; try { j = JSON.parse(process.env._CG_INPUT || ''); } catch {}
const ti = j.tool_input || {};
const globs = claim.split(/[\n:]+/).map(s => s.trim()).filter(Boolean);
const base = (claimBase || '').replace(/\/+$/, '');

// A claim is a PATH PREFIX: "src"/"src/" matches everything under src; "src/x.ts" matches that file;
// glob chars (* ** ? [..]) are honored. Malformed glob fails CLOSED here (treated as a non-match →
// out-of-claim → deny) so a bad claim errs toward a hold, matching merge-check.sh.
function matches(g, p) {
  g = g.trim();
  if (!g) return false;
  const hasGlob = /[*?[\]]/.test(g);
  if (!hasGlob) {
    const d = g.replace(/\/+$/, '');
    return p === d || p.startsWith(d + '/');
  }
  let re = g.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*\*/g, ' ').replace(/\*/g, '[^/]*').replace(/ /g, '.*').replace(/\?/g, '[^/]');
  try { return new RegExp('^' + re + '$').test(p); } catch { return false; }
}
function normalize(p) {
  const abs = p.startsWith('/');
  const out = [];
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (out.length && out[out.length - 1] !== '..') out.pop(); else if (!abs) out.push('..'); }
    else out.push(seg);
  }
  return (abs ? '/' : '') + out.join('/');
}
function rel(absPath) {
  return (absPath === base || absPath.startsWith(base + '/')) ? absPath.slice(base.length).replace(/^\/+/, '') : absPath;
}
function isOutside(absPath) {
  const r = rel(absPath);
  return !globs.some(g => matches(g, r) || matches(g, absPath));
}

function deny(target, kind) {
  process.stderr.write(`claim-guard: BLOCKED ${kind} to "${target}" — outside your path-claim [${globs.join(', ')}]. Edit only inside your claim, or ask the orchestrator to widen it.\n`);
  process.exit(2);
}

// --- Edit/Write/MultiEdit: a single concrete file path ---
const file = ti.file_path || '';
if (file) {
  const abs = file.startsWith('/') ? normalize(file) : normalize(((jsonCwd || '').replace(/\/+$/, '') + '/' + file));
  if (isOutside(abs)) deny(rel(abs), 'edit');
  process.exit(0);
}

// --- Bash: best-effort. Parse obvious write targets; block clear out-of-claim ones; else ALLOW. ---
const cmd = ti.command || '';
if (!cmd) process.exit(0);

// Effective cwd: honor a leading `cd <dir> && …` / `cd <dir>; …` (the worker's recommended pattern),
// else the JSON cwd. Targets resolve against this.
function effectiveCwd() {
  const m = cmd.match(/^\s*cd\s+("([^"]+)"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;)/);
  const j = (jsonCwd || '').replace(/\/+$/, '');
  if (m) { const d = m[2] || m[3] || m[4]; return d.startsWith('/') ? normalize(d) : normalize(j + '/' + d); }
  return j ? normalize(j) : '';
}
const eff = effectiveCwd();

// Extract write targets we can parse confidently: > / >> redirects (not >& fd-dups) and tee.
function targets() {
  const found = [];
  let m;
  const reRedir = /(?:^|[\s;&|(])\d*>>?\s*(?!&)("([^"]*)"|'([^']*)'|([^\s;&|>]+))/g;
  while ((m = reRedir.exec(cmd))) found.push(m[2] ?? m[3] ?? m[4]);
  const reTee = /(?:^|[\s;&|(])tee\s+([^;&|]+)/g;
  while ((m = reTee.exec(cmd))) {
    for (let tok of m[1].split(/\s+/)) {
      tok = tok.replace(/^["']|["']$/g, '');
      if (tok && !tok.startsWith('-')) found.push(tok);
    }
  }
  return found.filter(Boolean);
}

for (let t of targets()) {
  t = t.replace(/^["']|["']$/g, '');
  // Unresolvable (variables, command-subst, globs) → can't judge → ALLOW (best-effort, no false block).
  if (/[$`*?]/.test(t)) continue;
  const abs = t.startsWith('/') ? normalize(t) : normalize((eff ? eff + '/' : '') + t);
  if (/^\/dev\//.test(abs)) continue;           // /dev/null, /dev/stdout, … are not real writes
  if (isOutside(abs)) deny(t, 'Bash write');
}
process.exit(0);
NODE
