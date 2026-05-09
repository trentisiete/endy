# endy

endy is a local control plane for coding agents. It runs Codex, OpenCode,
CommandCode (`cmd`), Hermes, and other CLI agents inside tmux, records every
task to logs, and gives you one command surface for spawning, watching,
resuming, and stopping work.

Use it when you want:

- one tmux session per project
- a global overview of every endy project
- durable task logs in `.logs/`
- simple delegation with `endy spawn ...`

## Install

Requirements:

- macOS or Linux
- `python3`
- `tmux`
- at least one agent CLI on `PATH`: `codex`, `opencode`, `cmd`, or `hermes`
- optional: `fzf` for the interactive task picker

Install the system tools first if needed:

```bash
# macOS
brew install tmux fzf

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y python3 tmux fzf
```

Then install endy:

```bash
git clone https://github.com/trentisiete/endy.git ~/Downloads/endy
cd ~/Downloads/endy
./scripts/install.sh --yes
exec "$SHELL" -l
endy doctor
```

If you already cloned the repo, just run:

```bash
cd /path/to/endy
./scripts/install.sh --yes
exec "$SHELL" -l
endy doctor
```

The installer is idempotent. It creates the needed config directories, links
`bin/endy` into `~/.local/bin/endy`, adds `~/.local/bin` to your shell rc file
when needed, installs completion, and backs up existing files before replacing
them.

You do not need every agent installed. `endy doctor` only requires `python3`,
`tmux`, and at least one supported agent CLI.

## First Run

From any project directory:

```bash
cd ~/work/my-project
endy start --clean
endy spawn <agent> -- "Say ENDY_OK and exit."
endy watch list
```

Replace `<agent>` with one installed agent, for example `codex`, `opencode`,
`cmd`, or `hermes`.

What happens:

- `endy start` creates a tmux session for the current directory, usually
  `endy-my-project`.
- The session opens `orchestrator`, `watch`, `docs`, and `tree` windows.
- Tasks spawned from this directory write logs to `.logs/per-dir/<session>/`.
- `endy watch list` shows status, agent, directory, runtime, and the latest
  useful output.

Attach later:

```bash
tmux attach -t endy-my-project
```

Stop this project session:

```bash
endy stop
```

## Session Modes

| Command | Scope | Use it for |
|---|---|---|
| `endy start` | current directory | normal work in one repo |
| `endy overview` | all endy sessions | global dashboard across projects |

Common lifecycle commands:

```bash
endy start --clean          # refresh this project's manager
endy overview --clean       # refresh the global all-session view
endy stop                   # stop this project's session
endy stop --all             # stop every endy session
```

## Daily Commands

| Goal | Command |
|---|---|
| Spawn a long task | `endy spawn opencode -- "write tests for src/foo"` |
| Ask a quick blocking question | `endy ask opencode "summarize this repo"` |
| See active tasks | `endy watch tree` |
| Browse tasks interactively | `endy watch browse` |
| See every project | `endy watch list --overview` |
| Follow one log in this terminal | `endy watch log <id>` |
| Open a follow window in tmux | `endy watch follow <id>` |
| Continue a task | `endy watch followup <id> -- "now fix the failing test"` |
| Open an interactive chat | `endy watch chat <id>` |
| Kill a stuck task | `endy watch kill <id>` |

Task ids accept unique prefixes.

## Which Agent To Use

| Agent | Best for | Example |
|---|---|---|
| `opencode` | fast implementation, refactors, tests | `endy spawn opencode -- "add parser tests"` |
| `cmd` | Kimi-backed coding and taste review | `endy spawn cmd -- "polish this API"` |
| `codex` | long-context planning and orchestration | `endy spawn codex -- "review this design"` |
| `hermes` | Nous/Hermes workflows and tool-heavy agent work | `endy spawn hermes -- "investigate this flow"` |

Install and authenticate only the agents you use. `endy doctor` shows what is
available.

## What `endy start` Creates

| Window | Purpose |
|---|---|
| `orchestrator` | your main agent shell, usually Codex |
| `watch` | interactive task browser |
| `docs` | README and NEXT_STEPS |
| `tree` | auto-refreshing task tree |

Useful tmux keys:

- `Ctrl-b w` - window picker
- `Ctrl-b n` / `Ctrl-b p` - next/previous window
- `Ctrl-b d` - detach
- `Ctrl-b &` - kill current window

## Logs And Task Files

Each task writes:

- `task-<id>.prompt.md` - prompt sent to the agent
- `task-<id>.meta` - agent, cwd, tmux window, parent task, resume id
- `task-<id>.log` - stdout/stderr plus `ENDY_EXIT=<n>`

Locations:

- per-project: `.logs/per-dir/<session>/`
- global overview: `.logs/`

These files are the source of truth for the CLI, dashboard, and followups.

## Web Dashboard

```bash
endy overview --clean
endy web
```

Open the printed URL. By default, endy binds to your Tailscale IP when
available, otherwise localhost. For shared networks, set a token:

```bash
export ENDY_WEB_TOKEN="choose-a-token"
endy web
```

Clients can pass `?token=...` or the `X-Endy-Token` header.

## Agent Setup

Minimal setup examples:

```bash
codex                 # login if prompted
opencode auth login
cmd login
hermes status
```

Important notes:

- `cmd` has no CLI `--model` flag. Set the model inside `cmd` with `/model`.
- `opencode` needs a working directory. endy passes it automatically.
- `hermes` uses `hermes chat -Q --accept-hooks` under the hood.
- Missing optional agents do not block the install.

## Command Reference

```bash
endy install
endy doctor
endy start [--clean] [--no-attach] [--serve-opencode] [--logs]
endy overview [--clean] [--no-attach]
endy stop [--all|--session <name>]
endy spawn <agent> [--supervised] [--prompt-file <file>] -- "<prompt>"
endy ask <agent> "<prompt>"
endy chat <agent>
endy watch list [--overview]
endy watch tree [--all] [--overview]
endy watch browse [--all] [--overview] [--cwd <dir>] [--orch <name>]
endy watch log <id>
endy watch follow <id>
endy watch view <id>
endy watch chat <id>
endy watch followup <id> -- "<prompt>"
endy watch kill <id>
endy watch kill-all --cwd <dir>
endy web [--localhost|--host <ip>] [--port <n>]
```

Run `endy help` for the current CLI help and `endy help <agent>` for focused
agent notes.

## Install Details

`./scripts/install.sh --yes`:

- symlinks `bin/endy` into `~/.local/bin/endy`
- adds `~/.local/bin` to your shell rc file if needed
- installs shell completion
- symlinks bundled Codex, OpenCode, and CommandCode personas
- symlinks the Codex `endy-delegate` skill
- symlinks `AGENTS.md` for Codex and CommandCode
- appends or refreshes the managed endy block in `~/.codex/config.toml`

Existing files are backed up as `*.bak.<timestamp>`.

## Project Layout

```text
bin/endy                         main CLI
scripts/start.sh                 tmux manager session bootstrap
scripts/spawn-long-task.sh       detached agent task runner
scripts/spawn-chat.sh            interactive chat runner
scripts/endy-watch.sh            task list, tree, browse, follow, kill
scripts/lib/session.sh           per-directory session naming
scripts/lib/status.sh            bash status heuristic
web/server.py                    dashboard server
codex/agents/                    Codex personas
codex/skills/endy-delegate/      Codex skill for endy delegation
opencode/agents/                 OpenCode personas
commandcode/agents/              CommandCode personas
NEXT_STEPS.md                    implementation handoff and open work
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `endy: command not found` | Run `exec "$SHELL" -l`; if needed, add `~/.local/bin` to `PATH` |
| `tmux session '<name>' not running` | Run `endy start` or `endy overview` |
| no tasks in picker | Use `endy watch browse --all` |
| task stuck in `PENDING` | Attach with `tmux attach -t <session>` and inspect the task window |
| task is `DONE-ERR` | Open `endy watch view <id>` and inspect the warning or error |
| `cmd --model` ignored | Set the model inside `cmd` with `/model` |

## Per-CLI gotchas

### opencode

- Prefer `endy spawn opencode -- "..."` for long work.
- OpenCode needs a project directory; endy passes `--dir "$(pwd)"`.
- Personas only apply when their frontmatter allows primary/all mode.
- Some OpenCode failures still exit 0. Check `endy watch list` and the log.

### cmd

- Use `endy spawn cmd -- "..."` for Kimi-backed coding work.
- There is no non-interactive `--model` flag. Set the model in an interactive
  `cmd` session with `/model`; spawned tasks inherit that setting.
- Non-interactive persona selection is not available. Put the role in the
  prompt instead.
- `-p` must be the last flag before the prompt in raw `cmd` calls.

### hermes

- endy runs Hermes with `hermes chat -Q --accept-hooks`.
- Hermes models are normally selected through Hermes configuration, not by
  passing a model to every endy command.

### claude

- Claude Code support exists in the CLI wrappers, but this stack primarily uses
  Codex, OpenCode, CommandCode, and Hermes.
- Use `endy help claude` only if your local Claude CLI is configured.

### tmux specifics

- `endy start` creates one manager session for the current directory.
- `endy overview` creates or refreshes the global `endy` session.
- Long tasks run in dedicated tmux windows and write persistent logs.
- `endy stop --all` kills every `endy*` tmux session.

## Roadmap

See `NEXT_STEPS.md` for current implementation notes and follow-up work.
