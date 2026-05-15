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

## Phase 4 — Auto-detection of exhaustion (shipped)

Detects exhaustion from CLI stderr signals and fires `endy handoff`
automatically — closing the loop on the "never run out of tier" pitch.

What landed:

- `scripts/lib/exhaustion.sh` — per-agent signal detector, single
  function `_endy_detect_exhaustion <agent> <log-path>` returning a
  short reason string (e.g. `rate_limit_exceeded`, `max_turns`,
  `provider_quota`, `auth_failed`, `auth_required`, `credit_exhausted`,
  `model_unavailable`) or empty. Covers gemini, opencode, cmd, hermes,
  claude, codex.
- `scripts/auto-handoff.sh` — orchestrator. Reads task meta + log,
  checks ENDY_EXIT≠0 + exhaustion signal + opt-outs, calls `endy
  handoff <id> --reason "auto: <signal>"`. Appends a clear
  `[endy] auto-handoff triggered: agent=X reason=Y` line to the parent
  log so the trail is visible.
- `scripts/spawn-long-task.sh` — appends `scripts/auto-handoff.sh
  <task-id>` to INNER_CMD after the agent exits and ENDY_EXIT lands.
  New flag `--no-auto-handoff` records `auto_handoff=0` in the task
  meta to opt out per-task.
- Opt-outs (in order checked): `ENDY_AUTO_HANDOFF=0` env, `auto_handoff=0`
  in meta, `<cwd>/.endy/no-auto-handoff` marker file, handoff_chain
  depth ≥ 5 (loop prevention).
- `tests/smoke-auto-handoff.sh` — 31 checks: 15 detector unit tests
  (per agent + negative cases), 6 E2E (synthesized fake exhausted task
  → handoff fires → child meta verified), 5 opt-out / loop-prevention
  cases, 1 false-positive guard. Verified passing on WSL/Ubuntu.

Signal coverage per agent (the exact patterns are in
`scripts/lib/exhaustion.sh`):

| CLI | Reasons emitted |
|---|---|
| gemini | `rate_limit_exceeded` (RESOURCE_EXHAUSTED / quotaExceeded / 429), `auth_required` (GEMINI_API_KEY missing) |
| opencode | `provider_quota` (ProviderModelNotFoundError / rate_limit_exceeded / insufficient_quota), `auth_failed` (Unauthorized / InvalidApiKey) |
| cmd | `max_turns` (Reached maximum conversation turns), `credit_exhausted` (insufficient credit / payment required), `auth_failed` (Unauthorized) |
| hermes | `rate_limit_exceeded` (429 / too many requests), `model_unavailable` (model_not_supported / invalid_request_error) |
| claude | `rate_limit_exceeded` (usage_limit_exceeded / rate_limit_error / 429), `auth_failed` (authentication_error / invalid api key) |
| codex | `rate_limit_exceeded`, `auth_failed` |

Design principle: false positives are worse than missed handoffs.
Generic markers like `Error:` / `Exception:` are deliberately NOT in
the detector — the patterns are taken from the specific phrases each
CLI emits in real exhaustion events.

## Phase 5 — Git worktree isolation (next)

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
| 2 | `c227761` (endy), `466a473`, `6138d3d`, `4248c57`, `55dfba1`, `74b5a9e` (multiplexor PyPI rename) |
| 3 | `3bf6940` (endy state + skill + spawn auto-injection) |
| 4 | _this commit_ (auto-handoff: exhaustion.sh + auto-handoff.sh + smoke) |
