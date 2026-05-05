# CommandCode (cmd) personas

CommandCode's CLI is `cmd` (verified May 2026 with v0.25.1). Personas live at `~/.commandcode/agents/<name>.md` (global) or `<project>/.commandcode/agents/` (project-local). `install.sh` symlinks `agents/` here to the global location.

## Pre-flight (one time)

```bash
cmd login                  # interactive auth, writes ~/.commandcode/auth.json
cmd status                 # confirm "Authenticated as <user>"
```

The wrapper assumes auth.json exists. Without it, every spawn-long-task.sh call against `cmd` fails silently in the tmux window.

## CLI gotchas confirmed by cmd's own docs research (R3)

These are baked into spawn-long-task.sh; documented here so they're not surprises:

- **No `--model` CLI flag.** Model is set globally via `cmd model` (interactive) or the `/model` slash command. Pass `--model` to spawn-long-task.sh and it's ignored with a warning.
- **No `--agent` CLI flag.** Agent definitions in `~/.commandcode/agents/` are real but selection is interactive-only via the `/agents` slash command. For non-interactive spawns, use **ad-hoc inline prompts** (no `--persona`).
- **`cmd` is an MCP client only**, not an MCP server. You cannot expose `cmd` to other agents as a tool source. (Hermes can; OpenCode can via `opencode serve`. Cmd cannot, as of v0.25.1.)
- **Don't trust the exit code.** cmd's exit codes are undocumented and don't reliably reflect tool failures or model errors. spawn-long-task.sh's completion detection uses a log heuristic (`Error:`, `auto-rejecting`, etc.) instead.
- **Auth flow is `cmd login` (writes auth.json), not env vars.** A wrapper running under cron / a different user without that auth.json gets nothing.

## CLI argv we use

```bash
cmd --skip-onboarding --trust [--yolo] -p "<prompt>"
```

- `--skip-onboarding` skips the taste setup prompt — required for any unattended run.
- `--trust` auto-trusts the cwd, skipping the initial permission prompt.
- `--yolo` bypasses all permission prompts (added by `--full-auto` in spawn-long-task.sh).
- `-p` must be the last flag before the prompt; `cmd`'s parser is sensitive to ordering.

## What's the persona file for, then?

Even though we can't select it from the CLI, the persona file is still useful:

- When you run `cmd` interactively from your terminal, `/agents` lists every agent in `~/.commandcode/agents/` and you can pick `taste-reviewer` for the session.
- It documents what role each persona is *meant* for — useful when sending an ad-hoc prompt that happens to match. You can paste the persona's instructions into the inline prompt.
- It versions with this repo. If cmd ever adds CLI agent selection, we just upgrade.

## Why CommandCode in the stack at all

Its specialty is the **taste-1** model — purpose-built for code-aesthetics review. For "does this code read well / match the codebase's idioms" it's the strongest tool we have. For mechanical refactors and test writing, OpenCode's default agent is cheaper and equally good.
