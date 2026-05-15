#!/usr/bin/env python3
# scripts/state.py — compose endy environment state for the running agent.
#
# Reads on-disk meta files + queries tmux + calls the per-agent stats helpers
# to produce a snapshot of:
#   - self (which task am I, in which session, under which orchestrator)
#   - lineage (handoff chain — agents that preceded me on this task)
#   - peers (other tasks in my session, other endy sessions)
#   - tiers (rate-limit headroom per agent: codex 5h/wk, opencode $/session, ...)
#
# Three output formats:
#   json   — machine-parseable, full data, stable schema (version field)
#   human  — pretty terminal printout for `endy state` invoked by hand
#   prompt — markdown block prepended to spawn prompts (## endy environment)
#
# Invocation shape:
#   state.py --task-id <id> --format {json,human,prompt}
#   state.py                 (self-detect via $TMUX_PANE, omit self if not in tmux)
#
# Exit codes:
#   0 ok
#   2 bad arguments
#   4 --task-id passed but no matching meta found
#
# No external deps. Imports only from the Python stdlib.

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = "1"
CHAIN_RENDER_CAP = 5
ENDY_ROOT = Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _run(cmd, timeout=2):
    """Run a command, return stdout (str) or '' on failure. Fail-silent."""
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=timeout)
        if r.returncode != 0:
            return ""
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


def _iter_log_dirs():
    """Yield every log dir endy knows about: .logs/ and .logs/per-dir/*/.

    Replicates the shell _iter_log_dirs() inline in handoff.sh / session.sh.
    """
    root = ENDY_ROOT / ".logs"
    if root.is_dir():
        yield root
        per_dir = root / "per-dir"
        if per_dir.is_dir():
            for d in sorted(per_dir.iterdir()):
                if d.is_dir():
                    yield d


def _iter_meta_files():
    """Yield every task-*.meta path under all known log dirs."""
    for d in _iter_log_dirs():
        for m in sorted(d.glob("task-*.meta")):
            if m.is_file():
                yield m


def _read_meta(path):
    """Parse a task-*.meta file into a dict (key=value lines)."""
    fields = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" not in line:
                continue
            k, _, v = line.partition("=")
            fields[k.strip()] = v.strip()
    except OSError:
        return {}
    return fields


def _find_meta_by_task_id(task_id):
    """Find a meta file whose task_id (or filename prefix) matches."""
    for m in _iter_meta_files():
        # Fast path: filename derives from task_id.
        if m.name == f"task-{task_id}.meta":
            return m
    # Fallback: prefix or substring search inside the meta content.
    for m in _iter_meta_files():
        d = _read_meta(m)
        tid = d.get("task_id", "")
        if tid == task_id or tid.startswith(task_id) or task_id in tid:
            return m
    return None


# ---------------------------------------------------------------------------
# tmux helpers
# ---------------------------------------------------------------------------

def _tmux_pane_info():
    """Return {session, window, pane} for $TMUX_PANE, or {} if not in tmux."""
    pane = os.environ.get("TMUX_PANE", "")
    if not pane:
        return {}
    out = _run(["tmux", "display-message", "-p", "-t", pane,
                "#{session_name}|#{window_name}|#{pane_id}"])
    if not out.strip():
        return {}
    parts = out.strip().splitlines()[0].split("|")
    if len(parts) < 3:
        return {}
    return {"session": parts[0], "window": parts[1], "pane": parts[2]}


def _tmux_sessions():
    """Return list of endy* tmux session names."""
    out = _run(["tmux", "list-sessions", "-F", "#S"])
    if not out:
        return []
    return [s for s in out.strip().splitlines()
            if s == "endy" or s.startswith("endy-")]


def _tmux_windows(session):
    """Return list of window names in <session>."""
    out = _run(["tmux", "list-windows", "-t", session, "-F", "#W"])
    if not out:
        return []
    return [w for w in out.strip().splitlines() if w]


# ---------------------------------------------------------------------------
# tier stats (subprocess calls into existing helpers)
# ---------------------------------------------------------------------------

def _tier_codex(cwd):
    """Parse _endy-codex-stats.py output. Returns {} if unavailable."""
    script = ENDY_ROOT / "scripts" / "_endy-codex-stats.py"
    if not script.is_file():
        return {"source": "unknown"}
    out = _run([sys.executable, str(script), cwd], timeout=3)
    if not out.strip():
        return {"source": "unknown"}
    # ctx|pct|total_tokens|context_window|h5_pct|wk_pct|plan|h5_resets_epoch
    parts = out.strip().splitlines()[0].split("|")
    if len(parts) < 8:
        return {"source": "unknown"}
    def _pct(s):
        try:
            return float(s) if s else None
        except ValueError:
            return None
    return {
        "source": "disk-rollout",
        "plan": parts[6] or None,
        "h5_pct": _pct(parts[4]),
        "wk_pct": _pct(parts[5]),
        "resets_at": parts[7] or None,
        "ctx_pct": _pct(parts[1]),
    }


def _tier_opencode(cwd):
    """Parse _endy-opencode-stats.py output. Returns {} if unavailable."""
    script = ENDY_ROOT / "scripts" / "_endy-opencode-stats.py"
    if not script.is_file():
        return {"source": "unknown"}
    out = _run([sys.executable, str(script), cwd], timeout=3)
    if not out.strip():
        return {"source": "unknown"}
    # ctx|pct|tin|tout|cache_r|cache_w|reason|cost|model|window
    parts = out.strip().splitlines()[0].split("|")
    if len(parts) < 10:
        return {"source": "unknown"}
    try:
        cost = float(parts[7])
    except ValueError:
        cost = None
    return {
        "source": "disk-sqlite",
        "session_cost": cost,
        "model": parts[8] or None,
    }


def _compose_tiers(cwd):
    """Build the tiers dict. Agents without a detector get source=unknown."""
    tiers = {
        "codex": _tier_codex(cwd) if cwd else {"source": "unknown"},
        "opencode": _tier_opencode(cwd) if cwd else {"source": "unknown"},
        "claude": {"source": "estimate-only"},
        "gemini": {"source": "unknown"},
        "hermes": {"source": "unknown"},
        "cmd": {"source": "unknown"},
    }
    return tiers


# ---------------------------------------------------------------------------
# main state composer
# ---------------------------------------------------------------------------

def _derive_wt_fields(meta):
    """Phase 5.2: compute live git counters for the worktree referenced by
    `meta`. Returns a dict with 5 keys (all values nullable). Empty dict
    when there is no worktree_dir or it's gone.

    All git calls have a 1s timeout. On any failure we leave the field
    None instead of poisoning the JSON / prompt.
    """
    wt = meta.get("worktree_dir") or ""
    origin = meta.get("worktree_origin_cwd") or ""
    if not wt:
        return {}
    wt_path = Path(wt)
    if not wt_path.is_dir():
        return {}

    out = {
        "commits_ahead": None,
        "porcelain_modified": None,
        "porcelain_untracked": None,
        "origin_branch": None,
        "chain_size": None,
    }

    if origin and Path(origin).is_dir():
        origin_head = _run(["git", "-C", origin, "rev-parse", "HEAD"], timeout=1).strip()
        if origin_head:
            cnt = _run(["git", "-C", wt, "rev-list", "--count", f"{origin_head}..HEAD"],
                       timeout=1).strip()
            try:
                out["commits_ahead"] = int(cnt) if cnt else None
            except ValueError:
                pass
        ob = _run(["git", "-C", origin, "symbolic-ref", "--short", "HEAD"], timeout=1).strip()
        if ob:
            out["origin_branch"] = ob

    porc = _run(["git", "-C", wt, "status", "--porcelain"], timeout=1)
    if porc is not None:
        mod = untr = 0
        for line in porc.splitlines():
            if line.startswith("??"):
                untr += 1
            elif line.strip():
                mod += 1
        out["porcelain_modified"] = mod
        out["porcelain_untracked"] = untr

    # chain_size = how many tasks (inheritors + owner) share this worktree.
    # One disk walk; cheap for typical .logs/ sizes (dozens of metas).
    try:
        cnt = 0
        for m in _iter_meta_files():
            d = _read_meta(m)
            if d.get("worktree_dir") == wt:
                cnt += 1
        out["chain_size"] = cnt
    except OSError:
        pass

    return out


def _self_from_meta(meta_path, meta):
    """Build the `self` block from a parsed meta dict.

    The worktree_* fields are Phase 5: when present, the task is running
    in an isolated git worktree (see SKILL.md / docs/roadmap.md Phase 5).
    Phase 5.2 enriches the block with 5 live git counters
    (commits_ahead, porcelain_modified, porcelain_untracked,
    origin_branch, chain_size) — null when not derivable.
    """
    derived = _derive_wt_fields(meta)
    return {
        "task_id": meta.get("task_id") or "",
        "agent": meta.get("agent") or "",
        "session": (meta.get("window") or "").split(":", 1)[0],
        "window": meta.get("window") or "",
        "cwd": meta.get("cwd") or "",
        "orchestrator": meta.get("orchestrator") or "",
        "orchestrator_agent": meta.get("orchestrator_agent") or "",
        "spawned_at": meta.get("spawned_at") or "",
        "meta_path": str(meta_path),
        "worktree_dir": meta.get("worktree_dir") or "",
        "worktree_branch": meta.get("worktree_branch") or "",
        "worktree_origin_cwd": meta.get("worktree_origin_cwd") or "",
        "worktree_inherited": meta.get("worktree_inherited") or "",
        "worktree_commits_ahead": derived.get("commits_ahead"),
        "worktree_porcelain_modified": derived.get("porcelain_modified"),
        "worktree_porcelain_untracked": derived.get("porcelain_untracked"),
        "worktree_origin_branch": derived.get("origin_branch"),
        "worktree_chain_size": derived.get("chain_size"),
    }


def _lineage_from_meta(meta):
    """Build the `lineage` block: handoff_chain (full) + immediate parent.

    handoff_chain in the meta is comma-separated ids of all previous tasks
    (in spawn order), NOT including self. We enrich each id with its meta
    (agent + reason) so the agent can pretty-print the chain.
    """
    chain_str = meta.get("handoff_chain") or ""
    chain_ids = [i for i in chain_str.split(",") if i]
    enriched = []
    for tid in chain_ids:
        m = _find_meta_by_task_id(tid)
        if not m:
            enriched.append({"task_id": tid, "agent": None, "reason": None})
            continue
        d = _read_meta(m)
        enriched.append({
            "task_id": d.get("task_id") or tid,
            "agent": d.get("agent") or None,
            "reason": d.get("handoff_reason") or None,
            "cwd": d.get("cwd") or None,
        })
    return {
        "handoff_chain": enriched,
        "parent_task": meta.get("parent_task") or None,
        "handoff_from": meta.get("handoff_from") or None,
        "handoff_reason": meta.get("handoff_reason") or None,
    }


def _peers_for(session, self_task_id):
    """Build the `peers` block.

    in_session: tasks/chats in `session` other than self.
    other_sessions: every other endy-* tmux session, summarized.
    """
    in_session = []
    if session:
        for w in _tmux_windows(session):
            # Match task-<id> or chat-<id> or follow-<id> windows.
            m = re.match(r"^(?:task|chat|follow)-(\S+)$", w)
            if not m:
                continue
            tid = m.group(1)
            if tid == self_task_id:
                continue
            meta_path = _find_meta_by_task_id(tid)
            agent = None
            if meta_path:
                agent = _read_meta(meta_path).get("agent")
            in_session.append({
                "task_id": tid,
                "agent": agent,
                "window": w,
            })

    other_sessions = []
    for s in _tmux_sessions():
        if s == session:
            continue
        windows = _tmux_windows(s)
        task_windows = [w for w in windows if re.match(r"^(?:task|chat|follow)-", w)]
        other_sessions.append({
            "session": s,
            "tasks": len(task_windows),
            "live_panes": len(task_windows),
        })

    return {"in_session": in_session, "other_sessions": other_sessions}


def compose_state(task_id=None):
    """Build the full state dict. task_id is optional — if omitted, try to
    self-detect via $TMUX_PANE."""
    state = {
        "version": SCHEMA_VERSION,
        "as_of": _now_iso(),
        "self": None,
        "lineage": None,
        "peers": {"in_session": [], "other_sessions": []},
        "tiers": _compose_tiers(""),
    }

    # Resolve task: explicit --task-id wins; otherwise infer from tmux window.
    meta_path = None
    if task_id:
        meta_path = _find_meta_by_task_id(task_id)
        if not meta_path:
            return {"error": "task not found", "task_id": task_id,
                    "version": SCHEMA_VERSION, "as_of": state["as_of"]}, 4
    else:
        info = _tmux_pane_info()
        win = info.get("window", "")
        m = re.match(r"^(?:task|chat|follow)-(\S+)$", win)
        if m:
            meta_path = _find_meta_by_task_id(m.group(1))

    if meta_path:
        meta = _read_meta(meta_path)
        state["self"] = _self_from_meta(meta_path, meta)
        state["lineage"] = _lineage_from_meta(meta)
        state["tiers"] = _compose_tiers(state["self"]["cwd"])
        state["peers"] = _peers_for(state["self"]["session"], state["self"]["task_id"])
    else:
        # No self — still list other sessions for context.
        state["peers"] = _peers_for("", "")

    return state, 0


# ---------------------------------------------------------------------------
# renderers
# ---------------------------------------------------------------------------

def render_json(state):
    return json.dumps(state, indent=2, sort_keys=False)


def _ordinal(n):
    if 10 <= (n % 100) <= 20:
        return f"{n}th"
    suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _tier_line_codex(t):
    plan = t.get("plan") or "?"
    h5 = t.get("h5_pct")
    wk = t.get("wk_pct")
    resets = t.get("resets_at") or ""
    h5_s = f"5h {h5:.0f}%" if h5 is not None else "5h ?"
    wk_s = f"wk {wk:.0f}%" if wk is not None else "wk ?"
    tail = f"   resets at {resets}" if resets else ""
    return f"{plan:<5} {h5_s}  {wk_s}{tail}"


def _tier_line_opencode(t):
    cost = t.get("session_cost")
    model = t.get("model") or "?"
    cost_s = f"${cost:.2f} session" if cost is not None else "—"
    return f"{cost_s}   model: {model}"


def _render_tiers_block(tiers):
    lines = []
    # codex first, then opencode, then the rest alphabetically.
    order = ["codex", "opencode", "claude", "gemini", "hermes", "cmd"]
    for agent in order:
        t = tiers.get(agent, {})
        source = t.get("source", "unknown")
        if agent == "codex" and source == "disk-rollout":
            lines.append(f"codex:    {_tier_line_codex(t)}")
        elif agent == "opencode" and source == "disk-sqlite":
            lines.append(f"opencode: {_tier_line_opencode(t)}")
        elif agent == "claude":
            lines.append("claude:   max   estimate-only")
        else:
            lines.append(f"{agent + ':':<9} unknown")
    return "\n".join("  " + l for l in lines)


def _render_chain_block(lineage, self_agent):
    """Render the handoff chain as a numbered list. Caps at CHAIN_RENDER_CAP
    entries when there are more."""
    chain = (lineage or {}).get("handoff_chain") or []
    full_len = len(chain) + 1  # +1 for self (you)
    if not chain:
        return None, full_len

    visible = chain[-CHAIN_RENDER_CAP:]
    truncated = len(chain) > CHAIN_RENDER_CAP
    out_lines = []
    if truncated:
        out_lines.append(f"  … ({len(chain) - CHAIN_RENDER_CAP} earlier links elided)")
    for i, link in enumerate(visible, start=full_len - len(visible)):
        agent = link.get("agent") or "?"
        reason = link.get("reason")
        reason_s = f" — {reason}" if reason else ""
        out_lines.append(f"  {i}. {agent}{reason_s}")
    out_lines.append(f"  {full_len}. {self_agent} ← you")
    return "\n".join(out_lines), full_len


def render_human(state):
    if state.get("error"):
        return f"endy state: {state['error']} (task_id={state.get('task_id', '?')})"

    s = state.get("self") or {}
    lin = state.get("lineage") or {}
    peers = state.get("peers") or {}

    lines = ["endy state", "=========="]
    if s:
        lines.append(f"task: {s.get('task_id', '?')}  agent: {s.get('agent', '?')}")
        lines.append(f"session: {s.get('session', '?')}  cwd: {s.get('cwd', '?')}")
        if s.get("orchestrator"):
            lines.append(f"orchestrator: {s['orchestrator']} ({s.get('orchestrator_agent') or '?'})")
    else:
        lines.append("(no self — not invoked from inside a tmux task window)")

    chain_block, full_len = _render_chain_block(lin, (s.get("agent") if s else "?"))
    if chain_block:
        lines.append("")
        lines.append(f"handoff chain ({_ordinal(full_len)} link is you):")
        lines.append(chain_block)
        reason = lin.get("handoff_reason")
        if reason:
            lines.append(f"  reason: \"{reason}\"")

    in_sess = peers.get("in_session") or []
    others = peers.get("other_sessions") or []
    if in_sess or others:
        lines.append("")
        lines.append("peers:")
        if in_sess:
            for p in in_sess:
                lines.append(f"  same session: {p.get('agent') or '?'} on {p.get('window') or '?'}")
        else:
            lines.append("  same session: (none)")
        if others:
            for o in others:
                lines.append(f"  other session: {o.get('session')} "
                             f"({o.get('tasks', 0)} task windows)")

    lines.append("")
    lines.append("tier headroom:")
    lines.append(_render_tiers_block(state.get("tiers") or {}))

    return "\n".join(lines)


def render_prompt(state):
    """Markdown block prepended to spawn prompts. Stable layout — agents
    will be reading this on every turn-1, so format changes have downstream
    cost."""
    if state.get("error"):
        return ""  # no block on error — don't poison the prompt

    s = state.get("self") or {}
    lin = state.get("lineage") or {}
    peers = state.get("peers") or {}

    out = ["## endy environment", ""]

    if s:
        agent = s.get("agent", "?")
        task_id = s.get("task_id", "?")
        session = s.get("session", "?")
        cwd = s.get("cwd", "?")
        out.append(f"You are **{agent}**, task `{task_id}` in `{cwd}` "
                   f"(session `{session}`).")
        # Phase 5: if we're in an isolated worktree, mention it. Agents
        # need to know they can edit freely without stomping a peer task.
        wt_dir = s.get("worktree_dir") or ""
        if wt_dir:
            wt_branch = s.get("worktree_branch") or "?"
            wt_origin = s.get("worktree_origin_cwd") or "?"
            wt_inherited = s.get("worktree_inherited") or ""
            tag = " (inherited from previous link)" if wt_inherited else ""
            out.append(f"Git worktree: branch `{wt_branch}` "
                       f"(origin repo: `{wt_origin}`){tag}.")
            # Phase 5.2 — live counters. Each follow-up line is conditional
            # on having content; an agent in a clean wt with no commits sees
            # only the branch line above.
            commits = s.get("worktree_commits_ahead") or 0
            mod = s.get("worktree_porcelain_modified") or 0
            untr = s.get("worktree_porcelain_untracked") or 0
            origin_branch = s.get("worktree_origin_branch")
            if commits > 0 or mod > 0 or untr > 0:
                parts = []
                if commits > 0:
                    target = f"`{origin_branch}`" if origin_branch else "origin"
                    parts.append(
                        f"{commits} commit{'s' if commits != 1 else ''} "
                        f"ahead of {target}"
                    )
                if mod > 0 or untr > 0:
                    total = mod + untr
                    parts.append(
                        f"{mod} modified + {untr} untracked "
                        f"file{'s' if total != 1 else ''} in your dir"
                    )
                out.append("  → " + ", ".join(parts) + ".")
            chain = s.get("worktree_chain_size") or 1
            if chain > 1:
                other = chain - 1
                out.append(
                    f"  → {other} other link{'s' if other != 1 else ''} "
                    f"in this handoff chain share this worktree."
                )
        out.append("")

    chain_block, full_len = _render_chain_block(lin, (s.get("agent") if s else "?"))
    if chain_block:
        out.append("### How you got here")
        out.append(f"{_ordinal(full_len)} link in handoff chain:")
        out.append(chain_block)
        reason = lin.get("handoff_reason")
        if reason:
            out.append("")
            out.append(f'Last reason: "{reason}". Original prompt below the markers.')
        out.append("")

    in_sess = peers.get("in_session") or []
    others = peers.get("other_sessions") or []
    if in_sess or others:
        out.append("### Peers right now")
        if in_sess:
            for p in in_sess:
                out.append(f"- Same session: {p.get('agent') or '?'} on `{p.get('window') or '?'}`")
        else:
            out.append("- Same session: (none)")
        if others:
            other_summary = ", ".join(
                f"{o.get('session')} ({o.get('tasks', 0)} tasks)" for o in others
            )
            out.append(f"- Other sessions: {other_summary}")
        out.append("")

    out.append(f"### Tier headroom (estimates, as of {state.get('as_of', '?')})")
    tier_block = _render_tiers_block(state.get("tiers") or {})
    # _render_tiers_block already indents with 2 spaces; strip and re-emit
    # so it sits flush in the prompt without the indented-code-block effect.
    for line in tier_block.splitlines():
        out.append(line.lstrip())
    out.append("")

    out.append("Hand off when needed: `endy handoff <your-id> --to <agent> --reason \"...\"`")

    return "\n".join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="endy-state",
        description="Compose endy environment state (self, lineage, peers, tiers).",
    )
    p.add_argument("--task-id", default=None,
                   help="task id to inspect (default: self-detect via $TMUX_PANE)")
    p.add_argument("--format", choices=("json", "human", "prompt"), default="human",
                   help="output format (default: human)")
    args = p.parse_args(argv)

    state, code = compose_state(task_id=args.task_id)

    if code != 0:
        print(json.dumps(state) if args.format == "json" else
              f"endy state: {state.get('error', 'unknown error')}",
              file=sys.stderr)
        return code

    if args.format == "json":
        print(render_json(state))
    elif args.format == "prompt":
        out = render_prompt(state)
        if out:
            print(out)
    else:
        print(render_human(state))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
