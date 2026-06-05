# claude-fleet — agent self-install

**You are an AI agent installing claude-fleet into a target repository.** Execute these steps in
order. Each is exact and copy-paste-ready. Do not skip the verification step — it proves the install
works rather than assuming it.

## Preconditions

- You can run shell commands and write files in the target repo.
- `git`, `bash`, and `node` are available (`node` ships with Claude Code).
- You know two paths:
  - `KIT` — where this claude-fleet kit lives.
  - The **target repo root** — run every command below from there.

Set them and confirm:

```bash
KIT="<path-to-claude-fleet-kit>"     # EDIT THIS
cd "<path-to-target-repo>"           # EDIT THIS
ROOT="$(git rev-parse --show-toplevel)" && cd "$ROOT"
command -v git node bash >/dev/null && echo "preconditions OK"
```

## Step 1 — copy skill, subagent, scripts, hook

```bash
mkdir -p .claude/skills .claude/agents .claude/fleet/scripts
cp -R "$KIT/skills/agent-orchestrator"  .claude/skills/agent-orchestrator
cp -R "$KIT/skills/grow-worker"         .claude/skills/grow-worker   # interactive worker generator
cp    "$KIT"/agents/[!_]*.md            .claude/agents/        # real agents only (skip the template)
cp    "$KIT/agents/_worker-template.md" .claude/fleet/_worker-template.md   # copy-to-grow, NOT auto-registered
cp    "$KIT"/scripts/*.sh               .claude/fleet/scripts/
cp    "$KIT/hooks/claim-guard.sh"       .claude/fleet/scripts/
chmod +x .claude/fleet/scripts/*.sh
```

The `[!_]*.md` glob installs the real worker agents and skips `_worker-template.md` — the template
carries placeholder frontmatter, so keep it OUT of `.claude/agents/` (where it would try to register
as a bogus agent) and in `.claude/fleet/` as a reference to copy when growing the library.

Expected resulting layout:

```
.claude/
├── skills/
│   ├── agent-orchestrator/{SKILL.md, WORKER-CONTRACT.md, references/protocols.md}
│   └── grow-worker/SKILL.md   ← interactive generator for custom worker agents
├── agents/{merge-validator.md, orchestrator-worker.md, bugfix-worker.md, refactor-worker.md}
└── fleet/
    ├── _worker-template.md   ← copy this to .claude/agents/<name>-worker.md to grow the library
    └── scripts/{claim-guard.sh, heartbeat.sh, worktree.sh, merge-check.sh,
                 board.sh, trail.sh, race.sh, review.sh, on-subagent-stop.sh}
```

## Step 2 — register the hooks in `.claude/settings.json`

Merge this `hooks` block into `.claude/settings.json` (create the file if absent; if it exists,
merge — do not clobber existing keys). The **required** hook is `claim-guard` on `PreToolUse`; the
other two are optional monitoring.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/claim-guard.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|Bash",
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

If `.claude/settings.json` already has a `hooks` object, append these entries to the matching arrays
rather than replacing them. Keep `${CLAUDE_PROJECT_DIR}` literally — Claude Code expands it to the
repo root, so the install stays path-independent. Never write an absolute path here.

If `node` is present, you can merge programmatically and safely:

```bash
node -e '
const fs="fs",f=".claude/settings.json";
const j=require(fs).existsSync(f)?JSON.parse(require(fs).readFileSync(f,"utf8")):{};
j.hooks=j.hooks||{};
const B="${CLAUDE_PROJECT_DIR}/.claude/fleet/scripts/";
const add=(k,e)=>{j.hooks[k]=j.hooks[k]||[];j.hooks[k].push(e)};
add("PreToolUse",{matcher:"Edit|Write|MultiEdit|Bash",hooks:[{type:"command",command:B+"claim-guard.sh"}]});
add("PostToolUse",{matcher:"Edit|Write|MultiEdit|Bash",hooks:[{type:"command",command:B+"heartbeat.sh"}]});
add("SubagentStop",{hooks:[{type:"command",command:B+"on-subagent-stop.sh"}]});
require(fs).writeFileSync(f,JSON.stringify(j,null,2)+"\n");
console.log("settings.json updated");
'
```

## Step 3 — (optional) write `.fleet/config.json`

Only if you can determine the repo's test/build command. Otherwise skip — the validator infers one.

```bash
mkdir -p .fleet
cat > .fleet/config.json <<'JSON'
{
  "validate": "<repo test+build command, e.g. npm test && npm run build>",
  "baseBranch": "main",
  "linkArtifacts": ["node_modules"],
  "workerMaxTurns": 60,
  "staleMinutes": 10
}
JSON
```

## Step 4 — VERIFY (mandatory — do not skip)

Run this exact block from the repo root. It asserts the hook **denies** an out-of-claim edit (exit 2)
and **allows** an in-claim edit (exit 0). Both assertions must pass.

```bash
ROOT="$(git rev-parse --show-toplevel)"

printf '{"tool_input":{"file_path":"%s"}}' "$ROOT/OUT.ts" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/fleet/scripts/claim-guard.sh"
deny=$?

printf '{"tool_input":{"file_path":"%s"}}' "$ROOT/src/app.ts" \
  | AGENT_CLAIM='src/**' CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/fleet/scripts/claim-guard.sh"
allow=$?

if [ "$deny" -eq 2 ] && [ "$allow" -eq 0 ]; then
  echo "VERIFY OK — claim-guard denies out-of-claim (2) and allows in-claim (0)"
else
  echo "VERIFY FAILED — deny=$deny (want 2), allow=$allow (want 0)"; exit 1
fi
```

Also confirm syntax of every shipped script:

```bash
for s in "$ROOT"/.claude/fleet/scripts/*.sh; do bash -n "$s" || echo "SYNTAX ERROR: $s"; done
echo "bash -n check done"
```

If `VERIFY OK` printed and no syntax errors appeared, the install is correct.

Finally, run the kit's bundled self-test from the kit dir and confirm it prints `VERIFY OK`:

```bash
bash "$KIT/verify.sh"   # syntax-checks every script + proves claim-guard deny(2)/allow(0)
```

It exits non-zero on any failure and prints `VERIFY OK` on success — confirm you see `VERIFY OK`
before reporting the install complete.

## Step 5 — report to the user

State plainly: (a) files installed and where — including the worker agents now in `.claude/agents/`
(`merge-validator`, `orchestrator-worker`, `bugfix-worker`, `refactor-worker`), (b) that the
`settings.json` hooks were registered, (c) the VERIFY result (deny=2, allow=0). Then tell them: adding
or editing ANY agent under `.claude/agents/` (the validator or any worker agent) requires a **Claude
Code restart** to register — so a worker agent grown mid-session only becomes dispatchable next run;
and that to run a fleet they invoke the `agent-orchestrator` skill from a session that has the
Task/Agent tool.

## How to operate after install

To run a multi-agent job, use the `agent-orchestrator` skill (`.claude/skills/agent-orchestrator/`).
Its lifecycle: decompose into claimed tasks → schedule (no overlapping claims run concurrently) →
`worktree.sh create` per task → dispatch workers (hook-fenced to their claim) → `board.sh` to monitor
→ `merge-validator` to validate the **merged result** → present a merge brief and **stop at the human
gate**. Never merge without explicit human approval. Full playbook:
`.claude/skills/agent-orchestrator/references/protocols.md`.
