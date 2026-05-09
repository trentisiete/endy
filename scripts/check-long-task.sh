#!/usr/bin/env bash
# Check status of an endy long task.
#
# Usage:
#   check-long-task.sh <task-id> [--tail <n>]
#   check-long-task.sh --list
#
# Output prefix is one of: RUNNING / DONE / FAILED / UNKNOWN.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-$(_endy_session_name "$(pwd)")}"
LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"
TAIL_N=50

# In --list mode we scan every per-dir scope unless the user explicitly
# scoped via ENDY_LOG_DIR. _list_log_dirs() prints one per line.
_list_log_dirs() {
  if [[ -n "${ENDY_LOG_DIR:-}" ]]; then
    printf '%s\n' "$ENDY_LOG_DIR"
  else
    _endy_list_per_dir_log_dirs
  fi
}

# Locate a task's meta file across scopes.
_find_meta() {
  local id="$1" d
  while IFS= read -r d; do
    if [[ -f "${d}/task-${id}.meta" ]]; then
      printf '%s\n' "${d}/task-${id}.meta"
      return 0
    fi
  done < <(_list_log_dirs)
  return 1
}

# Heuristic: even when exit==0, scan for common error markers. CLI agents
# (opencode in particular) often print errors and still exit 0. The first
# alternation handles ANSI-coloured logs by allowing arbitrary chars before
# the marker.
log_looks_failed() {
  local f="$1"
  grep -qE '(^|[^A-Za-z])(Error:|ERROR:|Exception:|Traceback)' "$f" 2>/dev/null \
    || grep -qE '(ProviderModelNotFoundError|Unauthorized|forbidden|model not found|auto-rejecting)' "$f" 2>/dev/null \
    || grep -qE 'Reached maximum (conversation )?turns|response may be incomplete' "$f" 2>/dev/null
}

meta_field() {
  local meta="$1" field="$2"
  grep "^${field}=" "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true
}

tmux_window_alive() {
  local window="$1"
  [[ -n "$window" ]] || return 1
  local session="endy"
  local window_name="$window"
  if [[ "$window" == *:* ]]; then
    session="${window%%:*}"
    window_name="${window#*:}"
  fi
  window_name="${window_name%%.*}"
  # Exact window-name check first: tmux display-message can resolve a
  # missing window to another live window, giving false positives.
  tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null \
    | grep -Fx -- "$window_name" >/dev/null || return 1
  local pane_dead
  pane_dead="$(tmux display-message -p -t "${session}:${window_name}.0" '#{pane_dead}' 2>/dev/null || true)"
  [[ -n "$pane_dead" && "$pane_dead" != "1" ]]
}

if [[ "${1:-}" == "--list" ]]; then
  shopt -s nullglob
  while IFS= read -r _scan_dir; do
    for m in "${_scan_dir}"/task-*.meta; do
    id="$(basename "$m" .meta | sed 's/^task-//')"
    spawned="$(meta_field "$m" spawned_at)"
    agent="$(meta_field "$m" agent)"
    kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    log="$(meta_field "$m" log)"; log="${log:-${_scan_dir}/task-${id}.log}"
    window="$(meta_field "$m" window)"
    if [[ ! -f "$log" ]]; then
      if [[ -n "$window" ]] && ! tmux_window_alive "$window"; then
        st="ABANDONED"
      else
        st="$([[ "$kind" == "chat" ]] && echo CHAT || echo PENDING)"
      fi
    elif grep -qE '^ENDY_EXIT=[0-9]+' "$log" 2>/dev/null; then
      ec="$(grep -E '^ENDY_EXIT=[0-9]+' "$log" | tail -1 | cut -d= -f2)"
      if [[ "$ec" == "0" ]]; then
        if log_looks_failed "$log"; then
          st="DONE-ERR"
        else
          st="DONE"
        fi
      else
        st="FAILED($ec)"
      fi
    elif [[ -n "$window" ]] && ! tmux_window_alive "$window"; then
      st="ABANDONED"
    elif [[ "$kind" == "chat" ]]; then
      st="CHAT"
    else
      st="RUNNING"
    fi
    printf '%-30s  %-8s  %-10s  %s\n' "$id" "$st" "$agent" "$spawned"
    done
  done < <(_list_log_dirs)
  unset _scan_dir
  shopt -u nullglob
  exit 0
fi

[[ $# -ge 1 ]] || { echo "usage: $0 <task-id> [--tail <n>]" >&2; exit 2; }
TASK_ID="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail) TAIL_N="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

META="${LOG_DIR}/task-${TASK_ID}.meta"
LOG="${LOG_DIR}/task-${TASK_ID}.log"
# Fallback: search every per-dir scope if not in our default LOG_DIR.
if [[ ! -f "$META" ]]; then
  if _found="$(_find_meta "$TASK_ID" 2>/dev/null)"; then
    META="$_found"
    LOG="${_found%.meta}.log"
  fi
  unset _found
fi
KIND="spawn"
if [[ -f "$META" ]]; then
  meta_log="$(meta_field "$META" log)"
  [[ -n "$meta_log" ]] && LOG="$meta_log"
  KIND="$(meta_field "$META" kind)"; KIND="${KIND:-spawn}"
fi

if [[ ! -f "$LOG" ]]; then
  if [[ "$KIND" == "chat" ]]; then
    echo "CHAT  no log yet at $LOG"
  else
    echo "UNKNOWN  no log at $LOG"
  fi
  exit 1
fi

window=""
[[ -f "$META" ]] && window="$(meta_field "$META" window)"

if grep -qE '^ENDY_EXIT=[0-9]+' "$LOG" 2>/dev/null; then
  ec="$(grep -E '^ENDY_EXIT=[0-9]+' "$LOG" | tail -1 | cut -d= -f2)"
  if [[ "$ec" == "0" ]]; then
    if log_looks_failed "$LOG"; then
      echo "DONE-WITH-ERRORS  exit=0  log=${LOG}  — agent logged an error despite exit 0"
    else
      echo "DONE  exit=0  log=${LOG}"
    fi
  else
    echo "FAILED  exit=${ec}  log=${LOG}"
  fi
elif [[ -n "$window" ]] && ! tmux_window_alive "$window"; then
  echo "ABANDONED  tmux window ${window} is gone or pane is dead, no exit code recorded  log=${LOG}"
elif [[ "$KIND" == "chat" ]]; then
  echo "CHAT  log=${LOG}"
else
  echo "RUNNING  log=${LOG}"
fi

if [[ -f "$META" ]]; then
  echo "--- meta ---"
  cat "$META"
fi

echo "--- last ${TAIL_N} lines ---"
tail -n "$TAIL_N" "$LOG"
