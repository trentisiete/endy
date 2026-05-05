# NEXT_STEPS.md — implementation handoff

You're picking up the **endy** multi-agent control plane. The user-facing operator's manual is [README.md](README.md). This file is for **you, the implementing agent** — what's done, what's WIP, what's open, and how to verify each piece.

---

## Operating principles

Before touching code:

1. **Use `endy spawn cmd` (Kimi K2.6) as your default subagent** for parallel research. For multi-fetch research where cmd hits its turn budget with empty output, **switch to opencode** (its default `build` agent on `big-pickle` handles tool chains in fewer turns). See `feedback_cmd_kimi_limits.md` in the user's memory.
2. **Always print explicit tmux commands** when something opens/changes a window. The user works over SSH+Tailscale and shouldn't have to recall tmux semantics. Example: after `endy spawn`, list how to attach, switch, kill.
3. **Personas are optional**, never required. Skip `--persona` and inline the role description when you've already specified the behaviour in the prompt. Don't dress up "no persona" as a fallback — it's a peer mode.
4. **Don't propose WhatsApp / Hermes mobile gateway** unless the user reopens that thread. The security investigation is done (see `.logs/task-20260505-12{3945,4000}*` for R1 and R2) but the user parked it explicitly.
5. **Don't drop the MCP shim path.** It's commented out in `codex/config.snippet.toml` on purpose; if you ever need to flip the stack from hybrid bash to MCP, the shim already works.
6. **Test by spawning real tasks.** Don't claim a feature works without a smoke test that lands in `.logs/`.

---

## What's verified working (May 2026)

- ✅ `endy install` — idempotent symlinks of agents, skills, AGENTS.md, `bin/endy` to `~/.local/bin`. Tested by re-running multiple times.
- ✅ `endy doctor` — checks tmux + 4 CLIs + AGENTS.md + tmux session. Tested.
- ✅ `endy ask <agent> "<prompt>"` — short blocking calls, tested with opencode (`ENDY-CLI-OK`) and cmd (`CMD-CLI-OK`).
- ✅ `endy spawn <agent> -- "<prompt>"` — long detached spawn. Tested with all four agent types. Long prompts (>2KB) work via `$(cat $PROMPT_PATH)` runtime expansion (don't revert to `tmux send-keys` typing the whole prompt — see "Why we don't send-keys" below).
- ✅ `endy watch list / log / view / follow / browse / panel / kill` — all working.
  - Multiple parallel `follow` windows confirmed (TASK-ALPHA + TASK-BRAVO simultaneously).
  - Browse uses fzf 0.71+ with `--preview-window=…:follow` for live tail in the right pane.
  - `^Y` in browse copies task id to system clipboard via pbcopy.
- ✅ Web dashboard at `endy web` — Python stdlib server, SSE for live tasks list and log streams, POST `/api/tasks` spawns through the same `spawn-long-task.sh`. Smoke-tested end-to-end (`WEB-API-OK`).
- ✅ Status heuristics — `RUN`, `PENDING`, `DONE`, `DONE-ERR`, `FAIL(<n>)`, `ABANDONED`. The `DONE-ERR` heuristic catches `Reached maximum turns`, `Error:`, `Exception:`, `auto-rejecting`, `ProviderModelNotFoundError`, `Unauthorized`, `forbidden`, `model not found`. The `ABANDONED` detection looks for missing tmux window + no `ENDY_EXIT`.
- ✅ Persona files for opencode (`refactor`, `test-writer`) load correctly with `mode: all` and `permission:` grants.
- ✅ AGENTS.md is symlinked globally so Codex and `cmd` see it on every session.

---

## What's implemented but UN-TESTED end-to-end

These have code in place, parsed and syntax-checked, but no live smoke test landed in `.logs/`. **Verify before claiming done.**

### `endy watch followup <id> [-- <new-prompt>]`

**File:** `scripts/endy-watch.sh` (function `cmd_followup`), `scripts/spawn-long-task.sh` (new `--resume` and `--parent-task` flags).

**Strategy per agent (verified docs/help):**

| Agent | Approach | How |
|-------|----------|-----|
| hermes | Native session resume | grep `^session_id: \d{8}_\d{6}_[a-f0-9]{6}$` from parent log → `hermes chat -Q --accept-hooks --resume <id> -q "<new>"` |
| opencode | Native via SQLite | `sqlite3 ~/.local/share/opencode/opencode.db "SELECT id FROM session WHERE directory='<cwd>' ORDER BY time_created DESC LIMIT 1"` → `opencode run --session <id> "<new>"` |
| cmd | **Context injection** (no headless resume exists) | Prepend last 80 lines of parent log + parent meta into the new prompt; spawn fresh |
| claude | Untested | TBD |

**Acceptance criteria for "verified":**

1. Spawn a hermes parent task: `endy spawn hermes -- "Your name is FluffyTeapot. Just say 'OK FluffyTeapot here.'"` — wait for `DONE`.
2. Followup: `endy watch followup <hermes-parent-id> -- "What's your name?"` — output should contain "FluffyTeapot" (proves the session was resumed, not a fresh hermes that doesn't know).
3. Same dance with opencode. The new task's `.meta` should have `parent_task=<original-id>` and `resume_id=<session-id-or-empty>`.
4. cmd followup: spawn parent + followup; the new prompt should contain the `[endy followup — parent task ...]` header with the excerpt. Verify the model treats it as continuation.
5. `endy watch list` should show the new task with `parent_task` link visible somewhere (currently the column doesn't render this — see "Polish work" below).

**Risks to watch for:**

- opencode's SQLite query is keyed by `directory`. If the parent task ran in a different cwd than what's now passed, it'll grab the wrong session or none. Test with explicit cwd.
- hermes session_id might not appear in the log if the run was killed mid-stream (only emitted at clean exit). Followup should warn and fall back to context injection.
- cmd's context-injection currently does `tail -n 80 | head -c 4000`. Tune if the model's continuation quality is poor.

---

## Open work, in priority order

### 1. Verify followup smoke-tests (above)

**Files:** none new — just run the four scenarios in the acceptance criteria above and report what works.

**Effort:** 30 min if everything works first try. Up to 2 hours if hermes session_id format varies or opencode SQLite query needs adjustment.

---

### 2. Render `parent_task` in `endy watch list` and the web dashboard

When a task has `parent_task=<id>` in its `.meta`, both the CLI table and the web dashboard should make this visible — at minimum a small indent or `↳` glyph linking to the parent. Currently the field is recorded but never displayed.

**Files to touch:**

- `scripts/endy-watch.sh` — function `cmd_list`. Add a column or visual indicator.
- `web/server.py` — `list_tasks()` already reads all meta fields; expose `parent_task` in the JSON.
- `web/index.html` — render the parent link in the task card.

**Acceptance:** spawn parent + followup, both appear in `endy watch list` and on `/`, with the followup visually nested under or pointing to the parent.

---

### 3. `endy chat <agent>` — persistent interactive sessions

Today every spawn is one-shot non-interactive. The user has asked for an "I want to actually talk to a running agent" mode. Sketch:

- `endy chat <agent> [--persona X]` opens a NEW tmux window running the agent in **interactive** mode (no `-Q` / `-p` / `-q`).
- Use `tmux pipe-pane -o -t <window> 'cat >> .logs/chat-<id>.log'` to capture output for monitoring.
- Meta gets a new field `kind=chat` (vs `kind=spawn`) so `endy watch list` can distinguish.
- The user attaches to that window (`tmux attach -t endy`, navigate to it) and talks normally.
- `endy watch follow` works on chat sessions too — the log file is the source of truth.

**Files to touch:**

- New function in `bin/endy`: `cmd_chat`.
- `scripts/spawn-long-task.sh` is fine for non-interactive; chat needs a sibling `scripts/spawn-chat.sh` OR a `--interactive` flag on the existing one (probably cleaner as a sibling).
- `endy-watch.sh` `log_status` should treat chat sessions specially — they don't write `ENDY_EXIT` because they don't exit until the user does. Show as `CHAT` instead of `RUN`.

**Acceptance:** `endy chat opencode`, attach, type a few messages, see live in `endy watch list` and the web dashboard. `tmux pipe-pane` capture is reliable across detach/reattach cycles.

**Risks:**

- `tmux pipe-pane` is per-pane, and panes don't survive `tmux kill-window`. If user kills the window, log capture stops — but the previously-written log is intact.
- Some CLIs use `tput`/cursor codes heavily in interactive mode; the captured log will have ANSI noise. Reuse the existing `strip_ansi` filter in display layers.

---

### 4. Web dashboard: spawn-from-browser polish

The dashboard already has a "+ Spawn" form that POSTs to `/api/tasks`. Improvements:

- **Dropdown for agent/persona/model** populated from disk (`~/.codex/agents/*.toml` etc.) — currently the persona is a free-text input.
- **Server-Sent Events for the new task's log** auto-opening when you submit, so you watch it in real time without an extra click.
- **Followup button** on a task detail dialog: prompts for new text, calls a new endpoint `POST /api/tasks/<id>/followup`. Wire it through `endy watch followup`.
- **Authentication beyond Tailscale** — currently any device on the user's Tailnet can use the dashboard. Add a simple shared-token check (header or query param) for the case where the user shares their Tailnet with others.

**Files to touch:** `web/server.py`, `web/index.html`. The bash plumbing doesn't change.

---

### 5. `endy chat resume <id>` — interactive resume

Combination of #3 and the followup primitive. Open an interactive tmux window that loads the prior session via the agent's native `--resume` (hermes/opencode) or via context injection (cmd). User attaches and continues conversing.

**Acceptance:** finish a hermes task; `endy chat resume <id>`; the new tmux window has hermes already loaded with prior context; user types a message, hermes answers as if the session never ended.

---

### 6. Audio interface (`endy speak <agent>`)

Defer until 1-5 are done. Sketch:

- Local STT via whisper.cpp or `WhisperX`.
- Local TTS via piper / mac `say` / ElevenLabs.
- `endy speak <agent>` records mic, transcribes, sends as prompt, speaks response.
- Loop: each utterance is a followup of the prior. Auto-end on silence.

**Out of scope for this iteration** unless explicitly asked. Mentioned for completeness.

---

### 7. Hermes mobile gateway (PARKED — do not unparked without explicit user request)

R1 and R2 research is in `.logs/task-20260505-12{3945-66df,4000-ec37}.log`. Summary in [hermes/README.md](hermes/README.md). The blockers were security configuration complexity, not technical capability. If the user reopens, the gating list is:

- Dedicated phone number (or self-chat mode)
- Custom toolset (default `safe` preset is wrong)
- Explicit `WHATSAPP_ALLOWED_USERS` (empty allowlist = allow all is a real CVE class — GH #15108)
- `approvals.mode: manual` for destructive ops
- `whatsapp.unauthorized_dm_behavior: ignore`
- Disable individual `write_file`/`patch` tools per `hermes tools`

---

## Polish / nice-to-haves (not blocking)

- Tab completion for `endy` (zsh + bash). Sketch in `scripts/endy-completion.sh`.
- `endy doctor` should also check whether `cmd` has a model set (`cmd status` parses) and warn if it falls back to default.
- README has a per-CLI gotcha table; expose the same content via `endy help <agent>` (e.g. `endy help cmd` shows the cmd gotchas).
- Currently `_endy-preview.sh` re-implements the status-classification logic. Refactor into a shared library file sourced by both `endy-watch.sh` and `_endy-preview.sh`. (Today they're in sync because we update both — easy to forget.)

---

## Why we don't `tmux send-keys` the prompt

Earlier versions of `spawn-long-task.sh` used:

```bash
tmux new-window -t endy -n task-... -c <cwd>
tmux send-keys -t endy:task-... "{ <agent> '<huge prompt>' ; printf ENDY_EXIT=%d ... } 2>&1 | tee LOG" C-m
```

This **silently hangs for prompts >2KB**: tmux types each character into the new shell's input buffer, the shell parses character by character, and the C-m (Enter) never gets accepted because the parser is still mid-word. The window shows the partially-typed command at a `%` shell prompt forever. Nothing in stdout, nothing in the log file, no ENDY_EXIT marker. From the outside it looks like the agent is stuck — actually it never started.

The fix is in current code: pass the full shell command directly as the third argument to `tmux new-window`, and let the prompt be expanded via `"$(cat <prompt-file>)"` at runtime inside the new window's shell. The literal command string tmux receives is small (~200 bytes), and ARG_MAX in the runtime expansion is ~256KB on macOS — plenty for any real prompt.

**Don't undo this.** If you need to set environment variables or run setup code in the spawned window, do it as additional shell statements inside the same `tmux new-window` command argument, NOT via subsequent send-keys.

---

## Files that should NOT be committed to the repo

`.gitignore` covers these but the implementing agent should know:

- `.logs/` — every spawned task writes here, may contain sensitive prompts/output.
- `.claude/` — Claude Code session metadata (this conversation's tooling).
- `node_modules/`, `mcp-shims/node_modules/` — dependencies.
- `.env*` — secrets.
- `*.bak.[0-9]*` — install.sh's backups when rewriting existing files.

If you find any of those checked in by accident, they leaked. Open an issue.

---

## Memory / context that lives outside this repo

The user has a Claude Code memory store at `~/.claude/projects/-<flattened-endy-path>/memory/`. Relevant entries:

- `project_endy.md` — the multi-agent stack project state.
- `user_stack.md` — what CLIs the user has installed and their versions.
- `feedback_personas_optional.md` — personas are options, not obligations.
- `feedback_default_delegate.md` — default delegate is cmd + Kimi K2.6 (with caveats).
- `feedback_tmux_commands.md` — always print explicit tmux commands.
- `feedback_cmd_kimi_limits.md` — switch to opencode for heavy-research tasks.

These influence how Claude Code (the user's main IDE agent) interacts with this repo. They're not strictly needed for you to do the work, but if you encounter behaviour from Claude Code that seems oddly specific, those memories explain it.

---

## Where to start

If you have one slot of work, do **#1 (verify followup smoke tests)** — it's the only piece in critical path that's unverified, and verifying it tells you whether #2 and #3 can build on a stable foundation.

If you have a half-day, also tackle **#2 (parent_task display)** — it's small and removes a real UX friction.

Anything else, ask the user before starting.
