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

OpenCode supports many providers (Anthropic, OpenAI, OpenRouter, Nous, Ollama-cloud, etc.). The default agent `build` uses model `big-pickle` which works without per-call config.

### CommandCode (`cmd`)

```bash
cmd login                    # one-time auth → ~/.commandcode/auth.json
cmd                          # opens interactive
/model Kimi K2.6             # set the global default model (slash command)
/exit
```

**Why this step matters:** `cmd` has **no `--model` CLI flag** — model is set globally via the slash command. Once set, every subsequent `cmd -p` invocation uses Kimi K2.6 (or whatever you pick). If you skip this, `cmd` falls back to its account default.

### Hermes (Nous Research)

```bash
hermes status                # if not authed, run `hermes model` to log in to a provider
hermes gateway status        # OPTIONAL — only if you want the messaging gateway later
```

The endy install does **not** modify your `~/.hermes/SOUL.md` or `~/.hermes/config.yaml`. Hermes integration with endy is purely via `hermes chat -Q -q "<prompt>"` from `endy spawn hermes`.

### Tailscale (only needed for phone access)

```bash
sudo tailscale up
sudo tailscale set --ssh     # so phone can ssh in without key management
tailscale ip -4              # note the 100.x.x.x IP — used by `endy web --tailnet`
```

---

## The `endy` CLI

```
endy install                          (re-)wire configs into ~/. (idempotent)
endy start [--clean] [--no-attach]    launch the 'endy' tmux session
                                      window 1 = watch, window 2 = docs, window 3 = tree
                                      opts: --serve-opencode, --logs
endy orchestrator [name] [opts]       open another orchestrator window
                                      opts: --cwd <dir>, --agent codex|cmd|opencode|hermes
endy tmux-help                        add/update the tmux command status line
endy stop                             kill the session
endy status                           tmux + Codex MCP + Tailscale state
endy doctor                           which agents are installed/authed

endy codex   [args]                   start a Codex session in the current dir
endy opencode [args]                  start OpenCode here
endy cmd     [args]                   start CommandCode here
endy hermes  [args]                   start Hermes here
endy <agent> --root                   run from the endy project root instead

endy ask <agent> [opts] <prompt>      short blocking call, output to stdout
endy spawn <agent> [opts] -- <prompt> long unsupervised task in a tmux window
                                      (--full-auto by default; --supervised opts out)
endy chat <agent> [opts]              interactive agent in a tmux window,
                                      captured into .logs/ as kind=chat

endy watch                            (see "endy watch family" below)
endy web [--tailnet | --localhost | --host <ip>] [--port <n>]
                                      web dashboard

endy help [<topic>]                   help text
```

### Examples

```bash
# A short ad-hoc question, output to stdout
endy ask opencode "What does the CLAUDE.md file in this dir do?"

# Long task that runs unsupervised in a tmux window. --full-auto is the default.
endy spawn cmd -- "Refactor src/auth/*.ts to use the new IdentityProvider interface. \
                   Run npm test after. If anything fails, revert and exit with a one-liner."

# Same task but with explicit max-turns budget for very deep reasoning
endy spawn hermes --max-turns 200 -- "..."

# Continue a finished task's conversation
endy watch followup 4b3c -- "Now also update the unit tests for those files."

# Start a second orchestrator for another project
endy orchestrator payments --cwd ~/work/payments
endy watch tree

# Start an interactive terminal you can type into
endy chat opencode --cwd /path/to/project
tmux attach -t endy
tmux select-window -t endy:chat-<id>

# Open Codex in the endy project root (full stack context loaded via AGENTS.md)
endy codex --root
```

### `--full-auto` and what it actually does

By default `endy spawn` adds `--full-auto`, which translates per agent to:

| Agent | Flag |
|-------|------|
| opencode | `--dangerously-skip-permissions` |
| cmd | `--yolo` (alias for `--dangerously-skip-permissions`) |
| hermes | `--yolo` |
| claude | `--dangerously-skip-permissions` |

Pass `--supervised` to `endy spawn` if you want approval prompts. Use it for context, slash-command, or read-only diagnostic tests where the agent should not get blanket filesystem approval.

### `--max-turns N` (cmd and hermes only)

Both `cmd` and `hermes` have an internal turn budget for tool-using chains. **Default in endy is 200** — high enough that you almost never hit it for legitimate work. Pass `--max-turns 500` or similar if you have an especially long agentic task. The flag is silently ignored by opencode and claude.

`cmd` does **not** document `--max-turns` in its `--help`, but the flag is real and supported (verified May 2026 v0.25.1). Without raising it, `cmd` caps at 10 turns, which silently truncates research-heavy tasks with empty output and only the warning `Reached maximum conversation turns`.

---

## The `endy watch` family

Most commands are observational. Mutating commands are `chat`, `followup`, `kill`, `kill-all`, and `purge`.

```
endy watch                            attach to 'endy' tmux session (read-write)
endy watch attach [<id>] [--strict]   attach with a task window pre-selected;
                                      --strict re-enables tmux read-only mode
                                      (blocks navigation too — rarely what you want)
endy watch list                       enriched table: id / status / parent /
                                      orchestrator / agent / persona / cwd / runtime / last
endy watch tree [--all]               active tasks grouped by orchestrator + cwd
endy watch dir <path> [--all]         tasks under one working directory
endy watch log <id>                   `less +F` on that task's log file
endy watch chat <id>                  open an interactive chat for that task's
                                      agent/cwd; opencode/hermes resume when possible
endy watch view <id>                  one-shot dump (meta + prompt + last 200 lines)
                                      paged through `less`
endy watch follow <id>                NEW tmux window with prompt header + live tail
                                      Multiple calls → multiple windows. Watching task
                                      A is not interrupted when you also follow B.
endy watch browse                     fzf picker for active tasks/chats with live preview.
                                      opts: --all, --cwd <dir>, --orch <name>.
                                      Enter chat/switch, ^O open chat and stay,
                                      ^F follow, ^V view, ^L log,
                                      ^Y copy id to clipboard, ^K kill.
endy watch panel [--all]              tile view of running tasks (warns if >4)
endy watch followup <id> [-- <prompt>]
                                      Resume the conversation of an existing task.
                                      hermes/opencode → native session resume.
                                      cmd → context injection (no headless resume).
                                      Always spawns a NEW task with parent_task=<id>.
endy watch kill <id>                  kill a stuck task (closes tmux window AND
                                      writes ENDY_EXIT=130 so it stops showing as RUNNING)
endy watch kill-all --agent <name>    close all task/chat/follow windows for an agent
endy watch kill-all --cwd <dir>       close all task/chat/follow windows under a dir
endy watch kill-all --orch <name>     close all task/chat/follow windows for an orchestrator
endy watch purge <id> [--dry-run]     delete a task and all descendants from .logs/
                                      and kill their tmux windows. double confirmation
                                      required (type '&', then the full task id).
                                      aliases: delete, purge-session.
```

`<id>` everywhere accepts a unique prefix — `endy watch log 4b3c` is enough if no other task starts with `4b3c`.

### Status values explained

| Status | Meaning |
|--------|---------|
| `RUN` | task running; tmux window present, no `ENDY_EXIT=` marker yet |
| `CHAT` | interactive `endy chat` window is open/captured; it does not exit until you close it |
| `PENDING` | meta written but log file not started yet (small race window) |
| `DONE` | `ENDY_EXIT=0`; no error patterns in the log |
| `DONE-ERR` | `ENDY_EXIT=0` but the log contains `Error:` / `Exception:` / `Reached maximum turns` / `auto-rejecting` etc. — agent reported a problem despite exit 0 |
| `FAIL(<n>)` | non-zero `ENDY_EXIT=` |
| `ABANDONED` | no `ENDY_EXIT=` AND the tmux window is gone or its pane is dead (task died silently) |

### Tmux commands you'll actually use

```bash
tmux attach -t endy             # attach (read-write)
tmux attach -t endy -r          # attach read-only (BLOCKS NAVIGATION too — rarely useful)
Ctrl-b N                         # next window
Ctrl-b P                         # previous window
Ctrl-b 0..9                      # jump to window by number
Ctrl-b w                         # interactive window picker with preview
Ctrl-b ,                         # rename current window
Ctrl-b d                         # detach (session keeps running)
Ctrl-b x                         # kill current pane
Ctrl-b &                         # kill current window
tmux list-windows -t endy        # see all windows
tmux kill-window -t endy:<name>  # kill one window
tmux kill-session -t endy        # nuke everything (`endy stop` does this)
```

`endy start` and `endy tmux-help` also put the most-used tmux commands in the tmux status line and create a live `tree` window you can reopen with `tmux select-window -t endy:tree`.

`endy start --clean` closes old `task-*`, `chat-*`, `follow-*`, `panel`, `watch`, `docs`, `tree`, `help`, `opencode`, and `logs` windows, then recreates the manager layout:

```bash
tmux select-window -t endy:watch      # task browser
tmux select-window -t endy:docs       # README.md + NEXT_STEPS.md
tmux select-window -t endy:tree       # live tree grouped by orchestrator + directory
tmux kill-session -t endy             # stop the whole endy session
```

`opencode serve` is not part of the default manager layout anymore. Start it only when you explicitly want that local server:

```bash
endy start --serve-opencode --logs
```

### Following multiple tasks at once

```bash
endy watch follow 4b3c            # opens window 'follow-4b3c'
endy watch follow a104            # opens window 'follow-a104'
tmux attach -t endy               # attach
Ctrl-b w                          # picker → see follow-4b3c and follow-a104 side by side
```

Each `follow` window stays alive (`remain-on-exit on`) so even after the underlying task ends, you can scroll back through it.

### Taking Over A Task

```bash
endy watch browse                 # pick a task visually
Enter                             # open interactive chat and switch to it
Ctrl-o                            # open chat but stay in browse
Ctrl-f                            # open a live log follow window instead
```

Or directly:

```bash
endy watch chat 4b3c
```

For `opencode` and `hermes`, endy tries to resume the task's native session before opening the interactive terminal. For `cmd`, headless `cmd -p` runs do not persist a native interactive session, so endy opens CommandCode in the same working directory with the parent prompt and log tail injected as the initial message.

### Manager Workflows

Open one orchestrator per project or workstream:

```bash
endy start
endy orchestrator payments --cwd ~/work/payments
endy orchestrator mobile --agent cmd --cwd ~/work/mobile
```

Each subagent spawned from those orchestrator windows records `orchestrator`, `orchestrator_agent`, `origin_window`, `origin_pane`, and `origin_cwd` in its meta file. In the UI this appears as `ORCH`, for example `mobile[cmd]` or `orchestrator[codex]`. Then use:

```bash
endy watch tree                         # grouped by orchestrator, then directory
endy watch dir ~/work/payments --all     # one project directory
endy watch list --orch payments          # one orchestrator
endy watch browse --cwd ~/work/payments  # visual picker for that project
endy watch chat <id>                     # open a typed chat for follow-up
endy watch kill-all --cwd ~/work/payments # close all task windows for that project
```

Older tasks that predate these fields show as `manual` or use the tmux window name if endy can infer it.

For a manual spawn outside an orchestrator window, label both pieces explicitly:

```bash
endy spawn cmd --orchestrator ux-review --orchestrator-agent codex -- "<prompt>"
```

What the manager can do today:

| Task | Command |
|------|---------|
| See every active subagent by orchestrator and directory | `endy watch tree` |
| Include finished/failed history | `endy watch tree --all` |
| Focus one repo | `endy watch dir ~/work/payments --all` |
| Focus one orchestrator | `endy watch list --orch mobile` |
| Open a chat for follow-up | `endy watch chat <id>` |
| Open chat without leaving browse | `Ctrl-o` inside `endy watch browse` |
| Follow logs without interrupting | `endy watch follow <id>` |
| Stop one stuck task | `endy watch kill <id>` |
| Stop all work for a repo | `endy watch kill-all --cwd ~/work/payments` |
| Stop all work for an orchestrator | `endy watch kill-all --orch mobile` |
| Purge a task and its descendants | `endy watch purge <id>` |
| Stop endy completely | `tmux kill-session -t endy` or `endy stop` |

---

## The web dashboard

```bash
endy web                          # default: binds to your Tailnet IP, port 9120
endy web --localhost              # local-only
endy web --host 0.0.0.0           # ⚠ public bind — only with explicit auth in front
```

A single Python file ([web/server.py](web/server.py)) using stdlib only — no `pip install` required. Reads from the same `.logs/` as the CLI; spawns via the same `spawn-long-task.sh`.

Endpoints:

| Method | Path | What |
|--------|------|------|
| GET | `/` | Dashboard HTML ([web/index.html](web/index.html)) |
| GET | `/api/tasks` | JSON list (status, agent, persona, cwd, runtime, last) |
| GET | `/api/tasks/<id>` | JSON detail (meta + last 200 log lines + prompt) |
| GET | `/api/tasks/<id>/stream` | SSE: each new log line as `data: {"line":"…"}` |
| GET | `/api/events` | SSE: full task list re-emitted on any change |
| POST | `/api/tasks` | `{agent, persona?, cwd?, prompt, full_auto?}` → spawns |
| POST | `/api/tasks/<id>/followup` | `{prompt}` → `endy watch followup <id>` |
| DELETE | `/api/tasks/<id>` | Equivalent to `endy watch kill` |

From your phone (over Tailscale): open `http://<mac-tailnet-ip>:9120/`. Mobile-first dashboard — task cards, "+ Spawn" sheet with agent picker, parent-task markers, a Follow up button, tmux command snippets, and live log streaming. Tailscale is the auth layer; the server never binds to a public address by default.

To keep the dashboard alive across SSH sessions, run it inside the endy tmux session:

```bash
ssh $USER@<your-mac-host>
endy start                                             # if not running
tmux send-keys -t endy:placeholder 'endy web' C-m      # or just open the window manually
```

---

## How agents themselves use endy

Once installed, `~/.codex/AGENTS.md` and `~/.commandcode/AGENTS.md` are symlinks to this repo's `AGENTS.md`, which describes the stack. Codex reads it on every session; `cmd` reads it via its `/init`-style mechanism.

For an agent (Codex, OpenCode, `cmd`, or Hermes) to spawn a subagent, it just calls `endy spawn` from its own bash tool:

```bash
# What Codex would run via its bash tool to delegate a refactor:
endy spawn opencode --persona refactor -- \
  "Rename frobnicate→banalize in src/lib/, run tests, exit non-zero on failure."

# What CommandCode would run to ask a research question:
endy spawn opencode -- "Research the difference between Map and WeakMap in V8 and summarise."
```

The spawned task lands in the same `.logs/` directory and is visible to `endy watch list`, the web dashboard, and any other agent introspecting state. **Hermes is special**: it has its own builtin `codex`/`opencode`/`claude-code` skills for delegation, so when Hermes delegates via *those*, the result does not appear in `.logs/`. To get hermes into the monitoring loop, have it call `endy spawn` via its shell tool instead.

The Codex-side skill `endy-delegate` (in `codex/skills/endy-delegate/SKILL.md`) gives Codex a decision rule for when to delegate vs. handle a task itself.

---

## File layout and conventions

```
endy/
├── bin/endy                      single CLI entry point (→ ~/.local/bin/endy)
├── AGENTS.md                     stack context (→ ~/.codex/AGENTS.md, ~/.commandcode/AGENTS.md)
├── README.md                     this file
├── NEXT_STEPS.md                 implementation roadmap for the next agent
├── codex/
│   ├── config.snippet.toml       appended to ~/.codex/config.toml
│   ├── agents/                   → ~/.codex/agents/  (architect / reviewer / researcher TOMLs)
│   └── skills/endy-delegate/     → ~/.codex/skills/endy-delegate/
├── opencode/
│   └── agents/                   → ~/.config/opencode/agents/  (mode: all + permission grants)
├── commandcode/
│   ├── README.md                 cmd-specific notes (auth, slash commands, gotchas)
│   └── agents/                   → ~/.commandcode/agents/  (interactive-only — no CLI flag)
├── hermes/                       integration notes (no auto-symlink — preserves user's SOUL.md)
├── mcp-shims/
│   ├── agent-mcp.mjs             generic stdio MCP shim, parameterised by env
│   └── package.json
├── scripts/
│   ├── install.sh                symlink everything into ~/. (idempotent, asks once)
│   ├── start.sh                  tmux session launcher
│   ├── status.sh
│   ├── spawn-long-task.sh        the spawn primitive (write meta, open tmux, tee log)
│   ├── spawn-chat.sh             interactive tmux chat primitive (pipe-pane capture)
│   ├── check-long-task.sh        --list and per-id status query (machine-parseable)
│   ├── endy-watch.sh             user-facing watch dispatcher
│   └── _endy-preview.sh          fzf preview pane renderer for `endy watch browse`
├── web/
│   ├── server.py                 stdlib HTTP server with SSE
│   └── index.html                vanilla JS dashboard
├── mobile/                       phase 1 docs (Tailscale + Blink)
└── .logs/                        per-task .log + .meta + .prompt.md (gitignored)
```

### `.logs/task-<id>.{log,meta,prompt.md}` contract

Every spawned task writes three files in `.logs/`:

- `task-<id>.prompt.md` — the prompt verbatim, persisted at spawn time. Survives the run.
- `task-<id>.meta` — `key=value` lines including `task_id`, `kind`, `orchestrator`, `origin_session`, `origin_window`, `origin_pane`, `origin_cwd`, `agent`, `persona`, `model`, `cwd`, `window`, `log`, `prompt`, `spawned_at` (ISO 8601 UTC), and (for followups/chats) `parent_task` and `resume_id`. Append-only after spawn — `endy watch followup`, `endy watch tree`, and the web dashboard use these.
- `task-<id>.log` — `tee`'d stdout+stderr of the underlying agent CLI invocation. Always ends with a line `ENDY_EXIT=<n>` once the agent exits — that's how `check-long-task.sh` distinguishes RUNNING from DONE.

Interactive `endy chat` sessions use the same `task-<id>.meta` and `task-<id>.prompt.md` convention, but set `kind=chat` and write pane capture to `chat-<id>.log`.

Anything that reads `.logs/` and respects this contract is a valid endy front-end. The web dashboard, `endy watch list`, and the CLI all use the same files.

---

## Per-CLI gotchas

These are the integration quirks we found the hard way. They're all worked around in `spawn-long-task.sh`, but if you change wrapper code, **read these first**:

### opencode

- **Headless `opencode run` needs `--dir <cwd>`.** Opening the tmux window with `-c <cwd>` is not enough for all opencode tools; without `--dir`, glob/search can drift into the user's home directory and hit `~/Library` permission/interruption errors. `endy spawn opencode` and `endy ask opencode` pass `--dir` automatically.
- **`--agent <name>` requires `mode: primary` or `mode: all`** in the persona's frontmatter. `mode: subagent` causes opencode to fall back to the default agent silently (with a warning to stderr). All endy-shipped opencode personas use `mode: all`.
- **Persona files must declare `permission:` grants** in the frontmatter, e.g. `permission: { edit: allow, write: allow, bash: allow, webfetch: ask }`. Without these, opencode auto-rejects `external_directory` access and the task fails with `Error: The user rejected permission to use this specific tool call.`.
- **Default format does not emit `session_id` to stdout.** It's stored in SQLite at `~/.local/share/opencode/opencode.db` (table `session`, keyed by `directory`). `endy watch followup` queries this DB to harvest the latest session for the parent task's cwd.
- **Exit code is unreliable** — opencode sometimes exits 0 when it has logged a `ProviderModelNotFoundError` or hit auth issues. The DONE-ERR heuristic catches this.

### cmd (CommandCode v0.25.1)

- **No `--model` CLI flag.** Model is set globally via `cmd model` (interactive) or `/model` (slash). `endy spawn cmd --model X` is silently ignored with a warning.
- **No `--agent` CLI flag.** Personas in `~/.commandcode/agents/` only apply via interactive `/agents` selection. `endy spawn cmd --persona X` is similarly silently ignored.
- **`cmd -p` cannot resume a session.** `-c/--continue` and `-r/--resume` are interactive-only by design (per the docs: *"Each invocation is a standalone session with no conversation history."*). For followup, endy injects parent context into the new prompt instead.
- **Order matters in argv.** `-p` must come last, immediately before the prompt. `cmd -p --skip-onboarding ...` parses `--skip-onboarding` as the prompt value and hangs. Always `cmd --skip-onboarding --trust [--max-turns N] [--yolo] -p "<prompt>"`.
- **`--max-turns` is undocumented but real**, default 10. Endy passes `--max-turns 200` by default. Without raising it, complex tool-using research finishes with `Warning: Reached maximum conversation turns` and zero useful output.
- **Exit code is unreliable** in the same way as opencode.
- **Auth required first.** `cmd login` writes `~/.commandcode/auth.json`. Without it, every `cmd -p` invocation hangs in the tmux window with no output.

### hermes (Nous Research)

- **`-Q` is mandatory for programmatic use.** Without it, you get banner + spinner + tool previews on stdout. With `-Q`, only the final response and a `session_id: <YYYYMMDD_HHMMSS_<6char-hex>>` line.
- **`--accept-hooks` is required** for unattended runs. Without it, hermes prompts for approval of any unseen shell hooks declared in `config.yaml` and waits forever in non-TTY contexts.
- **Native session resume works.** `hermes chat -Q --accept-hooks --resume <session_id> -q "new prompt"` continues the prior conversation. `endy watch followup` greps `^session_id: ...$` from the parent's log and uses this.
- **Has its own MCP server** (`hermes mcp serve`) — if you ever flip endy to MCP mode, hermes plugs in directly without needing the agent-mcp.mjs shim.
- **Has its own delegation skills** (`claude-code`, `codex`, `opencode` builtin) — if hermes delegates via those, the spawned subagent does NOT appear in endy's `.logs/`. To get hermes-spawned subagents into the monitoring loop, hermes must call `endy spawn` via its shell tool.

### claude (Anthropic Claude Code)

Currently **not in the active stack** — slot reserved. The `claude` agent type in `spawn-long-task.sh` is wired but un-tested. Re-add when re-subscribed; gotchas TBD.

### tmux specifics for spawn-long-task.sh

- **Long prompts are passed via `"$(cat <prompt-file>)"` substitution at runtime**, not via `tmux send-keys`. Earlier versions used send-keys for the full prompt and hung on prompts >2KB because tmux types the whole thing character-by-character into a shell buffer. The current pipeline expands `$(cat …)` inside the new tmux window's shell, so ARG_MAX (~256KB on macOS) is the only limit.
- **Each window has `set-window-option remain-on-exit on`.** When the agent exits, the pane shows `Pane is dead (status N, …)` instead of closing. You can scroll back through the final state.
- **Default-shell respected.** tmux invokes the user's `$SHELL` (typically zsh on macOS) for each new window's command. The `printf '%q'` quoting in `spawn-long-task.sh` is bash-style but compatible with zsh.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `endy: command not found` | Run `exec "$SHELL" -l`; if needed, add `~/.local/bin` to `PATH` |
| `tmux session '<name>' not running` | Run `endy start` or `endy overview` |
| no tasks in picker | Use `endy watch browse --all` |
| task stuck in `PENDING` | Attach with `tmux attach -t <session>` and inspect the task window |
| task is `DONE-ERR` | Open `endy watch view <id>` and inspect the warning or error |
| `cmd --model` ignored | Set the model inside `cmd` with `/model` |

## Roadmap

See `NEXT_STEPS.md` for current implementation notes and follow-up work.
