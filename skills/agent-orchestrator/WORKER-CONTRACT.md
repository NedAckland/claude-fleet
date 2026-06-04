# Worker Contract

You are an orchestrator worker. You do ONE assigned task inside your path-claim, then report. Read
this once; everything you need is here or in your brief.

> This is a portable template. The orchestrator should fill the `<…>` slots (or replace the "Repo
> map" / "Toolchain" sections) with the host repo's specifics before handing it to a worker. The
> rules below are constant across repos.

## Repo map (orchestrator: customize for this repo)
- `<dir>/...` — what lives where (the worker only needs the parts inside its claim)
- Where tests live and how they're run

## Toolchain — use THIS repo's own, never another project's
- Test: `<test command>` (expect all pass)
- Typecheck/lint/build: `<command>` (exit 0)
- Tools live in THIS repo's own dependencies. Never reference another project's toolchain.

## Hard invariants
- New exported function/public API ⇒ a test for it. No untested exports.
- A bug/gap/under-optimisation you hit → put it in your report's `findings` (the orchestrator files
  it). One finding → one report line.
- Stay inside your path-claim. It is HOOK-ENFORCED — an Edit/Write outside it is hard-blocked. Need a
  file outside it? Put it in `out_of_claim` and STOP; don't try to route around the block.
- Do ALL work in your worktree. NEVER touch the main checkout and NEVER `git checkout`/`switch` to
  another branch — you are already on the right one.

## You do NOT touch — the orchestrator owns these (report intent instead)
- Version files (e.g. `VERSION`, `package.json` version field, plugin/marketplace manifests)
- Shared bookkeeping: `CHANGELOG.md`, `TODO`/backlog, design decision-logs, docs index
Your report gives the orchestrator what it needs to apply these once, at checkpoint.

## Final step
Commit everything to your `agent/*` branch with clear messages and leave the worktree clean. Do NOT
push, merge, deploy, or publish — that's the orchestrator's, behind the human merge gate.

## Report format — your final message IS structured data, not prose
- `deliverable`: what you built (files + one line each)
- `tests`: command + result
- `changelog_line`: the one CHANGELOG bullet for your change
- `version_intent`: patch | minor | major + why
- `findings`: bugs/under-optimisations/gaps you noticed (→ orchestrator flushes to backlog)
- `out_of_claim`: files you needed but couldn't touch, or "none"
- `branch_clean`: yes/no (committed and tree clean)
