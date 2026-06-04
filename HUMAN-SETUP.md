# claude-fleet — human setup & operating guide

This guide is for a **person** installing claude-fleet into a repository and then driving a
multi-agent run. It assumes you have a clone of this kit and a target repo you want to add it to.

> Installing into your own repo? You can also hand the whole job to a Claude Code agent — point it at
> [CLAUDE-SETUP.md](CLAUDE-SETUP.md), which is the same install written as imperative steps an agent
> executes for you.

---

## 1. Get the kit

```bash
git clone <your-fork-or-copy-of>/claude-fleet.git
# …or just copy the claude-fleet/ directory you already have next to your target repo.
```

For the commands below, `KIT` is the path to this kit and you run everything from your **target
repo's root**:

```bash
KIT=/path/to/claude-fleet     # adjust
cd /path/to/your-target-repo
```

---

## 2. Copy the files into your repo's `.claude/`

claude-fleet installs four things: the **skill**, the **subagent**, the **scripts**, and the
**hook**. Run these from your target repo root:

```bash
# 2a. the orchestrator skill (the conductor's playbook)
mkdir -p .claude/skills
cp -R "$KIT/skills/agent-orchestrator" .claude/skills/agent-orchestrator

# 2b. the merge-validator subagent
mkdir -p .claude/agents
cp "$KIT/agents/merge-validator.md" .claude/agents/merge-validator.md

# 2c. the scripts AND the hook (the hook lives alongside the scripts)
mkdir -p .claude/fleet/scripts
cp "$KIT"/scripts/*.sh        .claude/fleet/scripts/
cp "$KIT"/hooks/claim-guard.sh .claude/fleet/scripts/
chmod +x .claude/fleet/scripts/*.sh
```

Resulting layout in your repo:

```
.claude/
├── skills/agent-orchestrator/{SKILL.md, WORKER-CONTRACT.md, references/protocols.md}
├── agents/merge-validator.md
├── fleet/scripts/{claim-guard.sh, heartbeat.sh, worktree.sh, merge-check.sh,
│                  board.sh, trail.sh, race.sh, review.sh, on-subagent-stop.sh}
└── settings.json                   ← register the hooks (next section)
```

> Adding or editing the `merge-validator` subagent requires a **Claude Code restart** to re-register
> it.

---

## 3. Register the hooks in `.claude/settings.json`

Add this block to `.claude/settings.json` (merge it into any existing file). The **only required**
hook is `claim-guard` on `PreToolUse` — that's what enforces path-claims. `heartbeat` (PostToolUse)
and `on-subagent-stop` (SubagentStop) are optional monitoring niceties.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/claim-guard.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/heartbeat.sh" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/on-subagent-stop.sh" }
        ]
      }
    ]
  }
}
```

`${CLAUDE_PROJECT_DIR}` is set by Claude Code to the repo root, so these paths resolve wherever the
repo lives — no absolute paths needed. Want the hook in **every** repo instead of one? Put the same
`PreToolUse` block in your **user** `~/.claude/settings.json` and point `command` at an absolute
install path.

### Safe to install — the hook is a no-op until a claim is set

`claim-guard.sh` allows the edit (exit 0) **whenever there is no active claim**. A claim is "active"
only when one of these is present:

- the `$AGENT_CLAIM` env var (set per dispatched worker) — newline- or colon-separated path globs, or
- a `.agent-claim` file in a worktree (written automatically by `worktree.sh`), or
- a `.claude/claim` file in the repo root (one glob per line).

So in ordinary single-agent sessions, and in every repo where you haven't claimed a worker, the hook
does **nothing**. It only "bites" when an orchestrated worker has a claim, and then it **denies (exit
2)** any Edit/Write/MultiEdit outside the claim and tells the model exactly which claim it violated.

---

## 4. (Optional) Configure validation

Drop a `.fleet/config.json` in your repo so runs are automatic (every field optional):

```json
{
  "validate": "npm test && npm run build",
  "baseBranch": "main",
  "linkArtifacts": ["node_modules"],
  "workerMaxTurns": 60,
  "staleMinutes": 10
}
```

Without it, the validator infers a test command from the repo (`package.json` scripts, `Makefile`,
`cargo`, `pytest`, `go test`) and reports `skipped` if there's nothing to run — it won't block a repo
that has no tests. Full schema: `skills/agent-orchestrator/references/protocols.md`.

### (Optional) A static deny-floor

Some paths should be off-limits to **every** worker, regardless of claim — CI config, lockfiles,
secrets. Add a `permissions.deny` list to `.claude/settings.json`; a project-level deny can't be
overridden by user settings:

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

Swap `package-lock.json` for your real lockfile (`yarn.lock`, `Cargo.lock`, `poetry.lock`, `go.sum`).

---

## 5. Verify the install

From your target repo root, confirm the hook denies an out-of-claim edit and allows an in-claim one:

```bash
ROOT="$(pwd)"

# out-of-claim → should print BLOCKED and exit 2
AGENT_CLAIM='src/**' \
  printf '{"tool_input":{"file_path":"%s"}}' "$ROOT/OUT.ts" \
  | CLAUDE_PROJECT_DIR="$ROOT" bash .claude/fleet/scripts/claim-guard.sh
echo "out-of-claim exit: $?"     # expect: 2

# in-claim → should be silent and exit 0
AGENT_CLAIM='src/**' \
  printf '{"tool_input":{"file_path":"%s"}}' "$ROOT/src/app.ts" \
  | CLAUDE_PROJECT_DIR="$ROOT" bash .claude/fleet/scripts/claim-guard.sh
echo "in-claim exit: $?"         # expect: 0
```

If you see `exit: 2` then `exit: 0`, the guard is live.

---

## 6. Drive a multi-agent run

Open a Claude Code session in the repo that **has the Task/Agent tool** (the orchestrator session).
Tell it:

> "Use the agent-orchestrator skill. Break this work into parallel tasks with non-overlapping
> claims, give each its own worktree and `agent/*` branch, dispatch workers, and don't merge anything
> until I approve."

The orchestrator then walks its lifecycle (full detail in the skill):

1. **Decompose & claim** — split the goal into tasks, each with a minimal path-claim.
2. **Schedule** — overlapping claims can't run concurrently; it sequences them with dependencies.
3. **Provision** — `worktree.sh create` cuts a worktree + `agent/*` branch and writes the claim.
4. **Dispatch** — background workers, or a manual launch block you paste into your own session.
5. **Monitor** — `board.sh` shows ahead/behind + a heartbeat age; a stale heartbeat flags `STALL?`.
   `trail.sh <id> <slug>` shows what a worker was actually doing.
6. **Validate** — the merge-validator trial-merges each finished branch and runs your tests on the
   **merged result**.

### Watch the fleet yourself

```bash
.claude/fleet/scripts/board.sh main          # one-line-per-agent status
.claude/fleet/scripts/board.sh --watch main  # live, re-renders every few seconds
.claude/fleet/scripts/trail.sh 1 parser      # recent actions of worktree 1-parser
```

---

## 7. The merge gate (your decision)

When a branch is validated, the orchestrator presents a **merge brief** and stops. The outcome is
yours and it's **three-way**:

- **Approve** → the orchestrator runs a **merge train**: lands one branch with `--no-ff`, then rebases
  and **re-validates** every other in-flight branch (a prior approval is stale once the base moves),
  tears down the merged worktree, and frees its claim.
- **Revise** → leave comments instead of yes/no. The orchestrator renders the diff with FILE/hunk
  anchors (`review.sh`) and re-dispatches the **same** worker on the **same** branch to address them.
- **Reject / defer** → the branch is left in place; nothing is lost.

**The orchestrator never merges on its own.** Validation makes the decision *informed*; the merge is
still yours.

---

## Troubleshooting

- **Hook never blocks.** That's the no-op path — no claim is set. Confirm `$AGENT_CLAIM` or a
  `.agent-claim` file is present for the worker. Re-run the step 5 verification.
- **Tests don't run in a worktree.** Worktrees don't inherit gitignored build output (e.g.
  `node_modules`). List those dirs in `linkArtifacts` so they're symlinked into each worktree.
- **`conflicts: null` from `merge-check.sh`.** Your git predates `merge-tree --write-tree` (2.38);
  the validator falls back to a real trial-merge automatically.
- **A worktree branch won't delete on teardown.** `worktree.sh remove` uses safe `git branch -d` and
  refuses to drop unmerged work. Use `git branch -D` yourself only when you're sure.
