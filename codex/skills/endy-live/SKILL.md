---
name: endy-live
description: "Use this skill — it is the primary one — when you need to drive another coding agent interactively through a tmux pane. Open named windows, send prompts, capture output, manage lifecycle, AND switch models / change auth / use slash commands inside the live CLI (claude, cmd, opencode, hermes, gemini, codex). Includes a per-CLI reference of model-management commands, available models, and the picker-driving recipe you need to do this from outside the terminal."
metadata:
  short-description: Open + drive interactive agent panes (the main one)
---
# endy-live — Interactive agent pane orchestration (primary skill)

This skill is the principal one for working inside the endy stack. If
your task is "open a CLI, talk to it, manage it" — start here.

Pair with `endy-delegate` only when you need to hand off work between
agents (`endy handoff`) or fire a fully headless batch (`endy spawn`).
For everything else — interactive sessions, model switching, picker
navigation, auth, slash commands — this is the skill.

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
- `<agent>` — one of: `claude`, `cmd`, `opencode`, `hermes`, `codex`, `gemini`, `bash`

The window is a **real interactive terminal**: the agent owns the pty, draws its TUI normally, can launch its own subagents/commands, and you drive it via `send`/`capture`. Output is mirrored to `.logs/.../live-<name>.log` via `tmux pipe-pane` (does not interfere with the TUI). Use `bash` (alias `shell`) when you just want a raw shell window — handy as a generic subagent terminal where you run commands manually.
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
- Excludes system windows: orchestrator, watch, list, browse, docs, tree, sessions, agents, help, opencode, logs, panel, task-*, chat-*, follow-*

Note on tmux session names: with per-directory mode (the default since
v0.5.x) the session is named after the cwd basename (`endy-myproject`)
rather than a single global `endy`. Use `tmux list-sessions` to find
yours, or check what `endy doctor` reports. Live pane references in
this skill use `<session>:<window>` notation — substitute the real
session.

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

## When a live agent runs out of tier

The live pattern is for an interactive agent owning a window. If that
agent hits its rate limit / quota / auth wall mid-session, you have two
choices:

- **Keep the conversation:** stay on the same agent and wait for the
  cooldown. Useful when the conversation history is the value.
- **Transfer the work to a different agent:** use `endy handoff` (see
  `endy-delegate` skill). It will spawn a NEW window with a different
  agent and a composed prompt containing the original task + the live
  agent's full output. The new agent picks up the work — not the
  conversation.

If you have multiplexor wired
(`ENDY_HANDOFF_RESOLVER=multiplexor-next-provider`, the default after
`endy install`), the next agent is picked automatically: `endy handoff
<task-id>` with no `--to`. Otherwise pass `--to <agent>` explicitly.

The live pane and the handoff target are independent: handoff opens
its own task window; the live pane stays where it is (close it
manually with `endy live close` once you've confirmed the handoff
took).

---

## Per-CLI reference: managing the agent inside its terminal

Once you have a live pane open, the agent is yours to drive. This is
the canonical reference for *what to type into each CLI* once it is
running. Each subsection covers: how to authenticate, how to change
model, how to resume a previous session, and the slash commands worth
remembering. Drive everything from outside with `endy live send` /
`endy live capture` per the section above.

Driving a picker from outside (you'll need this often): open with `endy
live send <name> "/model"`, give it a beat, then a second Enter if the
slash menu filtered itself to one entry. Navigate with one `Down`/`Up`
per `send` (text-search via `send` is debounced away by Ink/Bubble Tea
TUIs in cmd/hermes — use arrow keys). Confirm with `Enter` and verify
against the persistence file the CLI writes to (`~/.commandcode/
config.json`, `~/.hermes/config.yaml`, etc.) instead of the visible
TUI, because the picker closes and the pane may go blank.

### claude (Anthropic Claude Code)

**Boot:**
```bash
endy live open cc claude --cwd /path --full-auto
```
Endy passes `--dangerously-skip-permissions` for `--full-auto`.

**Authentication:**
- `claude auth` subcommand to manage auth interactively.
- `claude setup-token` to set up a long-lived token (subscription).
- `ANTHROPIC_API_KEY` env var also works (used by `--bare` mode).

**Model selection:**
- CLI flag: `--model <alias-or-fullname>`. Aliases that resolve to the
  latest: `sonnet`, `opus`. Full names: `claude-sonnet-4-6`,
  `claude-opus-4-7` (Opus 4.7 is the latest as of 2026-05).
- `--effort low|medium|high|xhigh|max` controls reasoning depth.
- `--fallback-model <m>` enables auto-fallback when the default is
  overloaded (only works with `--print`).

**Resume:**
- `-c, --continue` continues the most recent conversation in the cwd.
- `-r, --resume [value]` resumes a specific session id or opens an
  interactive picker (with optional search term).
- `--fork-session` creates a new session id when resuming (useful for
  branching).

**Permission modes:** `--permission-mode acceptEdits | auto |
bypassPermissions | default | dontAsk | plan`.

**Subcommands you may run from the live pane:** `claude agents` (manage
background agents), `claude mcp` (MCP servers), `claude doctor` (health
check), `claude plugin` (plugins), `claude ultrareview` (cloud
multi-agent review of the current branch).

**Models worth knowing (May 2026):**
- `opus` → claude-opus-4-7 — flagship, long context, planning + heavy
  reasoning. Default for substantial work.
- `sonnet` → claude-sonnet-4-6 — balanced cost/quality, the daily
  workhorse.
- Older `claude-3-7-*`, `claude-4-*` series still resolvable by full
  name if pinned.

**Slash commands inside the TUI:** `/help` lists them; the common ones
are agent-management and project-management commands rather than model
switching (Claude switches model via the `--model` flag at boot or via
the agents framework).

### cmd (CommandCode — Kimi K2.6 / DeepSeek)

**Boot:**
```bash
endy live open cmd-dev cmd --cwd /path --full-auto
```
Endy passes `--yolo` for `--full-auto`. Note: `--full-auto` is silently
ignored for `--model`/`--agent` because cmd lacks those CLI flags.

**Authentication:**
- `cmd login` writes `~/.commandcode/auth.json`. Without it, every `cmd
  -p` hangs silently.
- `cmd logout` / `cmd status` / `cmd whoami` for managing it.

**Model selection — the important one:**
- **No `--model` CLI flag.** Model is global, persisted in
  `~/.commandcode/config.json`. Two ways to change it:
  - Subcommand: `cmd model` opens the interactive picker (then
    arrow-Down to the model, Enter).
  - Slash command inside TUI: `/model` opens the same picker. Or
    keyboard shortcut `Alt+P` ("quick model switch") on Linux/Windows
    (`Option+P` on macOS).
- After confirming, `~/.commandcode/config.json`'s `model` field is
  updated synchronously. Verify with: `grep '"model"'
  ~/.commandcode/config.json` (no need for jq).

**Driving the cmd `/model` picker from outside (worked example):**
```bash
WIN=endy-myproj:cmd-dev
endy live send cmd-dev "/model"
sleep 2
endy live send cmd-dev ""              # extra Enter — slash menu filters to one
sleep 2
endy live capture cmd-dev --lines 40   # confirm picker is open
# Navigate. Count rows then arrow-Down. Text filter is debounced away.
for _ in 1 2 3 4 5 6; do
  tmux send-keys -t "$WIN" Down
  sleep 0.2
done
endy live capture cmd-dev --lines 25   # verify ❯ on the target row
tmux send-keys -t "$WIN" Enter         # confirm
sleep 2
grep '"model"' ~/.commandcode/config.json
```

**Resume:**
- `-c, --continue` — last conversation.
- `-r, --resume [name]` — resume by name (multi-word names need quotes),
  or open picker.
- `--plan` boots in plan mode.

**Slash commands worth knowing:** `/init` (seed AGENTS.md for the
project), `/memory` (manage memory), `/resume`, `/rewind` (restore
checkpoint — also `Esc Esc`), `/clear`, `/taste` (taste-learning
packages), `/learn-taste` (learn from other agents' sessions),
`/skills`, `/agents` (persona picker — also has no CLI flag), `/mcp`,
`/model`, `/compact` (compact history), `/context` (context-window
breakdown), `/usage` (credits + plan + metrics), `/status`,
`/add-dir`, `/share`, `/review [pr]`, `/pr-comments`, `/login`,
`/logout`, `/help`, `/exit`.

**Keyboard shortcuts:** `Shift+Tab` toggle mode (default → auto-accept
→ plan), `Ctrl+T` toggle learning feed, `Ctrl+O` expand tool output,
`Alt+P` quick model switch, `Ctrl+G` open input in external editor
(`$EDITOR`), `Esc Esc` rewind.

**Models in the cmd catalog (high-level — pick via `/model`):**
- **Kimi K2.6** — Moonshot's default for cmd. Strong on general
  coding, taste, and tool use. The user's persisted default.
- **DeepSeek V4 Pro** — 1M-context model with hybrid attention. Use
  when feeding a full repo or long traces.
- **DeepSeek V4 Flash** — faster/cheaper sibling of V4 Pro.
- **Step 3.5 Flash** — quick edits.
- **GLM-5 / GLM-5.1** — Zhipu's flagship; GLM-5 is solid on
  architecture/planning, GLM-5.1 on autonomous multi-step.
- **Anthropic Claude models** (e.g. claude-opus-4-7) — only via the
  `anthropic` provider auth path in cmd, NOT the default
  `command-code` provider. Different auth flow; not in the default
  picker.

When cmd hits its turn budget producing empty output (a known failure
mode of Kimi K2.6 on multi-fetch research), either `/model` to a
different cmd model or `endy handoff <task-id> --to opencode` — the
new opencode task inherits the prompt and cmd's full output, no
re-typing.

### opencode (multi-provider, default `build` agent)

**Boot:**
```bash
endy live open oc opencode --cwd /path --full-auto
```
Endy passes `--dangerously-skip-permissions` for `--full-auto`.

**Authentication:**
- `opencode auth login` (alias `opencode providers`) — manage
  per-provider credentials.

**Model selection:**
- CLI flag: `-m, --model provider/model` (e.g. `opencode/big-pickle` or
  `opencode/minimax-m2.5-free`). Provider prefix is required.
- Slash inside TUI: `/model` opens picker.
- List installed models: `opencode models [provider]` (no provider =
  full list).

**Resume:**
- `-c, --continue` — last session.
- `-s, --session <id>` — by id.
- `--fork` — fork the session when continuing.

**Available models (default `opencode` provider — May 2026):**
- `opencode/big-pickle` — default for the `build` agent, no extra auth.
  General coding workhorse.
- `opencode/deepseek-v4-flash-free` — fast, free tier.
- `opencode/minimax-m2.5-free` — alternative free option, good for
  exploration.
- `opencode/nemotron-3-super-free` — Nvidia Nemotron family.
- `opencode/qwen3.6-plus-free` — Alibaba Qwen.

These are the models bundled in the opencode provider. Other providers
(Anthropic, OpenAI, OpenRouter, Nous, etc.) become available once
`opencode auth login` is run for them.

**Subcommands worth knowing:** `opencode models` (list), `opencode
stats` (token usage + cost), `opencode session` (manage sessions),
`opencode export <sessionId>` / `opencode import <file>` (move
sessions between machines), `opencode mcp` (MCP servers), `opencode
agent` (manage personas).

**Personas (`--agent <name>`):** require `mode: primary` or `mode:
all` in the persona's frontmatter; `mode: subagent` causes silent
fallback to the default `build` agent. endy-shipped personas
(`refactor`, `test-writer`) use `mode: all`.

### hermes (Nous Research)

**Boot:**
```bash
endy live open her hermes --cwd /path --full-auto
```
Endy translates `--full-auto` to `--yolo` AND always passes
`-Q --accept-hooks` for programmatic safety (quiet mode + auto-approve
hook scripts).

**Authentication:**
- `hermes login` interactively authenticates against an inference
  provider. `hermes logout`, `hermes auth` (pooled credentials),
  `hermes status` (current config).

**Model selection:**
- CLI flag: `-m, --model provider/model` (e.g. `anthropic/claude-sonnet-4`,
  `gemini-3.1-pro-preview`). Provider prefix when needed.
- Subcommand: `hermes model` opens an interactive picker for both
  default model AND provider.
- Fallbacks: `hermes fallback` manages a chain of providers to try when
  the primary fails.
- Provider flag: `--provider <name>` (default `auto`; user-defined names
  come from `providers:` in `~/.hermes/config.yaml`).

**Resume:**
- `--resume <session_id>` (the `session_id: YYYYMMDD_HHMMSS_<hex>` line
  from a previous run's log).
- `--continue [name]`.

**Required flags for programmatic use:**
- `-Q` (quiet) — without it you get banner + spinner + tool previews.
- `--accept-hooks` — auto-approve unseen shell hooks declared in
  `~/.hermes/config.yaml`. Without it, hermes prompts and hangs in
  non-TTY contexts.

**Skills:** `-s, --skills <name>` preloads one or more skills for the
session (rough analogue of personas). Repeatable or comma-separated.

**Subcommand surface (large — `hermes -h` for the full list):** `chat`,
`model`, `fallback`, `gateway`, `proxy`, `lsp`, `setup`, `whatsapp`,
`slack`, `cron`, `webhook`, `kanban`, `hooks`, `doctor`, `dump`,
`debug`, `backup`, `checkpoints`, `config`, `pairing`, `skills`,
`plugins`, `curator`, `memory`, `tools`, `computer-use`, `mcp`,
`sessions`, `insights`, `profile`, `dashboard`, `logs`.

**Hermes has its own MCP server** (`hermes mcp serve`) and its own
delegation skills (`claude-code`, `codex`, `opencode` builtin). If
Hermes delegates via *those* builtins, the spawned subagent does NOT
appear in endy's `.logs/`. To get hermes-spawned subagents into the
endy monitoring loop, hermes should call `endy spawn` via its shell
tool instead.

### gemini (Google Gemini CLI)

**Boot:**
```bash
endy live open gem gemini --cwd /path --full-auto
```
Endy passes `-y, --yolo` for `--full-auto` (equivalent to
`--approval-mode=yolo`).

**Authentication:**
- `GEMINI_API_KEY` env var.
- Or settings in `~/.gemini/settings.json` (auth method + provider).
- Or `GOOGLE_GENAI_USE_VERTEXAI=1` for Vertex AI, or
  `GOOGLE_GENAI_USE_GCA=1` for GCA.

**Model selection:**
- CLI flag: `-m, --model <model>` (e.g. `gemini-2.5-pro`).
- Inside the TUI, switch model via `/model` (similar Ink picker to
  cmd — drive with arrow keys, not text filter).

**Resume:**
- `-r, --resume <id-or-latest>` (use `latest` for most recent or an
  index number).
- `--list-sessions` to enumerate, `--delete-session <index>` to prune.
- `--session-id <UUID>` to start with a specific id.

**Approval modes (`--approval-mode`):**
- `default` — prompt for approval per tool call.
- `auto_edit` — auto-approve edits but ask for other tools.
- `yolo` — auto-approve everything.
- `plan` — read-only, no edits or shell.

**Available models (May 2026):**
- `gemini-3.1-pro-preview` — newest preview tier, used by Hermes auto
  when configured.
- `gemini-2.5-pro` — production flagship.
- `gemini-2.5-flash` — fast/cheap variant for trivial work.
- `gemini-2.5-pro-experimental` — feature preview.

The free tier has a daily quota; on exhaustion, stderr surfaces
`RESOURCE_EXHAUSTED` and the request fails. That signal is what Phase
4 of endy will key off for auto-handoff.

**Subcommands:** `gemini mcp`, `gemini extensions`, `gemini skills`,
`gemini hooks`, `gemini gemma` (local Gemma routing).

**Worktree:** `-w, --worktree [name]` boots gemini in a fresh git
worktree (similar to claude's `--worktree`).

### codex (orchestrator)

**Boot:**
```bash
endy live open cdx codex --cwd /path --full-auto
```
Codex is the conductor; endy doesn't pass `--dangerously-...` because
codex's sandbox model is explicit (see below).

**Authentication:**
- `codex login` / `codex logout` (manage credentials).

**Model selection:**
- CLI flag: `-m, --model <MODEL>` (e.g. `o3`, `gpt-5`,
  `gpt-5.1-codex`). OpenAI Responses-API model names.
- Or override via config: `-c model="o3"` (TOML override pattern).
- For OSS: `--oss --local-provider lmstudio|ollama`.

**Sandbox & approval (codex-specific, explicit):**
- `-s, --sandbox read-only|workspace-write|danger-full-access` — what
  the sandbox can do.
- `-a, --ask-for-approval untrusted|on-request|never` — when to ask
  for human approval. `--dangerously-bypass-approvals-and-sandbox`
  exists but is intended only for externally sandboxed environments.

**Resume / fork:**
- `codex resume` opens a picker of previous interactive sessions; use
  `--last` to continue the most recent without picking.
- `codex fork` forks a previous session at a chosen point.

**Subcommands worth knowing:** `codex exec "<prompt>"` (non-interactive
one-shot, alias `e`), `codex review` (non-interactive code review on
the branch), `codex mcp` (manage MCP servers), `codex sandbox` (run a
command inside the sandbox), `codex apply` (apply the latest diff as
`git apply`, alias `a`), `codex cloud` (browse Codex Cloud tasks),
`codex update`, `codex doctor`-equivalents via subcommands.

**Config-override pattern:** `-c key=value` lets you change any config
field on the fly. Examples from `codex --help`:
- `-c model="o3"`
- `-c 'sandbox_permissions=["disk-full-read-access"]'`
- `-c shell_environment_policy.inherit=all`

**Profiles:** `-p, --profile <name>` selects a profile block from
`~/.codex/config.toml`. Useful when you keep separate "review" and
"build" profiles.

**Models (OpenAI Responses tier — May 2026):**
- `o3` — flagship reasoning, default for substantial work.
- `gpt-5` / `gpt-5.1` — newer flagships when available on the user's
  plan.
- `gpt-5.1-codex` — codex-tuned variant.
- Pin model per session via `-m` or persist in `config.toml`.

---

## Quick-reference table: where to change the model in each CLI

| CLI | CLI flag | Slash command | Persists to |
|---|---|---|---|
| claude | `--model sonnet\|opus\|<full-name>` | (no in-session switch) | per-session |
| cmd | (no flag) | `/model` or `Alt+P` quick switch | `~/.commandcode/config.json` |
| opencode | `-m provider/model` | `/model` | per-session + `~/.config/opencode/` |
| hermes | `-m provider/model` + `--provider` | (use `hermes model` subcommand) | `~/.hermes/config.yaml` |
| gemini | `-m <model>` | `/model` | per-session + `~/.gemini/settings.json` |
| codex | `-m <model>` or `-c model="..."` | (config override) | `~/.codex/config.toml` (if persisted) |

**Rule of thumb:** if the CLI persists the model globally (cmd, hermes,
gemini, codex via config), changing it in a live session affects ALL
subsequent spawns from that machine. `endy watch list` shows whatever
model was active at *spawn time* for each task — the meta is written
once and never rewritten, so drift is bounded by design.
