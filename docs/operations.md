# Operations

Full command reference and runbook for endy. The [README](../README.md)
has the pitch and the demo; this document is the manual.

---

## Session modes

| Command | Scope | Use it for |
|---|---|---|
| `endy start` | current directory | normal work in one repo |
| `endy overview` | all endy sessions | global dashboard across projects |

Lifecycle:

```bash
endy start --clean          # refresh this project's manager
endy overview --clean       # refresh the global all-session view
endy stop                   # stop this project's session
endy stop --all             # stop every endy* tmux session
```

`endy start` creates a per-directory session named `endy-<basename>`
(hash-suffixed on collision). It opens four windows: `orchestrator`,
`watch`, `docs`, `tree`. Tasks spawned from this directory write logs
under `.logs/per-dir/<session>/`. The global `endy overview` aggregates
every session and its logs.

---

## Daily commands

| Goal | Command |
|---|---|
| Spawn a long task | `endy spawn opencode -- "write tests for src/foo"` |
| Ask a quick question (blocking) | `endy ask cmd "what's in this dir"` |
| Hand off to another agent | `endy handoff <id> --to <agent>` |
| See active tasks | `endy watch tree` |
| Browse tasks interactively | `endy watch browse` |
| Follow one log | `endy watch log <id>` |
| Open a follow window | `endy watch follow <id>` |
| Continue with the same agent | `endy watch followup <id> -- "now also …"` |
| Interactive chat with a task | `endy watch chat <id>` |
| Kill a stuck task | `endy watch kill <id>` |

Task IDs accept unique prefixes everywhere.

---

## Which agent to use

| Agent | Best for | Example |
|---|---|---|
| `codex` | long-context planning, orchestration | `endy spawn codex -- "review this design"` |
| `opencode` | fast implementation, refactors, tests | `endy spawn opencode -- "add parser tests"` |
| `cmd` | Kimi-backed coding and taste review | `endy spawn cmd -- "polish this API"` |
| `hermes` | Nous/Hermes workflows, tool-heavy work | `endy spawn hermes -- "investigate this flow"` |
| `gemini` | breadth, big context, free tier | `endy spawn gemini -- "summarize the design across all docs"` |
| `bash` | smoke testing the handoff machinery | `endy spawn bash -- "pretend to work"` |

`endy doctor` shows which are installed and authenticated.

---

## What `endy start` creates

| Window | Purpose |
|---|---|
| `orchestrator` | main agent shell, usually Codex |
| `watch` | interactive task browser |
| `docs` | README and NEXT_STEPS |
| `tree` | auto-refreshing task tree |

Useful tmux keys:

- `Ctrl-b w` — window picker
- `Ctrl-b n` / `Ctrl-b p` — next/previous window
- `Ctrl-b d` — detach
- `Ctrl-b &` — kill current window

---

## Spawning and handoff

```bash
endy spawn <agent> [opts] -- "<prompt>"
endy spawn <agent> --prompt-file <path>
```

Default: `--full-auto` (auto-approve permission prompts). Pass
`--supervised` to opt out. Other options:

- `--persona <name>` — opencode/hermes only; cmd ignores it
- `--model <model>` — opencode/hermes only; cmd ignores it
- `--cwd <dir>` — override working directory
- `--max-turns <n>` — cmd and hermes (default 200)
- `--orchestrator <name>` / `--orchestrator-agent <agent>` — manual labels

### `endy handoff`

```bash
endy handoff <task-id> --to <agent>
                       [--reason "<text>"]
                       [--instructions "<text>"]
                       [--lines N]            # default 80
                       [--stop-parent]        # kill the parent's tmux window after spawning
                       [--no-attach]
```

Reads the parent task's meta + log + prompt, builds a structured
continuation prompt, and spawns a new task in the SAME tmux session as
the parent. The new task's meta records:

```
parent_task=<parent-id>
handoff_from=<parent-id>
handoff_chain=<id1>,<id2>,...,<parent-id>
handoff_reason=<the --reason text>
```

`handoff_chain` makes multi-step routes (A → B → C) fully traceable. The
new agent receives a prompt structured with explicit markers:

```
[endy handoff — you are taking over from a previous agent]
Previous agent: <agent>
Previous task: <parent-id>
Handoff chain: <chain>
Reason for handoff: <reason>

--- original task prompt ---
<original>
--- end original task prompt ---

--- last <N> lines of previous agent's output ---
<tail>
--- end previous output ---

--- handoff instructions ---
<instructions>
--- end handoff instructions ---

Continue the work above. …
```

Resolver hook for auto-routing:

```bash
export ENDY_HANDOFF_RESOLVER="multiplexor next-provider"
endy handoff <task-id>          # --to is now optional
```

The resolver is invoked as `"$ENDY_HANDOFF_RESOLVER" <prev-agent>
<task-id> <cwd>` and must print the chosen agent name to stdout.

---

## The `endy watch` family

Most commands are observational. Mutating commands are `chat`, `followup`,
`kill`, `kill-all`, and `purge`.

```
endy watch                            attach to the tmux session (read-write)
endy watch attach [<id>] [--strict]   attach with a task window pre-selected
endy watch list                       enriched table: id / status / parent /
                                      orchestrator / agent / persona / cwd /
                                      runtime / last
endy watch tree [--all]               active tasks grouped by orchestrator + cwd
endy watch dir <path> [--all]         tasks under one working directory
endy watch log <id>                   `less +F` on the task's log file
endy watch chat <id>                  interactive chat for that task's agent/cwd
endy watch view <id>                  one-shot dump (meta + prompt + last 200 lines)
endy watch follow <id>                NEW tmux window with prompt header + live tail
endy watch browse                     fzf picker with live preview
endy watch panel [--all]              tile view of running tasks (warns if >4)
endy watch followup <id> -- "<prompt>"
                                      same-agent resume (opencode/hermes native,
                                      cmd via context injection). Spawns a new
                                      task with parent_task=<id>.
endy watch kill <id>                  kill a stuck task (writes ENDY_EXIT=130)
endy watch kill-all --agent <name>    close all task/chat/follow windows for an agent
endy watch kill-all --cwd <dir>       close all task/chat/follow windows under a dir
endy watch kill-all --orch <name>     close all task/chat/follow windows for an orchestrator
endy watch purge <id> [--dry-run]     delete a task and all descendants from .logs/
                                      and kill their tmux windows. double confirmation
                                      required. aliases: delete, purge-session.
```

Browse keybindings:

- `Enter` — open chat and switch
- `Ctrl-o` — open chat but stay in browse
- `Ctrl-f` — open a follow window
- `Ctrl-v` — view
- `Ctrl-l` — log
- `Ctrl-y` — copy id to clipboard
- `Ctrl-k` — kill

### Status values

| Status | Meaning |
|---|---|
| `RUN` | running; tmux window present, no `ENDY_EXIT=` yet |
| `CHAT` | interactive `endy chat` window open |
| `PENDING` | meta written but log file not started yet |
| `DONE` | `ENDY_EXIT=0`; no error patterns in log |
| `DONE-ERR` | `ENDY_EXIT=0` but log contains `Error:` / `Exception:` / `Reached maximum turns` / `ProviderModelNotFoundError` / etc. |
| `FAIL(<n>)` | non-zero `ENDY_EXIT=` |
| `ABANDONED` | no `ENDY_EXIT=` AND tmux window is gone or pane is dead |

### Following multiple tasks

```bash
endy watch follow 4b3c            # opens window 'follow-4b3c'
endy watch follow a104            # opens window 'follow-a104'
Ctrl-b w                          # picker → see both side by side
```

Each follow window stays alive (`remain-on-exit on`) so you can scroll
back after the underlying task ends.

---

## Manager workflows

Open one orchestrator per project or workstream:

```bash
endy start
endy orchestrator payments --cwd ~/work/payments
endy orchestrator mobile --agent cmd --cwd ~/work/mobile
```

Each subagent spawned from those orchestrator windows records
`orchestrator`, `orchestrator_agent`, `origin_window`, `origin_pane`, and
`origin_cwd` in its meta file. In the UI this appears as `ORCH`, for
example `mobile[cmd]` or `orchestrator[codex]`.

Common queries:

```bash
endy watch tree                          # grouped by orchestrator, then directory
endy watch dir ~/work/payments --all     # one project directory
endy watch list --orch payments          # one orchestrator
endy watch browse --cwd ~/work/payments  # visual picker for that project
endy watch kill-all --cwd ~/work/payments
endy watch kill-all --orch mobile
```

Manual spawn outside an orchestrator window — label both pieces explicitly:

```bash
endy spawn cmd --orchestrator ux-review --orchestrator-agent codex -- "<prompt>"
```

---

## The `.logs/` contract

Every spawned task writes three files:

- `task-<id>.prompt.md` — the prompt verbatim, persisted at spawn time
- `task-<id>.meta` — `key=value` lines (see below). Append-only after spawn.
- `task-<id>.log` — `tee`'d stdout+stderr of the agent invocation. Always
  ends with `ENDY_EXIT=<n>` once the agent exits.

Meta fields:

| Field | Notes |
|---|---|
| `task_id` | the canonical id |
| `kind` | `spawn` or `chat` |
| `agent` | `opencode` / `cmd` / `hermes` / `claude` / `gemini` / `bash` |
| `persona` | optional, agent-dependent |
| `model` | optional, agent-dependent |
| `cwd` | absolute working directory |
| `window` | `<session>:task-<id>` |
| `log` | absolute path to the log |
| `prompt` | absolute path to the prompt file |
| `spawned_at` | ISO 8601 UTC |
| `parent_task` | id of the immediate parent (set by `followup` and `handoff`) |
| `resume_id` | native-session id from opencode SQLite or hermes session line |
| `handoff_from` | id of the predecessor in a handoff (same as `parent_task` in that case) |
| `handoff_chain` | comma-separated chain `<id1>,<id2>,...` ending in the immediate predecessor |
| `handoff_reason` | free-text reason captured at handoff time |
| `orchestrator` / `orchestrator_agent` | logical parent labels |
| `origin_session` / `origin_window` / `origin_pane` / `origin_cwd` | tmux origin |

Anything that reads `.logs/` and respects this contract is a valid endy
front-end. The web dashboard, `endy watch list`, and the CLI all use the
same files.

`endy chat` sessions use the same convention but set `kind=chat` and
write pane capture to `chat-<id>.log`.

---

## Web dashboard

```bash
endy overview --clean
endy web                          # default: Tailnet IP, port 9120
endy web --localhost              # local-only
endy web --host 0.0.0.0           # public bind — auth required
```

A single Python file (`web/server.py`) using stdlib only. Reads from the
same `.logs/` as the CLI; spawns via the same `spawn-long-task.sh`.

For shared networks, set a token:

```bash
export ENDY_WEB_TOKEN="choose-a-token"
endy web
```

Clients can pass `?token=...` or the `X-Endy-Token` header.

### Endpoints

| Method | Path | What |
|---|---|---|
| GET | `/` | Dashboard HTML |
| GET | `/api/tasks` | JSON list |
| GET | `/api/tasks/<id>` | JSON detail (meta + last 200 log lines + prompt) |
| GET | `/api/tasks/<id>/stream` | SSE: each new log line |
| GET | `/api/events` | SSE: full task list re-emitted on any change |
| POST | `/api/tasks` | `{agent, persona?, cwd?, prompt, full_auto?}` → spawns |
| POST | `/api/tasks/<id>/followup` | `{prompt}` → followup |
| DELETE | `/api/tasks/<id>` | kill |

### From your phone

Open `http://<mac-tailnet-ip>:9120/` over Tailscale. The dashboard is
mobile-first: task cards, spawn sheet with agent picker, parent-task
markers, follow-up button, tmux command snippets, live log streaming.
Tailscale is the auth layer; the server never binds to a public address
by default.

To keep the dashboard alive across SSH sessions, run it inside the endy
tmux session:

```bash
ssh $USER@<your-mac-host>
endy start                                             # if not running
tmux send-keys -t endy:placeholder 'endy web' C-m
```

### Tailscale setup (mobile)

```bash
sudo tailscale up
sudo tailscale set --ssh
tailscale ip -4               # note the 100.x.x.x IP
```

---

## Install details

`./scripts/install.sh --yes` is idempotent. It:

- symlinks `bin/endy` into `~/.local/bin/endy`
- adds `~/.local/bin` to your shell rc file if needed
- installs shell completion
- symlinks bundled Codex, OpenCode, and CommandCode personas
- symlinks the Codex `endy-delegate` skill
- symlinks `AGENTS.md` for Codex and CommandCode
- appends or refreshes the managed endy block in `~/.codex/config.toml`

Existing files are backed up as `*.bak.<timestamp>`.

Agent setup notes:

```bash
codex                       # login if prompted
opencode auth login
cmd login                   # then: cmd → /model Kimi K2.6
hermes status               # if not authed: hermes model
```

- `cmd` has no CLI `--model` flag. Set the model inside `cmd` with `/model`.
- `opencode` needs a working directory. endy passes it automatically.
- `hermes` uses `hermes chat -Q --accept-hooks` under the hood.
- Missing optional agents do not block the install.

---

## Project layout

```text
bin/endy                         main CLI
scripts/start.sh                 tmux manager session bootstrap
scripts/spawn-long-task.sh       detached agent task runner
scripts/spawn-chat.sh            interactive chat runner
scripts/handoff.sh               cross-agent handoff
scripts/endy-watch.sh            task list, tree, browse, follow, kill
scripts/lib/session.sh           per-directory session naming
scripts/lib/status.sh            bash status heuristic
web/server.py                    dashboard server
codex/agents/                    Codex personas
codex/skills/endy-delegate/      Codex skill for endy delegation
opencode/agents/                 OpenCode personas
commandcode/agents/              CommandCode personas
docs/                            documentation (this file, cli-gotchas.md)
```

---

## Command reference

```bash
endy install
endy doctor
endy start [--clean] [--no-attach] [--serve-opencode] [--logs]
endy overview [--clean] [--no-attach]
endy stop [--all | --session <name>]
endy spawn <agent> [--supervised] [--prompt-file <file>] -- "<prompt>"
endy ask <agent> "<prompt>"
endy chat <agent>
endy handoff <id> --to <agent> [--reason "<text>"] [--instructions "<text>"] [--lines N] [--stop-parent] [--no-attach]
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
endy watch purge <id>
endy web [--localhost | --host <ip>] [--port <n>]
```

`endy help` prints top-level usage. `endy help <agent>` prints
per-CLI gotchas (see [cli-gotchas.md](cli-gotchas.md)).

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
| handoff says "parent session is gone" | Run `endy start` in the parent's `cwd` first |
