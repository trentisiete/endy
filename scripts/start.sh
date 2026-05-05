#!/usr/bin/env bash
# Launch (or reattach to) the endy tmux session.
#
# Layout:
#   window 0  orchestrator  — interactive Codex
#   window 1  opencode      — `opencode serve` (long-lived, avoids cold starts)
#   window 2  logs          — tail of the shim/serve logs
#
# Reattach from anywhere on the Tailnet with:
#   ssh $USER@<host> -t 'tmux attach -t endy'

set -euo pipefail

SESSION="endy"
ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ENDY_ROOT}/.logs"
mkdir -p "$LOG_DIR"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "session '$SESSION' already running — attaching"
  exec tmux attach -t "$SESSION"
fi

# window 0: orchestrator
tmux new-session  -d -s "$SESSION" -n orchestrator -c "$ENDY_ROOT"
tmux send-keys -t "${SESSION}:orchestrator" 'codex' C-m

# window 1: opencode serve (background daemon, optional but fast)
tmux new-window   -t "$SESSION" -n opencode -c "$ENDY_ROOT"
tmux send-keys -t "${SESSION}:opencode" \
  "opencode serve 2>&1 | tee ${LOG_DIR}/opencode-serve.log" C-m

# window 2: logs
tmux new-window   -t "$SESSION" -n logs -c "$ENDY_ROOT"
tmux send-keys -t "${SESSION}:logs" \
  "echo 'tail of shim logs (none yet — they appear when Codex calls a subagent)'" C-m

tmux select-window -t "${SESSION}:orchestrator"
exec tmux attach -t "$SESSION"
