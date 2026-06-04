# Orchestrator protocols

Detailed playbook for `agent-orchestrator`. SKILL.md is the map; this is the procedures. Read the
section you need. Script paths below are written relative to the kit install root
`.claude/fleet/scripts/`.

## Table of contents
- [Worker brief (background dispatch)](#worker-brief)
- [Manual launch block](#manual-launch)
- [Race mode (same-task best-of-N)](#race-mode)
- [Merge + rebase command sequence](#merge--rebase)
- [Revision loop (comment → revise at the gate)](#revision-loop)
- [Recovery: stalled / crashed / strayed agents](#recovery)
- [Static deny-floor (project settings)](#deny-floor)
- [`.fleet/config.json` schema](#config-schema)
- [Worktree layout & cleanup notes](#worktree-notes)

---

## Worker brief

Spawn a background worker via the Agent tool with `run_in_background: true` and `maxTurns` from
`workerMaxTurns`. Build its prompt from this template. The point of every line is to keep the worker
inside its lane so its branch merges cleanly later. (If you maintain a reusable worker subagent
definition, bake these constants into it and pass only the dynamic TASK / WORKING DIRECTORY / CLAIM —
version-controlled rules can't be forgotten or truncated.)

```
You are a worker agent. Do exactly this task and nothing else.

TASK: <task subject + full description>

WORKING DIRECTORY: <absolute worktree path>
  - This is your own isolated git worktree on branch <branch>. Do ALL work here.
  - Start every shell command by cd-ing in, e.g.  cd <worktree> && <command>
  - NEVER touch the main checkout at <repoRoot> and NEVER run `git checkout`/`git switch`
    to change branches — you are already on the right branch.

YOUR CLAIM (the only paths you may modify): <claim list>
  - This claim is ENFORCED: a hook will hard-block (deny) any Edit/Write outside it — you cannot
    stray even by accident. If completing the task honestly requires a file OUTSIDE this claim,
    STOP and report what you need and why. Do not fight the block.

WORK EFFICIENTLY:
  - Targeted reads + exact chunk edits; never paste full files or long logs back to me.
  - Don't write throwaway scripts to "figure it out" — if the task is ambiguous, STOP and report.
  - For a big change, trace silently then drop a short implementation_plan.md in the worktree and
    PROCEED — your TASK + CLAIM above ARE the approved scope, so do NOT halt for sign-off. If the
    plan shows you must exceed the claim, STOP.
  - Verify with the build/test command before reporting done; keep the report terse.

WHEN DONE:
  - Commit everything to <branch> with clear messages and leave the worktree clean. Do NOT push,
    merge, deploy, or publish — that's mine to do behind the human merge gate.
  - Then report exactly: one-line summary, files changed, test/build output,
    branch-committed-&-clean (yes/no), any out-of-claim needs, Learnings, Suggestions.
    If you got blocked or had to stray, say so plainly instead of forcing it.
```

After spawning, record the returned background task id on the task, set `owner`, and flip `status`
to `in_progress`.

**Bound the worker** so a hung/looping agent self-aborts into a reportable state instead of waiting
forever (the "infinite wait" failure mode): pass `maxTurns` on the Agent call (default from
`workerMaxTurns` in `.fleet/config.json`). Combined with the heartbeat watchdog (a `STALL?` on
`board.sh` when `.agent-heartbeat` goes stale), you can tell a *progressing* worker from a zombie
rather than trusting that the process is merely alive.

---

## Manual launch

When the user runs the worker as their **own** session, hand them this block to act on. They open a
session whose working directory is the worktree, so most of the isolation is automatic.

```
Open a new agent/session in this directory:
    <absolute worktree path>
You're on branch <branch>, cut from <base>.

Paste this as the session's first instruction:
---
Work efficiently: targeted chunk edits, no chat clutter, ask me if ambiguous, verify with build/test
before done. Only modify files under: <claim list>. If you need to touch anything outside that, stop
and tell me — don't edit it. When done, commit to this branch and leave the tree clean (don't push or
merge). Don't switch branches or touch the main checkout.
TASK: <task subject + description>
---
```

Set the task `owner` to the person, `status` to `in_progress`. Monitor via `board.sh` (their
branch will show commits / ahead count) rather than completion notifications.

---

## Race mode

Best-of-N for one task: run N independent attempts, keep the best. Use it when the task is
open-ended or high-stakes and the first attempt isn't reliably the best (a tricky bug, an API design,
a perf rewrite). Because **only one attempt is ever merged**, the attempts may share the same claim —
they live on disjoint branches and never combine.

1. **Provision N attempts** (same claim, disjoint branches `agent/<id>-<slug>-r1..rN`):
   ```
   scripts/race.sh create <id> <slug> <N> [base-ref] [claim-prefix ...]
   ```
   It prints a JSON array of `{variant, worktree, branch, base}`. Symlink `linkArtifacts` into each as
   usual. Track the set under one task (e.g. `race = N`).
2. **Dispatch the SAME brief** to each attempt (background workers or manual), one per worktree. Vary
   nothing but the worktree/branch — you want independent takes on the identical task. (Optionally use
   different models per attempt for diversity.)
3. **Compare** when they finish:
   ```
   scripts/race.sh compare <id> <slug> <N> [base-ref]
   ```
   Shows commits + diffstat + dirty-state per attempt. Read a promising one with
   `scripts/review.sh <id> <slug>-rK`. Judge on the real diff, not the stats alone; you can also run
   the validator on each finalist.
4. **Keep the winner** (force-drops the losing throwaways):
   ```
   scripts/race.sh keep <id> <slug> <N> <winner>
   ```
   The surviving `agent/<id>-<slug>-r<winner>` then goes through the normal **validate → human gate →
   merge train** like any other branch. (Unlike normal teardown, `keep` force-deletes losing branches
   even with unmerged commits — they're attempts you explicitly chose to discard, not work to preserve.)

---

## Merge + rebase

Run from the **main checkout** (not a worktree). `WB` = working branch (e.g. `main` or the feature
integration branch the user is landing onto). `FB` = the approved feature branch `agent/<id>-<slug>`.

Land one approved branch:
```bash
git switch "$WB"
git merge --no-ff "$FB" -m "merge $FB: <subject>"   # --no-ff keeps the agent's work as one unit
```

Then reconcile every *other* in-flight branch against the new base (their prior validation is now
stale):
```bash
for br in $(git for-each-ref --format='%(refname:short)' refs/heads/agent/); do
  [ "$br" = "$FB" ] && continue
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$br" '
        /^worktree /{w=$2} /^branch /{if($2==b) print w}')
  [ -z "$wt" ] && continue
  git -C "$wt" rebase "$WB" || {
      echo "REBASE CONFLICT on $br — flag to user, do not force";
      git -C "$wt" rebase --abort; }
done
```
Any branch that fails to rebase cleanly is now a real conflict: surface it to the user with the
conflicting files; the owning agent (or a fresh one) resolves it in its worktree before it can be
re-validated and re-approved. **Re-run the merge-validator** on every rebased branch — never carry
an approval across a base change.

Teardown the merged task:
```bash
scripts/worktree.sh remove <id> <slug>
```
Then mark it `completed`. Freeing its claim may make blocked tasks ready — provision and dispatch
those next.

---

## Revision loop

When the user reviews a finished branch (step 7) and wants changes rather than a yes/no, don't
reject-and-restart — revise in place. The worktree and branch still exist, so the same worker can
pick up with full context.

1. Render the diff with anchors the user can comment against:
   ```
   scripts/review.sh <id> <slug> [base-ref]
   ```
   It prints a files summary, the commits, and each file's diff under a `===== FILE n: <path> =====`
   header. The user attaches each comment to a `FILE n` and/or an `@@` hunk header.
2. Build a **revision brief** from the comments and re-dispatch the *same* worker on the *same*
   branch/worktree (background: a fresh Agent call pinned to the existing worktree path; manual: paste
   into their open session):
   ```
   REVISION of task <id> on branch <branch> (worktree <path>). Your prior work is committed there.
   Address these review comments, then commit and report — same claim, same rules:
     - FILE <n> (<path>) @@<hunk>: <requested change>
     - ...
   Do not expand scope beyond the comments; if a comment needs a path outside your claim, STOP and say so.
   ```
3. The worker commits the revisions; **re-run the merge-validator** (its prior verdict is now stale),
   then present an updated merge brief. Loop until approved or rejected.

Keep revisions tight: if the comments amount to a different task, that's a new task with its own
claim, not a revision.

---

## Recovery

A worker can stall (no commits for a long time), crash, or stray outside its claim. The harness
re-invokes you when a *background* task ends; for manual sessions you notice via `board.sh` (no new
commits, or `DIRTY` for a long time).

- **Stalled / crashed:** confirm with the user before acting. Then release the lane so others
  aren't blocked: set the task back to `pending` (or a `stalled` note) and **clear its claim from
  the active set** — but **keep the branch and worktree**; never delete unmerged work. Offer to
  re-dispatch a fresh worker onto the same branch (it picks up where the last left off) or to a new
  branch.
- **Strayed (edited outside its claim):** the `claim-guard` hook normally *prevents* this by denying
  the edit, so a worker that needed an out-of-claim path will have STOPPED and reported it (the right
  outcome — usually you widen the claim, re-check overlap against in-flight tasks, and resume; if it
  now overlaps an active task you have a real conflict to sequence). The merge-validator's
  `outOfScope` check remains the backstop for anything that slips through (e.g. the guard failing
  open). Either way: don't auto-merge; revert the stray hunks or re-scope the claim.
- **Two tasks discovered to overlap mid-flight** (claims were wrong): pause the later one, let the
  earlier land, rebase the later onto it, re-validate.

The guiding rule: **a wrong claim is a planning miss, not the worker's fault** — fix the board, and
preserve every commit.

---

## Deny-floor

Claim-guard enforces *per-task* claims, but some paths must be off-limits to **every** worker no
matter their claim. Encode those as a static `permissions.deny` list in the project's
`.claude/settings.json`. A project-level `deny` **cannot be overridden by user settings**, so it is a
hard policy floor that survives any worker's context. Recommended starting set (tune per repo):

```json
{
  "permissions": {
    "deny": [
      "Edit(.fleet/config.json)", "Write(.fleet/config.json)",
      "Edit(.github/**)", "Write(.github/**)",
      "Edit(package-lock.json)", "Write(package-lock.json)",
      "Read(.env)", "Read(**/.env)"
    ]
  }
}
```
Swap `package-lock.json` for the repo's real lockfile (`yarn.lock`, `Cargo.lock`, `poetry.lock`,
`go.sum`). These deny the *editing tools* — a worker can still regenerate a lockfile via the package
manager through Bash, it just can't hand-edit it. Two layers, two jobs: the deny-floor stops the
always-off paths; claim-guard scopes each worker to its lane. If a repo doesn't already have a
`.claude/settings.json`, offer to create one with this floor at first run.

---

## Config schema

`.fleet/config.json`, committed per-repo, makes runs automatic. All fields optional:

```json
{
  "validate": "npm test && npm run build",
  "baseBranch": "main",
  "worktreeDir": "../<repo>-worktrees",
  "branchPrefix": "agent/",
  "maxConcurrent": 4,
  "linkArtifacts": ["node_modules"],
  "workerMaxTurns": 60,
  "staleMinutes": 10
}
```
- `validate` — shell command the merge-validator runs on the trial-merged result. Exit 0 = pass.
- `baseBranch` — default base for new worktrees and the default merge target.
- `worktreeDir` — override where worktrees go (default: sibling `<repo>-worktrees/`).
- `maxConcurrent` — soft cap on simultaneously dispatched workers; queue the rest as ready-but-held.
- `linkArtifacts` — gitignored dirs (e.g. `node_modules`) to symlink from the main checkout into each
  new worktree AND the validator's trial-merge worktree. Worktrees don't inherit gitignored build
  output, so tests won't run without this.
- `workerMaxTurns` — default `maxTurns` ceiling passed to each background worker so a hung/looping
  agent aborts into a reportable state instead of waiting forever. Omit for no cap.
- `staleMinutes` — `board.sh` flags an in-flight worker whose `.agent-heartbeat` is older than this as
  `STALL?` (default 10; also via `$FLEET_STALE_MINUTES`).

The orchestrator also maintains **`.fleet/memory.json`** (separate from this config): an append-only
log of per-run learnings (too-narrow claims, validator verdicts, decompositions that worked). It is
*read* at decompose time (lifecycle step 1) and *written* at wrap-up (step 9) so each run improves on
the last. It is **gitignored by default** (machine-local learning state). If you want that learning to
persist across clones or be shared with the team, remove the `.fleet/memory.json` line from
`.gitignore` and commit it per-repo.

If the file is absent, infer `validate` from the repo (package.json scripts, Makefile, cargo,
pytest, go test) and ask once if ambiguous, offering to write this file.

---

## Worktree notes

- Worktrees share the repo's object database, so a commit a worker makes on `agent/3-foo` in its
  worktree is immediately visible to `git merge agent/3-foo` from the main checkout. That's why
  this works without pushing anywhere.
- A branch can only be checked out in one worktree at a time — that's a feature: it stops two
  agents grabbing the same branch.
- `worktree.sh remove` uses `--force` then `git worktree prune`, and only `git branch -d` (safe
  delete) — it refuses to drop an unmerged branch, so you can't lose work by tearing down too
  early. Use `git branch -D` yourself only when you're sure.
- Keep `<repo>-worktrees/` out of the repo (it's a sibling, so it already is) — no `.gitignore`
  entry needed.
```
