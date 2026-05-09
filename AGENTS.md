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

## Endy operational primitives

A few endy commands worth knowing — they save time when debugging or onboarding:

- `endy doctor` — checks tmux + every agent CLI + `AGENTS.md` symlinks + the cmd model setting (`~/.commandcode/config.json`). A blank cmd model is a common cause of silent spawn hangs. Also lists every running `endy*` tmux session so you can see the per-dir landscape.
- `endy help <agent>` — prints the per-CLI gotcha section straight out of `README.md`. Agents: `opencode`, `cmd`, `hermes`, `claude`, `tmux`. Use this before guessing why a flag is being ignored.
- `endy start` (per-directory by default) — spins up a tmux session named `endy-<basename>` (with a 4-hex-char hash suffix on collision/reserved names) scoped to `$cwd`. Logs land in `.logs/per-dir/<session>/`. Tasks spawned from this cwd, or with their meta `cwd` under it, show up in this session's watch picker only.
- `endy overview` — the GLOBAL aggregator, equivalent to the original single-session behavior. Forces `ENDY_SESSION=endy` and `LOG_DIR=$ENDY_ROOT/.logs`. Watch/list/tree/browse here all support `--overview` to scan every per-dir session in addition to the global one.
- `endy stop [--all|--session <name>]` — `--all` kills every `endy*` tmux session; `--session` targets a specific one; bare `endy stop` kills the per-dir session for the current cwd.
- Per-dir overrides for any subcommand: set `ENDY_SESSION` and `ENDY_LOG_DIR` in env, or pass `--session <name> --log-dir <path>` to `spawn-long-task.sh` / `spawn-chat.sh`. The web dashboard auto-discovers every per-dir scope on startup.
- Shell completion — `scripts/endy-completion.sh` covers subcommands, agents, watch ops, and help topics in both bash and zsh. `endy install` wires it in via a marked block in your rc file; pass `--yes` for non-interactive installs (CI/quickstart).
- Web dashboard — `endy web` defaults to a Tailnet-only bind (no public exposure). For shared Tailnets, set `ENDY_WEB_TOKEN=<value>` before launch; clients must then send `X-Endy-Token: <value>` or `?token=<value>`. Persona dropdowns auto-populate from `opencode/agents/`, `commandcode/agents/`, and `codex/agents/` in this repo.
- Status heuristic — `scripts/lib/status.sh` is the single bash source of truth for `RUN/PENDING/DONE/DONE-ERR/FAIL/ABANDONED/CHAT`. `endy-watch.sh` and `_endy-preview.sh` both source it; web/server.py and check-long-task.sh keep parallel copies — patch them all when you add a new error pattern.

## File and directory conventions

- This project is at `$HOME/Downloads/endy/` (or wherever you cloned it). The `endy` CLI is at `bin/endy`.
- Long-task logs and metadata:
  - per-dir mode: `endy/.logs/per-dir/<session>/task-<timestamp>-<short>.{log,meta,prompt.md}`
  - overview/global mode: `endy/.logs/task-<timestamp>-<short>.{log,meta,prompt.md}`
- Each per-dir log dir holds a `.cwd` marker file recording which absolute path owns the session — used to detect collisions on second `endy start` from another cwd whose basename matches.
- Backups of any file `install.sh` modifies: `<original>.bak.<unix-timestamp>`.
- Don't write here from inside a delegated task unless explicitly asked. Stick to the cwd you were given.

## When delegating, the prompt is the contract

The subagent sees nothing of the orchestrator's session. So when you delegate, the prompt must be self-contained:
- Concrete file paths (not "the auth module").
- An acceptance check the subagent can run itself, ideally a test command.
- A failure policy ("if you can't complete cleanly, leave the working tree dirty and exit with a one-line summary of where you got stuck").

Spend 30 extra seconds on the prompt; you'll save five minutes of failed-and-restart later.

## Working methodology — the four-step loop

When the user gives you a non-trivial task in this stack, default to this loop. Each step has a different agent or mode; don't collapse them.

### 1. Investigate (opencode)

For diagnosis, audit, code-reading, comparison, or "why does X happen" questions, dispatch **opencode** with `endy spawn opencode --full-auto -- "<self-contained prompt>"`. Give it a concrete output contract: a markdown file at `.logs/diag-<topic>.md` with sections it must fill (gap confirmation, root cause, patch surface, pitfalls, output budget). Opencode is good at multi-file reading and producing tight, sourced reports.

Don't combine investigation and implementation in one delegation — the report becomes the input contract for step 3.

### 2. Synthesize (in the orchestrator)

Read the diag file. Cross-check claims against the actual files (a diag that says "line 944" can be off by ±20). Decide which recommendations to apply, drop, or modify. Write a consolidated patch list as a single prompt. Resist the temptation to skip this step: agents will faithfully implement bad ideas if you don't filter them.

### 3. Implement (cmd with Kimi K2.6)

For code changes — edits, new functions, refactors — dispatch **cmd** with `endy spawn cmd --full-auto --max-turns 9999 -- "<patch list prompt>"`. The patch list should be unambiguous: file paths, line numbers, exact strings, and a clear hand-off file (`.logs/applied-<topic>.md`) listing what changed and any deviations. `--max-turns 9999` is the user's standing preference — let cmd iterate as needed.

Treat cmd as a typing-heavy executor, not a designer. If cmd starts redesigning, the prompt was too loose.

### 4. Verify empirically

Never declare a task done from `bash -n` alone. Verification means **running the changed code on real inputs and observing the result**:
- Diff the modified files against a snapshot you took before dispatching cmd.
- Spot-check each landing zone (grep for the new symbol, read ±5 lines around the patch).
- Run the actual flow end-to-end on a real fixture (a real task ID, a real cwd, etc.).
- For TUI changes, drive the TUI: `tmux send-keys` to issue the action, `tmux capture-pane -p` to read what the user would see. Don't trust the agent's hand-off file as proof — only the live screen counts.
- For CLI changes, exercise the new flag against a real call.

If the live test shows wrong behaviour, fix it directly (or send a tight follow-up to cmd). The loop ends when the on-screen result matches the intent — not when the diff looks right.

### When to deviate

- Skip step 1 when the diagnosis is trivial and you already have all the context (a typo fix, a one-line rename).
- Skip step 3 (do it yourself) when the change is ≤ ~15 lines AND you have the full mental model already; the round-trip overhead exceeds the typing.
- Never skip step 4. A passing `bash -n` and a confident hand-off file are not verification.

The skill `endy-delegate` (in `codex/skills/endy-delegate/SKILL.md`) has the operational details: capture-pane semantics, send-keys gotchas (use arrow keys not text-search in TUI pickers), the cmd-headless-doesn't-persist constraint, and tmux RAM hygiene primitives (`endy watch gc`, `endy watch kill-all --done`).
