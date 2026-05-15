# Roadmap

What's done, what's coming, and why. This is the implementation-facing
companion to the [README](../README.md)'s pitch. Phase numbers are not
ship dates — they're an ordering of dependencies.

---

## Phase 0 — Reposition (shipped)

Stop selling "yet another multi-agent orchestrator" — the space is
crowded. Sell what's actually unique: cross-agent handoff over free
tiers, with a strict `.logs/` contract so any frontend can read state.

- README rewritten around the handoff pitch + GIF hero.
- Encyclopedic content moved to [`docs/operations.md`](operations.md)
  and [`docs/cli-gotchas.md`](cli-gotchas.md).
- LICENSE (MIT) added.
- Cross-link with [multiplexor](https://github.com/trentisiete/multiplexor).
- GitHub topics + homepage set.

## Phase 1 — Manual handoff (shipped)

The one command that defines the product: `endy handoff <id> --to <agent>`.

- `scripts/handoff.sh` reads the parent meta + log + prompt, builds a
  structured continuation prompt, and spawns a new task in the parent's
  tmux session. Meta records `handoff_from`, `handoff_chain`,
  `handoff_reason`.
- Offline `bash` stub agent (also exposed as `stub` and `noop`) for
  rehearsing the loop without burning real-agent credits.
- `--stop-parent` flag closes the rate-limited window in the same shot.
- Cross-agent followup-via-context-injection works for cmd (which has
  no headless resume).
- `endy watch tree` / `list` render the `↪ handoff from X` line.
- Web dashboard shows `↪ from <short>` badges and full chain panels.
- `tests/smoke-handoff.sh` exercises the full Phase 1 loop, no quota
  burned. Verified passing on WSL/Ubuntu tmux 3.4.

## Phase 2 — Automatic routing (shipped)

Make the handoff target automatic so `endy handoff <id>` works without
`--to`. One command to install, everything wired.

- `endy install` bootstraps multiplexor automatically (`pipx` → `uv
  tool` → `pip --user` in order of preference) from a local checkout
  (sibling dir or `MULTIPLEXOR_REPO`) or from the GitHub URL.
- `ENDY_HANDOFF_RESOLVER` exported to the shell rc as a managed marked
  block.
- multiplexor ships `multiplexor-next-provider` as a dedicated console
  script — endy's resolver hook executes the env var as a single
  binary, so the wrapper sidesteps the bash-quoting limit.
- `multiplexor next-provider [PREV] [TASK_ID] [CWD]` is the pure-query
  command. Marks PREV exhausted, returns next eligible, exits cleanly
  when nothing left. `--no-mark`, `--mode`, `--verbose`, `--for endy`
  available.
- `multiplexor status --json [name ...]` exposes the same routing state
  as machine-parseable JSON (with `exhausted_seconds_remaining` already
  computed) — the contract `endy state` consumes.
- `tests/smoke-multiplexor-handoff.sh` covers 17 checks: resolver
  standalone, full E2E, multi-hop bash → stub → noop chain, exhaustion
  exit, doctor surface.

## Phase 3 — Environment awareness (shipped)

A spawned agent should know who else is in the room. `endy state`
snapshots: who am I (task-id, agent, cwd), what handoff chain led here,
which peers are running in this session and others, and what tier
headroom each provider has.

- `scripts/state.py` builds the snapshot.
- `spawn-long-task.sh` prepends a `## endy environment` block to every
  spawn prompt; `--no-state` bypasses for one-off runs.
- `codex/skills/endy-state/` ships the skill so Codex auto-loads the
  context model and knows what `endy state` returns.
- Tier headroom for the routed providers comes from `multiplexor status
  --json <agent>` — the JSON contract was prepared during Phase 2.

## Phase 4 — Auto-detection of exhaustion (next)

Today the user (or an orchestrator) decides when to call `endy
handoff`. Phase 4 detects exhaustion from CLI stderr signals and fires
the handoff itself.

Provider-specific signals to watch for:

| CLI | Signal |
|---|---|
| gemini | `RESOURCE_EXHAUSTED`, HTTP 429 with `quota` |
| opencode | `ProviderModelNotFoundError`, `rate_limit_exceeded`, `insufficient_quota` |
| cmd | `Unauthorized` on credit, `Reached maximum conversation turns` |
| hermes | session terminator without `session_id` emission |
| claude | `usage_limit_exceeded`, `Anthropic API Error 429` |

Implementation plan:

- `scripts/lib/exhaustion.sh` — per-agent regex matchers, single
  function `endy_detect_exhaustion <agent> <log-path>` returning a
  reason string or empty.
- Hook in `spawn-long-task.sh` after `ENDY_EXIT=` lands: if the task
  exited non-zero AND a known exhaustion signal is in the tail, auto-
  invoke `endy handoff <id>` (which uses the resolver to pick the next
  agent). Emit a `[endy] auto-handoff: <prev> → <next>` line so the user
  knows it happened.
- Opt-out flag `--no-auto-handoff` on spawn and a global config knob.
- New smoke test `tests/smoke-auto-handoff.sh` simulating each
  exhaustion signal against the offline stub and verifying the chain
  fires automatically.

Risks: false positives. The signal list above is conservative — anything
ambiguous (generic `Error:` etc.) is not in scope. We'd rather miss a
real exhaustion than route on a false alarm.

## Phase 5 — Git worktree isolation (later)

Two agents working on the same files simultaneously is currently a
foot-gun. Phase 5 makes every `endy spawn` (optionally) create a fresh
git worktree under `.endy/worktrees/<task-id>/` so parallel tasks
literally cannot stomp each other.

- New flag `--worktree` on `endy spawn` (and default-on for orchestrator
  windows).
- Cleanup hook on `endy watch purge` / `endy stop` removes the worktree
  if no uncommitted changes remain.
- The resolver's view of "which cwd" stays at the original repo root;
  only the task's `cwd` flips to the worktree.

## Phase 6 — Adoption (later)

- multiplexor on PyPI (so `pip install multiplexor` works without the
  GitHub URL — the auto-install in `endy install` would prefer PyPI).
- endy 0.6.0+ on npm with a stable surface.
- Real GIF in `docs/media/handoff.gif` recorded from
  [`docs/demo.md`](demo.md).
- Public post: HN "Show HN: I run coding agents for €0/month" + Twitter
  thread + r/LocalLLaMA cross-post.

## Out of scope (for now)

- **WhatsApp / Hermes mobile gateway.** Security investigation done
  but parked.
- **MCP server mode.** The shim in `mcp-shims/` works; hybrid bash mode
  is the active path. Flip-able later.
- **Mobile-first app.** Tailscale + the web dashboard covers the
  "phone" story.

---

## Phase history (commits)

| Phase | Closing commits |
|---|---|
| 0 | `e67facb` (endy), `12c6e32` (multiplexor) |
| 1 | `acd167d`, `f892073`, `74360f5` |
| 2 | `c227761` (endy), `466a473`, `6138d3d`, `4248c57`, `55dfba1` (multiplexor) |
| 3 | (see `endy watch list` and the recent main log) |
