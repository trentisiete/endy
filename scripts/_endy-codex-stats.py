#!/usr/bin/env python3
# Codex per-cwd stats for the agents/tree dashboard.
#
# Output (single pipe-separated line, fields in this order):
#   ctx|pct|total_tokens|context_window|h5_pct|wk_pct|plan|h5_resets_epoch
#
# Fail-silent: prints nothing and exits 0 if no usage data is available.
# Source: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
#   - record type=session_meta has payload.cwd
#   - record type=event_msg, payload.type=token_count has
#       payload.info.{last_token_usage, total_token_usage, model_context_window}
#       payload.rate_limits.{primary, secondary, plan_type}

import json
import sys
from pathlib import Path

# Cap how many recent rollouts we open looking for a cwd match.
MAX_FILES = 40


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    target_cwd = sys.argv[1].rstrip("/")
    sessions_dir = Path.home() / ".codex" / "sessions"
    if not sessions_dir.is_dir():
        return 0

    files = sorted(
        (p for p in sessions_dir.glob("*/*/*/rollout-*.jsonl") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:MAX_FILES]

    chosen = None
    for path in files:
        try:
            with path.open() as f:
                first = f.readline()
            d = json.loads(first)
        except (OSError, json.JSONDecodeError):
            continue
        if d.get("type") != "session_meta":
            continue
        pl = d.get("payload") or {}
        if (pl.get("cwd") or "").rstrip("/") == target_cwd:
            chosen = path
            break

    if chosen is None:
        return 0

    last_tc = None
    last_rl = None
    try:
        with chosen.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "event_msg":
                    continue
                pl = d.get("payload") or {}
                if pl.get("type") == "token_count":
                    last_tc = pl
                    # rate_limits comes in two flavours and the last event in
                    # a session is usually "premium" (credits balance, no
                    # primary/secondary). We want the most recent "codex"
                    # event, which carries the actual 5h+weekly subscription
                    # quota.
                    rl = pl.get("rate_limits") or {}
                    if rl.get("limit_id") == "codex" and (rl.get("primary") or rl.get("secondary")):
                        last_rl = rl
    except OSError:
        return 0

    if last_tc is None:
        return 0

    info = last_tc.get("info") or {}
    last_usage = info.get("last_token_usage") or {}
    total_usage = info.get("total_token_usage") or {}
    window = info.get("model_context_window") or 0
    # Codex `input_tokens` already includes the cached portion of the prompt
    # (the prompt that was sent for the latest turn), which is what we want
    # for "current context filled".
    ctx = last_usage.get("input_tokens", 0) or 0
    total_session = total_usage.get("total_tokens", 0) or 0
    pct = int((ctx / window) * 100) if window else 0

    rl = last_rl or {}
    primary = rl.get("primary") or {}
    secondary = rl.get("secondary") or {}
    h5p = primary.get("used_percent", "")
    wkp = secondary.get("used_percent", "")
    plan = rl.get("plan_type") or ""
    h5_resets = primary.get("resets_at") or ""

    # Normalize floats with one decimal max ('1.0' rather than '1.0000').
    def fmt(v):
        if v == "" or v is None:
            return ""
        if isinstance(v, float):
            return f"{v:.0f}" if v == int(v) else f"{v:.1f}"
        return str(v)

    print(
        f"{ctx}|{pct}|{total_session}|{window}|"
        f"{fmt(h5p)}|{fmt(wkp)}|{plan}|{h5_resets}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except Exception:
        sys.exit(0)
