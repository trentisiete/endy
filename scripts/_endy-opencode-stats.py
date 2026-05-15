#!/usr/bin/env python3
# Opencode per-cwd stats for the agents/tree dashboard.
#
# Output (single pipe-separated line, fields in this order):
#   ctx|pct|total_in|total_out|cache_read|cache_write|reasoning|cost|model|window
#
# Fail-silent: prints nothing and exits 0 if no usage data is available.
# Source: opencode.db (SQLite) — opencode stores it under the *Windows* user
# home even when invoked from WSL (`/mnt/c/Users/<user>/.local/share/opencode`)
# because the binary is the Windows shim. We probe both candidate paths.

import json
import os
import re
import sqlite3
import sys
from pathlib import Path


CONTEXT_LIMITS = {
    "deepseek-v4-flash-free": 128_000,
    "deepseek-v4-pro": 128_000,
    "claude-opus-4-7": 200_000,
    "claude-opus-4-6": 200_000,
    "claude-sonnet-4-6": 1_000_000,
    "claude-sonnet-4-5": 200_000,
    "claude-haiku-4-5": 200_000,
    "gpt-5": 256_000,
    "gpt-4.1": 1_000_000,
}


def db_candidates():
    home = Path.home()
    yield home / ".local" / "share" / "opencode" / "opencode.db"
    # Opencode on Windows-shim stores under the Windows user; from WSL this is
    # under /mnt/c/Users/<user>/. We don't know the username here, so glob.
    for win_home in Path("/mnt/c/Users").glob("*"):
        p = win_home / ".local" / "share" / "opencode" / "opencode.db"
        if p.exists():
            yield p


def linux_to_windows(p: str) -> str:
    if not p.startswith("/mnt/"):
        return p
    drive = p[5]
    rest = p[7:].replace("/", "\\")
    return f"{drive.upper()}:\\{rest}"


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    cwd = sys.argv[1].rstrip("/")
    win_cwd = linux_to_windows(cwd)

    db_path = None
    for p in db_candidates():
        if p.is_file():
            db_path = p
            break
    if db_path is None:
        return 0

    try:
        c = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        c.row_factory = sqlite3.Row
    except sqlite3.Error:
        return 0

    row = None
    for d in (cwd, win_cwd):
        try:
            cur = c.execute(
                "SELECT id, tokens_input, tokens_output, tokens_reasoning, "
                "tokens_cache_read, tokens_cache_write, cost, model "
                "FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1",
                (d,),
            )
            row = cur.fetchone()
            if row:
                break
        except sqlite3.Error:
            continue
    if row is None:
        return 0

    tin = row["tokens_input"] or 0
    tout = row["tokens_output"] or 0
    tres = row["tokens_reasoning"] or 0
    tcr = row["tokens_cache_read"] or 0
    tcw = row["tokens_cache_write"] or 0
    cost = float(row["cost"] or 0.0)
    model_raw = row["model"] or ""

    model = model_raw
    try:
        m = json.loads(model_raw)
        if isinstance(m, dict):
            model = m.get("id", model_raw)
    except (TypeError, ValueError, json.JSONDecodeError):
        pass

    # Current context size: read the newest `part` row for this session and
    # use its `tokens.total` (opencode emits one step-finish part per turn
    # with the full prompt+response token accounting).
    ctx = 0
    try:
        cur = c.execute(
            "SELECT data FROM part WHERE session_id = ? "
            "ORDER BY time_created DESC LIMIT 1",
            (row["id"],),
        )
        part = cur.fetchone()
        if part:
            data = json.loads(part["data"])
            tokens = data.get("tokens") or {}
            ctx = int(tokens.get("total") or 0)
    except (sqlite3.Error, json.JSONDecodeError, TypeError):
        pass

    window = CONTEXT_LIMITS.get(model, 128_000)
    pct = int((ctx / window) * 100) if window else 0

    print(
        f"{ctx}|{pct}|{tin}|{tout}|{tcr}|{tcw}|{tres}|{cost:.4f}|{model}|{window}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except Exception:
        sys.exit(0)
