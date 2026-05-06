#!/usr/bin/env python3
"""
endy web — minimal dashboard over the endy task backend.

Reads .logs/ for state, spawns via scripts/spawn-long-task.sh, kills via
scripts/endy-watch.sh. Same source-of-truth as the CLI; just a different
front-end. Python stdlib only — no pip dependencies.

Endpoints:
  GET    /                       static dashboard HTML
  GET    /api/tasks              JSON list of all tasks (status/runtime/last)
  GET    /api/tasks/<id>         JSON detail (meta + last 200 lines)
  GET    /api/tasks/<id>/stream  SSE — log lines as they're written (event: line)
  GET    /api/events             SSE — "task" event when status changes (poll-based)
  POST   /api/tasks              form/json {agent, persona?, cwd?, prompt} → spawn
  POST   /api/tasks/<id>/followup form/json {prompt} → endy watch followup
  DELETE /api/tasks/<id>         kill the task

Bind to your Tailnet IP by default (auto-discovered via `tailscale ip -4`).
Never binds 0.0.0.0 unless you explicitly pass --host 0.0.0.0.
"""

import argparse
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ENDY_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ENDY_ROOT / ".logs"
SCRIPTS = ENDY_ROOT / "scripts"
WEB_DIR = ENDY_ROOT / "web"

ANSI_RE = re.compile(
    r"\x1b\][^\x07]*(?:\x07|\x1b\\)"
    r"|\x1bP.*?\x1b\\"
    r"|\x1b_.*?\x1b\\"
    r"|\x1b\[[0-9;?<>]*[ -/]*[@-~]"
    r"|\x1b[()][A-Za-z0-9]"
    r"|\x1b\\"
    r"|\x1b[=>]"
    r"|\x1b",
    re.DOTALL,
)
EXIT_RE = re.compile(r"^ENDY_EXIT=(\d+)$", re.MULTILINE)
ERR_PATTERNS = re.compile(
    r"(?:^|[^A-Za-z])(?:Error:|ERROR:|Exception:|Traceback)"
    r"|ProviderModelNotFoundError|Unauthorized|forbidden|model not found|auto-rejecting"
    r"|Reached maximum (?:conversation )?turns|response may be incomplete"
)


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def parse_meta(meta_path: Path) -> dict:
    out = {}
    try:
        for line in meta_path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return out


def meta_log_path(tid: str, meta_data: dict) -> Path:
    raw = meta_data.get("log") or ""
    return Path(raw) if raw else LOG_DIR / f"task-{tid}.log"


def meta_prompt_path(tid: str, meta_data: dict) -> Path:
    raw = meta_data.get("prompt") or ""
    return Path(raw) if raw else LOG_DIR / f"task-{tid}.prompt.md"


def tmux_window_exists(meta_data: dict) -> bool:
    window = meta_data.get("window") or ""
    if not window:
        return False
    if ":" in window:
        session, window_name = window.split(":", 1)
    else:
        session, window_name = "endy", window
    try:
        res = subprocess.run(
            ["tmux", "list-windows", "-t", session, "-F", "#W"],
            capture_output=True,
            text=True,
            timeout=1,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False
    if res.returncode != 0:
        return False
    return window_name in set(res.stdout.splitlines())


def task_status(log_path: Path, meta_data: dict | None = None) -> str:
    kind = (meta_data or {}).get("kind", "spawn")
    window_exists = tmux_window_exists(meta_data or {})
    if not log_path.exists():
        if meta_data and not window_exists:
            return "ABANDONED"
        return "CHAT" if kind == "chat" else "PENDING"
    try:
        text = log_path.read_text(errors="replace")
    except OSError:
        if meta_data and not window_exists:
            return "ABANDONED"
        return "CHAT" if kind == "chat" else "PENDING"
    m = list(EXIT_RE.finditer(text))
    if m:
        ec = int(m[-1].group(1))
        if ec == 0:
            return "DONE-ERR" if ERR_PATTERNS.search(text) else "DONE"
        return f"FAILED({ec})"
    if meta_data and not window_exists:
        return "ABANDONED"
    return "CHAT" if kind == "chat" else "RUNNING"


def task_last_line(log_path: Path, kind: str = "spawn") -> str:
    if kind == "chat":
        return "interactive pane captured"
    if not log_path.exists():
        return ""
    try:
        text = log_path.read_text(errors="replace")
    except OSError:
        return ""
    for ln in reversed(text.splitlines()):
        clean = strip_ansi(ln).strip()
        if not clean:
            continue
        if clean.startswith("ENDY_EXIT=") or clean.startswith("[endy-watch]"):
            continue
        alnum = sum(1 for ch in clean if ch.isalnum())
        if alnum == 0 or (len(clean) > 40 and alnum < 5):
            continue
        return clean[:200]
    return ""


def task_model(log_path: Path, meta_data: dict) -> str:
    model = meta_data.get("model", "")
    if model or not log_path.exists():
        return model
    agent = meta_data.get("agent", "")
    try:
        text = strip_ansi(log_path.read_text(errors="replace"))
    except OSError:
        return ""
    if agent == "opencode":
        for line in text.splitlines():
            m = re.match(r"^> .* · (.+)$", line.strip())
            if m:
                return m.group(1).strip()
    if agent in {"cmd", "commandcode"}:
        for line in text.splitlines():
            if "model: " in line:
                return line.split("model: ", 1)[1].strip()
    return ""


def orchestrator_label(meta_data: dict) -> str:
    orch = meta_data.get("orchestrator") or meta_data.get("origin_window") or "manual"
    orch_agent = meta_data.get("orchestrator_agent", "")
    return f"{orch}[{orch_agent}]" if orch_agent else orch


def runtime_seconds(spawned_iso: str) -> int:
    try:
        dt = datetime.strptime(spawned_iso, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
        return int((datetime.now(timezone.utc) - dt).total_seconds())
    except (ValueError, TypeError):
        return 0


def list_tasks() -> list:
    tasks = []
    if not LOG_DIR.exists():
        return tasks
    for meta in sorted(LOG_DIR.glob("task-*.meta")):
        tid = meta.stem.replace("task-", "")
        meta_data = parse_meta(meta)
        log_path = meta_log_path(tid, meta_data)
        tasks.append(
            {
                "task_id": tid,
                "kind": meta_data.get("kind", "spawn"),
                "orchestrator": meta_data.get("orchestrator", meta_data.get("origin_window", "manual")),
                "orchestrator_agent": meta_data.get("orchestrator_agent", ""),
                "orchestrator_label": orchestrator_label(meta_data),
                "origin_window": meta_data.get("origin_window", ""),
                "origin_cwd": meta_data.get("origin_cwd", ""),
                "agent": meta_data.get("agent", ""),
                "persona": meta_data.get("persona", ""),
                "model": task_model(log_path, meta_data),
                "cwd": meta_data.get("cwd", ""),
                "spawned_at": meta_data.get("spawned_at", ""),
                "parent_task": meta_data.get("parent_task", ""),
                "resume_id": meta_data.get("resume_id", ""),
                "runtime_s": runtime_seconds(meta_data.get("spawned_at", "")),
                "status": task_status(log_path, meta_data),
                "last": task_last_line(log_path, meta_data.get("kind", "spawn")),
            }
        )
    tasks.sort(key=lambda t: t["spawned_at"] or "", reverse=True)
    return tasks


def task_detail(tid: str) -> dict | None:
    meta_path = LOG_DIR / f"task-{tid}.meta"
    if not meta_path.exists():
        return None
    meta_data = parse_meta(meta_path)
    log_path = meta_log_path(tid, meta_data)
    prompt_path = meta_prompt_path(tid, meta_data)
    log_text = ""
    if log_path.exists():
        text = log_path.read_text(errors="replace")
        # Last 200 lines
        lines = text.splitlines()
        log_text = strip_ansi("\n".join(lines[-200:]))
    prompt_text = prompt_path.read_text(errors="replace") if prompt_path.exists() else ""
    return {
        "task_id": tid,
        "kind": meta_data.get("kind", "spawn"),
        "orchestrator": meta_data.get("orchestrator", meta_data.get("origin_window", "manual")),
        "orchestrator_agent": meta_data.get("orchestrator_agent", ""),
        "orchestrator_label": orchestrator_label(meta_data),
        "origin_window": meta_data.get("origin_window", ""),
        "origin_cwd": meta_data.get("origin_cwd", ""),
        "agent": meta_data.get("agent", ""),
        "persona": meta_data.get("persona", ""),
        "model": task_model(log_path, meta_data),
        "cwd": meta_data.get("cwd", ""),
        "spawned_at": meta_data.get("spawned_at", ""),
        "parent_task": meta_data.get("parent_task", ""),
        "resume_id": meta_data.get("resume_id", ""),
        "window": meta_data.get("window", ""),
        "runtime_s": runtime_seconds(meta_data.get("spawned_at", "")),
        "status": task_status(log_path, meta_data),
        "log_tail": log_text,
        "prompt": prompt_text,
        "last": task_last_line(log_path, meta_data.get("kind", "spawn")),
    }


def spawn_task(agent: str, prompt: str, persona: str = "", cwd: str = "",
               model: str = "", full_auto: bool = True) -> dict:
    args = [str(SCRIPTS / "spawn-long-task.sh"), "--agent", agent, "--prompt", prompt]
    if persona:
        args += ["--persona", persona]
    if cwd:
        args += ["--cwd", cwd]
    if model:
        args += ["--model", model]
    args += ["--orchestrator", "web", "--orchestrator-agent", "web"]
    if full_auto:
        args += ["--full-auto"]
    res = subprocess.run(args, capture_output=True, text=True)
    out = {"stdout": res.stdout, "stderr": res.stderr, "rc": res.returncode}
    # Parse TASK_ID=… from stdout
    for ln in res.stdout.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip().lower()] = v.strip()
    return out


def kill_task(tid: str) -> dict:
    res = subprocess.run(
        [str(SCRIPTS / "endy-watch.sh"), "kill", tid],
        capture_output=True, text=True,
    )
    return {"stdout": res.stdout, "stderr": res.stderr, "rc": res.returncode}


def followup_task(tid: str, prompt: str) -> dict:
    res = subprocess.run(
        [str(SCRIPTS / "endy-watch.sh"), "followup", tid, "--", prompt],
        capture_output=True,
        text=True,
    )
    out = {"stdout": res.stdout, "stderr": res.stderr, "rc": res.returncode}
    for ln in res.stdout.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip().lower()] = v.strip()
    return out


# ----------------------------------------------------------------------------
# HTTP routing
# ----------------------------------------------------------------------------


def stream_log(handler, tid: str):
    """SSE: emit each new log line as it arrives, until ENDY_EXIT seen
    or the client disconnects."""
    meta_data = parse_meta(LOG_DIR / f"task-{tid}.meta")
    log_path = meta_log_path(tid, meta_data)

    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("Connection", "keep-alive")
    handler.send_header("X-Accel-Buffering", "no")
    handler.end_headers()

    def write(payload, event=None):
        try:
            if event:
                handler.wfile.write(f"event: {event}\n".encode())
            handler.wfile.write(f"data: {payload}\n\n".encode())
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    # Wait up to 5s for the log file to appear.
    waited = 0
    while not log_path.exists() and waited < 5:
        time.sleep(0.5)
        waited += 0.5
    if not log_path.exists():
        write(json.dumps({"error": "log not yet written"}), event="error")
        return

    last_size = 0
    saw_exit = False
    last_heartbeat = time.time()
    try:
        with log_path.open("r", errors="replace") as fp:
            while True:
                fp.seek(last_size)
                chunk = fp.read()
                if chunk:
                    last_size = fp.tell()
                    for line in chunk.splitlines():
                        clean = strip_ansi(line)
                        if not write(json.dumps({"line": clean})):
                            return
                        if EXIT_RE.match(clean):
                            saw_exit = True
                if saw_exit:
                    write(json.dumps({"status": task_status(log_path, meta_data)}), event="end")
                    return
                # Heartbeat every 15s so proxies don't drop the connection.
                if time.time() - last_heartbeat > 15:
                    if not write(": heartbeat"):
                        return
                    last_heartbeat = time.time()
                time.sleep(0.5)
    except (BrokenPipeError, ConnectionResetError, OSError):
        return


def stream_events(handler):
    """SSE: emit a 'tasks' event with the full task list whenever it changes
    (poll-based, ~2s)."""
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("Connection", "keep-alive")
    handler.send_header("X-Accel-Buffering", "no")
    handler.end_headers()

    def write(payload, event=None):
        try:
            if event:
                handler.wfile.write(f"event: {event}\n".encode())
            handler.wfile.write(f"data: {payload}\n\n".encode())
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    last_signature = None
    last_heartbeat = time.time()
    try:
        while True:
            tasks = list_tasks()
            # Only re-send when something changed.
            sig = tuple((t["task_id"], t["status"], t["last"], t.get("parent_task", ""), t.get("orchestrator", "")) for t in tasks)
            if sig != last_signature:
                if not write(json.dumps(tasks), event="tasks"):
                    return
                last_signature = sig
            if time.time() - last_heartbeat > 15:
                if not write(": heartbeat"):
                    return
                last_heartbeat = time.time()
            time.sleep(2)
    except (BrokenPipeError, ConnectionResetError, OSError):
        return


def send_json(handler, code: int, data):
    body = json.dumps(data).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def send_text(handler, code: int, body: str, ctype: str = "text/plain; charset=utf-8"):
    raw = body.encode()
    handler.send_response(code)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


def parse_body(handler):
    length = int(handler.headers.get("Content-Length", "0"))
    raw = handler.rfile.read(length) if length else b""
    ctype = handler.headers.get("Content-Type", "")
    if "application/json" in ctype:
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            return {}
    if "application/x-www-form-urlencoded" in ctype or not ctype:
        return {k: v[0] if v else "" for k, v in parse_qs(raw.decode()).items()}
    return {}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "endy-web/0.1"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.address_string()} {fmt % args}\n")

    def _route(self, method: str):
        url = urlparse(self.path)
        path = url.path

        # Static frontend
        if method == "GET" and path == "/":
            html = (WEB_DIR / "index.html").read_text()
            return send_text(self, 200, html, "text/html; charset=utf-8")

        # Tasks list
        if method == "GET" and path == "/api/tasks":
            return send_json(self, 200, list_tasks())

        # Task detail
        m = re.match(r"^/api/tasks/([\w-]+)$", path)
        if m and method == "GET":
            d = task_detail(m.group(1))
            return send_json(self, 200 if d else 404, d or {"error": "not found"})

        # Task log SSE
        m = re.match(r"^/api/tasks/([\w-]+)/stream$", path)
        if m and method == "GET":
            return stream_log(self, m.group(1))

        # Events SSE
        if method == "GET" and path == "/api/events":
            return stream_events(self)

        # Spawn
        if method == "POST" and path == "/api/tasks":
            body = parse_body(self)
            agent = (body.get("agent") or "").strip()
            prompt = (body.get("prompt") or "").strip()
            if not agent or not prompt:
                return send_json(self, 400, {"error": "agent and prompt required"})
            result = spawn_task(
                agent=agent,
                prompt=prompt,
                persona=(body.get("persona") or "").strip(),
                cwd=(body.get("cwd") or "").strip(),
                model=(body.get("model") or "").strip(),
                full_auto=str(body.get("full_auto", "true")).lower() != "false",
            )
            code = 200 if result.get("rc", 1) == 0 else 500
            return send_json(self, code, result)

        # Followup
        m = re.match(r"^/api/tasks/([\w-]+)/followup$", path)
        if m and method == "POST":
            body = parse_body(self)
            prompt = (body.get("prompt") or "").strip()
            if not prompt:
                return send_json(self, 400, {"error": "prompt required"})
            result = followup_task(m.group(1), prompt)
            code = 200 if result.get("rc", 1) == 0 else 500
            return send_json(self, code, result)

        # Kill
        m = re.match(r"^/api/tasks/([\w-]+)$", path)
        if m and method == "DELETE":
            return send_json(self, 200, kill_task(m.group(1)))

        return send_json(self, 404, {"error": f"no route for {method} {path}"})

    def do_GET(self):    self._route("GET")
    def do_POST(self):   self._route("POST")
    def do_DELETE(self): self._route("DELETE")


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def discover_tailnet_ip() -> str:
    try:
        out = subprocess.run(
            ["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=2
        )
        for line in out.stdout.splitlines():
            line = line.strip()
            if line.startswith("100."):
                return line
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return ""


def main():
    p = argparse.ArgumentParser(description="endy web dashboard")
    p.add_argument("--host", default=None,
                   help="bind address (default: Tailnet IP, fallback localhost)")
    p.add_argument("--port", type=int, default=9120, help="port (default 9120)")
    p.add_argument("--localhost", action="store_true",
                   help="force bind to 127.0.0.1 instead of Tailnet")
    args = p.parse_args()

    if args.host:
        host = args.host
    elif args.localhost:
        host = "127.0.0.1"
    else:
        host = discover_tailnet_ip() or "127.0.0.1"

    srv = ThreadingServer((host, args.port), Handler)
    print(f"endy web listening on http://{host}:{args.port}", file=sys.stderr)
    print(f"  tasks dir: {LOG_DIR}", file=sys.stderr)
    if host.startswith("100.") or host == "0.0.0.0":
        print("  reachable from Tailnet — make sure Tailscale is up", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nendy web stopping…", file=sys.stderr)
        srv.shutdown()


if __name__ == "__main__":
    main()
