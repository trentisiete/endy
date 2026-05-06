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
- ✅ `endy watch list / tree / dir / log / view / follow / browse / panel / kill` — all working.
  - Multiple parallel `follow` windows confirmed (TASK-ALPHA + TASK-BRAVO simultaneously).
  - Browse uses fzf 0.71+ with `--preview-window=right:50%:wrap:follow` for live tail in the right pane, and supports `--cwd` / `--orch` filters.
  - `^Y` in browse copies task id to system clipboard via pbcopy.
- ✅ Orchestrator/source metadata — new spawns record `orchestrator`, `orchestrator_agent`, `origin_window`, `origin_pane`, `origin_cwd`; `endy watch tree` groups by orchestrator first and directory second.
- ✅ `endy orchestrator <name> --cwd <dir>` — opens additional orchestrator tmux windows with `ENDY_ORCHESTRATOR` exported so subagents are attributed to the right manager/workstream.
- ✅ `endy tmux-help` / `endy start` tmux hints — status line shows the key tmux commands and a persistent `tree` window auto-refreshes the orchestrator/directory view plus delete/window/chat/watch commands.
- ✅ `endy start --clean --no-attach` — recreates manager layout without attaching: window 1 `watch` runs `endy watch browse`, window 2 `docs` opens README/NEXT_STEPS, window 3 `tree` auto-refreshes `endy watch tree`, and stale `task-*`/`chat-*`/`follow-*`/`panel`/`tree`/`help`/`opencode`/`logs` windows are closed.
- ✅ `opencode serve` is now opt-in via `endy start --serve-opencode --logs`; it no longer appears as a noisy default manager window.
- ✅ `endy watch browse` is now active-task and chat-first: default view shows only active tasks/chats, `--all` includes history; Enter opens `endy watch chat <id>` and switches to it, `^O` opens chat in the background and keeps browse open, `^F` opens a live follow window, `^V` views, `^L` logs, `^K` kills.
- ✅ `endy watch kill-all` — closes matching task/chat/follow windows by `--agent`, `--cwd`, `--orch`, or explicit `--everything`, and prints the tmux commands for full-session shutdown.
- ✅ `ORCH` now supports `orchestrator_agent`: new tasks can display labels such as `orchestrator[codex]` or `mobile[cmd]`; manual spawns can set it with `--orchestrator-agent`. Old smoke-test labels (`smoke`, `verify`) remain in historical logs only.
- ✅ Web dashboard at `endy web` — Python stdlib server, SSE for live tasks list and log streams, POST `/api/tasks` spawns through the same `spawn-long-task.sh`. Smoke-tested end-to-end (`WEB-API-OK`).
- ✅ Status heuristics — `RUN`, `PENDING`, `DONE`, `DONE-ERR`, `FAIL(<n>)`, `ABANDONED`. The `DONE-ERR` heuristic catches `Reached maximum turns`, `Error:`, `Exception:`, `auto-rejecting`, `ProviderModelNotFoundError`, `Unauthorized`, `forbidden`, `model not found`. The `ABANDONED` detection looks for missing tmux window + no `ENDY_EXIT`.
- ✅ Persona files for opencode (`refactor`, `test-writer`) load correctly with `mode: all` and `permission:` grants.
- ✅ AGENTS.md is symlinked globally so Codex and `cmd` see it on every session.

---

## Remaining end-to-end verification

Only Hermes native resume still needs a live smoke. opencode and cmd followups are already smoke-tested with real tasks in `.logs/`.

- opencode parent `20260506-115916-2f59` → followup `20260506-115957-7554`, native `resume_id=ses_20345bfb1ffef6sbOL30HqrpE9`, output `ENDY-OPENCODE-FOLLOWUP-SMOKE`.
- cmd parent `20260506-115925-3bdf` → followup `20260506-120006-657a`, context injection, output `ENDY-CMD-FOLLOWUP-SMOKE`.

**Files:** `scripts/endy-watch.sh` (`cmd_followup`), `scripts/spawn-long-task.sh` (`--resume`, `--parent-task`).

**Strategy per agent:**

| Agent | Approach | How |
|-------|----------|-----|
| hermes | Native session resume | grep `^session_id: \d{8}_\d{6}_[a-f0-9]{6}$` from parent log → `hermes chat -Q --accept-hooks --resume <id> -q "<new>"` |
| opencode | Native via SQLite | `sqlite3 ~/.local/share/opencode/opencode.db "SELECT id FROM session WHERE directory='<cwd>' ORDER BY time_created DESC LIMIT 1"` → `opencode run --session <id> "<new>"` |
| cmd | **Context injection** (no headless resume exists) | Prepend last 80 lines of parent log + parent meta into the new prompt; spawn fresh |
| claude | Untested | TBD |

**Hermes acceptance check:**

1. `endy spawn hermes -- "Your name is FluffyTeapot. Just say 'OK FluffyTeapot here.'"`.
2. Wait for `DONE`.
3. `endy watch followup <hermes-parent-id> -- "What's your name?"`.
4. Output should contain `FluffyTeapot`, and the followup `.meta` should have `parent_task=<original-id>` plus `resume_id=<hermes-session-id>`.

**Risks to watch for:**

- hermes session_id might not appear in the log if the run was killed mid-stream (only emitted at clean exit). Followup should warn and fall back to context injection.
- cmd's context-injection currently does `tail -n 80 | head -c 4000`. Tune if the model's continuation quality is poor.

---

## Recent verification notes

### Multi-orchestrator attribution with live subagents

**Done 2026-05-06.** Files: `bin/endy`, `scripts/spawn-long-task.sh`, `scripts/spawn-chat.sh`, `scripts/endy-watch.sh`, `web/server.py`.

**Verified:**

- `endy tmux-help` applied the status line; `tmux show-options -t endy status-right` contains `Ctrl-b n/p next/prev` and `Ctrl-b & kill window`.
- `endy orchestrator smoke --cwd /Users/naudit/Downloads/endy --agent opencode --no-attach` created `endy:orch-smoke`; cleaned up with `tmux kill-window -t endy:orch-smoke`.
- opencode smoke task `20260506-130607-9170` and cmd smoke task `20260506-130605-abed` both recorded `orchestrator=smoke`.
- `endy watch list --orch smoke` showed both tasks with `ORCH=smoke`.
- `endy watch tree --orch smoke --all` grouped them under `/Users/naudit/Downloads/endy`.
- `endy watch chat 20260506-130607-9170 --no-attach` opened chat `20260506-130835-2783`, preserved `ORCH=smoke`, linked `parent_task=20260506-130607-9170`, then was closed with `endy watch kill`.
- `endy start --clean --no-attach` recreated a clean tmux session with manager windows; after the chat-first/no-serve update the intended default is `0 orchestrator`, `1 watch`, `2 docs`, `3 tree`.
- Verification agents launched through endy: cmd `20260506-185159-a448`, opencode `20260506-185200-4209`, both with `orchestrator=verify`.
- cmd returned `CMD-VERIFY-PASS`. opencode returned `OPENCODE-VERIFY-PASS`; endy classified it as `DONE-ERR` because the verifier tried one invalid `rg --include` command before correcting itself.
- Follow-up fix from verification: `web/server.py` now mirrors CLI `ABANDONED` detection by checking whether the task tmux window still exists; `web/index.html` renders an `ABANDONED` status class.

**Still worth a manual pass:** open `endy watch browse --orch smoke` in a real terminal and press `^O`; fzf itself is interactive, so the automated smoke covered the underlying `watch chat` path instead.

---

### Parent links in CLI and web

**Done 2026-05-06.** When a task has `parent_task=<id>` in its `.meta`, both the CLI table and the web dashboard expose it.

**Files touched:**

- `scripts/endy-watch.sh` — `cmd_list` parent column.
- `web/server.py` — `parent_task`, `resume_id`, and `kind` JSON fields.
- `web/index.html` — parent marker in the task card.

**Verified:** real opencode/cmd followups show parent refs in `endy watch list` as `115916-2f59` / `115925-3bdf`. Web API exposes `parent_task`, `resume_id`, and `kind`; the dashboard renders parent markers.

---

### `endy chat <agent>` — persistent interactive sessions

**Basic implementation done 2026-05-06.** The user has asked for an "I want to actually talk to a running agent" mode.

- `endy chat <agent> [--persona X]` opens a NEW tmux window running the agent in **interactive** mode (no `-Q` / `-p` / `-q`).
- `tmux pipe-pane -o` captures output to `.logs/chat-<id>.log`.
- Meta writes `kind=chat`, `log=chat-<id>.log`, and normal `task-<id>.meta`.
- `endy watch list` shows active chats as `CHAT`; killed chats become `FAIL(130)` with last line `(interactive pane captured)` to avoid raw TUI control noise.
- `endy watch follow` works on chat sessions too — the log file is the source of truth.

**Files touched:**

- New function in `bin/endy`: `cmd_chat`.
- New sibling script: `scripts/spawn-chat.sh`.
- `endy-watch.sh` `log_status` treats live chat sessions as `CHAT`.

**Verified:** `endy chat opencode --cwd /Users/naudit/Downloads/endy` created `20260506-120122-1142`, showed as `CHAT` in `endy watch tree`, captured the pane, and was closed with `endy watch kill`.

**Risks:**

- `tmux pipe-pane` is per-pane, and panes don't survive `tmux kill-window`. If user kills the window, log capture stops — but the previously-written log is intact.
- Some CLIs use `tput`/cursor codes heavily in interactive mode; the captured log will have ANSI noise. Reuse the existing `strip_ansi` filter in display layers.

---

### Web dashboard: spawn-from-browser polish

The dashboard already has a "+ Spawn" form that POSTs to `/api/tasks`. Improvements:

- **Dropdown for agent/persona/model** populated from disk (`~/.codex/agents/*.toml` etc.) — currently the persona is a free-text input.
- **Server-Sent Events for the new task's log** auto-opening when you submit, so you watch it in real time without an extra click. **Done 2026-05-06.**
- **Followup button** on a task detail dialog: prompts for new text, calls a new endpoint `POST /api/tasks/<id>/followup`. **Done 2026-05-06.**
- **Authentication beyond Tailscale** — currently any device on the user's Tailnet can use the dashboard. Add a simple shared-token check (header or query param) for the case where the user shares their Tailnet with others.

**Files to touch:** `web/server.py`, `web/index.html`. The bash plumbing doesn't change.

---

### `endy chat resume <id>` — interactive resume

**Update 2026-05-06:** this now exists as `endy watch chat <id>`, with `^O chat` in `endy watch browse`.

Open an interactive tmux window that loads the prior session via the agent's native `--resume` (hermes/opencode) when available. `cmd` still has no reliable headless interactive resume, so it opens a fresh CommandCode terminal in the same cwd and records `parent_task=<id>`.

**Still to verify:** finish a hermes task; `endy watch chat <id>`; the new tmux window has hermes already loaded with prior context; user types a message, hermes answers as if the session never ended.

---

### Audio interface (`endy speak <agent>`)

Defer until Hermes resume is verified and the manager UX has settled. Sketch:

- Local STT via whisper.cpp or `WhisperX`.
- Local TTS via piper / mac `say` / ElevenLabs.
- `endy speak <agent>` records mic, transcribes, sends as prompt, speaks response.
- Loop: each utterance is a followup of the prior. Auto-end on silence.

**Out of scope for this iteration** unless explicitly asked. Mentioned for completeness.

---

### Hermes mobile gateway (PARKED — do not unpark without explicit user request)

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

If you have one slot of work, verify **Hermes native followup/resume** from the acceptance check above. opencode/cmd followups, parent display, chat, browse, tree, and kill-all are already implemented and smoke-tested.

If you have a half-day, add `endy` shell completion and `endy help <agent>` pages. Those are polish, not blockers.

Anything else, ask the user before starting.
