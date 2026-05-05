# MCP shims

One file: `agent-mcp.mjs`. It's a stdio MCP server. The orchestrator (Codex) launches it three times — once per backend — with different env vars, and each instance exposes one tool:

| AGENT_NAME    | Tool registered            | What it wraps              |
|---------------|----------------------------|----------------------------|
| `opencode`    | `delegate_to_opencode`     | `opencode run …`           |
| `commandcode` | `delegate_to_commandcode`  | `cmd exec …`               |
| `claude-code` | `delegate_to_claude-code`  | `claude -p …` (commented)  |

## Install

```bash
cd mcp-shims
npm install                 # pulls @modelcontextprotocol/sdk
```

## Test a shim by hand

```bash
AGENT_NAME=opencode \
AGENT_BIN="$HOME/.opencode/bin/opencode" \
AGENT_RUN_MODE=opencode \
node agent-mcp.mjs
```

It will sit on stdio waiting for JSON-RPC. The fastest sanity check is the MCP inspector:

```bash
npx @modelcontextprotocol/inspector node agent-mcp.mjs
# (with the same env vars set)
```

## Why one file instead of three packages

Three shims would mostly be copy-paste. Diverging the argv shape (`opencode run` vs `cmd exec` vs `claude -p`) is one switch statement; the rest — process spawning, timeouts, MCP plumbing — is shared. If a backend grows a real quirk (long-lived `opencode serve --attach` for cold-start avoidance, persistent sessions, streaming) split it out then.

## Open verification points

- **CommandCode argv** is a guess until `cmd` is installed and `cmd exec --help` confirms the flag names. The shim's `commandcode` branch may need a tweak.
- **OpenCode `--agent`** flag exists per the docs (`opencode run --agent <name>`); confirm it does what we want by running `opencode run --agent refactor "rename foo to bar in src/"`.
