# Per-CLI gotchas

The integration quirks we found the hard way. All of them are worked around
in `scripts/spawn-long-task.sh`, but if you change wrapper code, read these
first. `endy help <agent>` extracts the relevant section straight from this
file at runtime, so keep the `### <agent>` headings intact.

---

### opencode

- **Headless `opencode run` needs `--dir <cwd>`.** Opening the tmux window
  with `-c <cwd>` is not enough for all opencode tools; without `--dir`,
  glob/search can drift into the user's home directory and hit
  `~/Library` permission/interruption errors. `endy spawn opencode` and
  `endy ask opencode` pass `--dir` automatically.
- **`--agent <name>` requires `mode: primary` or `mode: all`** in the
  persona's frontmatter. `mode: subagent` causes opencode to fall back to
  the default agent silently (with a warning to stderr). All endy-shipped
  opencode personas use `mode: all`.
- **Persona files must declare `permission:` grants** in the frontmatter,
  e.g. `permission: { edit: allow, write: allow, bash: allow, webfetch: ask }`.
  Without these, opencode auto-rejects `external_directory` access and the
  task fails with
  `Error: The user rejected permission to use this specific tool call.`.
- **Default format does not emit `session_id` to stdout.** It's stored in
  SQLite at `~/.local/share/opencode/opencode.db` (table `session`, keyed
  by `directory`). `endy watch followup` queries this DB to harvest the
  latest session for the parent task's cwd.
- **Exit code is unreliable** — opencode sometimes exits 0 when it has
  logged a `ProviderModelNotFoundError` or hit auth issues. endy's
  `DONE-ERR` heuristic catches this.

---

### cmd (CommandCode v0.25.1)

- **No `--model` CLI flag.** Model is set globally via `cmd model`
  (interactive) or `/model` (slash). `endy spawn cmd --model X` is
  silently ignored with a warning.
- **No `--agent` CLI flag.** Personas in `~/.commandcode/agents/` only
  apply via interactive `/agents` selection. `endy spawn cmd --persona X`
  is silently ignored.
- **`cmd -p` cannot resume a session.** `-c/--continue` and `-r/--resume`
  are interactive-only by design (per the docs: *"Each invocation is a
  standalone session with no conversation history."*). For followup, endy
  injects parent context into the new prompt instead.
- **Order matters in argv.** `-p` must come last, immediately before the
  prompt. `cmd -p --skip-onboarding ...` parses `--skip-onboarding` as the
  prompt value and hangs. Always
  `cmd --skip-onboarding --trust [--max-turns N] [--yolo] -p "<prompt>"`.
- **`--max-turns` is undocumented but real**, default 10. endy passes
  `--max-turns 200` by default. Without raising it, complex tool-using
  research finishes with `Warning: Reached maximum conversation turns`
  and zero useful output.
- **Exit code is unreliable** in the same way as opencode.
- **Auth required first.** `cmd login` writes `~/.commandcode/auth.json`.
  Without it, every `cmd -p` invocation hangs in the tmux window with no
  output.

---

### hermes (Nous Research)

- **`-Q` is mandatory for programmatic use.** Without it, you get banner +
  spinner + tool previews on stdout. With `-Q`, only the final response
  and a `session_id: <YYYYMMDD_HHMMSS_<6char-hex>>` line.
- **`--accept-hooks` is required** for unattended runs. Without it,
  hermes prompts for approval of any unseen shell hooks declared in
  `config.yaml` and waits forever in non-TTY contexts.
- **Native session resume works.**
  `hermes chat -Q --accept-hooks --resume <session_id> -q "new prompt"`
  continues the prior conversation. `endy watch followup` greps
  `^session_id: ...$` from the parent's log and uses this.
- **Has its own MCP server** (`hermes mcp serve`) — if you ever flip endy
  to MCP mode, hermes plugs in directly without needing the
  agent-mcp.mjs shim.
- **Has its own delegation skills** (`claude-code`, `codex`, `opencode`
  builtin) — if hermes delegates via those, the spawned subagent does NOT
  appear in endy's `.logs/`. To get hermes-spawned subagents into the
  monitoring loop, hermes must call `endy spawn` via its shell tool.

---

### gemini

- **`--yolo` is gemini-cli's auto-approve.** Equivalent to opencode's
  `--dangerously-skip-permissions` and cmd's `--yolo`. `endy spawn gemini
  --full-auto` passes it.
- **Headless mode takes the prompt as a `-p` positional**, same as cmd
  and claude. endy wires this in `spawn-long-task.sh`.
- **Free tier has a daily quota** — failures usually surface as
  `RESOURCE_EXHAUSTED` in stderr. Phase 2's auto-exhaustion detector will
  watch for this.

---

### claude (Anthropic Claude Code)

- **`-p` (one-shot) is the only programmatic mode.** Same argv shape as
  cmd: keep `-p` adjacent to the prompt.
- **`--dangerously-skip-permissions`** for auto-approve.
- Less battle-tested in this repo than the others — most endy testing
  flowed through opencode/cmd/hermes/gemini.

---

### bash (offline stub)

- **Not a real agent.** It just prints the composed prompt and idles in
  the tmux window until you kill it.
- **Use it for smoke tests.** You can rehearse a full handoff chain —
  spawn, handoff, tree rendering, dashboard — without burning a single
  free-tier call. Demo recording becomes deterministic.
- **No exit code semantics.** Treat it as a black hole that records the
  meta + log files correctly and nothing else.

---

### tmux specifics for spawn-long-task.sh

- **Long prompts are passed via `"$(cat <prompt-file>)"` substitution at
  runtime**, not via `tmux send-keys`. Earlier versions used send-keys
  for the full prompt and hung on prompts >2KB because tmux types the
  whole thing character-by-character into a shell buffer. The current
  pipeline expands `$(cat …)` inside the new tmux window's shell, so
  `ARG_MAX` (~256KB on macOS) is the only limit.
- **Each window has `set-window-option remain-on-exit on`.** When the
  agent exits, the pane shows `Pane is dead (status N, …)` instead of
  closing. You can scroll back through the final state.
- **Default-shell respected.** tmux invokes the user's `$SHELL` (typically
  zsh on macOS) for each new window's command. The `printf '%q'` quoting
  in `spawn-long-task.sh` is bash-style but compatible with zsh.
