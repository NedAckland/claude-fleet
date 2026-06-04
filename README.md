# claude-fleet

**Run several Claude Code coding agents in parallel against one repo — without merge collisions —
and land their work only after a human approves.**

claude-fleet is a drop-in kit. It gives each agent its own **git worktree + branch**, fences each one
to a declared **path-claim** with a **blocking hook** (a worker physically cannot edit outside its
lane), validates finished branches with a read-only **merge-validator** subagent that tests the
*merged* result, and then **stops at an explicit human merge gate** — it never merges on its own.

Zero framework dependency: pure `git` + `bash` (macOS 3.2 safe) + `node` (already present with Claude
Code). No `jq`, no python, nothing to `npm install`.

## Why

Concurrent agents collide for two avoidable reasons:

1. **They share one working tree.** Two agents editing the same file clobber each other; one agent's
   `git checkout` yanks the floor out from under another. → Fix: **one worktree per agent**, so edits
   are physically isolated.
2. **Nobody owns the big picture.** Two agents get handed overlapping work, or B starts before A's
   refactor has landed. → Fix: a **single source of truth for who-owns-what** (path-claims + a
   dependency order), with the claim **enforced by a hook** rather than left as advice an agent can
   ignore or hallucinate around.

claude-fleet provides both, plus the safe-merge machinery on the back end.

## 30-second quickstart

You drive this from an **orchestrator** Claude Code session (the one with the Task/Agent tool). After
installing (see the setup guides below), tell that session:

> "Use the agent-orchestrator skill. Split this work into parallel tasks, give each its own claim and
> worktree, and don't merge anything until I approve."

The orchestrator then: decomposes the goal → assigns non-overlapping claims → provisions a worktree +
`agent/*` branch per task → dispatches workers (each hook-fenced to its claim) → shows you a live
board of who's progressing vs. stalled → validates each finished branch on its *merged* result →
presents a merge brief and **waits for your go**.

You can also exercise the mechanism directly:

```bash
# provision an isolated worktree + branch, claimed to one directory
# (args: create <id> <slug> <base-ref> <claim-prefix...> — base-ref first, then the claim)
.claude/fleet/scripts/worktree.sh create 1 parser HEAD src/parser/

# see every agent worktree's status (ahead/behind, heartbeat, STALL?)
.claude/fleet/scripts/board.sh main
```

## Verify your install

After installing, run the kit's self-test from the kit dir to confirm everything works:

```bash
bash verify.sh
```

It syntax-checks every script under `hooks/` and `scripts/`, then functionally proves the
`claim-guard` hook by feeding it an out-of-claim edit (must DENY, exit 2) and an in-claim edit (must
ALLOW, exit 0). It prints `VERIFY OK` and exits 0 on success, and exits non-zero on any failure. Pure
`bash` + `node` — nothing to install.

## Install

See **[CLAUDE-SETUP.md](CLAUDE-SETUP.md)** — terse, imperative, copy-paste-ready steps to install
this into a target repo: exact file copies, the `settings.json` hook edit, and a self-verification
command to run. Written for an AI agent to execute, but equally followable by a person reading
straight down it.

## Repo map

```
claude-fleet/
├── README.md                        ← this file
├── CLAUDE-SETUP.md                  ← install + verify steps (agent- or human-followable)
├── LICENSE                          ← MIT
├── verify.sh                        ← one-command self-test (claim-guard deny/allow + syntax)
├── .gitignore
├── skills/
│   └── agent-orchestrator/          ← the orchestrator SKILL (the conductor's playbook)
│       ├── SKILL.md
│       ├── WORKER-CONTRACT.md       ← the one stable doc each worker reads
│       └── references/
│           └── protocols.md         ← worker brief, race mode, merge train, recovery, config schema
├── agents/
│   └── merge-validator.md           ← read-only subagent: is this branch safe to merge?
├── hooks/
│   └── claim-guard.sh               ← PreToolUse hook: DENIES edits outside an agent's path-claim
└── scripts/
    ├── worktree.sh                  ← create/claim/remove a per-task worktree + agent/* branch
    ├── merge-check.sh               ← read-only "is this branch safe to merge?" probe
    ├── board.sh                     ← one-line-per-agent status (ahead/behind, heartbeat, STALL?)
    ├── trail.sh                     ← what a worker actually did (pair with a STALL? on the board)
    ├── race.sh                      ← same-task best-of-N (provision N attempts, keep one)
    ├── review.sh                    ← render a branch diff with FILE/hunk anchors for the human gate
    ├── heartbeat.sh                 ← PostToolUse hook: stamps liveness + action trail per worktree
    └── on-subagent-stop.sh          ← SubagentStop hook: breadcrumb if a worker left work uncommitted
```

## How it works (one paragraph)

The orchestrator decomposes the user's goal into tasks, gives each a **non-overlapping path-claim**,
and provisions **one git worktree + `agent/*` branch per task** so agents are physically isolated and
can never clobber each other's files or yank each other's branch. It dispatches workers (background or
manual), each fenced to its lane by the `claim-guard` hook; `board.sh` / `trail.sh` show who's
progressing vs. stalled. When a task reports done, the **merge-validator** subagent trial-merges the
branch in a throwaway worktree and runs the project's tests **on the merged result** — catching
*logical* conflicts that merge clean but break at runtime — and returns a structured verdict. The
orchestrator presents a merge brief and then **stops at the human gate**: it never merges on its own.
On explicit approval it runs a **merge train** — land one branch with `--no-ff`, rebase + re-validate
every other in-flight branch (a prior approval is stale once the base moves), tear down the worktree,
and free the claim (which may unblock dependent tasks).

## The path-claim, in one line

A **claim** is a list of path prefixes a worker may touch — a directory (`src/` matches everything
under it) or an exact file (`src/index.ts`). `worktree.sh claim` writes it to a git-excluded
`.agent-claim` file in the worker's worktree; the `claim-guard` PreToolUse hook reads that file on
every edit and **hard-blocks (exit 2) anything outside the listed prefixes**. A claim can also be set
via the `$AGENT_CLAIM` env var (newline- or colon-separated globs). **No claim set → the hook is a
no-op (exit 0)** — so installing it never affects ordinary single-agent work; it only bites a worker
you've actively claimed.

## Requirements

- `git` ≥ 2.5 (worktrees). The static conflict probe in `merge-check.sh` uses
  `git merge-tree --write-tree` (git ≥ 2.38); on older git it reports `conflicts: null` and the
  validator falls back to a real trial-merge.
- `bash` (3.2+), `node` (ships with Claude Code), `awk`/`sed` (standard). No `jq`, no python.

## License

MIT — see [LICENSE](LICENSE).
