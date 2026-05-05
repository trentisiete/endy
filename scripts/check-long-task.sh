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
LOG_DIR="${ENDY_ROOT}/.logs"
TAIL_N=50

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

if [[ "${1:-}" == "--list" ]]; then
  shopt -s nullglob
  for m in "${LOG_DIR}"/task-*.meta; do
    id="$(basename "$m" .meta | sed 's/^task-//')"
    spawned="$(grep '^spawned_at=' "$m" | cut -d= -f2-)"
    agent="$(grep '^agent=' "$m" | cut -d= -f2-)"
    log="${LOG_DIR}/task-${id}.log"
    if grep -qE '^ENDY_EXIT=[0-9]+' "$log" 2>/dev/null; then
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
    else
      st="RUNNING"
    fi
    printf '%-30s  %-8s  %-10s  %s\n' "$id" "$st" "$agent" "$spawned"
  done
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

LOG="${LOG_DIR}/task-${TASK_ID}.log"
META="${LOG_DIR}/task-${TASK_ID}.meta"

if [[ ! -f "$LOG" ]]; then
  echo "UNKNOWN  no log at $LOG"
  exit 1
fi

window=""
[[ -f "$META" ]] && window="$(grep '^window=' "$META" | cut -d= -f2-)"

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
elif [[ -n "$window" ]] && ! tmux list-windows -t "${window%%:*}" 2>/dev/null | grep -q "^[0-9]*: ${window##*:}"; then
  echo "ABANDONED  tmux window ${window} no longer exists, no exit code recorded  log=${LOG}"
else
  echo "RUNNING  log=${LOG}"
fi

if [[ -f "$META" ]]; then
  echo "--- meta ---"
  cat "$META"
fi

echo "--- last ${TAIL_N} lines ---"
tail -n "$TAIL_N" "$LOG"
