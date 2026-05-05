# Hermes (Nous Research)

`hermes` is a fourth delegation target in the endy stack alongside OpenCode, CommandCode, and (future) Claude Code. Installed as `hermes` in your terminal; project root at `~/.hermes/`.

## How it's wired

`scripts/spawn-long-task.sh --agent hermes` invokes:

```bash
hermes chat -Q --accept-hooks [--skills <name>] [--model <provider/model>] [--yolo] -q "<prompt>"
```

- **`-Q`** — quiet mode: only the final response + session info reach stdout. Crucial for programmatic capture.
- **`--accept-hooks`** — auto-approves any unseen shell hooks declared in `config.yaml`. Always on for spawned tasks since you're not at the TTY to approve them.
- **`--skills <name>`** — Hermes uses **skills** instead of personas; spawn-long-task.sh maps `--persona` → `--skills`. Hermes has a builtin skill catalogue (`hermes skills list`); you can also install your own.
- **`--yolo`** — set when you pass `--full-auto` to spawn-long-task.sh. Bypasses dangerous-command approval prompts.

## Personas / skills

Hermes already ships a rich skill ecosystem (run `hermes skills list` — categories include `autonomous-ai-agents`, `creative`, `apple`, etc.). For most endy tasks you won't need new skills — pick from what's installed.

If you do want endy-specific Hermes skills, the format is different from OpenCode's frontmatter agents:

```bash
hermes skills install <github-url-or-registry-name>
hermes skills inspect <name>
hermes skills config              # interactive enable/disable
```

We don't ship custom Hermes skills in this repo yet. Add a `hermes/skills/<name>/` dir later if a recurring Hermes task earns its keep, and document the install procedure here.

## When to pick Hermes over OpenCode

Both can do the same kinds of coding work. Bias toward Hermes when:

- The task involves heavy tool use (lots of MCP, shell, web) and you want Nous's tool-calling-tuned models.
- You want a specific provider in Hermes's catalogue: `nous`, `openrouter`, `ollama-cloud`, `huggingface`, `kimi-coding`, `minimax`, etc.
- The work is open-ended / agentic rather than narrow / mechanical.

Bias toward OpenCode when:

- The task is mechanical (multi-file rename, codemod, test stubs).
- You want the cheapest fastest possible loop.

## Native MCP support

Hermes ships its own MCP server: `hermes mcp serve`. If you ever flip the endy stack from hybrid bash to MCP, you don't need our shim — uncomment the `[mcp_servers.hermes]` block in `codex/config.snippet.toml` (it points at `hermes mcp serve` directly, no `agent-mcp.mjs` indirection) and re-run `install.sh`.
