# Codex agent personas

Each `*.toml` here is a Codex subagent definition. After `install.sh` symlinks this directory to `~/.codex/agents/`, Codex picks them up automatically and the orchestrator can spawn them via the `multi_agent` toolset (`spawn_agent`, `send_input`, `wait_agent`, `close_agent`).

## Adding a new persona

1. Drop a `<name>.toml` here following the same shape as `architect.toml`.
2. No restart needed — Codex re-reads on next invocation.
3. To call it: in the main Codex session, ask "spawn the <name> subagent on …".

## Field reference

| Field | What it does |
|---|---|
| `name` | Identifier used by `spawn_agent`. |
| `description` | One-liner shown to the orchestrator's planner so it knows when to pick this agent. **Write this carefully — it drives routing.** |
| `model` | Override the default model for this persona. Leave at `gpt-5.5` unless you have a reason. |
| `reasoning_effort` | `low` / `medium` / `high` / `xhigh`. Cheaper personas (reviewer nits) → `medium`; planning → `xhigh`. |
| `developer_instructions` | The system prompt. Be terse and concrete; describe behaviour, not personality. |

## Routing tips

- The orchestrator decides when to spawn which subagent based on the `description` field. If you find it picking the wrong one, sharpen the descriptions to be more *specific* about when each applies.
- Personas should compose, not duplicate. If two personas cover the same ground, merge them.
