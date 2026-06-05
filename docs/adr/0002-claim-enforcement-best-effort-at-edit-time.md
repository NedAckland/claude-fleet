# Claim enforcement is best-effort at edit time, authoritative at the merge gate

The `claim-guard` PreToolUse hook blocks out-of-claim `Edit/Write/MultiEdit` and makes a **best-effort**
attempt to block obvious out-of-claim **Bash** writes — but shell writes cannot be perfectly
intercepted, so the **authoritative** enforcement is the merge-validator's diff-based `outOfScope`
check, which inspects the actually-committed diff before merge.

## Why (with evidence)

A probe (background subagent, `scripts/` claim) confirmed the asymmetry empirically: a `Write`-tool
edit outside the claim was hard-blocked by claim-guard, while `echo > out-of-claim` via **Bash wrote
the same path freely**. Shell can write via `>`, `>>`, `tee`, `sed -i`, `cp`, `mv`, `git apply`,
`python -c`, heredocs, … — detecting "this command writes outside the claim" from a command string is
effectively undecidable.

## Considered options

- **Airtight edit-time Bash parsing** — try to fully validate every shell command. Rejected: it can't
  be done reliably, and a parser strict enough to matter throws false positives on legitimate
  build/test commands, making workers fight the guard.
- **Best-effort edit-time + authoritative gate-time (chosen)** — claim-guard catches casual strays
  cheaply; the validator's diff check (a diff cannot lie about which files changed) is the guarantee.

## Consequences

- Documentation must **not** claim a worker "physically cannot" edit outside its lane. The honest
  statement: Edit/Write/MultiEdit are blocked at edit time; a Bash-written stray is caught at the
  merge gate by the validator's scope check, not necessarily at edit time.
- The merge-validator's `outOfScope` step is load-bearing, not a redundant backstop — never skip it.
- (Separately confirmed by the same probe: the `additionalDirectories` permission is **not** required
  for sibling-worktree writes in current Claude Code — so the kit adds no such config.)
