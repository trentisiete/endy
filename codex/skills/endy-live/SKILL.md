---
name: endy-live
description: "Use this skill when you need to drive another coding agent interactively through a tmux pane — open named windows, send prompts, capture output, and manage lifecycle. Preferred over endy spawn when you need to inspect live state, correct without relaunching, or use the agent as a TUI."
metadata:
  short-description: Interactive agent pane orchestration
---
# endy-live — Interactive agent pane orchestration

## When to use live vs spawn

| Use `endy live` when… | Use `endy spawn` when… |
|---|---|
| You want to see the agent's live output | You just need the final result |
| You may correct or redirect mid-task | The task is fire-and-forget |
| The agent has menus or interactive prompts | The agent runs a single prompt to completion |
| You want the user watching real-time state | You want log-based tracking only |
| Short inspection/verification tasks | Long autonomous multi-turn work |

## Operations

### `open` — Launch an agent in a named tmux window

```bash
endy live open <name> <agent> [--cwd <dir>] [--model <m>] [--persona <p>] [--full-auto]
```

- `<name>` — meaningful name chosen by you (e.g., `claude-review`, `cmd-design`)
- `<agent>` — one of: `claude`, `cmd`, `opencode`, `hermes`, `codex`
- `--cwd` — working directory for the agent (default: current directory)
- `--model` — model override (agent-specific: supported by claude/opencode/hermes)
- `--persona` — persona/skill name (opencode: `--agent`, hermes: `--skills`)
- `--full-auto` — skip permission prompts (`--yolo` for cmd/hermes, `--dangerously-skip-permissions` for claude/opencode)

**Output:** `WINDOW=<session>:<name>` on stdout

**Examples:**
```bash
endy live open claude-review claude --cwd /path/to/project --full-auto
endy live open cmd-design cmd --cwd /path/to/project --full-auto
endy live open oc-refactor opencode --cwd /path/to/project --persona refactor --full-auto
```

### `send` — Deliver a prompt to an agent pane

```bash
endy live send <name> <text...>
```

- Clears any stale input on the agent's line (C-u) before sending
- Appends Enter after the text
- Safe for special characters: quotes, `$`, `;`, backslashes all pass through correctly
- Use for short prompts (≤ 200 chars). For long prompts, use `send-file`.

**Examples:**
```bash
endy live send claude-review "Review the git diff. READ ONLY. Write /tmp/review.md."
endy live send cmd-design "What's the cleanest approach to refactor this module?"
```

### `send-file` — Tell agent to read a prompt file

```bash
endy live send-file <name> <path>
```

- Validates the file exists and is readable
- Resolves to absolute path
- Sends: `Please read <abs-path> and follow it exactly.` + Enter
- Use when the prompt is long or contains structured content
- Write the prompt file first (to `/tmp/` for transient, to repo for persistent)

**Examples:**
```bash
# Write prompt, then deliver it
cat > /tmp/design-task.md << 'EOF'
Design the new API module...
[long prompt here]
EOF
endy live send-file cmd-design /tmp/design-task.md
```

### `capture` — Observe the agent's pane

```bash
endy live capture <name> [--lines <N>]
```

- Captures the last N lines of the pane (default: 80)
- Output includes ANSI escape sequences (you can parse/strip them)
- Use to check agent status, verify prompt was received, or read results

**Examples:**
```bash
endy live capture claude-review          # last 80 lines
endy live capture claude-review --lines 200  # last 200 lines
```

### `clear` — Clear the agent's current input line

```bash
endy live clear <name>
```

- Sends Ctrl-U to discard whatever the agent has partially typed
- Use when an agent leaves suggested text on its input line after completing
- Always clear before sending a new prompt if the agent may have leftover input

### `close` — Kill the agent window

```bash
endy live close <name>
```

- Kills the tmux window immediately
- No confirmation — you decided to close it
- Use when the agent has finished and output is persisted
- Safe to call on already-closed windows (no error)

### `list` — Show all live panes

```bash
endy live list
```

- Lists all non-system windows in the current session
- Shows: window name, agent, cwd (tab-separated)
- Excludes system windows: orchestrator, watch, docs, tree, help, opencode, logs, panel, task-*, chat-*, follow-*

## Window lifecycle rules

### When to reuse a window
- Same agent, same topic, same working directory
- Previous context is still relevant and helpful
- Example: `claude-review` did review v1, v2, v3 of the same patch → keep it

### When to close and reopen
- Different topic or task from what's in context
- Agent has suggested dangerous actions on its input line
- Context is contaminated with failed approaches or wrong assumptions
- Agent appears stuck or confused

### Cleanup rules
1. **Clear stale input**: If you see suggested text on the agent's input line after it finishes, call `endy live clear <name>` before sending new instructions
2. **Close when done**: Once output is persisted (to `/tmp/` or repo) and the task is complete, call `endy live close <name>`
3. **Never trust agent-suggested input**: If the agent leaves "commit this" or "revert this" or "implement this" on its line, DO NOT just press Enter. Clear it or close the window.

## Prompt delivery patterns

### Short bounded tasks: use `send` directly
```
endy live send claude-review "Read CLAUDE.md and review the current git diff. READ ONLY. Write /tmp/review.md."
```

### Long or complex tasks: use `send-file`
```bash
# Write the prompt
cat > /tmp/architecture-review.md << 'EOF'
Review the following architectural proposal...
[detailed requirements, constraints, examples]
EOF
# Deliver it
endy live send-file claude-review /tmp/architecture-review.md
```

### Transient output: write to /tmp/
```
Write your report to /tmp/claude_review.md
```
The orchestrator reads `/tmp/claude_review.md`, acts on it, then the file can be discarded.

### Repo-persistent output: write to repo
```
Write the design document to coordination/CLAUDE_DESIGN_api_v2.md
```
The output becomes part of the repo's coordination artifacts.

## Boot detection pattern

Since `open` returns immediately, poll for the agent to be ready:

```bash
# Open the pane
endy live open claude-review claude --cwd /path/to/project --full-auto

# Wait for boot (typical: 2-5 seconds depending on agent)
sleep 3

# Check if agent is ready by looking for its prompt/banner
if endy live capture claude-review --lines 10 | grep -q 'Claude Code\|>'; then
  echo "Ready"
else
  sleep 2  # Wait more if needed
fi
```

## Safety rules

1. **Subagent writes report; orchestrator decides.** The subagent produces analysis and recommendations. You (the orchestrator) decide what to apply.
2. **Never accept dangerous suggestions from agent-suggested input.** If an agent offers "commit this", "revert this", or "implement this" on its input line, clear it (C-u) or close the window. The agent is a consultant, not an executor.
3. **Use `--full-auto` for autonomous agents** where you want them to work without permission prompts. Don't use it for agents you want to supervise closely.
4. **Verify output before closing.** Capture the pane and confirm the output is complete and correct before closing the window.
