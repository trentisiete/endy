#!/usr/bin/env bash
# endy live — interactive agent pane orchestration
#
# Thin wrapper around tmux for the orchestrator-driven "live pane" pattern:
# open named agent windows, send prompts, capture output, manage lifecycle.
#
# Subcommands:
#   endy live open <name> <agent> [--cwd <dir>] [--model <m>] [--persona <p>] [--full-auto]
#   endy live send <name> <text...>
#   endy live send-file <name> <path>
#   endy live capture <name> [--lines <N>]
#   endy live clear <name>
#   endy live close <name>
#   endy live list
#   endy live status
#
# The orchestrator (Codex) decides window reuse, prompt strategy, and cleanup.
# This script provides the primitives — no policy.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-$(_endy_session_name "$(pwd)")}"
LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"

# Resolve a window name to a full tmux target. If the arg already contains ':',
# use it as-is. Otherwise prefix with $SESSION.
resolve_target() {
  local arg="$1"
  if [[ "$arg" == *:* ]]; then
    printf '%s' "$arg"
  else
    printf '%s:%s' "$SESSION" "$arg"
  fi
}

require_session() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "endy live: tmux session '$SESSION' not running — run: endy start" >&2
    exit 3
  fi
}

require_window() {
  local target="$1"
  local wname="${target##*:}"
  if ! tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qxF "$wname"; then
    echo "endy live: window '$target' not found in session '$SESSION'" >&2
    exit 4
  fi
}

# Safe text delivery: load into a named buffer, paste into pane, submit with Enter.
# Avoids send-keys' character-interpretation problems with quotes, $, ;, etc.
send_text_to_pane() {
  local target="$1" text="$2"
  printf '%s' "$text" | tmux load-buffer -b endy-live-send -
  tmux paste-buffer -b endy-live-send -t "$target"
  tmux delete-buffer -b endy-live-send 2>/dev/null || true
  tmux send-keys -t "$target" Enter
}

# Build the agent launch command string for a given agent type.
# Mirrors spawn-long-task.sh argv patterns exactly.
build_agent_cmd() {
  local agent="$1" cwd="$2" model="${3:-}" persona="${4:-}" full_auto="${5:-0}"

  case "$agent" in
    claude)
      local args=("claude")
      [[ -n "$model" ]] && args+=(--model "$model")
      [[ "$full_auto" == "1" ]] && args+=(--dangerously-skip-permissions)
      printf '%s ' "${args[@]}" | sed 's/ $//'
      ;;
    cmd|commandcode)
      local args=("cmd" --skip-onboarding --trust)
      [[ "$full_auto" == "1" ]] && args+=(--yolo)
      printf '%s ' "${args[@]}" | sed 's/ $//'
      ;;
    opencode)
      local args=("opencode" run --dir "$cwd")
      [[ -n "$persona" ]] && args+=(--agent "$persona")
      [[ -n "$model"   ]] && args+=(--model "$model")
      [[ "$full_auto" == "1" ]] && args+=(--dangerously-skip-permissions)
      printf '%s ' "${args[@]}" | sed 's/ $//'
      ;;
    hermes)
      local args=("hermes" chat -Q --accept-hooks)
      [[ -n "$persona" ]] && args+=(--skills "$persona")
      [[ -n "$model"   ]] && args+=(--model "$model")
      [[ "$full_auto" == "1" ]] && args+=(--yolo)
      printf '%s ' "${args[@]}" | sed 's/ $//'
      ;;
    codex)
      printf 'codex'
      ;;
    *)
      echo "endy live: unknown agent '$agent' (try: claude, cmd, opencode, hermes, codex)" >&2
      exit 2
      ;;
  esac
}

# Write a minimal .meta file so endy watch can see live panes.
write_live_meta() {
  local name="$1" cwd="$2" agent="$3" model="${4:-}" persona="${5:-}"
  local meta_file="${LOG_DIR}/live-${name}.meta"
  mkdir -p "$LOG_DIR"
  {
    printf 'kind=live\n'
    printf 'window=%s:%s\n' "$SESSION" "$name"
    printf 'cwd=%s\n' "$cwd"
    printf 'agent=%s\n' "$agent"
    [[ -n "$model"   ]] && printf 'model=%s\n' "$model"
    [[ -n "$persona" ]] && printf 'persona=%s\n' "$persona"
  } > "$meta_file"
}

# Remove the meta file on close.
remove_live_meta() {
  local name="$1"
  local meta_file="${LOG_DIR}/live-${name}.meta"
  rm -f "$meta_file"
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

cmd_live_open() {
  local name="" agent=""
  local cwd="$(pwd)" model="" persona="" full_auto=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd|--dir)   cwd="$2"; shift 2 ;;
      --model)       model="$2"; shift 2 ;;
      --persona)     persona="$2"; shift 2 ;;
      --full-auto)   full_auto=1; shift ;;
      -*)
        echo "endy live open: unknown flag '$1'" >&2
        echo "usage: endy live open <name> <agent> [--cwd <dir>] [--model <m>] [--persona <p>] [--full-auto]" >&2
        exit 2
        ;;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$agent" ]]; then agent="$1"
        else
          echo "endy live open: unexpected argument '$1'" >&2
          exit 2
        fi
        shift
        ;;
    esac
  done

  [[ -n "$name"  ]] || { echo "endy live open: <name> is required" >&2; exit 5; }
  [[ -n "$agent" ]] || { echo "endy live open: <agent> is required" >&2; exit 5; }

  require_session

  # Resolve cwd to absolute
  cwd="$(cd "$cwd" 2>/dev/null && pwd)" || { echo "endy live open: cannot access cwd '$cwd'" >&2; exit 6; }

  # Check for duplicate window name
  if tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qxF "$name"; then
    echo "endy live: window '$name' already exists in session '$SESSION' (reusing)"
    printf 'WINDOW=%s:%s\n' "$SESSION" "$name"
    return 0
  fi

  local agent_cmd
  agent_cmd="$(build_agent_cmd "$agent" "$cwd" "$model" "$persona" "$full_auto")"

  # Enable pipe-pane logging so output is captured for watch
  local log_file="${LOG_DIR}/live-${name}.log"
  mkdir -p "$LOG_DIR"

  tmux new-window -t "$SESSION" -n "$name" -c "$cwd" \
    "bash -lc $(printf '%q' "${agent_cmd} 2>&1 | tee ${log_file}")"
  tmux set-window-option -t "${SESSION}:${name}" remain-on-exit on 2>/dev/null || true

  write_live_meta "$name" "$cwd" "$agent" "$model" "$persona"

  printf 'WINDOW=%s:%s\n' "$SESSION" "$name"
}

cmd_live_send() {
  local name="${1:-}"
  [[ -n "$name" ]] || { echo "usage: endy live send <name> <text...>" >&2; exit 5; }
  shift

  local text="${*:-}"
  require_session

  local target; target="$(resolve_target "$name")"
  require_window "$target"

  # Clear any stale input first, then send
  tmux send-keys -t "$target" C-u
  send_text_to_pane "$target" "$text"
}

cmd_live_send_file() {
  local name="${1:-}" path="${2:-}"
  [[ -n "$name" ]] || { echo "usage: endy live send-file <name> <path>" >&2; exit 5; }
  [[ -n "$path" ]] || { echo "endy live send-file: <path> is required" >&2; exit 5; }

  # Resolve to absolute path
  local abs_path
  abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" || {
    echo "endy live send-file: cannot resolve path '$path'" >&2; exit 6
  }
  [[ -f "$abs_path" && -r "$abs_path" ]] || {
    echo "endy live send-file: file not found or not readable: $abs_path" >&2; exit 6
  }

  require_session

  local target; target="$(resolve_target "$name")"
  require_window "$target"

  tmux send-keys -t "$target" C-u
  send_text_to_pane "$target" "Please read ${abs_path} and follow it exactly."
}

cmd_live_capture() {
  local name="${1:-}"
  [[ -n "$name" ]] || { echo "usage: endy live capture <name> [--lines <N>]" >&2; exit 5; }
  shift

  local lines=80
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      *) echo "endy live capture: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done

  require_session

  local target; target="$(resolve_target "$name")"
  require_window "$target"

  tmux capture-pane -t "$target" -p -S -"$lines"
}

cmd_live_clear() {
  local name="${1:-}"
  [[ -n "$name" ]] || { echo "usage: endy live clear <name>" >&2; exit 5; }

  require_session

  local target; target="$(resolve_target "$name")"
  require_window "$target"

  tmux send-keys -t "$target" C-u
}

cmd_live_close() {
  local name="${1:-}"
  [[ -n "$name" ]] || { echo "usage: endy live close <name>" >&2; exit 5; }

  require_session

  local target; target="$(resolve_target "$name")"

  # Don't error if window is already gone
  tmux kill-window -t "$target" 2>/dev/null || true
  remove_live_meta "$name"
}

cmd_live_list() {
  require_session

  # System window name prefixes to exclude
  local system_prefixes="orchestrator watch docs tree help opencode logs panel task- chat- follow-"

  local excluded_pattern=""
  for pfx in $system_prefixes; do
    excluded_pattern="${excluded_pattern}${pfx}|"
  done
  excluded_pattern="${excluded_pattern%|}"

  while IFS= read -r wname; do
    # Skip system windows
    [[ "$wname" =~ ^($excluded_pattern) ]] && continue

    local target="${SESSION}:${wname}"
    local meta_file="${LOG_DIR}/live-${wname}.meta"
    local agent="?" cwd="?"

    if [[ -f "$meta_file" ]]; then
      agent="$(grep '^agent=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"
      cwd="$(grep '^cwd=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi

    agent="${agent:-?}"
    cwd="${cwd:-?}"

    printf '%s\t%s\t%s\n' "$wname" "$agent" "$cwd"
  done < <(tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null)
}

cmd_live_status() {
  require_session

  local now; now="$(date +%s)"
  local have_color=0
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && have_color=1

  local C_RST="" C_DIM="" C_BOLD="" C_BLU="" C_GRN="" C_YLW="" C_RED="" C_CYN="" C_MAG=""
  if [[ "$have_color" == "1" ]]; then
    C_RST=$'\033[0m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_BLU=$'\033[34m'
    C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYN=$'\033[36m'
    C_MAG=$'\033[35m'
  fi

  # Collect live pane entries from meta files
  local entries=()
  shopt -s nullglob
  local m
  for m in "${LOG_DIR}"/live-*.meta; do
    local name; name="$(basename "$m" .meta | sed 's/^live-//')"
    local agent; agent="$(grep '^agent=' "$m" 2>/dev/null | head -1 | cut -d= -f2-)"
    local cwd;   cwd="$(grep '^cwd=' "$m" 2>/dev/null | head -1 | cut -d= -f2-)"
    local persona; persona="$(grep '^persona=' "$m" 2>/dev/null | head -1 | cut -d= -f2-)"
    local model; model="$(grep '^model=' "$m" 2>/dev/null | head -1 | cut -d= -f2-)"

    agent="${agent:-?}"
    cwd="${cwd:-?}"

    # Check if window still exists
    if ! tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qxF "$name"; then
      entries+=("CLOSED"$'\t'"$name"$'\t'"$agent"$'\t'"$cwd"$'\t'""$'\t'""$'\t'"0")
      continue
    fi

    local target="${SESSION}:${name}"
    local log_file="${LOG_DIR}/live-${name}.log"

    # Detect status from log activity and pane content
    local status="unknown"
    local last_line=""
    local log_mtime=0

    if [[ -f "$log_file" ]]; then
      log_mtime="$(stat -c %Y "$log_file" 2>/dev/null || echo 0)"
      last_line="$(tail -1 "$log_file" 2>/dev/null | tr -d '\r\n' | head -c 120)"
    fi

    local age=$((now - log_mtime))

    # Capture pane for prompt detection
    local pane_content
    pane_content="$(tmux capture-pane -t "$target" -p -S -20 2>/dev/null || true)"

    # Detect prompt: lines ending with common agent prompt patterns
    local has_prompt=0
    if echo "$pane_content" | grep -qE '(> |codex>|➜|❯|$)'; then
      has_prompt=1
    fi

    if [[ "$age" -lt 10 ]]; then
      status="working"
    elif [[ "$has_prompt" == "1" ]]; then
      if [[ "$age" -lt 60 ]]; then
        status="ready"
      else
        status="idle"
      fi
    elif [[ "$age" -lt 30 ]]; then
      status="booting"
    else
      status="ready"  # fallback: assume ready if window exists
    fi

    # Uptime from meta file mtime
    local meta_mtime; meta_mtime="$(stat -c %Y "$m" 2>/dev/null || echo "$now")"
    local uptime=$((now - meta_mtime))

    entries+=("$status"$'\t'"$name"$'\t'"$agent"$'\t'"$cwd"$'\t'"$last_line"$'\t'"$(human_runtime "$uptime")"$'\t'"${persona:-—}"$'\t'"${model:-—}")
  done
  shopt -u nullglob

  if [[ "${#entries[@]}" -eq 0 ]]; then
    echo "(no live panes in session $SESSION)"
    echo "open one with: endy live open <name> <agent> [--cwd <dir>]"
    return 0
  fi

  # Print header
  printf '%s%-6s  %-28s  %-10s  %-40s  %s%-120s%s  %-9s\n' \
    "" "STATUS" "NAME" "AGENT" "CWD" "$C_DIM" "LAST OUTPUT" "$C_RST" "UPTIME"
  printf '%s\n' "$(printf '─%.0s' {1..220})"

  # Sort: working first, then ready, idle, booting, unknown, closed
  printf '%s\n' "${entries[@]}" | sort -t $'\t' -k1,1 | while IFS=$'\t' read -r status name agent cwd last_line uptime persona model; do
    local scolor sicon
    case "$status" in
      working) scolor="$C_GRN"; sicon="●" ;;
      ready)   scolor="$C_BLU"; sicon="◉" ;;
      idle)    scolor="$C_CYN"; sicon="◌" ;;
      booting) scolor="$C_YLW"; sicon="◔" ;;
      CLOSED)  scolor="$C_RED"; sicon="✕" ;;
      *)       scolor="$C_DIM"; sicon="?" ;;
    esac

    local agent_label="$agent"
    [[ -n "$persona" && "$persona" != "—" ]] && agent_label="${agent}[${persona}]"
    [[ -n "$model" && "$model" != "—" ]] && agent_label="${agent_label}(${model})"

    printf '%s%s %-5s%s  %-28s  %-10s  %-40s  %s%s%s  %-9s\n' \
      "$scolor" "$sicon" "$status" "$C_RST" \
      "$(printf '%.28s' "$name")" \
      "$(printf '%.10s' "$agent_label")" \
      "$(printf '%.40s' "$cwd")" \
      "$C_DIM" "$(printf '%.120s' "$last_line")" "$C_RST" \
      "$uptime"
  done
}

human_runtime() {
  local secs="$1"
  if   [[ $secs -lt 60     ]]; then printf '%ds' "$secs"
  elif [[ $secs -lt 3600   ]]; then printf '%dm%02ds' $((secs/60)) $((secs%60))
  elif [[ $secs -lt 86400  ]]; then printf '%dh%02dm' $((secs/3600)) $(((secs%3600)/60))
  else                              printf '%dd%02dh' $((secs/86400)) $(((secs%86400)/3600))
  fi
}

show_help() {
  sed -n '2,16p' "$0"
  exit 0
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  open)       shift; cmd_live_open "$@" ;;
  send)       shift; cmd_live_send "$@" ;;
  send-file)  shift; cmd_live_send_file "$@" ;;
  capture)    shift; cmd_live_capture "$@" ;;
  clear)      shift; cmd_live_clear "$@" ;;
  close)      shift; cmd_live_close "$@" ;;
  list)       shift; cmd_live_list "$@" ;;
  status)     shift; cmd_live_status "$@" ;;
  -h|--help|help) show_help ;;
  *)
    echo "endy live: unknown subcommand '${1:-}'" >&2
    echo "usage: endy live <open|send|send-file|capture|clear|close|list>" >&2
    exit 2
    ;;
esac
