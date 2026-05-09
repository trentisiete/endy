# endy

A multi-agent control plane for coding CLIs. Run **Codex**, **OpenCode**, **CommandCode** (`cmd`), and **Hermes** (Nous Research) from one terminal command, with per-directory tmux sessions for focused work and a global overview session when you want to watch everything at once.

```
                         ┌────────── you ──────────┐
                         │   endy <subcommand>      │   ← terminal CLI
                         │   endy web              │   ← phone-friendly web UI
                         │   ssh + tmux attach     │   ← raw tmux when you want it
                         └───────────┬─────────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │   endy backend (single host)    │
                    │                                 │
                    │   .logs/ + .logs/per-dir/      │
                    │   spawn-long-task.sh ← spawner │
                    │   tmux endy-<cwd> sessions     │
                    │   tmux 'endy' overview         │
                    │                                 │
                    └─────┬────┬───┬──────┬───────────┘
                          │    │   │      │
                       codex  opencode cmd hermes
                          │    │   │      │
                       (agents can also call `endy spawn …` themselves —
                        AGENTS.md is symlinked into each agent's home dir)
```

---

## Table of contents

1. [What endy is and isn't](#what-endy-is-and-isnt)
2. [Prerequisites](#prerequisites)
3. [Install](#install)
4. [Configure](#configure)
5. [The `endy` CLI — every subcommand](#the-endy-cli)
6. [The `endy watch` family — monitoring and follow-up](#the-endy-watch-family)
7. [The web dashboard](#the-web-dashboard)
8. [How agents themselves use endy](#how-agents-themselves-use-endy)
9. [File layout and conventions](#file-layout-and-conventions)
10. [Per-CLI gotchas (read these before debugging)](#per-cli-gotchas)
11. [Troubleshooting](#troubleshooting)
12. [Roadmap and open work](#roadmap-and-open-work) — see [NEXT_STEPS.md](NEXT_STEPS.md) for the full handoff to the next implementing agent.

---

## One-shot install

Already have at least one of `codex` / `opencode` / `cmd` / `hermes` installed and on `PATH`? Then:

```bash
git clone https://github.com/trentisiete/endy.git ~/Downloads/endy
cd ~/Downloads/endy
./scripts/install.sh --yes        # symlinks agents/skills/AGENTS.md, puts endy on PATH,
                                  # wires shell completion into ~/.zshrc or ~/.bashrc
exec "$SHELL" -l                  # reload so completion + PATH take effect
endy doctor                       # confirm everything is wired up
endy start --clean                # create this cwd's per-dir manager session
endy overview --clean             # optional: global all-session dashboard
endy spawn opencode -- "say hi"   # smoke-test the spawn pipeline
endy watch list                   # see your task land
```

If `endy` is not found after install, `~/.local/bin` is not on your `PATH` — the install warning tells you the line to add. See [Install](#install) below for the long-form, opt-in walk-through.

---

## What endy is and isn't

**Is:**
- A thin orchestration layer over four coding-agent CLIs.
- A persistent monitor for long-running tasks: every spawn opens its own tmux window AND writes a tee'd log file, so you can detach, attach from another machine, follow a task on your phone, kill it, or resume its conversation later.
- A delegation primitive that any of the four agents can invoke from their own bash tool: `endy spawn <agent> -- "<prompt>"`. The result is auditable in `.logs/` and the live tmux window.
- Hybrid bash by default; an MCP shim path is present but commented out (see `codex/config.snippet.toml`). Hermes ships its own MCP server (`hermes mcp serve`) — flip on directly if you want.

**Is not:**
- A replacement CLI for the agents. You still run `codex`, `opencode`, `cmd`, `hermes` directly when you want.
- A SaaS. Everything runs on your own machine. Phone access is via Tailscale, never public internet.
- A model router. Each CLI keeps its own provider/model selection.

---

## Quick start for managers

```bash
endy start --clean                 # create/refresh this cwd's manager session
endy overview --clean              # create/refresh the global all-session view
tmux attach -t endy-<basename>     # enter the per-dir session later
tmux select-window -t endy-<basename>:tree
tmux select-window -t endy-<basename>:watch
```

`endy start` scopes to the directory you ran it from. The session name is `endy-<sanitized-basename>` and gains a 4-hex suffix only when needed to avoid collisions. Logs for that session live under `.logs/per-dir/<session>/`. `endy overview` is the legacy-style global session named `endy`; its watch/list/tree/browse commands aggregate global logs plus every per-dir log directory.

The default session layout is:

| Window | Purpose |
|--------|---------|
| `0 orchestrator` | Main Codex orchestrator, with `ENDY_ORCHESTRATOR=orchestrator` and `ENDY_ORCHESTRATOR_AGENT=codex` exported. |
| `1 watch` | `endy watch browse`, the interactive picker for active tasks/chats. |
| `2 docs` | README + NEXT_STEPS opened in `less`. |
| `3 tree` | Auto-refreshing `endy watch tree` grouped by orchestrator, then directory. |

Daily loop:

```bash
endy watch tree                         # what is active, grouped by owner + directory
endy watch browse                       # pick a task visually
endy watch browse --cwd ~/work/payments # focus one repo
endy watch browse --orch mobile         # focus one orchestrator/workstream
endy watch chat <id>                    # open a typed follow-up terminal
endy watch follow <id>                  # watch logs without disturbing the agent
endy watch kill-all --cwd ~/work/foo    # close all task/chat/follow windows for a repo
```

In `browse`, press `Enter` to open chat and switch to it, `Ctrl-o` to open chat in the background while staying in browse, and `Ctrl-f` to open a live log-follow window.

---

## Prerequisites

| Tool | Why | Install |
|------|-----|---------|
| `tmux` ≥ 3.0 | Session/window/log persistence | `brew install tmux` |
| `bash` ≥ 3.2 | All scripts portable to the macOS-default bash | already on macOS |
| `python3` ≥ 3.10 | Web dashboard (`endy web`) | already on macOS |
| `fzf` ≥ 0.50 | `endy watch browse` interactive picker | `brew install fzf` |
| `pbcopy` (macOS) / `wl-copy` / `xclip` | `^Y` clipboard binding in `browse` | macOS has it built-in |
| `sqlite3` | `endy watch followup` opencode-session harvest | already on macOS |
| `tailscale` | Remote access from phone | `brew install tailscale` |
| At least one of: `codex`, `opencode`, `cmd`, `hermes` | The actual coding work | see each project's docs |

`endy doctor` checks all of the above and tells you what's missing.

---

## Install

```bash
git clone <this-repo> ~/Downloads/endy
cd ~/Downloads/endy
./scripts/install.sh
```

`install.sh` is **idempotent** — re-runnable without harm. It:

1. **Symlinks Codex agent personas** in `codex/agents/*.toml` → `~/.codex/agents/`.
2. **Symlinks the Codex skill** `codex/skills/endy-delegate/` → `~/.codex/skills/endy-delegate/` so Codex auto-loads delegation guidance.
3. **Symlinks OpenCode agent personas** `opencode/agents/*.md` → `~/.config/opencode/agents/`.
4. **Symlinks CommandCode agents** `commandcode/agents/*.md` → `~/.commandcode/agents/`.
5. **Symlinks `AGENTS.md`** to `~/.codex/AGENTS.md` and `~/.commandcode/AGENTS.md` so Codex and `cmd` auto-load endy stack context on every session.
6. **Symlinks `bin/endy`** to `~/.local/bin/endy`. If `~/.local/bin` is not on your `PATH`, you get a warning telling you what to add to `~/.zshrc`/`~/.bashrc`.
7. **Hooks shell completion** by appending a `source` line for `scripts/endy-completion.sh` into `~/.zshrc` (with `bashcompinit`) or `~/.bashrc`, gated by an idempotent marker block.
8. **Appends an `[mcp_servers.*]` block** (currently commented out — bash mode is active) to `~/.codex/config.toml` between markers so the change is reversible.

Pass `--yes` (or `-y`) to skip the interactive confirmation — handy for CI and quickstart pipes.

Existing files at the target paths are renamed `*.bak.<unix-timestamp>` rather than overwritten.

After install:

```bash
endy doctor                  # confirm tmux + each agent CLI + AGENTS.md + tmux session
```

---

## Configure

Each agent CLI needs its own one-time setup before endy can drive it.

### Codex (OpenAI)

```bash
codex                        # first run prompts for login if needed
```

Codex reads `~/.codex/config.toml` — your existing file plus the appended endy block. Default model `gpt-5.5` with `xhigh` reasoning is fine; change in the file if you prefer.

### OpenCode

```bash
opencode auth login          # interactive auth flow with whichever provider you use
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
endy start [--clean] [--no-attach]    launch this cwd's per-dir tmux session
                                      window 1 = watch, window 2 = docs, window 3 = tree
                                      opts: --serve-opencode, --logs
endy overview [--clean] [--no-attach] launch global aggregator session 'endy'
endy orchestrator [name] [opts]       open another orchestrator window
                                      opts: --cwd <dir>, --agent codex|cmd|opencode|hermes
endy tmux-help                        add/update the tmux command status line
endy stop                             kill this cwd's endy session
endy stop --session <name>            kill one named endy tmux session
endy stop --all                       kill every endy* tmux session
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
tmux attach -t endy-<basename>
tmux select-window -t endy-<basename>:chat-<id>

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

Most commands are observational. Mutating commands are `chat`, `followup`, `kill`, and `kill-all`.

```
endy watch                            attach to 'endy' tmux session (read-write)
endy watch attach [<id>] [--strict]   attach with a task window pre-selected;
                                      --strict re-enables tmux read-only mode
                                      (blocks navigation too — rarely what you want)
endy watch list [--overview]          enriched table: id / status / parent /
                                      orchestrator / agent / persona / cwd / runtime / last
endy watch tree [--all] [--overview]  active tasks grouped by orchestrator + cwd
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
                                      opts: --all, --cwd <dir>, --orch <name>,
                                      --overview.
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
tmux attach -t <session>        # attach (read-write)
tmux attach -t <session> -r     # attach read-only (BLOCKS NAVIGATION too — rarely useful)
Ctrl-b N                         # next window
Ctrl-b P                         # previous window
Ctrl-b 0..9                      # jump to window by number
Ctrl-b w                         # interactive window picker with preview
Ctrl-b ,                         # rename current window
Ctrl-b d                         # detach (session keeps running)
Ctrl-b x                         # kill current pane
Ctrl-b &                         # kill current window
tmux list-windows -t <session>        # see all windows
tmux kill-window -t <session>:<name>  # kill one window
tmux kill-session -t <session>        # nuke one session (`endy stop` does this)
```

`endy start`, `endy overview`, and `endy tmux-help` also put the most-used tmux commands in the tmux status line and create a live `tree` window you can reopen with `tmux select-window -t <session>:tree`.

`endy start --clean` closes old `task-*`, `chat-*`, `follow-*`, `panel`, `watch`, `docs`, `tree`, `help`, `opencode`, and `logs` windows, then recreates the manager layout:

```bash
tmux select-window -t <session>:watch      # task browser
tmux select-window -t <session>:docs       # README.md + NEXT_STEPS.md
tmux select-window -t <session>:tree       # live tree grouped by orchestrator + directory
tmux kill-session -t <session>             # stop one endy session
```

`opencode serve` is not part of the default manager layout anymore. Start it only when you explicitly want that local server:

```bash
endy start --serve-opencode --logs
```

### Following multiple tasks at once

```bash
endy watch follow 4b3c            # opens window 'follow-4b3c'
endy watch follow a104            # opens window 'follow-a104'
tmux attach -t <session>          # attach
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

For `opencode` and `hermes`, endy tries to resume the task's native session before opening the interactive terminal. For `cmd`, there is no reliable headless interactive resume, so endy opens CommandCode in the same working directory and links the new chat back to the parent task.

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
| Stop one endy session | `tmux kill-session -t <session>` or `endy stop` |
| Stop every endy session | `endy stop --all` |

---

## The web dashboard

```bash
endy web                          # default: binds to your Tailnet IP, port 9120
endy web --localhost              # local-only
endy web --host 0.0.0.0           # ⚠ public bind — only with explicit auth in front
```

A single Python file ([web/server.py](web/server.py)) using stdlib only — no `pip install` required. Reads from the same global and per-dir log scopes as the CLI; spawns via the same `spawn-long-task.sh`.

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
endy overview                                          # if not running
tmux new-window -t endy -n web 'endy web'              # or just open the window manually
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

The spawned task lands in the active log scope: `.logs/per-dir/<session>/` for `endy start`, or `.logs/` for `endy overview`. It is visible to `endy watch list`, `endy watch list --overview`, the web dashboard, and any other agent introspecting state. **Hermes is special**: it has its own builtin `codex`/`opencode`/`claude-code` skills for delegation, so when Hermes delegates via *those*, the result does not appear in endy's logs. To get hermes-spawned subagents into the monitoring loop, have Hermes call `endy spawn` via its shell tool instead.

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

### Task log contract

Task records live in one of two places:

- Per-dir mode (`endy start`): `.logs/per-dir/<session>/task-<id>.{log,meta,prompt.md}`
- Overview/global mode (`endy overview`): `.logs/task-<id>.{log,meta,prompt.md}`

Every spawned task writes three files:

- `task-<id>.prompt.md` — the prompt verbatim, persisted at spawn time. Survives the run.
- `task-<id>.meta` — `key=value` lines including `task_id`, `kind`, `orchestrator`, `origin_session`, `origin_window`, `origin_pane`, `origin_cwd`, `agent`, `persona`, `model`, `cwd`, `window`, `log`, `prompt`, `spawned_at` (ISO 8601 UTC), and (for followups/chats) `parent_task` and `resume_id`. Append-only after spawn — `endy watch followup`, `endy watch tree`, and the web dashboard use these.
- `task-<id>.log` — `tee`'d stdout+stderr of the underlying agent CLI invocation. Always ends with a line `ENDY_EXIT=<n>` once the agent exits — that's how `check-long-task.sh` distinguishes RUNNING from DONE.

Interactive `endy chat` sessions use the same `task-<id>.meta` and `task-<id>.prompt.md` convention, but set `kind=chat` and write pane capture to `chat-<id>.log`.

Anything that reads these log scopes and respects this contract is a valid endy front-end. The web dashboard, `endy watch list --overview`, and the CLI all use the same files.

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

| Symptom | Cause / fix |
|---------|------------|
| `endy: command not found` | `~/.local/bin` not on PATH. Run `endy install` and follow the warning. |
| `tmux session '<name>' not running` | Run `endy start` for a per-dir session, or `endy overview` for the global session. |
| `endy watch follow <id>` says `task <id> has no log yet (still starting up)` | Race during agent boot. Try again in 5 seconds, or check `endy watch view <id>` for the meta. |
| `endy watch browse` errors `unknown action: reload-preview` | fzf binding bug — already fixed in current code (was `reload-preview`, should be `refresh-preview`). Pull latest. |
| Task stuck in `PENDING` forever | The agent's CLI is hung before producing output. Check it manually: `tmux attach -t <session>` then navigate to its window with `Ctrl-b w`. Often: missing auth (`cmd login`, `opencode auth login`). |
| Task shows `DONE-ERR` | Look at `endy watch view <id>` and grep for `Error:` / `Warning: Reached maximum` etc. The heuristic flagged a problem despite exit 0. Common causes: max-turns hit, auth issue, model mismatch. |
| Task shows `ABANDONED` | tmux window for it is gone or its pane is dead, with no `ENDY_EXIT=` marker. Likely the tmux session was killed mid-run, the agent auto-updated/restarted outside the wrapper, or the agent crashed before `ENDY_EXIT` could be written. The log up to that point is preserved. |
| `endy watch attach -r` won't let you switch windows | Read-only mode blocks ALL keys including `Ctrl-b`. Drop `-r` (the default in `endy watch attach`) or use `--strict` only when you really mean it. |
| Web dashboard says "no tasks" but `endy watch list` shows them | Check the web server's logs. Most likely it bound to a different `LOG_DIR` (the script auto-resolves via `__file__`'s parent). |
| `endy spawn cmd --model X` ignored | cmd has no `--model` flag. Set globally: `cmd /model X`. |
| `endy spawn cmd --persona X` ignored | cmd has no `--agent` flag. Personas via `/agents` interactively only. Use ad-hoc inline prompts. |
| Spawned cmd task has empty log + `Reached maximum turns` warning | `--max-turns` defaults to 200 but you can raise it. For research-heavy tasks, **prefer opencode** — its default agent finishes the same work in fewer turns. |

---

## Roadmap and open work

This README is the operator's manual. The companion file [NEXT_STEPS.md](NEXT_STEPS.md) is the implementing-agent's brief — it lists what's done, what's partially done, and what's open with concrete acceptance criteria for each.

If you're an agent picking this up, **start there**.
