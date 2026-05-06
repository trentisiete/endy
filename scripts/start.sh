#!/usr/bin/env bash
# Launch (or reattach to) the endy tmux session.
#
# Layout:
#   window 0  orchestrator  — interactive Codex
#   window 1  watch         — `endy watch browse`
#   window 2  docs          — README/NEXT_STEPS
#   window 3  tree          — live grouped view
#
# Optional:
#   --serve-opencode opens an `opencode serve` window.
#   --logs opens a log-tail window.
#
# Reattach from anywhere on the Tailnet with:
#   ssh $USER@<host> -t 'tmux attach -t endy'

set -euo pipefail

SESSION="endy"
ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ENDY_ROOT}/.logs"
mkdir -p "$LOG_DIR"

attach=1
clean=0
serve_opencode=0
show_logs=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-attach) attach=0; shift ;;
    --clean) clean=1; shift ;;
    --serve-opencode) serve_opencode=1; shift ;;
    --logs) show_logs=1; shift ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

configure_tmux_help() {
  "${ENDY_ROOT}/scripts/tmux-help.sh" >/dev/null 2>&1 || true
}

kill_window_if_exists() {
  local window="$1"
  tmux kill-window -t "${SESSION}:${window}" 2>/dev/null || true
}

cleanup_runtime_windows() {
  local windows window
  windows="$(tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null || true)"
  while IFS= read -r window; do
    case "$window" in
      task-*|chat-*|follow-*|panel|watch|docs|tree|help|opencode|logs)
        kill_window_if_exists "$window" ;;
    esac
  done <<< "$windows"
}

open_manager_windows() {
  kill_window_if_exists watch
  tmux new-window -t "$SESSION" -n watch -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "clear
printf '\033[1;36mendy watch browse\033[0m\n'
printf '\033[1;33mtmux: Ctrl-b w windows | Ctrl-b n/p next/prev | Ctrl-b d detach\033[0m\n'
printf '\033[1;33menter chat/switch | Ctrl-o open chat here | Ctrl-f follow | Ctrl-v view | Ctrl-l log | Ctrl-k kill | esc exit\033[0m\n\n'
${ENDY_ROOT}/bin/endy watch browse
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
")"

  kill_window_if_exists docs
  tmux new-window -t "$SESSION" -n docs -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "clear
printf '\033[1;36mendy docs\033[0m\n'
printf '\033[1;33mREADME.md and NEXT_STEPS.md. q exits less and leaves a shell.\033[0m\n\n'
less -R README.md NEXT_STEPS.md
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
")"
}

open_optional_windows() {
  if [[ "$serve_opencode" == "1" ]]; then
    kill_window_if_exists opencode
    tmux new-window -t "$SESSION" -n opencode -c "$ENDY_ROOT" \
      "bash -lc $(printf '%q' "opencode serve 2>&1 | tee ${LOG_DIR}/opencode-serve.log")"
  fi

  if [[ "$show_logs" == "1" ]]; then
    kill_window_if_exists logs
    tmux new-window -t "$SESSION" -n logs -c "$ENDY_ROOT" \
      "bash -lc $(printf '%q' "touch ${LOG_DIR}/opencode-serve.log
tail -F ${LOG_DIR}/opencode-serve.log
")"
  fi
}

if tmux has-session -t "$SESSION" 2>/dev/null; then
  [[ "$clean" == "1" ]] && cleanup_runtime_windows
  open_manager_windows
  open_optional_windows
  configure_tmux_help
  tmux select-window -t "${SESSION}:orchestrator" 2>/dev/null || true
  if [[ "$attach" == "1" ]]; then
    echo "session '$SESSION' already running — attaching"
    exec tmux attach -t "$SESSION"
  fi
  cat <<EOF
session '${SESSION}' ready.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:watch
  tmux select-window -t ${SESSION}:docs
  tmux select-window -t ${SESSION}:tree
  tmux kill-session -t ${SESSION}
EOF
  exit 0
fi

# window 0: orchestrator
tmux new-session  -d -s "$SESSION" -n orchestrator -c "$ENDY_ROOT"
tmux send-keys -t "${SESSION}:orchestrator" \
  "export ENDY_ORCHESTRATOR=orchestrator; export ENDY_ORCHESTRATOR_AGENT=codex; export ENDY_ORCHESTRATOR_CWD=${ENDY_ROOT}; codex" C-m

# windows 1 and 2: manager panes
open_manager_windows
open_optional_windows

configure_tmux_help
tmux select-window -t "${SESSION}:orchestrator"
if [[ "$attach" == "1" ]]; then
  exec tmux attach -t "$SESSION"
fi

cat <<EOF
session '${SESSION}' ready.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:watch
  tmux select-window -t ${SESSION}:docs
  tmux select-window -t ${SESSION}:tree
  tmux kill-session -t ${SESSION}
EOF
