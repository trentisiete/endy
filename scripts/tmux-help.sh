#!/usr/bin/env bash
# Apply the endy tmux status line and tree window to an existing session.

set -euo pipefail

SESSION="${ENDY_TMUX_SESSION:-endy}"
ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' is not running; run: endy start" >&2
  exit 3
fi

tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-left '[endy] '
tmux set-option -t "$SESSION" status-right 'Ctrl-b w windows | Ctrl-b n/p next/prev | Ctrl-b d detach | Ctrl-b & kill window | Ctrl-b x kill pane'

tmux kill-window -t "${SESSION}:help" 2>/dev/null || true
tmux kill-window -t "${SESSION}:tree" 2>/dev/null || true

tree_cmd="
while :; do
  clear
  printf '\033[1;36mendy watch tree\033[0m\n'
  printf '\033[1;33mtmux: Ctrl-b w windows | Ctrl-b n/p next/prev | Ctrl-b d detach | Ctrl-b & kill window | Ctrl-b x kill pane\033[0m\n'
  printf '\033[1;33mendy: watch browse | watch tree --all | watch dir <path> | watch chat <id> | watch kill-all --cwd <path>\033[0m\n\n'
  ${ENDY_ROOT}/bin/endy watch tree
  printf '\n\033[2mrefreshes every 5s. Ctrl-c stops auto-refresh and leaves this shell.\033[0m\n'
  sleep 5
done
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
"
tmux new-window -t "$SESSION" -n tree -c "$ENDY_ROOT" "bash -lc $(printf '%q' "$tree_cmd")"

cat <<EOF
tmux status/tree applied to session '${SESSION}'.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:tree
  tmux kill-window -t ${SESSION}:tree

endy commands:
  endy watch browse
  endy watch tree
  endy watch dir ${ENDY_ROOT}
EOF
