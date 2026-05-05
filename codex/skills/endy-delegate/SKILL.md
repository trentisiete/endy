---
name: endy-delegate
description: "Use this skill when a task is best handed off to another coding agent in the endy stack — OpenCode (multi-model worker, fast refactors, test writing), CommandCode/cmd (taste-1 model for code-aesthetics review), or Claude Code (when re-enabled). Covers BOTH short blocking calls inside the orchestrator's bash tool AND long unsupervised runs detached in a tmux window."
metadata:
  short-description: Delegate to endy subagents
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

## What this skill is NOT

- Not for "ask another agent for a second opinion" — that's slower and rarely better than thinking harder yourself.
- Not for tasks with rich back-and-forth — those belong in the orchestrator.
- Not for trivial single-file edits — overhead exceeds benefit.
