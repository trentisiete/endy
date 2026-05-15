#!/usr/bin/env bash
# Spawn a long-running endy subagent task in a detached tmux window.
#
# Usage:
#   spawn-long-task.sh --agent <opencode|cmd|claude|hermes>
#                      [--persona <name>]              # opencode: --agent; hermes: --skills; cmd: ignored (no CLI flag)
#                      [--model <model>]
#                      [--cwd <dir>]
#                      [--full-auto]                   # auto-approve permission prompts
#                      [--max-turns <n>]               # cmd & hermes only; raise the tool-call ceiling
#                      [--orchestrator <name>]          # logical parent/orchestrator label
#                      [--orchestrator-agent <agent>]   # logical parent agent label
#                      ( --prompt "<text>" | --prompt-file <path> )
#
# Output (stdout, machine-parseable):
#   TASK_ID=<id>
#   TMUX_WINDOW=endy:task-<id>
#   LOG=<absolute path>
#
# Exit code:
#   0  task spawned (says nothing about success of the task itself)
#   2  bad arguments
#   3  target tmux session not running — run `endy start` or `endy overview` first
#
# Implementation note: the prompt is persisted to a file and the inner shell
# command reads it back via "$(cat <file>)" at runtime, so the agent
# invocation that tmux launches is short (a few hundred bytes regardless of
# prompt size). This avoids the tmux send-keys bug where pasting a 2KB+
# prompt character-by-character into a shell prompt could hang or get
# interleaved.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-$(_endy_session_name "$(pwd)")}"
LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"

agent=""
persona=""
model=""
cwd="$(pwd)"
prompt=""
prompt_file=""
full_auto=0
resume_id=""
parent_task=""
handoff_from=""
handoff_chain=""
handoff_reason=""
orchestrator=""
orchestrator_agent="${ENDY_ORCHESTRATOR_AGENT:-}"
origin_cwd="$(pwd)"
origin_pane="${TMUX_PANE:-}"
origin_session=""
origin_window=""
# Default 200: cmd's hidden --max-turns silently caps complex tool-using
# research at 10 unless raised (verified May 2026 v0.25.1). 200 is
# generous enough for any reasonable agentic chain. User-pass --max-turns
# overrides; agents that ignore the flag (opencode, claude) just drop it.
max_turns=200

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)        agent="$2";        shift 2 ;;
    --persona)      persona="$2";      shift 2 ;;
    --model)        model="$2";        shift 2 ;;
    --cwd)          cwd="$2";          shift 2 ;;
    --prompt)       prompt="$2";       shift 2 ;;
    --prompt-file)  prompt_file="$2";  shift 2 ;;
    --full-auto)    full_auto=1;       shift   ;;
    --max-turns)    max_turns="$2";    shift 2 ;;
    --resume)         resume_id="$2";     shift 2 ;;
    --parent-task)    parent_task="$2";   shift 2 ;;
    --handoff-from)   handoff_from="$2";  shift 2 ;;
    --handoff-chain)  handoff_chain="$2"; shift 2 ;;
    --handoff-reason) handoff_reason="$2"; shift 2 ;;
    --orchestrator) orchestrator="$2"; shift 2 ;;
    --orchestrator-agent) orchestrator_agent="$2"; shift 2 ;;
    --session)      SESSION="$2";      shift 2 ;;
    --log-dir)      LOG_DIR="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$agent" ]] || { echo "--agent required (opencode|cmd|claude|hermes)" >&2; exit 2; }
[[ -n "$prompt" || -n "$prompt_file" ]] || \
  { echo "--prompt or --prompt-file required" >&2; exit 2; }

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' not running — run 'endy start' first (or 'endy overview' for the global session)" >&2
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

TASK_ID="$(date +%Y%m%d-%H%M%S)-$(_endy_rand_hex4)"
PROMPT_PATH="${LOG_DIR}/task-${TASK_ID}.prompt.md"
LOG_PATH="${LOG_DIR}/task-${TASK_ID}.log"
META_PATH="${LOG_DIR}/task-${TASK_ID}.meta"

if [[ -n "$prompt_file" ]]; then
  cp "$prompt_file" "$PROMPT_PATH"
else
  printf '%s\n' "$prompt" > "$PROMPT_PATH"
fi

# Build agent argv (everything EXCEPT the final prompt argument).
case "$agent" in
  opencode)
    cmd_argv=(opencode run --dir "$cwd")
    [[ -n "$resume_id" ]] && cmd_argv+=(--session "$resume_id")
    [[ -n "$persona" ]] && cmd_argv+=(--agent "$persona")
    [[ -n "$model"   ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--dangerously-skip-permissions)
    ;;
  cmd|commandcode)
    # cmd has no --model or --agent CLI flag (slash commands only).
    # Personas live at ~/.commandcode/agents/<name>.md but selection is
    # interactive-only — for non-interactive use, send ad-hoc inline prompts.
    # Pre-auth required: cmd login → ~/.commandcode/auth.json must exist.
    # --max-turns is undocumented in --help but accepted (verified May 2026 v0.25.1).
    cmd_argv=(cmd --skip-onboarding --trust)
    explicit_model="$model"
    if [[ -z "$model" ]]; then
      if command -v jq >/dev/null 2>&1 && [[ -f "${HOME}/.commandcode/config.json" ]]; then
        model="$(jq -r '.model // empty' "${HOME}/.commandcode/config.json" 2>/dev/null || true)"
      fi
    fi
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--yolo)
    [[ -n "$max_turns" ]] && cmd_argv+=(--max-turns "$max_turns")
    [[ -n "$resume_id" ]] && cmd_argv+=(-r "$resume_id")
    [[ -n "$explicit_model" ]] && \
      echo "info: cmd has no --model flag; '$explicit_model' recorded for metadata only. Use 'cmd model' interactively to set it." >&2
    [[ -n "$persona" ]] && \
      echo "warning: cmd has no --agent flag; '$persona' ignored. Personas only via /agents interactively." >&2
    cmd_argv+=(-p)
    ;;
  claude)
    # Same pattern as cmd — keep -p adjacent to the prompt.
    cmd_argv=(claude)
    [[ -n "$model" ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--dangerously-skip-permissions)
    cmd_argv+=(-p)
    ;;
  hermes)
    cmd_argv=(hermes chat -Q --accept-hooks)
    [[ -n "$resume_id" ]] && cmd_argv+=(--resume "$resume_id")
    [[ -n "$persona" ]] && cmd_argv+=(--skills "$persona")
    [[ -n "$model"   ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--yolo)
    [[ -n "$max_turns" ]] && cmd_argv+=(--max-turns "$max_turns")
    cmd_argv+=(-q)
    ;;
  gemini)
    # Gemini CLI (google-gemini/gemini-cli). Takes the prompt on stdin or
    # as the last positional. We pass it positionally — same shape as the
    # other agents. --yolo is gemini's auto-approve flag.
    cmd_argv=(gemini)
    [[ -n "$model" ]] && cmd_argv+=(--model "$model")
    [[ "$full_auto" == "1" ]] && cmd_argv+=(--yolo)
    cmd_argv+=(-p)
    ;;
  bash|stub|noop)
    # Offline stub agent. Prints the prompt and idles. Useful for smoke-
    # testing the endy machinery (handoff chain, tree rendering, web
    # surface) without burning real-agent credits. cmd_argv left empty —
    # INNER_CMD has a dedicated path for this agent below.
    cmd_argv=()
    ;;
  *)
    echo "unknown --agent: $agent (expected: opencode|cmd|claude|hermes|gemini|bash)" >&2; exit 2 ;;
esac

# Shell-quote each argv element so spaces, quotes, etc. survive.
quoted_argv=""
for a in "${cmd_argv[@]+"${cmd_argv[@]}"}"; do
  quoted_argv+=" $(printf '%q' "$a")"
done

quoted_prompt_path="$(printf '%q' "$PROMPT_PATH")"
quoted_log_path="$(printf '%q' "$LOG_PATH")"

# The full shell command run inside the new tmux window. The prompt is
# substituted by the shell at runtime via $(cat <file>), so the literal
# command stays small even for 100KB prompts.
if [[ "$agent" == "bash" || "$agent" == "stub" || "$agent" == "noop" ]]; then
  # Offline stub: print the prompt + idle. No external command, no API.
  INNER_CMD="{ printf '[stub agent — prompt follows]\\n'; cat ${quoted_prompt_path}; printf '\\n[stub idle — Ctrl-c to exit, or kill via endy watch kill]\\n'; sleep infinity; } 2>&1 | tee ${quoted_log_path}"
else
  INNER_CMD="{ ${quoted_argv} \"\$(cat ${quoted_prompt_path})\" ; printf '\\nENDY_EXIT=%d\\n' \$? ; } 2>&1 | tee ${quoted_log_path}"
fi

WINDOW_NAME="task-${TASK_ID}"
tmux new-window -t "${SESSION}" -n "${WINDOW_NAME}" -c "${cwd}" "${INNER_CMD}"
tmux set-window-option -t "${SESSION}:${WINDOW_NAME}" remain-on-exit on 2>/dev/null || true

cat > "$META_PATH" <<EOF
task_id=${TASK_ID}
kind=spawn
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
handoff_from=${handoff_from}
handoff_chain=${handoff_chain}
handoff_reason=${handoff_reason}
EOF

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
