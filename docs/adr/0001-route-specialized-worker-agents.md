# Route specialized worker Agents, not worker-loaded Skills

To equip each dispatched Worker with the best-matching capability for its task, the orchestrator
selects a **specialized worker Agent** (a `subagent_type` whose `.md` definition pre-binds the
relevant Skill via its `skills:` frontmatter) at Dispatch — rather than naming a Skill in the worker
brief for the Worker to load itself at runtime.

## Considered options

- **Worker-loaded skill** — orchestrator names a Skill in the brief; the Worker invokes it mid-run.
  Hot (usable the moment a skill exists on disk, no restart) and matches the richer Skill registry —
  but depends on the dispatched Worker actually having Skill-tool access, which is not guaranteed, and
  lets the Worker's own auto-triggering pick the wrong skill, undercutting "the orchestrator chooses."
- **Specialized worker Agent (chosen)** — capability is bound at spawn by the Agent definition. No
  dependency on mid-run skill loading; the orchestrator controls the choice via `subagent_type`.

## Consequences

- Adding or editing an Agent requires a **Claude Code restart to register**. A specialist is therefore
  not dispatchable in the session it was created in — growth lands on the *next* run. The orchestrator
  must dispatch **only registry-present `subagent_type`s** (a freshly-written `.md` is treated as
  absent until registered) and degrade to the generic `orchestrator-worker` meanwhile.
- The kit ships a small set of **skill-free, self-contained** specialists (`bugfix-worker`,
  `refactor-worker`) plus the generic `orchestrator-worker` fallback and a copy-to-grow template.
  Prebuilts bind **no external Skills** — a prebuilt that declared `skills: tdd` would break on any
  install lacking that skill, re-importing the dependency-rot we are avoiding. Skill-binding
  specialists (e.g. `tdd-worker`) are the user's to grow against their own Skill library.
