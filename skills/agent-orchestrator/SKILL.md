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

> **Worker-agent routing:** at dispatch you pick the **specialized worker agent** (`subagent_type`)
> that best fits each task — a `bugfix-worker`, a `refactor-worker`, or one you've grown — and fall
> back to the generic `orchestrator-worker` when none clearly fits. The full selection rules are in
> step 4 ("Choose the worker agent"); growing the library is in `references/protocols.md`. This kit
> ships the agents under `agents/`, installed at `.claude/agents/`.

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
  writes each task's claim into its worktree and a **PreToolUse `claim-guard` hook hard-blocks any
  Edit/Write/MultiEdit outside it** (and best-effort blocks obvious Bash strays; see step 3 + Bundled
  scripts). Edit-time fencing isn't perfect for shell, so the merge-validator's diff-scope check is the
  authoritative backstop (ADR-0002) — never skip step 6.

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
| `agent`      | the worker agent dispatched, e.g. `bugfix-worker` / `refactor-worker` / `orchestrator-worker` (fallback) — chosen at step 4 |
| `model`      | model override for this worker if you set one (else inherited) — chosen by task weight at step 4 |
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
`.agent-claim` file the `claim-guard` PreToolUse hook reads to **deny any Edit/Write/MultiEdit outside
the claim** (and best-effort-block obvious Bash strays) — the edit-time guard behind non-negotiable #2,
authoritatively backstopped by the merge-validator's diff-scope check (ADR-0002). A worker that needs a
path it wasn't given is hard-blocked and must report back, exactly as intended.

### 4 — Dispatch (hybrid)
You support two worker kinds; the same board governs both. Every worker is told to make targeted
edits, avoid chat clutter, stop-and-report on ambiguity, and verify-before-done (the worker brief
in `references/protocols.md` spells this out).

**Choose the worker agent (`subagent_type`) first.** Match the task to the best-fitting *specialized
worker agent*, so the worker arrives already equipped for its kind of work instead of re-deriving it:

1. **The menu.** Use the `subagent_type` list your harness already exposes (it includes custom agents
   like `bugfix-worker`); if your harness doesn't inject one, enumerate `.claude/agents/` (project)
   then `~/.claude/agents/` (global) and read each `name` + `description`. Project shadows global on a
   name clash; dedup by name.
2. **Eligibility.** Only agents whose role is "execute one claimed coding task" are routable. **Exclude
   by category** orchestration, validation, planning, exploration, and meta agents — and treat the
   `deny` list in `.fleet/config.json` (seeded with `merge-validator`) as a hard floor that can't be
   reasoned around. `orchestrator-worker` is the **fallback only**, never a positive match.
3. **Match — and under-route.** Pick the one specialist whose description genuinely fits the task. If
   none is a *clear* fit, dispatch the generic **`orchestrator-worker`** — a wrong specialist misleads
   the worker, so bias toward the generic. (One agent per task; there is no "load two agents.")
4. **Only dispatch a registry-present `subagent_type`.** Never dispatch a name you just wrote to disk
   or guessed — a freshly-added agent isn't registered until a Claude Code restart, and an unregistered
   type errors the spawn. If a task would clearly benefit from a specialist that doesn't exist yet,
   dispatch the generic worker this run and record the gap (see `references/protocols.md` "Growing the
   worker library").

**Then choose the model.** The shipped agents declare `model: inherit`, so by default a worker runs on
*your* (the orchestrator's) model — fine, but not always right per task. The Agent tool takes a `model`
override at spawn, so pick by task weight rather than running an expensive model across the whole fleet:
a mechanical or low-ambiguity task (rename, doc tweak, small fix) → a cheaper/faster model; a subtle
bug, tricky refactor, or design-bearing task → a stronger model. When unsure, inherit. Record it on the
task (e.g. `model: haiku`) so the board shows each worker's loadout and `.fleet/memory.json` can learn
which weights paid off.

Record the chosen agent (and model, if overridden) on the task, then dispatch it via the kind below.

- **Background worker** — spawn via the Agent tool with `run_in_background: true`, the `subagent_type`
  you chose above (the generic `orchestrator-worker` when no specialist fit), and the `model` override
  if you picked one. The full spawn template (and what each line buys you) is in `references/protocols.md`
  "Worker brief". Pass `maxTurns` from `workerMaxTurns` so a hung worker self-aborts into a reportable
  state. Record the returned task id as the task's `worker`; set `owner` and flip `status` to `in_progress`.
- **Manual session** — the user opens their own session/window. A human worker can't be a
  `subagent_type`, so routing is advisory here: print the ready-to-use launch block from
  `references/protocols.md` ("Manual launch") and, if a specialist shape fit, fold its discipline
  (e.g. "reproduce + regression-test first" for a bugfix) into the brief. Set `owner` to the person
  and `status` to `in_progress`; you'll monitor via their branch's commits.

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
each action — Edit/Write/MultiEdit/Bash — inside a claimed worktree). A live process is not a
*progressing* one: board.sh flags
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
- `claim-guard.sh` — **PreToolUse** hook (matcher `Edit|Write|MultiEdit|Bash`, wired in
  `settings.json`). Reads the target's worktree `.agent-claim` (or `$AGENT_CLAIM`) and **blocks
  (exit 2) any Edit/Write/MultiEdit outside the claim**, plus a **best-effort** block of obvious
  out-of-claim Bash writes (`>`/`tee`; allows when it can't parse a target). Not a perfect shell fence
  — the merge-validator's diff-scope is the authoritative backstop (ADR-0002). Self-gates on the claim,
  so it's silent in the main checkout and ordinary sessions.
- `heartbeat.sh` — **PostToolUse** hook (matcher `Edit|Write|MultiEdit|Bash`). Stamps `.agent-heartbeat`
  (timestamp + cycle count) and appends a bounded `.agent-trail` (last 30 actions) inside the claimed
  worktree — including Bash, so an edit-light-but-busy worker (long test runs, git) still registers
  liveness and isn't a false `STALL?`. Locates the worktree the same way claim-guard does (file path,
  else a leading `cd` in the command, else cwd). `board.sh` turns the heartbeat into the HB column +
  `STALL?` flag; `trail.sh` reads the trail.
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

Read `references/protocols.md` when you need the exact worker brief, **growing the worker library**,
the manual launch block, race mode, the merge/rebase sequence, the revision loop, recovery-from-stall
steps, the deny-floor, or the `.fleet/config.json` schema. Keep this SKILL.md as your map; the
protocols file is the detailed playbook.

This kit ships, under `agents/` (install to `.claude/agents/`):
- **`merge-validator`** — read-only validate-the-merge subagent (step 6).
- **`orchestrator-worker`** — the generic worker, your default/fallback dispatch target (step 4).
- **`bugfix-worker`**, **`refactor-worker`** — skill-free specialist workers you route to by task shape.

Plus `_worker-template.md` (installed to `.claude/fleet/`) to copy when growing your own specialists.
Adding or editing any agent needs a Claude Code restart to re-register — see ADR-0001 and
`references/protocols.md` "Growing the worker library."
