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
# Reattach from anywhere on the Tailnet with the session printed by start:
#   ssh $USER@<host> -t 'tmux attach -t <session>'

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"

mode="per-dir"
attach=1
clean=0
serve_opencode=0
show_logs=0
launch_cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*)    mode="${1#--mode=}"; shift ;;
    --mode)      mode="$2"; shift 2 ;;
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

case "$mode" in
  overview)
    SESSION="${ENDY_SESSION:-endy}"
    LOG_DIR="${ENDY_LOG_DIR:-${ENDY_ROOT}/.logs}"
    ;;
  per-dir)
    if [[ -n "${ENDY_SESSION:-}" ]]; then
      SESSION="$ENDY_SESSION"
    else
      SESSION="$(_endy_session_name "$launch_cwd")"
    fi
    LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"
    ;;
  *) echo "unknown --mode: $mode (per-dir|overview)" >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR"
[[ "$mode" == "per-dir" ]] && _endy_record_session_owner "$SESSION" "$launch_cwd"

# Propagate to every script we exec/spawn.
export ENDY_ROOT ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$LOG_DIR"

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
  local browse_args=""
  local scope="$mode"
  [[ "$mode" == "overview" ]] && browse_args="--overview"
  local q_session q_log_dir q_endy_root
  q_session="$(printf '%q' "$SESSION")"
  q_log_dir="$(printf '%q' "$LOG_DIR")"
  q_endy_root="$(printf '%q' "$ENDY_ROOT")"
  kill_window_if_exists watch
  tmux new-window -t "$SESSION" -n watch -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "clear
export ENDY_SESSION=${q_session}
export ENDY_LOG_DIR=${q_log_dir}
printf '\033[1;36mendy watch browse  (scope=%s session=%s, auto-relaunch)\033[0m\n' '${scope}' '${SESSION}'
printf '\033[1;33mtmux: Ctrl-b w windows | Ctrl-b n/p next/prev | Ctrl-b d detach\033[0m\n'
printf '\033[1;33menter chat/switch | Ctrl-o chat bg | Ctrl-f follow | Ctrl-v view | Ctrl-l log | Ctrl-k kill | Ctrl-d purge | esc exit\033[0m\n\n'
while :; do
  ${q_endy_root}/bin/endy watch browse ${browse_args}
  printf '\n\033[2mpicker exited — relaunching in 1s. Ctrl-c to drop to shell.\033[0m\n'
  sleep 1 || break
done
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
  local q_log_dir
  q_log_dir="$(printf '%q' "$LOG_DIR")"
  if [[ "$serve_opencode" == "1" ]]; then
    kill_window_if_exists opencode
    tmux new-window -t "$SESSION" -n opencode -c "$ENDY_ROOT" \
      "bash -lc $(printf '%q' "opencode serve 2>&1 | tee ${q_log_dir}/opencode-serve.log")"
  fi

  if [[ "$show_logs" == "1" ]]; then
    kill_window_if_exists logs
    tmux new-window -t "$SESSION" -n logs -c "$ENDY_ROOT" \
      "bash -lc $(printf '%q' "touch ${q_log_dir}/opencode-serve.log
tail -F ${q_log_dir}/opencode-serve.log
")"
  fi
}

if tmux has-session -t "$SESSION" 2>/dev/null; then
  [[ "$clean" == "1" ]] && cleanup_runtime_windows
  open_manager_windows
  open_optional_windows
  configure_tmux_help
  # Cap scrollback to limit per-pane RAM (overrides ~/.tmux.conf's 100000).
  tmux set -g history-limit 25000
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
# In per-dir mode the orchestrator opens in the launch cwd; in overview mode
# it opens in the endy repo root (same as the original behavior).
if [[ "$mode" == "per-dir" ]]; then
  ORCH_CWD="$launch_cwd"
else
  ORCH_CWD="$ENDY_ROOT"
fi
q_orch_cwd="$(printf '%q' "$ORCH_CWD")"
q_session="$(printf '%q' "$SESSION")"
q_log_dir="$(printf '%q' "$LOG_DIR")"
tmux new-session  -d -s "$SESSION" -n orchestrator -c "$ORCH_CWD"
tmux send-keys -t "${SESSION}:orchestrator" \
  "export ENDY_ORCHESTRATOR=orchestrator; export ENDY_ORCHESTRATOR_AGENT=codex; export ENDY_ORCHESTRATOR_CWD=${q_orch_cwd}; export ENDY_SESSION=${q_session}; export ENDY_LOG_DIR=${q_log_dir}; codex" C-m

# windows 1 and 2: manager panes
open_manager_windows
open_optional_windows

# Cap scrollback to limit per-pane RAM (overrides ~/.tmux.conf's 100000).
tmux set -g history-limit 25000

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
