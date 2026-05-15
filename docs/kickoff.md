# Kickoff — endy + multiplexor

You're new to this project. Read this once, then refer back as needed.
Target: be productive in 15 minutes.

Companion docs (lighter reads first):

- [README.md](../README.md) — the pitch + 60-second demo
- [docs/roadmap.md](roadmap.md) — phases shipped / planned, commit hashes
- [docs/operations.md](operations.md) — full command reference + watch family
- [docs/cli-gotchas.md](cli-gotchas.md) — per-CLI integration quirks
- [AGENTS.md](../AGENTS.md) — the file every CLI agent auto-loads on startup

---

## 1. What this is

A control plane that lets a coding task survive across multiple agent
CLIs. When one CLI runs out of tier (rate limit, quota, max turns,
auth expired), endy hands the work — with full context — to the next
eligible agent. The chain is recorded; you can trace `taskA(opencode)
→ taskB(cmd) → taskC(hermes)` end to end.

Two repositories, designed to compose:

- **`endy`** (this repo) — the **runtime**. tmux sessions, per-task
  logs, the `endy handoff` command, the `endy state` snapshot, the
  web dashboard, the auto-detection of exhaustion.
- **[`multiplexor`](https://github.com/trentisiete/multiplexor)** — the
  **routing policy**. Knows which CLIs are installed, scores them by
  `priority + tier_bonus`, marks exhausted ones, picks the next.
  Published on PyPI as `endy-multiplexor`.

You can use either alone, but they're designed together. `endy install`
bootstraps multiplexor automatically.

---

## 2. Architecture in one diagram

```
USER / ORCHESTRATING AGENT
        │
        │  endy spawn <agent> -- "<prompt>"
        │  endy handoff <id> [--to <agent>]
        ▼
┌─────────────────────────────────────────────────────────┐
│ endy/bin/endy ─── dispatch ─── scripts/*.sh             │
│ ├ spawn-long-task.sh   spawns into tmux window          │
│ ├ handoff.sh           composes continuation prompt     │
│ ├ auto-handoff.sh      Phase 4: triggers handoff on     │
│ │                      exhaustion signal                │
│ ├ state.py             endy environment snapshot         │
│ └ lib/                 session naming, worktree, etc.   │
└─────────────────────────────────────────────────────────┘
        │                              │
        │  ENDY_HANDOFF_RESOLVER        │ writes
        ▼                              ▼
multiplexor-next-provider       .logs/per-dir/<session>/
(picks the next agent)          ├ task-<id>.meta
        │                       ├ task-<id>.log
        ▼                       └ task-<id>.prompt.md
[opencode | cmd | claude |
 hermes | gemini | bash stub] ← these run inside tmux windows
```

The `.logs/task-<id>.{log,meta,prompt.md}` contract is the source of
truth. Any frontend (CLI, web dashboard, future MCP server) reads from
the same files.

---

## 3. What's shipped

Five phases done. Latest first (most context for you):

| Phase | Title | Lands in |
|---|---|---|
| 5 | Git worktree isolation per spawn | `scripts/lib/worktree.sh`, `--worktree`/`--no-worktree` flags |
| 4 | Auto-detection of exhaustion | `scripts/lib/exhaustion.sh` + `scripts/auto-handoff.sh` |
| 3 | `endy state` snapshot + auto-injection in spawn prompts | `scripts/state.py`, `codex/skills/endy-state/` |
| 2 | Multiplexor bootstrap + auto-routing resolver | `scripts/install.sh` + `multiplexor-next-provider` binary |
| 1 | `endy handoff <id> --to <agent>` (manual handoff) | `scripts/handoff.sh` + watch/dashboard rendering |
| 0 | Reposition: pitch, README, license, docs split | `README.md`, `docs/`, `LICENSE` |

Phase 6 (adoption / launch) is the only open one — bumping npm,
recording the GIF, writing the Show HN post. See
[docs/roadmap.md](roadmap.md) for the full list and closing commits.

---

## 4. Repo map (where to look)

```
endy/
├── bin/endy                        the single CLI entry point — dispatches subcommands
├── scripts/
│   ├── install.sh                  endy install (idempotent, bootstraps multiplexor too)
│   ├── start.sh                    `endy start` / `endy overview` tmux layout
│   ├── spawn-long-task.sh          the primitive every spawn flows through
│   ├── handoff.sh                  composes continuation prompt, calls spawn
│   ├── auto-handoff.sh             Phase 4 orchestrator (post-ENDY_EXIT hook)
│   ├── state.py                    `endy state` snapshot builder (Phase 3)
│   ├── endy-watch.sh               every `endy watch *` subcommand
│   ├── live.sh                     `endy live` interactive pane orchestration
│   ├── tmux-help.sh                tmux key-binding status line
│   ├── postinstall.js              npm postinstall (chmod + reminder)
│   └── lib/
│       ├── session.sh              per-dir session naming + log dir derivation
│       ├── worktree.sh             Phase 5: git worktree helpers
│       ├── status.sh               status heuristics (RUN/DONE/DONE-ERR/...)
│       ├── exhaustion.sh           Phase 4: signal detection per agent
│       └── timefmt.sh              date / runtime / random id helpers
├── codex/
│   ├── agents/                     codex personas (architect, reviewer, researcher)
│   ├── skills/
│   │   ├── endy-delegate/SKILL.md  delegate-to-subagents reference
│   │   ├── endy-live/SKILL.md      interactive pane orchestration (PRIMARY skill)
│   │   └── endy-state/SKILL.md     environment snapshot reference
│   └── config.snippet.toml         appended to ~/.codex/config.toml on install
├── opencode/agents/                opencode personas (refactor, test-writer)
├── commandcode/agents/             cmd personas (taste-reviewer)
├── web/
│   ├── server.py                   stdlib HTTP + SSE dashboard
│   └── index.html                  the dashboard UI
├── tests/
│   ├── smoke-handoff.sh                Phase 1
│   ├── smoke-multiplexor-handoff.sh    Phase 2 (17 checks)
│   ├── smoke-auto-handoff.sh           Phase 4 (31 checks)
│   ├── smoke-real-agents.sh            Real-agent context propagation
│   ├── smoke-state.sh                  Phase 3
│   └── smoke-install-memory.sh         install.sh memory blocks
├── docs/
│   ├── operations.md               full command reference
│   ├── cli-gotchas.md              per-CLI quirks (`endy help <agent>` reads this)
│   ├── demo.md                     GIF recording script
│   ├── roadmap.md                  phases + commits
│   └── kickoff.md                  this file
├── README.md                       pitch + status table
├── AGENTS.md                       agent-facing global context (symlinked into ~/.codex/AGENTS.md etc.)
├── LICENSE                         MIT
└── package.json                    npm metadata (publishes to @noetiklab/endy)

multiplexor/                        sibling repo
├── multiplexor/
│   ├── cli.py                      every subcommand
│   ├── config.py                   YAML loader (with no-PyYAML fallback)
│   ├── providers.py                Provider dataclass + parsing
│   ├── router.py                   ranked_statuses / candidates / select_provider
│   ├── runner.py                   subprocess.run with timeout
│   └── state.py                    state.json: last_provider, exhausted marks
├── config.example.yaml             (mirrored at multiplexor/config.example.yaml)
└── tests/                          39 unit tests (unittest discover)
```

---

## 5. How we work here

### Conventions

- **Indentation:** 1 tab = 4 spaces (per user CLAUDE.md global).
- **No emojis** in code, commits, or PRs. User preference.
- **Comments:** explain WHY (non-obvious constraints, workarounds, the
  bug that caused this branch). Don't restate WHAT the code does.
- **Type hints:** only where the project already uses them (Python in
  multiplexor uses them sparingly; bash has none).
- **Bash style:** `set -euo pipefail` at the top; quote variables;
  use `printf` over `echo` for anything with backslashes or special
  chars; `$(cmd)` over backticks.
- **Spanish vs English:** user prefers Spanish in chat. Code, comments,
  commit messages, and docs in English (it's a public repo).

### Commits

Conventional-ish:

```
feat(area): one-line summary in lowercase

Why. The constraint that drove this. The bug that surfaced it. The
shape of the fix. Tradeoffs you considered. What you preserved.

Bullets when they help:
  - Specific behavior or file changed
  - Tradeoff explanation
  - Test coverage notes

Verified <how> (e.g. WSL/Ubuntu tmux 3.4, all smokes 31/31, etc.).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Areas seen so far: `feat`, `fix`, `docs`, `chore`, `test`. Scopes:
`handoff`, `phase4`, `install`, `watch`, `skill`, `readme`, `config`.

### Multi-agent collaboration (we have at least 2 agents touching this repo concurrently)

Critical rule: **never overwrite files another agent is modifying.**
Check `git status` before editing.

If a file shows `M` and you didn't modify it, it's the other agent's
working tree. Leave it alone. Do your work in different files, or wait
until the other agent commits.

When a file you need IS being modified by another agent:
1. Don't touch it. Find another way.
2. If you must, ASK the user first.
3. Surface the conflict — "the other agent is in scripts/X, I'll come
   back to it once they push."

Anti-pattern observed: an agent ran into a partial state, "tidied"
something they didn't fully understand, and clobbered in-flight work
the user had to redo. Don't do this.

### Testing

Three layers:

1. **Unit-ish** — multiplexor's `tests/` (`python3 -m unittest discover
   -s tests`). 39 tests, fast.
2. **Smoke (offline)** — `tests/smoke-*.sh` use the `bash` stub agent,
   no real-agent quota burned. Verifiable on any WSL/Ubuntu machine
   with tmux. Each smoke is self-contained, idempotent, cleans up.
3. **Smoke (real agent)** — `tests/smoke-real-agents.sh`. Burns a few
   tokens per agent on tiny prompts. Run manually after big changes.

Default: write an offline smoke for every behavior change. Real-agent
smokes are reserved for "did this CLI's auth/contract change".

When you touch detector regex or exhaustion patterns, ALWAYS run
`tests/smoke-auto-handoff.sh` — 31 checks catch most regressions.

### Where new work belongs

| Type of change | Lands in |
|---|---|
| Handoff prompt composition | `scripts/handoff.sh` |
| New spawn flag / agent | `scripts/spawn-long-task.sh` + maybe `bin/endy` for dispatch |
| New exhaustion signal | `scripts/lib/exhaustion.sh` + add a case in `tests/smoke-auto-handoff.sh` section 1 |
| Routing policy change | `multiplexor` repo (different repo, different commit) |
| Watch/dashboard rendering | `scripts/endy-watch.sh`, `web/server.py`, `web/index.html` |
| Agent's mental model | `codex/skills/<skill>/SKILL.md` (re-symlinked by `endy install`) |
| User-facing docs | `README.md` for the pitch, `docs/*` for reference |

---

## 6. Design principles to preserve

These were decided after real incidents. Don't unwind them without a
strong reason.

### 6.1. multiplexor is the policy; endy is the runtime

Don't pollute either side with the other's concerns. multiplexor never
opens a tmux window. endy never decides which agent to route to (it
asks multiplexor).

The contract between them: `multiplexor-next-provider <prev> <task>
<cwd>` prints the next agent name. `multiplexor status --json <agent>`
returns routing state. That's it. Keep it small.

### 6.2. False positives in the exhaustion detector are worse than misses

`scripts/lib/exhaustion.sh` patterns are CLI-specific phrases — not
generic `Error:` / `Exception:`. Rationale: auto-routing a healthy task
to a different agent burns the next agent's context for nothing. If a
signal isn't ironclad, leave it out; the user can `endy handoff --to`
manually.

### 6.3. Static catalogs drift; procedures don't

The endy-live SKILL deliberately does NOT enumerate "models available
in cmd / opencode / gemini" — those rotate. It gives the agent the
*procedure*: open `/model`, capture, web-search what you don't know,
pick. The CLI's `/model` picker is the source of truth.

The exception: structural facts (cmd has no `--model` flag, hermes
needs `-Q`) — those are stable, those we document.

### 6.4. Per-directory tmux sessions, not one global session

Old behavior: every project shared `endy:`. New behavior (since v0.5):
`endy-<basename>` per cwd, with `endy overview` for the global
aggregator. Don't write back to the assumption of one global session.

### 6.5. `set -euo pipefail` + robust meta reading

Bash scripts use `set -euo pipefail`. When reading optional meta
fields, use the pattern `{ grep ... || true; } | head -1 | cut -d= -f2-`
so pipefail doesn't abort the script on a missing-but-optional field
(`persona=`, `model=`, `handoff_chain=`). This bit us once — see
commit `9d1274e`.

### 6.6. Local models are NOT native endy agents

`endy spawn ollama` doesn't exist on purpose. ollama lacks the tool
surface (Edit/Bash/Read) of cloud agents; forcing it into the spawn
contract would be a half-agent. Local-model story lives in:

- hermes (configure ollama as a backend provider in `~/.hermes/config.yaml`)
- the host CLI's `/model` picker (codex `--oss --local-provider`, cmd's Ollama provider)
- multiplexor's local fallback for its own `delegate` (separate code path; endy doesn't use it)

### 6.7. The `endy install` shell-rc story

`ENDY_HANDOFF_RESOLVER` is written to BOTH `~/.bashrc` (interactive)
AND `~/.profile` / `~/.zshenv` (non-interactive + login). Reason:
Ubuntu's default `~/.bashrc` has an early-return guard for
non-interactive shells, so `bash -lc 'endy handoff'` from a script
would otherwise miss the var. See commit `32d2aa9`.

---

## 7. The three skills (Codex / Claude / Hermes auto-load these)

`endy install` symlinks each skill into the canonical paths
(`~/.agents/skills/`, `~/.codex/skills/`, `~/.claude/skills/`,
`~/.hermes/skills/`). The skills define how the agent thinks about
the system.

| Skill | When to invoke |
|---|---|
| **`endy-live`** (PRIMARY) | Open a CLI in a tmux pane and drive it. Model switching, slash commands, picker navigation, auth, lifecycle. The day-to-day skill. |
| **`endy-delegate`** | Hand work between agents (spawn / followup / handoff). The cross-agent flows. |
| **`endy-state`** | Inspect the environment of a task (chain, peers, tier headroom). Read-only. |

If you're touching skill files: they are USER-VISIBLE on first invocation
and they shape future-agent behavior. Be conservative. Test that
`endy help <agent>` still extracts the right per-CLI block from
`docs/cli-gotchas.md` (it greps for `### <agent>` headings).

---

## 8. CLI surface at a glance

The commands you'll use most:

```bash
endy install                            # bootstrap everything (idempotent)
endy doctor                             # what's installed + auth + sessions
endy start                              # tmux session for this cwd
endy overview                           # global all-session view

endy spawn <agent> -- "<prompt>"        # detached task, returns id
endy ask   <agent> "<prompt>"           # short blocking call
endy chat  <agent>                      # interactive tmux window
endy handoff <id> [--to <agent>]        # transfer to a different agent
                                        # (--to optional if resolver wired)
endy live open <name> <agent>           # named interactive pane
endy live send <name> "<text>"          # type into the pane
endy live capture <name>                # read the pane

endy state [--task-id <id>] [--format json|prompt|human]
endy watch tree | list | follow <id> | view <id> | kill <id>
endy watch followup <id> -- "<prompt>"  # same-agent native resume

endy web                                # web dashboard, default Tailnet IP
```

Multiplexor surface:

```bash
multiplexor doctor
multiplexor status [name] [--json]
multiplexor delegate "task"             # run on best eligible
multiplexor next                        # mark current exhausted + launch next
multiplexor next-provider [PREV]        # pure query (the endy resolver target)
multiplexor reset                       # clear exhaustion marks
```

---

## 9. Open work

Phase 6 — Adoption / launch. The remaining items:

- [ ] Bump npm to 0.6.0+ once Phase 5 stabilises in real use.
- [ ] Record the demo GIF following `docs/demo.md` (user-side action).
- [ ] Write the Show HN / r/LocalLLaMA / Twitter copy.
- [ ] CHANGELOG.md at root (Keep-a-Changelog style).

Nothing blocking. The product is feature-complete on the "never run out
of tier" pitch.

---

## 10. What NOT to do (anti-patterns we've already burned on)

- **Don't add native ollama spawn** (or any local-model spawn) to endy.
  See §6.6. Route via hermes or the host CLI's `/model`.
- **Don't widen exhaustion regex** to catch generic `Error:` / `Exception:`.
  See §6.2. Patterns are specific phrases per CLI.
- **Don't hardcode `~/Downloads/endy/...` paths** in skills or scripts.
  Use `$ENDY_ROOT`, `endy <subcommand>`, or relative paths.
- **Don't store private user memory** in skill files. Skills are public
  via the symlinks; user memory is at
  `C:\Users\maria\.claude\projects\...\memory\` and stays local.
- **Don't enumerate models** in skill files. The catalog drifts.
  Procedure: `/model` + web-search. See §6.3.
- **Don't assume a single `endy` tmux session.** Use per-dir. See §6.4.
- **Don't touch a file another agent has modified.** Check
  `git status` first. See §5 "Multi-agent collaboration".
- **Don't push without explicit user OK.** The user's standing rule
  (their CLAUDE.md global): never commit or push without asking first
  on substantive changes. For small docs fixes the bar is lower, but
  bias toward asking.

---

## 11. First-day checklist for a new agent

If you're a fresh Codex/Claude session opening this repo:

1. Read this file (you're here).
2. Skim [README.md](../README.md) for the pitch.
3. Skim [docs/roadmap.md](roadmap.md) for what's shipped and the
   commit graph.
4. Run `git log --oneline -20` to see the last ~20 commits — most of
   them have detailed messages explaining the WHY.
5. Run `endy doctor` — confirms what's installed locally.
6. Run `tests/smoke-handoff.sh` and `tests/smoke-auto-handoff.sh` —
   confirms the core paths work on this machine.
7. Ask the user what they want before writing code.

That's the entire kickoff. Good luck.
