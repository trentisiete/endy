---
name: endy-delegate
description: "Use this skill when a task is best handed off to another coding agent in the endy stack — OpenCode (multi-model worker, fast refactors, test writing), CommandCode/cmd (taste-1 model for code-aesthetics review), or Claude Code (when re-enabled). Covers short blocking calls, long unsupervised tmux runs, AND watching/driving running agents live via tmux capture-pane and send-keys."
metadata:
  short-description: Delegate to and live-drive endy subagents
---

# endy-delegate

Hand off a coding task to an endy subagent. Two delivery modes: **short** (blocking bash call, you wait for the output) and **long** (detached tmux window, you get a task ID back and check on it later).

## When to use which subagent

| Task shape                              | Subagent     | Why                                          |
|-----------------------------------------|--------------|----------------------------------------------|
| Mechanical multi-file refactor, codemod | `opencode` with persona `refactor`     | Fast, cheap (Haiku), built for grunt work |
| Write tests for existing code           | `opencode` with persona `test-writer`  | Sonnet for contract inference             |
| "Does this code read well / match style"| `cmd` with persona `taste-reviewer`    | taste-1 model is purpose-built            |
| Tool-heavy / agentic work (lots of MCP, shell, web), or you specifically want a Nous model | `hermes`               | Nous Research's tool-calling-tuned models, supports many providers, has its own skill ecosystem |
| Anything else (planning, bug hunt, …)   | Stay with Codex — don't delegate       | Delegation is overhead                    |

If two backends could plausibly handle a task: prefer `opencode` (cheapest, fastest) for narrow mechanical jobs, `hermes` when the task is broader / more open-ended / needs heavy tool use, `cmd` for taste.

## Short tasks (≤ ~5 min, you'll wait)

Call the CLI directly via your bash tool. The argv shape:

```bash
# OpenCode
opencode run [--agent <persona>] [--model <provider/model>] [--dangerously-skip-permissions] "<prompt>"

# CommandCode (no --model, no --agent at the CLI level — both are slash-command-only)
cmd --skip-onboarding --trust [--yolo] -p "<prompt>"
# -p MUST be the last flag before the prompt. cmd's parser is order-sensitive.
# Personas live at ~/.commandcode/agents/<name>.md but cannot be selected
# non-interactively — for spawn-style invocation, write the role into the prompt itself.

# Hermes (Nous Research)
hermes chat -Q --accept-hooks [--skills <name>] [--model <provider/model>] [--yolo] -q "<prompt>"
# -Q  → quiet mode (only final response on stdout — programmatic-friendly)
# --skills <name>   → preload a Hermes skill (rough analogue of a persona)
# --yolo  → bypass dangerous-command approval prompts (use deliberately)
```

For long, unsupervised, full-permission tasks, prefer `scripts/spawn-long-task.sh` which builds the right argv per agent (and handles the gotchas above) — see "Long tasks" below.

### With persona vs ad-hoc — pick deliberately

Personas (`--agent <name>`) load a fixed system prompt and tool set. Use one when **the task cleanly matches a preconfigured role** (mechanical refactor, test writing, taste review). When it does, the persona enforces output format, scope, and refusal of out-of-scope work — that's its whole value.

Skip `--agent` and write the full instructions inline when **you've already specified the role and behaviour in your prompt** — e.g. "You are an architecture reviewer for this auth module. Look for X, Y, Z. Output format: …". A persona on top of that is just contention. The default agent ("build") is a competent generalist; lean on it.

Decision in one line:

> If you'd describe the task as "do a {refactor, test, taste-review}", use the persona. Otherwise, ad-hoc.

### Common rules either way

1. **Self-contained prompt.** The subagent sees nothing of this conversation. Include file paths, the exact change requested, acceptance criteria.
2. **Capture stderr too**: append `2>&1` so failures don't disappear.
3. **Working dir matters.** Run with `(cd <project-dir> && opencode run …)` if the task is project-scoped, or pass `--dir <path>` to OpenCode.
4. **Don't fight the persona.** If you find yourself overriding most of a persona's defaults via the prompt, you're using the wrong tool — drop `--agent` and go ad-hoc.

## Long tasks (≥ ~5 min, run unsupervised, full permissions OK)

Use `scripts/spawn-long-task.sh`. It opens a fresh tmux window in the `endy` session, runs the command piped through `tee` to a log, and returns a task ID immediately.

`--persona` is **optional** — same with-persona-vs-ad-hoc rule as short tasks. Skip it when your prompt is fully self-specified.

```bash
# With persona:
~/Downloads/endy/scripts/spawn-long-task.sh \
  --agent opencode --persona refactor \
  --cwd /path/to/project \
  --prompt-file /tmp/task-prompt.md

# Ad-hoc (no persona — your prompt is the spec):
~/Downloads/endy/scripts/spawn-long-task.sh \
  --agent opencode \
  --cwd /path/to/project \
  --prompt-file /tmp/task-prompt.md
```

It echoes:

```
TASK_ID=20260505-143012-a1b2
TMUX_WINDOW=endy:task-20260505-143012-a1b2
LOG=$HOME/Downloads/endy/.logs/task-20260505-143012-a1b2.log
```

Tell the user the TASK_ID and LOG path, then move on. Do not block waiting.

### Checking on a long task

```bash
~/Downloads/endy/scripts/check-long-task.sh <TASK_ID>
```

Output is one of:

- `RUNNING` + last 50 lines of the log
- `DONE` + last 100 lines + exit code
- `FAILED` + last 100 lines + exit code

### Bringing the result back into the conversation

When the task is `DONE`:

1. Read the full log if it's small (`< 2000 lines`), otherwise read the last N lines plus grep for `ERROR|FAIL|Exception`.
2. Summarise what changed (file count, test result if any).
3. If the user wanted to review the diff, surface it: `(cd <cwd> && git diff)`.

## Why the prompt matters more than usual

When you're sitting next to the subagent (short tasks) you can correct mid-flight. With long tasks you can't. Spend the extra 30 seconds writing a tighter prompt:

- Concrete file paths, not "the auth module".
- Acceptance check the subagent can run itself — usually a test command. Include it in the prompt: "Verify with `npm test`. If anything fails, do not commit."
- Failure policy: "If you can't complete cleanly, leave the working tree dirty and exit with a one-line summary of where you got stuck."

## Permissions / sandbox

Long tasks default to the same sandbox the orchestrator is running in. If the user has explicitly OK'd full permissions (e.g. running with `--full-auto` or `sandbox = "danger-full-access"`) you can pass that through to the subagent. Otherwise, lean conservative: subagents can't grant themselves more than the orchestrator has.

## Watching and interacting with running agents

After spawning a long task or chat, you are not blind. Three primitives let you observe and drive a running agent without restarting it.

### 1. Read the log file (post-mortem or live tail)

Every spawn writes `.logs/task-<id>.log` (and chats write `.logs/chat-<id>.log` via `tmux pipe-pane`). Plain text. Read with the file tools or tail with `tail -F`. Cheap, persistent, survives the agent exiting.

Use when: the task has finished, or you want a non-disruptive snapshot.

### 2. `tmux capture-pane` — read the live screen

`tmux capture-pane -t endy:<window> -p` dumps the current contents of that pane's terminal cell grid as text on stdout. With `-S -200` you get the last 200 scrollback lines; with `-e` you also get ANSI escape codes (colour, bold).

This is **a tmux feature, not a screenshot.** tmux already maintains the cell grid in memory (it's how it draws to your terminal); `capture-pane` just exports it. No image, no OCR. Works on any TUI — interactive cmd, opencode chat, vim, htop.

```bash
# After cmd is mid-render, get a textual screenshot of its TUI:
tmux capture-pane -t endy:chat-20260506-205402-6f30 -p | tail -50
```

What you see: the banner, the input prompt, panels, slash-command menus, model name, anything visible to the user. Pre-render artifacts (cursor moves, repaints) may interleave — wait a beat or capture twice if the screen is animating.

Use when: the agent is interactive (cmd, opencode chat, hermes chat) and the log file alone doesn't show TUI state — slash-command output, picker overlays, status bars, in-flight content not yet committed to scrollback.

### 3. `tmux send-keys` — drive an agent like a keyboard

`tmux send-keys -t endy:<window> "<text>" Enter` literally sends keystrokes to the pane. The agent receives them as if you typed. Combine with `capture-pane` to drive a TUI without being there.

```bash
# Ask an open cmd chat to dump its context budget
WIN=endy:chat-20260506-205402-6f30
tmux send-keys -t "$WIN" "/context" Enter
sleep 2  # let the slash menu render
tmux capture-pane -t "$WIN" -p | tail -30
```

Notes:
- For multi-character input use `"text"` then `Enter` as separate args; do NOT embed `\n` in the string.
- Slash-command menus in cmd/opencode sometimes need an extra `Enter` once the picker filtered to one match.
- `send-keys` is racy — the agent may still be repainting. Capture once, sleep ~500ms–2s, capture again to confirm the new state stuck.
- You CAN type into a busy pane; the agent's input buffer queues your keys. Use `C-c` cautiously — only if you know the pane accepts it.

### When to use which primitive

| Goal | Primitive |
|---|---|
| "Did this task succeed? what did it say?" | log file (`.logs/task-<id>.log`) |
| "What's currently on screen in this chat?" | `tmux capture-pane -p` |
| "Has it printed `Reached maximum turns`?" | `grep -E "..." .logs/task-<id>.log` (or `Monitor`) |
| "Submit a follow-up to a spawn-task" | `endy watch followup <id> -- "<prompt>"` (preferred — proper resume + parent_task wiring) |
| "Submit a follow-up to a live interactive chat" | `tmux send-keys` into the chat window |
| "Inspect a slash-command output" | `send-keys` then `capture-pane` |

Prefer `endy watch followup` over raw `send-keys` whenever a structured resume exists — it threads the agent's native session resume (cmd `-r "$title"`, opencode `--session`, hermes `--resume`) and records `parent_task` in meta. `send-keys` is for ad-hoc interactive driving when there's no spawn flow that fits.

### Driving TUI pickers (slash commands, model switching)

cmd, opencode, and hermes all expose interactive pickers behind slash commands (`/model`, `/agents`, `/skills`, `/context`, `/resume`…). These can be driven end-to-end from outside the terminal using `send-keys` + `capture-pane`. The model switch is the canonical example.

**Worked example: switch cmd to a different model.**

```bash
WIN=endy:chat-<id>

# 1. Open the picker. Slash commands in cmd often need TWO Enters: the first
#    commits the typed `/model` into the slash-command menu (which filters
#    itself to that one entry), the second selects it and opens the actual
#    model picker. If the picker doesn't render after one Enter, send another.
tmux send-keys -t "$WIN" "/model" Enter
sleep 3
tmux send-keys -t "$WIN" Enter
sleep 3
tmux capture-pane -t "$WIN" -p -S -200 | tail -40   # confirm picker open

# 2. Navigate. Arrow keys are the reliable path.
#    Text-search via send-keys does NOT work in cmd's picker — sending
#    "deepseek pro" as a single string is ignored. The picker only
#    responds to single-keystroke events delivered in real time. So
#    don't try to filter; count rows and arrow-down to the target.
for _ in 1 2 3 4 5 6; do tmux send-keys -t "$WIN" Down; sleep 0.2; done
tmux capture-pane -t "$WIN" -p | tail -25   # verify ❯ on the right row

# 3. Confirm and verify the persistence layer.
tmux send-keys -t "$WIN" Enter
sleep 2
jq -r '.model' ~/.commandcode/config.json     # cmd writes the new model here
```

After confirmation, the picker closes (the pane goes mostly empty, a normal post-selection state). The new model is written to `~/.commandcode/config.json` synchronously — that file is the source of truth and is the right thing to assert against, not the visible TUI.

**Why arrow keys instead of text filter.** Pickers built on Ink/Bubble Tea (cmd, hermes) read keystrokes through an Ink/raw-mode TTY listener. `tmux send-keys "deepseek"` delivers the bytes too quickly, often during a render, and the input mode debounces them away. `Down` is one key per call — every press is processed cleanly. For automation, prefer `Down`/`Up`/`Enter` over typed search strings even when the picker advertises type-to-search.

**Snapshot semantics for endy's MODEL column.** `endy watch list`'s MODEL column reads `model=` from each task's `.meta` file. Meta is written at spawn-time and never rewritten. So switching the global model affects only NEW spawns; existing rows keep showing whatever model was active when they were spawned. That's the intended snapshot behavior — drift is bounded.

**Other slash-command pickers follow the same pattern.** `/agents`, `/skills`, `/resume` open similar TUIs. The same recipe works: open with slash + Enter (×2 if needed), navigate with arrows, confirm with Enter, verify against the persistence layer (config.json, the projects/ dir, etc.). For `/resume`, expect the picker to call `cmd -r` under the hood and replace the chat with the resumed session.

### Gotcha: chat-kind vs spawn-kind in the watch picker

`endy watch browse` is an fzf picker over rows. Two kinds of rows show up:

- **spawn-kind** (`kind=spawn` in `.meta`) — a long-running headless task. Pressing Enter opens a *new* chat window in the background (browse stays focused), so you can fan out without losing the picker.
- **chat-kind** (`kind=chat`) — an already-running interactive chat window. Pressing Enter focuses that window (browse persists in the background, prefix-l back).

The Enter binding routes through `endy-watch.sh _open <id>` which dispatches by kind. ^O always opens in background; ^G always opens in foreground and exits the picker.

### Gotcha: cmd headless tasks don't have native resume

`cmd -p "<prompt>"` (the headless mode behind `endy spawn cmd`) does NOT persist a session file under `~/.commandcode/projects/<slug>/`. Only interactive cmd (the full TUI) does.

Implication: for `kind=spawn` rows where `agent=cmd`, there is no `cmd -r "$title"` to resume. Endy detects this case and injects the parent task's `prompt.md` + last log tail as the *initial message* of the new interactive chat (via `spawn-chat.sh --initial-message`). The user gets continuity without an actual cmd session resume.

For `kind=chat` rows where `agent=cmd`, the interactive session DOES persist — but the live tmux window is usually still around, so `_open` just `tmux switch-client`s to it instead of trying to resume.

Don't promise users that arbitrary `endy spawn cmd` runs can be picked up exactly where they left off — the model context is gone after `cmd -p` exits. The injected-context chat is a continuation, not a true resume.

## Operational safety: tmux RAM hygiene

endy can run for hours of agent work, but the tmux session accumulates state if you don't garbage-collect. Audit summary (full report at `.logs/diag-tmux-ram.md`):

| Source | Cost | Bounded? |
|---|---|---|
| Live agent TUI (node for cmd/opencode) | **180–235 MB per agent** | Only by killing the window |
| tmux scrollback (per pane) | ~130 bytes/line — cheap | By `history-limit` |
| Dead windows (`remain-on-exit on`) | ~3 MB/window (shell + scrollback + pipe-pane) | Only by `kill-window` |
| `.logs/*.log` on disk | unbounded | Only by manual rotation |

**The dominant cost is the live agent process, not tmux itself.** A single concurrent cmd holds ~180 MB. Ten concurrent agents = ~1.8 GB. Cap *concurrency*, not scrollback, to control peak.

The accumulation risk is dead windows piling up. By default `endy spawn` and `endy chat` set `remain-on-exit on` so the user can scroll back through a finished agent's output — but nothing reaps them. After 200 spawns over a week, that's ~600 MB stranded.

### Three guardrails to add when sessions run long

1. **`tmux set -g history-limit 8000`** in `start.sh` near the session-creation step. The user's `~/.tmux.conf` may set 100000; for endy's verbose agents, 8000 lines covers ~3 full traces and caps per-pane scrollback at ~1 MB.
2. **`endy watch gc`** — a subcommand that walks `.logs/task-*.meta`, filters to DONE/DONE-ERR/FAIL/ABANDONED status, and `tmux kill-window`s each one. Dry-run flag (`--dry-run`) for safety.
3. **`endy watch kill-all --done`** — mass-cleanup variant that only kills finished tasks, preserving anything RUNning or in CHAT.

When to run:
- After a long unsupervised batch (`endy watch gc`)
- Before a presentation/demo (`endy watch kill-all --done` to clean visual noise)
- Daily if the orchestrator runs continuously (cron entry calling `endy watch gc`)

### Concurrency advice for the orchestrator

Don't rely on tmux to backpressure spawns. Each cmd/opencode TUI takes ~200 MB, so on an 8-GB machine the practical ceiling is ~30 concurrent agents — but that leaves no headroom for the user's own work. Suggested cap when doing parallel research/refactor batches: **4 concurrent spawns**, queue the rest. This is an orchestrator-side discipline, not something tmux enforces.

## What this skill is NOT

- Not for "ask another agent for a second opinion" — that's slower and rarely better than thinking harder yourself.
- Not for tasks with rich back-and-forth — those belong in the orchestrator.
- Not for trivial single-file edits — overhead exceeds benefit.
