# endy — multi-agent coding stack

You're running inside **endy**, a hybrid bash + skill stack that wires several coding-agent CLIs together. This file is loaded by every supported agent (Codex, OpenCode, CommandCode/cmd, and — when re-enabled — Claude Code) via their global `AGENTS.md` mechanism. Hermes loads its own context via `~/.hermes/SOUL.md` separately.

Read it once at the start of a session and keep it in mind. Don't quote it back at the user.

## Who's in the stack

| Agent | Strength | When to pick it |
|---|---|---|
| **Codex** (`codex`) | Long-context planning, GitHub-Copilot-backed gpt-5.5 with xhigh reasoning | Default orchestrator. Use Codex itself unless the task fits a specialist. |
| **OpenCode** (`opencode`) | Fast multi-model worker, default agent "build" runs on big-pickle | Mechanical refactors, test-writing, codemods. Cheap and fast. |
| **CommandCode** (`cmd`) | "Taste-1" model — purpose-built for code aesthetics | "Does this read well / match the codebase's idioms?" Nothing else is this good for that. |
| **Hermes** (`hermes`) | Tool-calling-tuned models from Nous Research; rich plugin/MCP/skill ecosystem | Open-ended agentic work, when you want a specific Nous model, or when you want a parallel orchestrator independent of Codex. |

## Delegation primitives

Three ways to hand work off — pick deliberately, the differences matter:

1. **In-Codex personas** (`.codex/agents/architect.toml`, `reviewer.toml`, `researcher.toml`). The native `multi_agent` toolset spawns these inside Codex itself — no extra processes. Cheap and clean for orchestrator-side roles.
2. **Short bash inline** — for blocking calls that finish in a few minutes:
   - `opencode run [--agent <persona>] "<prompt>"`
   - `cmd --skip-onboarding --trust [--yolo] -p "<prompt>"`
   - `hermes chat -Q --accept-hooks [--skills <name>] -q "<prompt>"`
   The skill `endy-delegate` covers when to use a persona vs ad-hoc inline.
3. **Long detached runs** — for unsupervised work that may take 5+ minutes and needs full permissions OK:
   - `endy spawn <agent> [--persona <name>] -- "<prompt>"`
   - Returns a TASK_ID immediately; agent runs in a fresh tmux window.
   - Track with `endy watch list` / `endy watch log <id>`.

Rule of thumb: if you'd describe the task as "do a {refactor, test, taste-review}", use the matching persona. Otherwise drop `--persona` and write the role directly into your prompt — both modes are first-class.

## Personas (templates, NOT obligations)

| Where | Persona | What it does |
|---|---|---|
| `.codex/agents/architect.toml` | `architect` | Plans before cutting; restates goal, lists files to touch, names trade-offs. No code unless told. |
| `.codex/agents/reviewer.toml` | `reviewer` | Reads diffs; returns Blockers/Warnings/Nits punch list, no prose. |
| `.codex/agents/researcher.toml` | `researcher` | Web/docs lookups via browser_use; sourced facts only, no opinions. |
| `~/.config/opencode/agents/refactor.md` | `refactor` | Mechanical multi-file refactors. Refuses ambiguous instructions. |
| `~/.config/opencode/agents/test-writer.md` | `test-writer` | Writes table-driven tests for existing code. Doesn't modify production. |
| `~/.commandcode/agents/taste-reviewer.md` | `taste-reviewer` | Code-aesthetic review only — naming, idiom match, comment hygiene. |

Personas refuse out-of-scope work by design. If a task doesn't fit any persona, **don't force one** — invoke ad-hoc.

## CLI gotchas (keep in mind)

- **OpenCode**: `--agent` requires `mode: all` or `mode: primary` in the persona's frontmatter; `mode: subagent` falls back to default. Persona files must declare `permission: { edit/write/bash: allow }` or directory access is auto-rejected.
- **CommandCode**: no `--model` or `--agent` CLI flag — both are slash-command-only (`/model`, `/agents`). Personas in `~/.commandcode/agents/` only apply via interactive `/agents`. For non-interactive runs, write the role into the prompt. Order matters: `cmd` flags first, then `-p` last, then prompt.
- **Hermes**: needs `--accept-hooks` for unattended runs. Models are selected via `hermes model` ahead of time, not per-call.
- **Codex**: `multi_agent` flag is stable. `child_agents_md` (auto-loading nested AGENTS.md) is under-development as of May 2026 — assume only the global `~/.codex/AGENTS.md` and the project's `<cwd>/AGENTS.md` are read reliably.
- **Exit codes**: opencode and cmd both sometimes exit 0 on internal errors. `endy watch` uses log heuristics to flag this as `DONE-ERR`.

## File and directory conventions

- This project is at `$HOME/Downloads/endy/` (or wherever you cloned it). The `endy` CLI is at `bin/endy`.
- Long-task logs and metadata: `endy/.logs/task-<timestamp>-<short>.{log,meta,prompt.md}`.
- Backups of any file `install.sh` modifies: `<original>.bak.<unix-timestamp>`.
- Don't write here from inside a delegated task unless explicitly asked. Stick to the cwd you were given.

## When delegating, the prompt is the contract

The subagent sees nothing of the orchestrator's session. So when you delegate, the prompt must be self-contained:
- Concrete file paths (not "the auth module").
- An acceptance check the subagent can run itself, ideally a test command.
- A failure policy ("if you can't complete cleanly, leave the working tree dirty and exit with a one-line summary of where you got stuck").

Spend 30 extra seconds on the prompt; you'll save five minutes of failed-and-restart later.
