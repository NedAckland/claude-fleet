#!/usr/bin/env bash
# verify.sh — one-command self-test a fresh agent runs after install to confirm the kit works.
#
# It (1) syntax-checks every script under hooks/ and scripts/, and (2) functionally proves the
# claim-guard hook — the kit's whole point — by feeding it an out-of-claim edit (must DENY, exit 2)
# and an in-claim edit (must ALLOW, exit 0) in a throwaway temp dir.
#
# Self-contained: pure bash + node (no tsx, no npm, no jq). Exits non-zero on ANY failure;
# prints "VERIFY OK" and exits 0 on success.
set -uo pipefail

# Resolve the kit directory regardless of where this is invoked from.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$KIT/hooks/claim-guard.sh"

fail() { echo "VERIFY FAILED — $*" >&2; exit 1; }

# --- 1. syntax-check every script under hooks/ and scripts/ ----------------------------------------
echo "== 1. bash -n syntax check =="
syntax_count=0
for s in "$KIT"/hooks/*.sh "$KIT"/scripts/*.sh; do
  [ -e "$s" ] || continue
  if bash -n "$s"; then
    echo "  ok: ${s#$KIT/}"
    syntax_count=$((syntax_count + 1))
  else
    fail "syntax error in ${s#$KIT/}"
  fi
done
[ "$syntax_count" -gt 0 ] || fail "no scripts found to syntax-check under hooks/ or scripts/"
echo "  $syntax_count script(s) passed bash -n"

# --- 2. functionally prove claim-guard deny + allow ------------------------------------------------
echo "== 2. claim-guard functional check =="
[ -f "$GUARD" ] || fail "claim-guard hook not found at $GUARD"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/src"

# 2a. out-of-claim edit → must DENY (exit 2)
printf '{"tool_input":{"file_path":"%s"}}' "$tmp/OUTSIDE.ts" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$tmp" bash "$GUARD" >/dev/null 2>&1
deny=$?
echo "  out-of-claim ($tmp/OUTSIDE.ts) → exit $deny (want 2 = DENY)"

# 2b. in-claim edit → must ALLOW (exit 0)
printf '{"tool_input":{"file_path":"%s"}}' "$tmp/src/in.ts" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$tmp" bash "$GUARD" >/dev/null 2>&1
allow=$?
echo "  in-claim     ($tmp/src/in.ts) → exit $allow (want 0 = ALLOW)"

# 2c. out-of-claim BASH write (the best-effort tripwire) → must DENY (exit 2)
printf '{"tool_input":{"command":"echo x > %s"},"cwd":"%s"}' "$tmp/OUTSIDE.txt" "$tmp" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$tmp" bash "$GUARD" >/dev/null 2>&1
bash_deny=$?
echo "  bash redirect out-of-claim → exit $bash_deny (want 2 = DENY)"

# 2d. in-claim BASH write → must ALLOW (exit 0)
printf '{"tool_input":{"command":"echo x > %s"},"cwd":"%s"}' "$tmp/src/in.txt" "$tmp" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$tmp" bash "$GUARD" >/dev/null 2>&1
bash_allow=$?
echo "  bash redirect in-claim     → exit $bash_allow (want 0 = ALLOW)"

[ "$deny" -eq 2 ]       || fail "out-of-claim edit was NOT denied (exit $deny, want 2) — claim-guard regressed"
[ "$allow" -eq 0 ]      || fail "in-claim edit was NOT allowed (exit $allow, want 0) — claim-guard regressed"
[ "$bash_deny" -eq 2 ]  || fail "out-of-claim Bash write was NOT denied (exit $bash_deny, want 2) — Bash tripwire regressed"
[ "$bash_allow" -eq 0 ] || fail "in-claim Bash write was NOT allowed (exit $bash_allow, want 0) — Bash tripwire regressed"

# --- 3. shipped agent definitions are well-formed -------------------------------------------------
echo "== 3. agent frontmatter check =="
# Real agents (the template is excluded by the [!_] glob) must declare name + description, and names
# must be unique — a dispatchable subagent_type with no description can't be matched/routed.
agent_count=0
names=""
for a in "$KIT"/agents/[!_]*.md; do
  [ -e "$a" ] || continue
  grep -qE '^name:[[:space:]]*[^[:space:]]' "$a"        || fail "agent ${a#$KIT/} missing 'name:'"
  grep -qE '^description:' "$a"                          || fail "agent ${a#$KIT/} missing 'description:'"
  nm="$(awk -F': *' '/^name:/{print $2; exit}' "$a")"
  case " $names " in *" $nm "*) fail "duplicate agent name '$nm' in ${a#$KIT/}" ;; esac
  names="$names $nm"
  echo "  ok: ${a#$KIT/} (name: $nm)"
  agent_count=$((agent_count + 1))
done
[ "$agent_count" -gt 0 ] || fail "no agent definitions found under agents/"
# The generic fallback worker must exist — selection always degrades to it.
case " $names " in *" orchestrator-worker "*) ;; (*) fail "missing the generic fallback agent 'orchestrator-worker'" ;; esac
echo "  $agent_count agent definition(s) OK"

# --- 4. heartbeat stamps a claimed worktree for a BASH action ------------------------------------
echo "== 4. heartbeat Bash liveness check =="
HB="$KIT/scripts/heartbeat.sh"
[ -f "$HB" ] || fail "heartbeat hook not found at $HB"
hbwt="$tmp/hbwt"
mkdir -p "$hbwt"
printf 'src/\n' > "$hbwt/.agent-claim"
# A Bash call (no file_path) that cd-s into the worktree must stamp .agent-heartbeat + .agent-trail.
printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && echo hi"},"cwd":"%s"}' "$hbwt" "$tmp" \
  | CLAUDE_PROJECT_DIR="$tmp" bash "$HB" >/dev/null 2>&1
[ -f "$hbwt/.agent-heartbeat" ] || fail "heartbeat did NOT stamp .agent-heartbeat for a Bash action — Bash heartbeat regressed"
grep -q "Bash" "$hbwt/.agent-trail" 2>/dev/null || fail "heartbeat trail missing the Bash action — trail regressed"
echo "  bash action stamped heartbeat + trail in the claimed worktree"
# A claimless dir must NOT be stamped (self-gating).
nofleet="$tmp/nofleet"; mkdir -p "$nofleet"
printf '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"%s"}' "$nofleet" \
  | CLAUDE_PROJECT_DIR="$nofleet" bash "$HB" >/dev/null 2>&1
[ -f "$nofleet/.agent-heartbeat" ] && fail "heartbeat stamped a claimless dir — self-gate regressed" || true
echo "  claimless dir left untouched (self-gate holds)"

echo
echo "VERIFY OK"
exit 0
