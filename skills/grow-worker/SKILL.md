---
name: grow-worker
description: >-
  Generate a custom specialized worker agent for an agent-orchestrator fleet by interviewing the user,
  then writing a well-formed `.claude/agents/<name>-worker.md` from the kit template. Use when the user
  wants to create/scaffold/generate a new worker agent, a fleet specialist, a custom subagent for the
  orchestrator, bind one of their skills into a worker, or "grow my worker library". Self-contained:
  depends on no external skills. Guards against worker-library rot before it writes anything.
---

# Grow a worker agent

You turn a recurring task shape into a reusable **specialized worker Agent** the `agent-orchestrator`
skill can route to. Your output is one file: `.claude/agents/<name>-worker.md`, filled from the kit
template. Interview first, write once, then tell the user to restart.

This is a *quick* path — keep the interview tight (one question at a time, recommend an answer, move
on). But do not skip the rot gate: a bad worker is worse than none, because it clutters routing and
breaks installs.

## Step 0 — the rot gate (run BEFORE interviewing)

A new agent only earns its existence if it passes **all** of these. Check them out loud with the user;
if any fails, say so and **stop** — recommend they just brief the generic `orchestrator-worker` for
this task instead of minting an agent.

1. **Recurring shape** — this kind of task shows up repeatedly, not once. A one-off is a brief, not an
   agent.
2. **Materially different from the generic worker** — its discipline genuinely changes how the work is
   done (a distinct method, a bound skill, or a narrower toolset). If the body would read like
   `orchestrator-worker`, don't make it.
3. **Description that routes** — you can write a one-line "use when the task is X, not Y" that the
   orchestrator could match against unambiguously. If you can't phrase the trigger, the agent can't be
   routed.

## Step 1 — interview (one question at a time, with a recommendation)

1. **Task shape & name.** What kind of task is this worker for? Derive a kebab-case `name` ending in
   `-worker` (e.g. `migration-worker`). Confirm it.
2. **Trigger phrasing.** Draft the routing description: "A fleet worker specialized for `<shape>` …
   Use when the task is `<trigger>` rather than `<what it is NOT for>`." This is the most important
   field — it's *how the orchestrator picks this worker* — so sharpen it like a glossary term.
3. **Skills to bind (optional).** Enumerate the user's installed skills (`ls ~/.claude/skills` and
   `ls .claude/skills`) and offer to bind a relevant one via `skills:` frontmatter. **Warn:** a bound
   skill is an install dependency — the worker breaks on any machine/repo that lacks it. Recommend
   binding only skills the user reliably has. Default: none (encode the discipline inline instead).
4. **Tools / permissions.** Default to the standard worker set
   (`Read, Edit, Write, MultiEdit, Bash, Grep, Glob, ToolSearch`, `permissionMode: acceptEdits`).
   Offer a **narrower** set when the role wants it — e.g. drop `Edit/Write` for a read-only
   investigator. A tighter toolset is itself a valid specialization (criterion 2).
5. **Discipline steps.** Elicit 3–5 method steps that distinguish this worker from the generic one
   (what it does first, the core method, how it verifies, what it explicitly does NOT do → `findings`).
   Keep them self-contained — don't assume context the orchestrator won't pass.

## Step 2 — write the file

Copy the kit template (`.claude/fleet/_worker-template.md`, or `agents/_worker-template.md` in the kit)
and fill every `<…>` slot from the answers. Default destination: project `.claude/agents/<name>.md`
(offer `~/.claude/agents/` for cross-repo use). Keep the constant rules deferred to
`WORKER-CONTRACT.md` — the agent body holds only identity + the discipline steps, like the shipped
`bugfix-worker` / `refactor-worker`.

Then validate what you wrote: frontmatter has a unique `name:` and a non-empty `description:`; the name
doesn't collide with an existing agent (`ls .claude/agents ~/.claude/agents`); the body has real
discipline steps, not leftover placeholders.

## Step 3 — report

State plainly: the file written and where; whether it binds a skill (and that the skill must stay
installed); and the hard step — **restart Claude Code to register the new `subagent_type`** before the
orchestrator can dispatch it (so it routes automatically on the *next* run, not this one). If you can
tell, mention the task shapes the orchestrator will now match to it.
