# OpenCode agent personas

Markdown files with YAML frontmatter. After `install.sh` symlinks this dir to `~/.config/opencode/agents/`, OpenCode picks them up. The orchestrator (Codex) reaches them via the MCP shim → `opencode run --agent <name> "<prompt>"`.

## Adding a new persona

Drop `<name>.md` here. Frontmatter fields:

| Field | What it does |
|---|---|
| `description` | Routing hint for the orchestrator. Write what it's *good at* and what it's *not for*. |
| `mode` | `primary` (interactive), `subagent` (only callable via @-mention from another agent), `all` (both). **For endy: use `all`.** OpenCode refuses to invoke a `subagent`-only persona directly via `opencode run --agent <name>` — it falls back to the default. `all` lets the persona work both as a CLI primary (which is how spawn-long-task.sh and short bash calls reach it) and as a summonable subagent later. |
| `model` | `<provider>/<model>`. Mix freely — e.g. Haiku for grunt work, Sonnet for thinking. |
| `tools` | Map of tool → bool. Default to enabling read/grep/glob; only enable write/edit/bash on agents that need to mutate state. |

The body of the file is the system prompt — same shape as Claude Code subagents.

## Why these two to start

- **refactor** uses a fast/cheap model (Haiku) because the work is mechanical.
- **test-writer** uses Sonnet because contract inference benefits from reasoning.

Add `migrator.md`, `docs-writer.md`, etc. as you find patterns you repeat.
