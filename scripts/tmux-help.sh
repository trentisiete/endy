#!/usr/bin/env bash
# Apply the endy tmux status line to the session named by $ENDY_SESSION
# (defaults to "endy" for the global/overview session).
#
# The dashboard windows (tree, sessions, agents, browse, docs) are owned
# by scripts/start.sh — this script no longer creates a tree window so it
# doesn't fight start.sh's auto-refreshing dashboard. It only configures
# the tmux status bar, which is safe to (re)apply at any time.

set -euo pipefail

SESSION="${ENDY_SESSION:-endy}"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' is not running; run: endy start" >&2
  exit 3
fi

tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-left '[endy] '
tmux set-option -t "$SESSION" status-right 'Ctrl-b w windows | Ctrl-b n/p next/prev | Ctrl-b d detach | Ctrl-b & kill window | Ctrl-b x kill pane'

# Defensive cleanup: drop any legacy `help` window from older versions.
tmux kill-window -t "${SESSION}:help" 2>/dev/null || true

cat <<EOF
tmux status bar applied to session '${SESSION}'.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:tree
  tmux kill-session -t ${SESSION}
EOF
