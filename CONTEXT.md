# claude-fleet

The orchestration domain for running multiple coding agents in parallel against one repo: how work is
decomposed, isolated, dispatched, validated, and merged behind a human gate.

## Language

**Worker**:
A dispatched sub-agent that performs exactly one claimed task in its own worktree, then reports.
_Avoid_: sub-agent (ambiguous — see Agent), bot

**Skill**:
A reusable capability defined by a `SKILL.md` under `~/.claude/skills/` (global) or `.claude/skills/`
(project). A Worker gains a Skill either by loading it at runtime via the Skill tool, or — preferred —
by an Agent declaring it in the Agent's `skills:` frontmatter so it is bound at spawn.
_Avoid_: plugin, tool

**Agent** (a.k.a. `subagent_type`):
A spawn-time worker identity chosen *before* a sub-agent starts — a `.md` definition under
`~/.claude/agents/` (global) or `.claude/agents/` (project) declaring its `tools`, `model`,
`permissionMode`, and the `skills:` it pre-binds (e.g. `merge-validator`, `orchestrator-worker`). The
unit the orchestrator routes to at Dispatch. Adding or editing one requires a Claude Code restart to
register.
_Avoid_: persona, role

**Specialized worker Agent**:
An Agent purpose-built for one kind of task (e.g. a `tdd-worker` that pre-binds `skills: tdd`), as
opposed to the generic `orchestrator-worker` fallback. The library the orchestrator selects from.
_Avoid_: specialist, custom worker

**Dispatch**:
The orchestrator's act of spawning a Worker for a ready task — choosing its Agent type, brief, claim,
and (now) the Skill it should load.
_Avoid_: launch, run, kick off

**Claim**:
The set of path prefixes a Worker is allowed to modify. Enforced best-effort at edit time by the
`claim-guard` hook and authoritatively at the merge gate by the merge-validator's scope check
(see ADR-0002).
_Avoid_: lock, lane (informal only), permission

**Scope drift**:
A Worker's committed diff touching files outside its Claim — caught by the merge-validator and a reason
to hold the merge.
_Avoid_: stray, leak, overreach
