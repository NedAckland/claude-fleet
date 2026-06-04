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

in_scope() { # <file> <claim...>
  local f="$1"; shift
  local c cc
  for c in "$@"; do
    cc="${c%/}"
    [ "$f" = "$c" ] && return 0
    [ "$f" = "$cc" ] && return 0
    case "$f" in "$cc"/*) return 0 ;; esac
  done
  return 1
}

out=""
if [ "$#" -gt 0 ] && [ -n "$changed" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! in_scope "$f" "$@"; then
      out="${out}${f}
"
    fi
  done <<EOF
$changed
EOF
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
