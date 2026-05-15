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
    "worktree_origin_cwd": "...", "worktree_inherited": "1",
    "worktree_commits_ahead": 3,
    "worktree_porcelain_modified": 2,
    "worktree_porcelain_untracked": 1,
    "worktree_origin_branch": "main",
    "worktree_chain_size": 2
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

## When you're in a worktree (Phase 5.2)

If `self.worktree_dir` is non-empty in the JSON / your prompt block contains a `Git worktree: branch \`endy/task-…\`` line, you are running in an isolated git worktree. You can edit any file freely — a parallel task on the same project cannot stomp your edits (it has its own checkout).

Five live counters tell you the shape of your work right now:

| Field | Meaning | When it matters |
|---|---|---|
| `worktree_commits_ahead` | Commits you (or earlier agents in this chain) made that aren't in the origin repo's HEAD | Decide whether the work needs review/merge before handoff |
| `worktree_porcelain_modified` | Tracked files with uncommitted edits | Decide whether to `git commit` before handing off |
| `worktree_porcelain_untracked` | New files not yet `git add`-ed | Same — uncommitted state never crosses the handoff cleanly |
| `worktree_origin_branch` | Branch name of the main repo (the merge target) | Mentioned when commits_ahead > 0 |
| `worktree_chain_size` | How many tasks in your handoff chain share this worktree | If > 1, you're inheriting work — be careful not to rewrite history |

### Commit-before-handoff heuristic

Before issuing `endy handoff <your-id> --to <agent>`:

- **porcelain_modified > 0 or porcelain_untracked > 0** → commit (or `git stash`) first. Uncommitted edits are bound to your tmux pane; the next agent inherits the same dir but won't see anything you didn't commit. Lossy by default.
- **porcelain == 0 and commits_ahead > 0** → don't commit, you're done. The next agent will see your commits at HEAD via `git log` and pick up from there.
- **porcelain == 0 and commits_ahead == 0** → the agent before you may have committed, or there's nothing to hand off but the prompt context. Either is fine.

### Self-inspection commands

The same data is reachable from inside your task without re-running `endy state`:

```bash
endy watch wt-log <your-task-id>          # commits you made
endy watch wt-diff <your-task-id>         # diff vs origin HEAD
endy watch wt-diff <your-task-id> --stat  # just the diffstat
endy watch worktrees --format json        # all active wts, with counters
```

`<your-task-id>` is `self.task_id` from `endy state`, or the prefix from your tmux window name (`task-<id>` → strip `task-`).

### Inspecting peer worktrees

If another agent is running in parallel on the same project, you can see their state without disturbing them:

```bash
endy watch worktrees --all                # all wts across every session
endy watch wt-diff <peer-task-id>         # what did THEY change?
```

This is read-only — you cannot push commits into their branch. Coordinate via `endy handoff` if you need to integrate their work.

## What this skill is NOT

- Not for spawning, killing, or driving agents — see `endy-delegate` and `endy-live`.
- Not for setting up the multi-agent stack — see `endy install` and `AGENTS.md`.
- Not authoritative on rate limits for agents whose source is `unknown` — Phase 2 will tighten this.
