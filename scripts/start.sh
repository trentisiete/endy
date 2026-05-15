#!/usr/bin/env bash
# Launch (or reattach to) the endy tmux session.
#
# Layout (per-dir mode):
#   orchestrator  — interactive Codex in the project cwd
#   browse        — `endy watch browse` interactive picker
#   docs          — README / NEXT_STEPS
#
# Layout (overview mode — pure management session, no orchestrator):
#   tree          — `endy watch tree`     full task tree, all sessions
#   browse        — `endy watch browse`   interactive agent/tmux picker
#   sessions      — `endy watch sessions` per-session summary
#   agents        — `endy watch agents`   unified active-agents view
#   docs          — README / NEXT_STEPS
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
    SESSION="$(_endy_session_name "$launch_cwd")"
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
      task-*|chat-*|follow-*|panel|watch|browse|docs|tree|sessions|agents|help|opencode|logs)
        kill_window_if_exists "$window" ;;
    esac
  done <<< "$windows"
}

# Open a read-only `endy watch <view>` window that re-runs the view every 2s.
# Args: <window-name> <title-text> <endy-watch-args...>
open_view_window() {
  local window="$1"; shift
  local title="$1"; shift
  local q_session q_log_dir q_endy_root q_args=""
  q_session="$(printf '%q' "$SESSION")"
  q_log_dir="$(printf '%q' "$LOG_DIR")"
  q_endy_root="$(printf '%q' "$ENDY_ROOT")"
  local a
  for a in "$@"; do q_args+=" $(printf '%q' "$a")"; done

  kill_window_if_exists "$window"
  tmux new-window -t "$SESSION" -n "$window" -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "export ENDY_SESSION=${q_session}
export ENDY_LOG_DIR=${q_log_dir}
while :; do
  clear
  printf '\033[1;36m${title}\033[0m \033[2m| session=${SESSION} | auto-refresh 2s | Ctrl-c -> shell\033[0m\n'
  printf '\033[1;33mtmux: Ctrl-b w ventanas | Ctrl-b n/p sig/ant | Ctrl-b d detach\033[0m\n\n'
  ${q_endy_root}/bin/endy watch${q_args} || true
  sleep 2 || break
done
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
")"
}

# Open the interactive `endy watch browse` picker window (relaunched on exit).
# Args: extra args for `endy watch browse`.
open_browse_window() {
  local q_session q_log_dir q_endy_root q_args=""
  q_session="$(printf '%q' "$SESSION")"
  q_log_dir="$(printf '%q' "$LOG_DIR")"
  q_endy_root="$(printf '%q' "$ENDY_ROOT")"
  local a
  for a in "$@"; do q_args+=" $(printf '%q' "$a")"; done

  kill_window_if_exists browse
  tmux new-window -t "$SESSION" -n browse -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "clear
export ENDY_SESSION=${q_session}
export ENDY_LOG_DIR=${q_log_dir}
printf '\033[1;36mendy watch browse \033[0m\033[2m| session=${SESSION} | auto-relaunch\033[0m\n'
printf '\033[1;33mtmux: Ctrl-b w ventanas | Ctrl-b n/p sig/ant | Ctrl-b d detach\033[0m\n'
printf '\033[1;33menter chat/switch | Ctrl-o chat bg | Ctrl-f follow | Ctrl-v view | Ctrl-l log | Ctrl-k kill | Ctrl-d purge | esc salir\033[0m\n\n'
while :; do
  ${q_endy_root}/bin/endy watch browse${q_args}
  printf '\n\033[2mpicker cerrado — relanzando en 1s. Ctrl-c para shell.\033[0m\n'
  sleep 1 || break
done
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
")"
}

# Open the docs window (README / NEXT_STEPS in less).
open_docs_window() {
  kill_window_if_exists docs
  tmux new-window -t "$SESSION" -n docs -c "$ENDY_ROOT" \
    "bash -lc $(printf '%q' "clear
printf '\033[1;36mendy docs\033[0m\n'
printf '\033[1;33mREADME.md y NEXT_STEPS.md. q sale de less y deja una shell.\033[0m\n\n'
docs_files=()
for f in README.md NEXT_STEPS.md; do
  [[ -f \"\$f\" ]] && docs_files+=(\"\$f\")
done
if [[ \${#docs_files[@]} -gt 0 ]]; then
  less -R \"\${docs_files[@]}\"
else
  echo '(no README.md / NEXT_STEPS.md)'
fi
BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --noprofile --norc
")"
}

open_manager_windows() {
  if [[ "$mode" == "overview" ]]; then
    open_view_window   tree     'endy watch tree - arbol de tareas (todas las sesiones)'   tree --overview --live --all
    open_view_window   sessions 'endy watch sessions - resumen por sesion'                 sessions
    open_view_window   agents   'endy watch agents - agentes activos (todas las sesiones)' agents
    open_browse_window --overview --live
  else
    open_browse_window
  fi
  open_docs_window
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

if [[ "$mode" == "overview" ]]; then
  FOCUS_WINDOW="tree"
else
  FOCUS_WINDOW="orchestrator"
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  [[ "$clean" == "1" ]] && cleanup_runtime_windows
  open_manager_windows
  open_optional_windows
  configure_tmux_help
  # Cap scrollback to limit per-pane RAM (overrides ~/.tmux.conf's 100000).
  tmux set -g history-limit 25000
  tmux select-window -t "${SESSION}:${FOCUS_WINDOW}" 2>/dev/null || true
  if [[ "$attach" == "1" ]]; then
    echo "session '$SESSION' already running — attaching"
    exec tmux attach -t "$SESSION"
  fi
  cat <<EOF
session '${SESSION}' ready.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:${FOCUS_WINDOW}
  tmux kill-session -t ${SESSION}
EOF
  exit 0
fi

# Bootstrap the session. In per-dir mode window 0 is the interactive Codex
# orchestrator launched in the project cwd. In overview mode the session is
# pure management — no orchestrator window — so we open a throwaway window
# first, build the manager windows, then drop the placeholder.
if [[ "$mode" == "per-dir" ]]; then
  ORCH_CWD="$launch_cwd"
  q_orch_cwd="$(printf '%q' "$ORCH_CWD")"
  q_session="$(printf '%q' "$SESSION")"
  q_log_dir="$(printf '%q' "$LOG_DIR")"
  tmux new-session  -d -s "$SESSION" -n orchestrator -c "$ORCH_CWD"
  tmux send-keys -t "${SESSION}:orchestrator" \
    "export ENDY_ORCHESTRATOR=orchestrator; export ENDY_ORCHESTRATOR_AGENT=codex; export ENDY_ORCHESTRATOR_CWD=${q_orch_cwd}; export ENDY_SESSION=${q_session}; export ENDY_LOG_DIR=${q_log_dir}; codex" C-m
  open_manager_windows
  open_optional_windows
else
  tmux new-session -d -s "$SESSION" -n __bootstrap -c "$ENDY_ROOT"
  open_manager_windows
  open_optional_windows
  kill_window_if_exists __bootstrap
fi

# Cap scrollback to limit per-pane RAM (overrides ~/.tmux.conf's 100000).
tmux set -g history-limit 25000

configure_tmux_help
tmux select-window -t "${SESSION}:${FOCUS_WINDOW}" 2>/dev/null || true
if [[ "$attach" == "1" ]]; then
  exec tmux attach -t "$SESSION"
fi

cat <<EOF
session '${SESSION}' ready.

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:${FOCUS_WINDOW}
  tmux kill-session -t ${SESSION}
EOF
