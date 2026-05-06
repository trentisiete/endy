#!/usr/bin/env bash
# Spawn an interactive endy chat session in a tmux window.
#
# Usage:
#   spawn-chat.sh --agent <opencode|cmd|claude|hermes>
#                 [--persona <name>]
#                 [--model <model>]
#                 [--cwd <dir>]
#                 [--resume <session-id>]
#                 [--parent-task <task-id>]
#                 [--orchestrator <name>]
#                 [--orchestrator-agent <agent>]
#                 [--full-auto]
#                 [--no-select]
#
# Output:
#   TASK_ID=<id>
#   TMUX_WINDOW=endy:chat-<id>
#   LOG=<absolute path>
#   META=<absolute path>

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ENDY_ROOT}/.logs"
SESSION="endy"

agent=""
persona=""
model=""
cwd="$(pwd)"
resume_id=""
parent_task=""
orchestrator=""
orchestrator_agent="${ENDY_ORCHESTRATOR_AGENT:-}"
origin_cwd="$(pwd)"
origin_pane="${TMUX_PANE:-}"
origin_session=""
origin_window=""
full_auto=0
select_window=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)        agent="$2";        shift 2 ;;
    --persona)      persona="$2";      shift 2 ;;
    --model)        model="$2";        shift 2 ;;
    --cwd)          cwd="$2";          shift 2 ;;
    --resume)       resume_id="$2";    shift 2 ;;
    --parent-task)  parent_task="$2";  shift 2 ;;
    --orchestrator) orchestrator="$2"; shift 2 ;;
    --orchestrator-agent) orchestrator_agent="$2"; shift 2 ;;
    --full-auto)    full_auto=1;       shift   ;;
    --no-select)    select_window=0;   shift   ;;
    -h|--help)
      sed -n '2,19p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$agent" ]] || { echo "--agent required (opencode|cmd|claude|hermes)" >&2; exit 2; }

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' not running - run ${ENDY_ROOT}/scripts/start.sh first" >&2
  exit 3
fi

cd "$cwd" || { echo "cannot cd to --cwd: $cwd" >&2; exit 2; }
cwd="$(pwd)"

if [[ -n "$origin_pane" ]]; then
  origin_session="$(tmux display-message -p -t "$origin_pane" '#S' 2>/dev/null || true)"
  origin_window="$(tmux display-message -p -t "$origin_pane" '#W' 2>/dev/null || true)"
fi
orchestrator="${orchestrator:-${ENDY_ORCHESTRATOR:-}}"
orchestrator="${orchestrator:-${origin_window:-manual}}"

mkdir -p "$LOG_DIR"

TASK_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"
WINDOW_NAME="chat-${TASK_ID}"
PROMPT_PATH="${LOG_DIR}/task-${TASK_ID}.prompt.md"
LOG_PATH="${LOG_DIR}/chat-${TASK_ID}.log"
META_PATH="${LOG_DIR}/task-${TASK_ID}.meta"

case "$agent" in
  opencode)
    cmd_argv=(opencode)
    [[ -n "$resume_id" ]] && cmd_argv+=(--session "$resume_id")
    [[ -n "$persona" ]] && cmd_argv+=(--agent "$persona")
    [[ -n "$model"   ]] && cmd_argv+=(--model "$model")
    ;;
  cmd|commandcode)
    cmd_argv=(cmd --skip-onboarding --trust)
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--yolo)
    [[ -n "$model" ]] && \
      echo "warning: cmd has no --model flag; '$model' ignored. Use 'cmd model' interactively to set it." >&2
    [[ -n "$persona" ]] && \
      echo "warning: cmd has no --agent flag; '$persona' ignored. Personas only via /agents interactively." >&2
    ;;
  claude)
    cmd_argv=(claude)
    [[ -n "$model" ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--dangerously-skip-permissions)
    ;;
  hermes)
    cmd_argv=(hermes chat --accept-hooks)
    [[ -n "$resume_id" ]] && cmd_argv+=(--resume "$resume_id")
    [[ -n "$persona" ]] && cmd_argv+=(--skills "$persona")
    [[ -n "$model"   ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--yolo)
    ;;
  *)
    echo "unknown --agent: $agent (expected: opencode|cmd|claude|hermes)" >&2; exit 2 ;;
esac

quoted_argv=""
for a in "${cmd_argv[@]}"; do
  quoted_argv+=" $(printf '%q' "$a")"
done

cat > "$PROMPT_PATH" <<EOF
Interactive endy chat session.

agent=${agent}
persona=${persona}
model=${model}
cwd=${cwd}
parent_task=${parent_task}
resume_id=${resume_id}
orchestrator=${orchestrator}
orchestrator_agent=${orchestrator_agent}
origin_session=${origin_session}
origin_window=${origin_window}
origin_pane=${origin_pane}
origin_cwd=${origin_cwd}

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:${WINDOW_NAME}
  tmux list-windows -t ${SESSION}
  tmux kill-window -t ${SESSION}:${WINDOW_NAME}

endy commands:
  endy watch view ${TASK_ID}
  endy watch follow ${TASK_ID}
  endy watch chat ${TASK_ID}
  endy watch followup ${TASK_ID} -- "<next prompt>"
  endy watch kill ${TASK_ID}
EOF

cat > "$META_PATH" <<EOF
task_id=${TASK_ID}
kind=chat
orchestrator=${orchestrator}
orchestrator_agent=${orchestrator_agent}
origin_session=${origin_session}
origin_window=${origin_window}
origin_pane=${origin_pane}
origin_cwd=${origin_cwd}
agent=${agent}
persona=${persona}
model=${model}
cwd=${cwd}
window=${SESSION}:${WINDOW_NAME}
log=${LOG_PATH}
prompt=${PROMPT_PATH}
spawned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
parent_task=${parent_task}
resume_id=${resume_id}
EOF

quoted_log_path="$(printf '%q' "$LOG_PATH")"
target="${SESSION}:${WINDOW_NAME}.0"

inner_script="
sleep 0.5
clear
printf '\033[1;36mendy chat: %s\033[0m\n' '${agent}'
printf '\033[1;33mtmux: attach=%s | select=%s | picker=Ctrl-b w | detach=Ctrl-b d\033[0m\n' '${SESSION}' '${SESSION}:${WINDOW_NAME}'
printf '\033[1;33mendy: view=%s | follow=%s | chat=%s | followup=%s | kill=%s\033[0m\n\n' 'endy watch view ${TASK_ID}' 'endy watch follow ${TASK_ID}' 'endy watch chat ${TASK_ID}' 'endy watch followup ${TASK_ID} -- \"<next prompt>\"' 'endy watch kill ${TASK_ID}'
printf 'Starting:%s\n\n' '${quoted_argv}'
exec ${quoted_argv}
"
inner_cmd="bash -lc $(printf '%q' "$inner_script")"

tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -c "$cwd" "$inner_cmd"
tmux set-window-option -t "${SESSION}:${WINDOW_NAME}" remain-on-exit on 2>/dev/null || true
tmux pipe-pane -o -t "$target" "cat >> ${quoted_log_path}"
[[ "$select_window" == "1" ]] && tmux select-window -t "${SESSION}:${WINDOW_NAME}"

cat <<EOF
TASK_ID=${TASK_ID}
TMUX_WINDOW=${SESSION}:${WINDOW_NAME}
LOG=${LOG_PATH}
META=${META_PATH}

tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:${WINDOW_NAME}
  tmux list-windows -t ${SESSION}
  tmux kill-window -t ${SESSION}:${WINDOW_NAME}

endy commands:
  endy watch view ${TASK_ID}
  endy watch follow ${TASK_ID}
  endy watch chat ${TASK_ID}
  endy watch followup ${TASK_ID} -- "<next prompt>"
  endy watch kill ${TASK_ID}
EOF
