#!/usr/bin/env bash
# merge-check.sh — read-only "is this branch safe to merge?" probe. Never mutates the working tree.
#
# Usage: merge-check.sh <base-branch> <feature-branch> [claim-prefix ...]
#   claim-prefix entries are file paths or directory prefixes the task was allowed to touch.
#
# Emits one line of JSON:
#   {base, branch, ahead, behind, conflicts(true|false|null), changedFiles[], outOfScope[], diffstat}
#   conflicts=null means this git is too old for `merge-tree --write-tree`; the validator should
#   fall back to a throwaway trial-merge to decide.
set -eo pipefail

base="${1:?usage: merge-check.sh <base> <feature> [claim ...]}"
feat="${2:?usage: merge-check.sh <base> <feature> [claim ...]}"
shift 2

changed="$(git diff --name-only "$base...$feat" 2>/dev/null || true)"

counts="$(git rev-list --left-right --count "$base...$feat" 2>/dev/null || printf '0\t0')"
behind="$(printf '%s' "$counts" | awk '{print $1}')"
ahead="$(printf '%s' "$counts" | awk '{print $2}')"

# Conflict probe without touching the working tree (git >= 2.38). Exit 0 = clean, 1 = conflicts.
set +e
git merge-tree --write-tree "$base" "$feat" >/dev/null 2>&1
rc=$?
set -e
case "$rc" in
  0) conflicts=false ;;
  1) conflicts=true ;;
  *) conflicts=null ;;
esac

# Out-of-claim detection. Uses the SAME glob semantics as hooks/claim-guard.sh — plain entries match
# as exact-file OR directory prefixes, and glob chars (* ** ? [..]) are honored — so the validator's
# scope check and the edit-time guard can never disagree (e.g. a "src/**" claim that the guard ALLOWS
# must not be flagged out-of-scope here). KEEP THIS matches() IN SYNC WITH claim-guard.sh's matches().
# A malformed glob fails CLOSED (counted as out-of-scope) so the validator errs toward a hold.
out=""
if [ "$#" -gt 0 ] && [ -n "$changed" ]; then
  # Program comes from the heredoc (node -); data comes via env (NOT a pipe — a pipe would collide
  # with the heredoc on stdin and the file list would never reach the script).
  export _MC_CLAIM="$(printf '%s\n' "$@")" _MC_CHANGED="$changed"
  out="$(node - <<'NODE'
const globs = (process.env._MC_CLAIM || "").split("\n").map(x => x.trim()).filter(Boolean);
const files = (process.env._MC_CHANGED || "").split("\n").map(x => x.trim()).filter(Boolean);
function matches(g, p) {
  g = g.trim();
  if (!g) return false;
  const hasGlob = /[*?[\]]/.test(g);
  if (!hasGlob) {
    const d = g.replace(/\/+$/, "");
    return p === d || p.startsWith(d + "/");
  }
  let re = g.replace(/[.+^${}()|\\]/g, "\\$&").replace(/\*\*/g, " ").replace(/\*/g, "[^/]*").replace(/ /g, ".*").replace(/\?/g, "[^/]");
  try { return new RegExp("^" + re + "$").test(p); } catch { return false; }
}
process.stdout.write(files.filter(f => !globs.some(g => matches(g, f))).join("\n"));
NODE
)"
fi

json_arr_from_lines() {
  local acc="" first=1 line
  # `|| [ -n "$line" ]` so a final line with no trailing newline isn't dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    line="${line//\\/\\\\}"
    line="${line//\"/\\\"}"
    if [ "$first" -eq 1 ]; then acc="\"$line\""; first=0; else acc="${acc},\"$line\""; fi
  done
  printf '[%s]' "$acc"
}

changed_json="$(printf '%s' "$changed" | json_arr_from_lines)"
out_json="$(printf '%s' "$out" | json_arr_from_lines)"
diffstat="$(git diff --shortstat "$base...$feat" 2>/dev/null | sed 's/^ *//' | tr -d '\n')"

printf '{"base":"%s","branch":"%s","ahead":%s,"behind":%s,"conflicts":%s,"changedFiles":%s,"outOfScope":%s,"diffstat":"%s"}\n' \
  "$base" "$feat" "${ahead:-0}" "${behind:-0}" "$conflicts" "$changed_json" "$out_json" "$diffstat"
