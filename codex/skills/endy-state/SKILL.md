---
name: endy-state
description: "Use this skill when you need to inspect the endy environment of a running task — handoff lineage (who handed work to whom and why), peers in the same and other endy sessions, and per-agent tier headroom (codex 5h/wk, opencode session cost) so you can pick the next agent to hand off to. The same data is auto-prepended to every spawn prompt as a '## endy environment' block, so use this skill when you need it on-demand or in JSON form."
metadata:
  short-description: Inspect endy environment, lineage, peers, and tier headroom
---

# endy-state — Inspect endy environment

`endy state` builds a snapshot of where the current task sits inside the endy multi-agent stack: handoff chain, peers, tier headroom. It is read-only — never spawns anything, never touches tmux state.

## When to use

- **You're mid-task and considering a handoff.** Run `endy state` to see which agents still have headroom (codex 5h+wk, opencode $/session) before picking `--to`.
- **You're an agent that just received a handed-off task.** The `## endy environment` block at the top of your prompt is the same data — but if you want it again on turn N, re-run `endy state` instead of re-reading the prompt.
- **You want the JSON for a dashboard or a smoke test.** `--format json` is the stable contract.

## Three formats

```bash
endy state                          # human-readable, default
endy state --format human
endy state --format json
endy state --format prompt          # the '## endy environment' block
```

`--task-id <id>` lets you inspect any task, not just self. Without it, `state.py` self-detects via `$TMUX_PANE` → tmux window name → `task-<id>`. If invoked outside tmux (no pane), the `self` block is omitted but peers/tiers still render.

## What you get

```
endy state
==========
task: 20260515-142312-a1b2  agent: claude
session: endy-noetiklab  cwd: /Noetiklab
orchestrator: demo (codex)

handoff chain (3rd link is you):
  1. codex — codex rate limit (5h window exhausted)
  2. gemini — gemini daily quota exhausted
  3. claude ← you
  reason: "gemini daily quota exhausted"

peers:
  same session: opencode on task-20260515-141100-9f02
  other session: endy-other-project (2 task windows)

tier headroom:
  codex:    plus  5h 87%  wk 91%   resets at 2026-05-15T17:10:00Z
  opencode: $0.42 session   model: claude-opus-4-7
  claude:   max   estimate-only
  gemini:   unknown
  hermes:   unknown
  cmd:      unknown
```

The `unknown` source on a tier means we have no signal for it yet — a
future expansion will add stderr-detected fallbacks (this is part of
[Phase 4 in the project roadmap](../../../docs/roadmap.md): auto-detection
of exhaustion from CLI stderr signals). Don't assume an `unknown` tier
is exhausted — assume nothing.

Tier data for the routed providers comes from `multiplexor status
--json [agent]` — a stable JSON contract that exposes
`exhausted_seconds_remaining` and the live `selected` provider. If
multiplexor is installed (it is, after `endy install`), `endy state`
queries it directly; otherwise the routing rows show as `unknown` and
the rest of the snapshot still renders.

## Auto-injection in spawn prompts

`scripts/spawn-long-task.sh` calls `endy state --task-id <new-task-id> --format prompt` before writing the prompt file, so every spawned agent sees the environment block at the top of its first prompt. Bypass with `--no-state` for offline stubs or strictly clean prompts.

That's why you don't need to invoke `endy state` on turn 1 of a handed-off task — the block is already there. Invoke it later turns to refresh (tier headroom changes per turn).

### Behavior during handoff

`endy handoff` spawns a new task via the same `spawn-long-task.sh`, so
the child gets its OWN fresh state block — generated from *its* point
of view (it sees itself as the new last link, the previous agent is
behind it in the chain, the cwd is inherited from the parent). The
block is not copy-pasted from the parent; it is recomputed.

The parent's full prompt (which itself starts with a `## endy
environment` block) is embedded verbatim inside the child's `--- original
task prompt ---` section, so the child can also see what context the
parent had — but the source of truth for "who am I right now" is the
child's own freshly generated block at the very top.

## JSON schema (stable)

```json
{
  "version": "1",
  "as_of": "2026-05-15T14:23:00Z",
  "self": {
    "task_id": "...", "agent": "...", "session": "...", "window": "...",
    "cwd": "...", "orchestrator": "...", "orchestrator_agent": "...",
    "spawned_at": "...", "meta_path": "...",
    "worktree_dir": "...", "worktree_branch": "endy/task-...",
    "worktree_origin_cwd": "...", "worktree_inherited": "1"
  },
  "lineage": {
    "handoff_chain": [
      {"task_id": "...", "agent": "codex", "reason": "...", "cwd": "..."}
    ],
    "parent_task": "...", "handoff_from": "...", "handoff_reason": "..."
  },
  "peers": {
    "in_session": [{"task_id": "...", "agent": "...", "window": "..."}],
    "other_sessions": [{"session": "...", "tasks": 2, "live_panes": 2}]
  },
  "tiers": {
    "codex":   {"source": "disk-rollout", "plan": "plus", "h5_pct": 87.0, "wk_pct": 91.0, "resets_at": "...", "ctx_pct": ...},
    "opencode":{"source": "disk-sqlite", "session_cost": 0.42, "model": "claude-opus-4-7"},
    "claude":  {"source": "estimate-only"},
    "gemini":  {"source": "unknown"},
    "hermes":  {"source": "unknown"},
    "cmd":     {"source": "unknown"}
  }
}
```

`version` is the contract — readers should tolerate unknown fields and bump only when adding required fields.

## What this skill is NOT

- Not for spawning, killing, or driving agents — see `endy-delegate` and `endy-live`.
- Not for setting up the multi-agent stack — see `endy install` and `AGENTS.md`.
- Not authoritative on rate limits for agents whose source is `unknown` — Phase 2 will tighten this.
