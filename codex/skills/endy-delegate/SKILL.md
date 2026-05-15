---
name: endy-delegate
description: "Use this skill when a task is best handed off to another coding agent in the endy stack — OpenCode (multi-model worker, fast refactors, test writing), CommandCode/cmd (Kimi K2.6 / DeepSeek), Hermes (Nous Research, tool-heavy), Gemini, or Claude. Covers three delivery modes: short blocking calls, long detached tmux spawns, and `endy handoff` — the cross-agent transfer used when one CLI runs out of tier mid-task."
metadata:
  short-description: Delegate to and hand off between endy subagents
---

# endy-delegate

Hand off a coding task to an endy subagent. Three delivery modes:

- **short** — blocking bash call, you wait for the output.
- **long** — detached tmux window, you get a task ID back and check on
  it later.
- **handoff** — transfer an *in-flight* task from one agent to another
  (e.g. opencode ran out of rate limit; cmd picks up with the same
  prompt + opencode's full log).

## Handoff: continue an in-flight task with a different agent

`endy handoff <task-id>` is the cross-agent transfer. It exists for the
case "this agent can't finish the task — get a different one to pick up
without losing context".

```bash
endy handoff <task-id> --to <next-agent> --reason "<short>" [--stop-parent]
```

What it does, automatically:

1. Reads the parent task's `.meta`, full `.log`, and `prompt.md`.
2. Composes a new prompt with explicit handoff markers:
   - `[endy handoff — you are taking over from a previous agent]`
   - The original task prompt verbatim.
   - The previous agent's FULL output (clear-to-EOL, ANSI-stripped). Cap
     it with `--lines N` only when the target has a small context
     window (e.g. gemini free).
   - The reason you provided.
3. Spawns the new agent in the **same tmux session** as the parent.
   Inherits cwd and orchestrator label.
4. Records the chain: `handoff_from`, `handoff_chain` (multi-hop
   accumulates), `handoff_reason` in the new task's meta.
5. With `--stop-parent`: closes the rate-limited window in the same
   shot.

If `ENDY_HANDOFF_RESOLVER=multiplexor-next-provider` is set (it is, by
default after `endy install`), drop `--to` entirely — multiplexor picks
the next eligible agent automatically:

```bash
endy handoff <task-id> --reason "rate limited"
# → multiplexor marks the previous agent exhausted, returns next-best
#   eligible (e.g. opencode → cmd), endy spawns it with the composed
#   prompt above.
```

### When to call handoff (vs. spawn / live)

| Situation | Use |
|---|---|
| Fresh task, no in-flight work to inherit | `endy spawn <agent>` |
| Fresh task you want to drive interactively | `endy live open` (see `endy-live` skill) |
| In-flight task hit a rate limit / quota / auth error | `endy handoff <task-id>` |
| Same agent, just continue the conversation | `endy watch followup <id>` (native resume) |
| Different agent, take over what was being done | `endy handoff <id> --to <agent>` |

### Same-agent followup vs. cross-agent handoff

`endy watch followup` is for **same agent** — it uses the agent's native
session resume (opencode SQLite, hermes session_id, cmd context
injection because cmd lacks headless resume). The conversation thread
continues.

`endy handoff` is for **different agent** — there is no native resume
across agents, so endy composes a fresh prompt with the parent's full
context. The new agent reads it, picks up the work, but the
conversation thread is new.

If you're an agent that received a handoff and want to know "what state
am I in", the answer is in your prompt: the `## endy environment` block
at the top (handoff chain, peers, tier headroom) plus the `--- original
task prompt ---` and `--- full output of previous agent's output ---`
blocks below. You don't need to call anything extra — the context is
already in your first turn. Use `endy state` (see the endy-state skill)
on later turns to refresh tier headroom.

### Multi-hop chains

`endy handoff` composes: each call adds the previous task to
`handoff_chain`, so a 3-step `bash → opencode → cmd` chain shows in the
final task's meta as `handoff_chain=<bashid>,<opencodeid>` and the
ancestor lineage is visible in `endy watch tree`, `endy watch list`,
and the web dashboard's chain badge.

## When to use which subagent

| Task shape                              | Subagent     | Why                                          |
|-----------------------------------------|--------------|----------------------------------------------|
| Mechanical multi-file refactor, codemod | `opencode` with persona `refactor`     | Fast, cheap (Haiku), built for grunt work |
| Write tests for existing code           | `opencode` with persona `test-writer`  | Sonnet for contract inference             |
| "Does this code read well / match style"| `cmd` with persona `taste-reviewer`    | taste-1 model is purpose-built            |
| Tool-heavy / agentic work (lots of MCP, shell, web), or you specifically want a Nous model | `hermes`               | Nous Research's tool-calling-tuned models, supports many providers, has its own skill ecosystem |
| Anything else (planning, bug hunt, …)   | Stay with Codex — don't delegate       | Delegation is overhead                    |

If two backends could plausibly handle a task: prefer `opencode` (cheapest, fastest) for narrow mechanical jobs, `hermes` when the task is broader / more open-ended / needs heavy tool use, `cmd` for taste.

## Model routing

The user's standing model preferences (full inventory in `.logs/diag-models.md`):

| Scenario | Agent + model | How to select |
|---|---|---|
| Default implementation work | **cmd + Kimi K2.6** | Already the persisted default in `~/.commandcode/config.json` |
| Massive context (full repo ingestion, long traces) | **cmd + DeepSeek V4 Pro** (1M ctx, hybrid attention) | Switch interactively: `cmd` → `/model` → arrow to DeepSeek V4 Pro → Enter. Persists. |
| Fast cheap edits | cmd + Step 3.5 Flash or DeepSeek V4 Flash | `/model` |
| Architecture / planning | cmd + GLM-5 | `/model` |
| Autonomous multi-step coding | cmd + GLM-5.1 | `/model` |
| Mechanical refactor / test-writing / multi-fetch research | **opencode + big-pickle** (default) | No flag — it's the default `build` agent |
| Free-tier exploration | opencode + minimax-m2.5-free | `--model opencode/minimax-m2.5-free` |

Notes:
- **cmd has no `--model` CLI flag.** Switching is slash-command-only and persists in `~/.commandcode/config.json`. Spawned cmd tasks inherit whatever the user last selected.
- For long-context cmd work, set `/model` to DeepSeek V4 Pro **before** dispatching the spawn — the spawn itself can't change it.
- When cmd hits its turn budget producing empty output (a known failure
  mode of Kimi K2.6 on multi-fetch research), switch to opencode rather
  than retrying cmd. `big-pickle` finishes the same work in fewer turns.
  This is also a great moment to use `endy handoff <cmd-task-id> --to
  opencode --reason "cmd turn budget exhausted"` — the new opencode task
  inherits the prompt and cmd's full output, no re-typing.
- Claude models (claude-opus-4-7 etc.) require the `anthropic` provider auth path in cmd, NOT the default `command-code` provider. Don't try to select them from the standard `/model` list.

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

Use `endy spawn <agent>`. It opens a fresh tmux window in the
per-directory endy session (`endy-<basename>` on the cwd, or the
global `endy` session in overview mode), runs the agent piped through
`tee` to a log, and returns a task ID immediately.

`--persona` is **optional** — same with-persona-vs-ad-hoc rule as short
tasks. Skip it when your prompt is fully self-specified.

```bash
# With persona:
endy spawn opencode --persona refactor --cwd /path/to/project \
  --prompt-file /tmp/task-prompt.md

# Ad-hoc (no persona — your prompt is the spec):
endy spawn opencode --cwd /path/to/project \
  --prompt-file /tmp/task-prompt.md

# Or with the prompt inline:
endy spawn opencode -- "refactor src/auth/ to use IdentityProvider, then run npm test"
```

It echoes:

```
TASK_ID=20260505-143012-a1b2
TMUX_WINDOW=endy-myproject:task-20260505-143012-a1b2
LOG=/.../endy/.logs/per-dir/endy-myproject/task-20260505-143012-a1b2.log
```

The TMUX_WINDOW reflects the per-directory session, so multiple
projects don't share a single tmux session — switch with `tmux attach
-t endy-myproject` (per-dir) or `tmux attach -t endy` (overview).

Tell the user the TASK_ID and LOG path, then move on. Do not block waiting.

### Checking on a long task

```bash
endy watch view <TASK_ID>       # one-shot meta + prompt + last 200 lines
endy watch log <TASK_ID>        # follow log with less +F
endy watch follow <TASK_ID>     # new tmux window with live tail
endy watch list                 # status table for everything in scope
```

Status is one of: `RUN`, `CHAT`, `PENDING`, `DONE`, `DONE-ERR`,
`FAIL(<n>)`, `ABANDONED` (see `docs/operations.md` for the heuristics).

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

After spawning a long task or chat, you are not blind. The primitives
to observe and drive a running agent without restarting it are
documented in detail in the **endy-live skill**. The summary:

- **Log file** (`.logs/per-dir/<session>/task-<id>.log`): plain text,
  persistent, survives the agent exiting. Read with the file tools or
  tail with `tail -F`. Use for post-mortem or non-disruptive snapshots.

- **`tmux capture-pane`** (`tmux capture-pane -t <session>:<window>
  -p`): dumps the live TUI as text. Use when the log alone doesn't show
  TUI state — slash-command menus, picker overlays, status bars, content
  not yet committed to scrollback. Replace `<session>` with the
  per-directory session name (e.g. `endy-myproject`), not a bare
  `endy:` — endy is no longer a single shared session.

- **`tmux send-keys`** (`tmux send-keys -t <session>:<window> "<text>"
  Enter`): drive an agent like a keyboard. Combine with `capture-pane`
  for slash-command pickers (`/model`, `/agents`, `/skills`). Use
  `Down` / `Up` / `Enter` one key per call for picker navigation;
  type-to-search via `send-keys` is debounced away in cmd/hermes Ink
  pickers.

For end-to-end recipes (model switching, picker navigation,
boot-detection, lifecycle rules), use the **endy-live skill** — it has
the worked examples and gotchas. This skill (`endy-delegate`) covers
the delegation side; `endy-live` covers the interactive-driving side.

### When to use which primitive

| Goal | Primitive |
|---|---|
| "Did this task succeed? what did it say?" | log file (`endy watch view <id>`) |
| "What's currently on screen in this chat?" | `endy-live` skill: `capture` |
| "Has it printed `Reached maximum turns`?" | `grep "Reached maximum" .logs/.../task-<id>.log` |
| "Submit a follow-up with the SAME agent" | `endy watch followup <id> -- "<prompt>"` |
| "Transfer to a DIFFERENT agent" | `endy handoff <id> --to <agent>` (or no `--to` if resolver wired) |
| "Submit a free-text prompt to a live interactive chat" | `endy-live` skill: `send` / `send-file` |
| "Drive a slash-command picker" | `endy-live` skill: `send` + `capture` |

Three layered primitives, ordered by structure:

- `endy watch followup` — same agent, native session resume. cmd `-r
  "$title"`, opencode `--session`, hermes `--resume`. Records
  `parent_task` in the new meta. Preferred over raw send-keys for
  same-agent continuation.
- `endy handoff` — different agent. Composes a fresh prompt with the
  parent's full context. Records `handoff_from` / `handoff_chain` /
  `handoff_reason`.
- `endy-live` primitives — raw send-keys/capture-pane for ad-hoc TUI
  driving when neither of the above fits.

### Gotcha: chat-kind vs spawn-kind in the watch picker

`endy watch browse` is an fzf picker over rows. Two kinds of rows show up:

- **spawn-kind** (`kind=spawn` in `.meta`) — a long-running headless task. Pressing Enter opens a *new* chat window in the foreground and exits the picker. Use ^O when you want browse to stay focused.
- **chat-kind** (`kind=chat`) — an already-running interactive chat window. Pressing Enter focuses that window and exits the picker.

The Enter binding routes through `endy-watch.sh chat <id>` in foreground mode. ^O always opens in background; ^G is a foreground alias.

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
