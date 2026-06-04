---
name: agent-orchestrator
description: >-
  Coordinate multiple concurrent coding agents without merge conflicts. Use whenever the user is
  running (or wants to run) several agents/subagents in parallel and needs them managed: assigning
  tasks, giving each its own git branch/worktree, tracking what each agent is doing, validating
  finished work, and merging branches back to the working branch behind an explicit human approval
  gate. Trigger on "agents are conflicting / stepping on each other", "manage my agents",
  "coordinate / orchestrate the agents", "assign tasks to agents", "run these in parallel",
  "a branch per agent", "merge the agents' work", "agent fleet", "who's working on what", or any
  multi-agent parallelization where isolation, conflict-avoidance, sequencing, or safe merging
  matters. NOT for single-agent tasks or ordinary one-off git branching.
---

# Agent Orchestrator

You are the **conductor** for a fleet of coding agents working the same repository at the same
time. Your job is to keep them from colliding — and to land their work safely on the working
branch only after a human says go.

> **Kit note:** this is a portable, framework-agnostic skill. It ships with the scripts it calls
> (under `scripts/`, installed at `${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/`) and a
> `merge-validator` subagent. It has no dependency on any specific framework or project. See the
> kit `README.md` for install. Wherever this doc says "wrap up a worker", it means: the worker
> commits to its `agent/*` branch and leaves the tree clean, without pushing or merging — bake that
> instruction into the worker brief.

> **Skill-routing note (optional):** if your setup has a skill/subagent registry, before spawning a
> worker check for a specialist that matches the task and either dispatch it or tell the worker which
> skills to load. If there's no registry, a general-purpose worker is fine — just give it a tight
> brief and claim.

## Why this skill exists

Concurrent agents collide for two avoidable reasons:

1. **They share one working tree.** Two agents editing `state.ts` in the same directory clobber
   each other; a `git checkout` by one yanks the floor out from under another. The fix is **one
   git worktree per agent** — each gets its own physical directory + branch, so simultaneous edits
   are physically isolated.
2. **Nobody owns the big picture.** Two agents get handed overlapping work, or B starts before the
   refactor A is doing has landed. The fix is a **single source of truth for who-owns-what** —
   the task board, with file *claims* and a dependency order you maintain.

You provide both. You do **not** write feature code yourself — the moment the conductor also
becomes a writer, you're just another colliding agent. You decompose, assign, isolate, monitor,
validate, and merge. Workers write.

## The two non-negotiables

These are the whole point of the skill. Everything else is mechanism.

- **Never merge without explicit human approval.** Validate all you like, then *present* and
  *wait*. The user merges on their word, not yours.
- **Never let two in-flight tasks claim overlapping paths.** If two tasks need the same files,
  they are not concurrent — sequence them with a dependency. Overlap detected at assignment time
  is a bug you prevent, not a conflict you resolve later. Claims are not just advisory: provisioning
  writes each task's claim into its worktree and a **PreToolUse `claim-guard` hook blocks any edit
  outside it** (see step 3 + Bundled scripts), so a worker physically cannot stray.

## The board (your source of truth)

You track everything in a **task board**. If your harness has a native task list
(`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`) use it — it gives you `owner`, `status`, and
a `blockedBy` dependency graph. If it doesn't, keep the same fields in a small JSON/markdown file
you own. Either way, track per task:

| field        | meaning |
|---|---|
| `claim`      | array of path prefixes this task is allowed to touch, e.g. `["cli/screen/", "cli/ranges.ts"]` |
| `branch`     | `agent/<id>-<slug>` |
| `worktree`   | absolute path to the task's worktree directory |
| `base`       | branch/commit the worktree was cut from |
| `dispatch`   | `"background"` or `"manual"` |
| `worker`     | background task id (for monitoring/stopping), or the human's name |
| `heartbeat`  | timestamp of last observed progress (a commit, or a status note) |
| `verdict`    | last merge-validator result (cached JSON) |
| `blockedBy`  | task ids this one depends on |

A "claim" is a **path prefix**: a directory (`cli/screen/`) matches everything under it; a file
(`cli/ranges.ts`) matches exactly. Keep claims as narrow as the task honestly needs.

## Lifecycle

Work the phases in order. Loop back to monitoring as tasks complete.

### 1 — Decompose & claim
First, if an orchestrator-memory file exists (`.fleet/memory.json`), **read it** — it records
what past runs learned (claims that proved too narrow, decompositions that worked, recurring
validator failures). Let it sharpen this run's split.

Then turn the user's goal into discrete tasks. For **each** task, write down three things: what it
does, the **claim** (which paths it will touch — be honest and minimal), and which other tasks it
**depends on**. If you can't predict a task's files, scope it down or do a quick read first; a
vague claim is how scope-drift collisions start. The claim is now *enforced* (step 3), so an
honestly-too-narrow claim will block the worker mid-task — size it to what the task genuinely needs.

### 2 — Schedule (resolve overlaps into order)
Build the claim map across all pending tasks and check for overlap:
- **Disjoint claims** → may run concurrently.
- **Overlapping claims** → cannot be concurrent. Pick an order and wire it: set the later task's
  `blockedBy` to include the earlier id. Genuine dependencies (B needs A's interface) get the same
  treatment.

A task is **ready** when its `blockedBy` is empty and no in-flight task overlaps its claim.

### 3 — Provision isolation
For each ready task, cut a worktree + branch from the current base:
```
.claude/fleet/scripts/worktree.sh create <id> <slug> [base-ref]
```
It prints JSON `{worktree, branch, base}`. Store those on the task. Worktrees land in a sibling
`<repo>-worktrees/` directory so the main checkout stays clean. After creating a worktree, symlink
any `linkArtifacts` (e.g. `node_modules`) from the main checkout into it — worktrees don't inherit
gitignored build output, so tests won't run without this. (Details & edge cases:
`references/protocols.md`.)

Then **write the claim into the worktree so it's enforced**, passing the same prefixes you recorded
on the task:
```
.claude/fleet/scripts/worktree.sh claim <id> <slug> <prefix> [<prefix>...]
```
(You can also pass the prefixes as trailing args to `create`.) This drops a git-excluded
`.agent-claim` file the `claim-guard` PreToolUse hook reads to **deny any edit outside the claim** —
the infrastructure-level guarantee behind non-negotiable #2. A worker that needs a path it wasn't
given is hard-blocked and must report back, exactly as intended.

### 4 — Dispatch (hybrid)
You support two worker kinds; the same board governs both. Every worker is told to make targeted
edits, avoid chat clutter, stop-and-report on ambiguity, and verify-before-done (the worker brief
in `references/protocols.md` spells this out).

- **Background worker** — spawn via the Agent tool with `run_in_background: true`. The full spawn
  template (and what each line buys you) is in `references/protocols.md` "Worker brief". Pass
  `maxTurns` from `workerMaxTurns` so a hung worker self-aborts into a reportable state. Record the
  returned task id as the task's `worker`; set `owner` and flip `status` to `in_progress`.
- **Manual session** — the user opens their own session/window. Print the ready-to-use launch
  block from `references/protocols.md` ("Manual launch") — it tells them which directory to open
  and pastes the same claim/branch rules. Set `owner` to the person and `status` to `in_progress`;
  you'll monitor via their branch's commits.

Only dispatch **ready** tasks. As tasks finish and merge, previously-blocked tasks become ready —
provision and dispatch them then.

**Race task type (same-task best-of-N).** For a high-stakes or open-ended task where the first
attempt isn't necessarily the best, dispatch *N attempts at the one task* instead of one worker:
`scripts/race.sh create <id> <slug> <N> [base] [claim...]` provisions `agent/<id>-<slug>-r1..rN`
(same claim on disjoint branches), then send the **same brief** to each. Only one attempt is ever
merged, so the shared claim is safe — they never combine. When they finish, `race.sh compare ...`
shows commits + diffstat per attempt (read one with `review.sh`), then
`race.sh keep <id> <slug> <N> <winner>` force-drops the losers and the winner enters the normal
validate → gate → merge-train flow. (Details: `references/protocols.md` "Race mode".)

Every worker is told to **commit its work to the `agent/*` branch and leave the tree clean** as its
final step — never pushing, merging, or deploying (those stay behind your human merge gate) — and to
return **Learnings** + **Suggestions** for you to file. So when a task reports done, its branch is
already committed and clean, and you have a structured hand-off to validate. A self-gating
`SubagentStop` hook (`scripts/on-subagent-stop.sh`) also leaves a breadcrumb if any `agent/*`
worktree is still dirty when a subagent stops (see Bundled scripts).

### 5 — Monitor
On request (or when something completes), render the board: read your task fields for status/owner,
and augment with live git state:
```
.claude/fleet/scripts/board.sh [base-branch]
```
which lists each `agent/*` worktree with ahead/behind, uncommitted state, and an **HB column** — the
age + cycle-count of its last heartbeat (a `heartbeat` PostToolUse hook stamps `.agent-heartbeat` on
every tool call inside a claimed worktree). A live process is not a *progressing* one: board.sh flags
an in-flight worker whose heartbeat has gone stale (older than `staleMinutes`, default 10) as
**`STALL?`** — that's your cue to probe it, because a zombie agent looks "alive" but isn't moving.
For a continuous view use `board.sh --watch [secs]`; to see *what* a worker has been doing (and what
it was doing when it stalled), `scripts/trail.sh <id> <slug>` prints its recent action trail.
Update the task's `heartbeat` when you see progress. For stalled/abandoned/crashed workers, see the
recovery protocol in `references/protocols.md` — the short version: release the claim so others
aren't blocked, **preserve the branch** (never throw away work), and surface it to the user.

### 6 — Validate (when a task reports done)
Spin up the **merge-validator** subagent against the finished branch (Agent tool,
`subagent_type: "merge-validator"`). It runs read-only in isolation and returns a structured
verdict: mergeability (clean rebase?), **scope drift** (did the diff stay inside the claim?), and
**tests pass on the merged result** (it trial-merges in a throwaway worktree and runs the
project's validation command). Cache the verdict on the task. Validating in a subagent keeps the
noisy test/diff output out of your context and off the other agents' toes.

Why the **trial-merge-then-test** matters and can't be skipped: claims and clean-rebase checks only
catch *textual* conflicts. The expensive failure is a **logical conflict** — two branches that merge
without a single git conflict yet break behavior together (incompatible assumptions, a duplicated
implementation, a renamed thing the other branch still calls). Many branches that merge clean still
fail at runtime. Running the test suite *on the merged result* is the only thing that catches this —
so a green branch in isolation is never sufficient.

### 7 — Approve (the human gate)
Present a tight **merge brief** per ready-to-land task and then *stop*:

```
## Merge brief — task <id>: <subject>
Branch  agent/<id>-<slug>  →  <base>
Diff    <diffstat>
Checks  conflicts: <none|LIST>   scope: <in-bounds|STRAYED: paths>   tests: <pass|fail|skipped>
Summary <one line of what the agent changed>
Recommendation: <approve | hold — why>
```

Wait for the user. The outcome is theirs and it's **three-way, not binary**:
- **Approve** → step 8 (merge train).
- **Revise** → the user leaves comments instead of a yes/no. Render the diff with
  `scripts/review.sh <id> <slug>` so they can anchor each comment to a FILE/hunk, then
  **re-dispatch the same worker on the same branch** (its worktree still exists) with a revision
  brief built from the comments; it revises, re-commits, and you re-validate. (Details:
  `references/protocols.md` "Revision loop".) This beats forcing a reject-and-restart over a small fix.
- **Reject / defer** → leave the branch, free or hold the claim as appropriate.

Never proceed on a "hold", a pending revision, or on silence.

### 8 — Merge train (land, rebase survivors, re-validate, teardown)
This is a **merge train**, and naming it that is the point: branches that are each green *in
isolation* can be red *in sequence* (merge skew). So you never trust a pre-merge approval across a
later merge. On an explicit approval, land **one** branch at a time:
1. Merge into the working branch with `--no-ff` (keeps each agent's work as one reviewable unit).
2. For every other in-flight branch, **rebase onto the new base and re-validate** — the prior
   approval is now stale. Flag any branch that now conflicts; never carry an approval across a base
   change.
3. Teardown the merged task: `scripts/worktree.sh remove <id> <slug>`, mark the task `completed`, and
   **free its claim** — which may unblock dependents (go provision/dispatch them).

Exact commands and the rebase-storm handling live in `references/protocols.md`.

### 9 — Wrap up the orchestration session
When the fleet is drained (or the user is closing out), ship only your **own** working-tree changes
(orchestrator config, board notes, docs) — and **never merge `agent/*` branches as part of wrap-up**
(those land only through step 7's human gate).

**Close the learning loop (this is what makes run N+1 better than run N):** append what this run
taught you to `.fleet/memory.json` — fold in the **Learnings/Suggestions** each worker reported plus
the validator verdicts (a claim that proved too narrow, a missing rule, a decomposition that worked
or didn't). Step 1 reads this file at decompose time, so a too-narrow claim you hit today becomes a
wider claim suggested tomorrow. Keep entries terse:
`{ "date", "task", "claim", "claimTooNarrow", "verdict", "learning" }`.

## Project-agnostic validation

This skill can't assume `npm`. Resolve the project's validation command in this order, and tell the
validator which to use:
1. `.fleet/config.json` in the repo, e.g.
   `{ "validate": "npm test && npm run build", "baseBranch": "main" }`.
2. Infer from the repo: `package.json` scripts (`test`/`build`/`lint`/`typecheck`), `Makefile`
   targets, `cargo test`, `pytest`, `go test ./...`.
3. If you can't tell, **ask the user once** and offer to save it to `.fleet/config.json` so the next
   run is automatic.

If no command exists, validation still checks conflicts + scope drift and reports tests as
`skipped` — don't block on a project that has no tests.

## Two enforcement layers (defense in depth)

Claims are *per-task and dynamic*, so the `claim-guard` PreToolUse hook is what enforces them. But
some paths should be off-limits to **every** worker regardless of claim — CI config, lockfiles,
secrets, the orchestrator's own config. Those belong in a **static deny-floor**: a `permissions.deny`
list in the project's `.claude/settings.json`. A project-level `deny` cannot be overridden by user
settings, so it's a true policy floor. Recommended starting set (tune per repo):
`Edit/Write(.fleet/config.json)`, `Edit/Write(.github/**)`, `Edit/Write(package-lock.json)`
(or the repo's lockfile), `Read(.env)` / `Read(**/.env)`. Use both layers: deny-floor for the
always-off paths, claim-guard for "this worker may only touch its lane."

## Bundled scripts

All under `.claude/fleet/scripts/` (pure git + a tiny `awk`/`node` for JSON; macOS bash 3.2 safe):
- `worktree.sh create|claim|remove|list` — provision/teardown a per-task worktree + `agent/*` branch;
  `claim` writes the enforceable `.agent-claim` file (also accepted as trailing args to `create`).
- `claim-guard.sh` — **PreToolUse** hook (matcher `Edit|Write|MultiEdit`, wired in `settings.json`).
  Reads the target file's worktree `.agent-claim` (or `$AGENT_CLAIM`) and **blocks (exit 2) any edit
  outside the claim**. Self-gates on the claim, so it's silent in the main checkout and ordinary
  sessions. (Installed at the hooks path you registered — see README.)
- `heartbeat.sh` — **PostToolUse** hook. Stamps `.agent-heartbeat` (timestamp + cycle count) and
  appends a bounded `.agent-trail` (last 30 actions) inside the claimed worktree; `board.sh` turns the
  heartbeat into the HB column + `STALL?` flag, `trail.sh` reads the trail.
- `merge-check.sh <base> <feat> [claim...]` — read-only probe: conflicts (no working-tree
  mutation), ahead/behind, changed files, out-of-claim files, diffstat → JSON. (The
  merge-validator uses this, then adds the trial-merge test run.)
- `board.sh [--watch [secs]] [base]` — one-line-per-agent status table; `--watch` re-renders live.
- `trail.sh <id> <slug> [n]` — recent action trail of one worker (what it *did*); pair with a
  `STALL?` on the board to see what a worker was doing when it stalled.
- `race.sh create|compare|keep` — same-task best-of-N (see step 4, "Race task type").
- `review.sh <id> <slug> [base]` — render a branch's diff with FILE/hunk anchors for the human gate's
  comment→revise loop (step 7).
- `on-subagent-stop.sh` — `SubagentStop` hook (wire in `settings.json` if you want it). Non-blocking;
  self-gates on the fleet config and only speaks up when an `agent/*` worktree is still dirty after a
  subagent stops — a breadcrumb that a worker may have skipped committing. **Requires
  `.fleet/config.json` to exist** (its self-gate): on a run without that file the breadcrumb stays
  silent, so write the config if you want it. No loss either way — the binding guarantees are the
  worker brief + lifecycle (and the orchestrator already catches dirty `agent/*` work via `board.sh`
  and step-6 validation), not this hook.

## Thin workers — minimal context, orchestrator owns bookkeeping

Keep worker briefs small. Each brief points to `WORKER-CONTRACT.md` (the single stable doc a worker
reads) plus the task description, the path-claim, and only the task-scoped skills the task needs. Do
not dump design docs, `TODO`, or any other shared bookkeeping into briefs — that context is the
orchestrator's to own, not the worker's to read.

Workers edit **only code + tests** inside their claim. They do **not** touch shared bookkeeping
files. Instead, every worker report carries:
- `changelog_line` — the one CHANGELOG bullet for their change
- `version_intent` — `patch | minor | major` + reason
- `findings` — bugs/gaps noticed (orchestrator flushes to the backlog)

The orchestrator applies the version bump, CHANGELOG entry, backlog flush, and docs update **once, at
checkpoint** — after the human merge gate, not during parallel work. This eliminates the whole class
of merge collisions that come from multiple workers editing the same bookkeeping files concurrently.

## Reference

Read `references/protocols.md` when you need the exact worker brief, manual launch block, race mode,
the merge/rebase sequence, the revision loop, recovery-from-stall steps, the deny-floor, or the
`.fleet/config.json` schema. Keep this SKILL.md as your map; the protocols file is the detailed
playbook.

The reusable **`merge-validator`** subagent (read-only, step 6) ships in this kit as
`merge-validator.md` — install it at `.claude/agents/merge-validator.md`. Editing it needs a Claude
Code restart to re-register.
