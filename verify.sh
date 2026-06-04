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

[ "$deny" -eq 2 ]  || fail "out-of-claim edit was NOT denied (exit $deny, want 2) — claim-guard regressed"
[ "$allow" -eq 0 ] || fail "in-claim edit was NOT allowed (exit $allow, want 0) — claim-guard regressed"

echo
echo "VERIFY OK"
exit 0
