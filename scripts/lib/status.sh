#!/usr/bin/env bash
# scripts/lib/status.sh — single source of truth for endy task status.
#
# Sourced by:
#   - scripts/endy-watch.sh
#   - scripts/_endy-preview.sh
#
# When adding new patterns, also update web/server.py's ERR_PATTERNS regex
# and check-long-task.sh's log_looks_failed() — those don't share this file.
#
# Public API (after sourcing):
#   endy_log_status <log> [task_id] [kind] [session]
#       echoes one of: PENDING | RUN | CHAT | DONE | DONE-ERR | FAIL(<n>) | ABANDONED
#   $ENDY_STATUS_ERR_REGEX_*   — three regexes used by callers that want to
#                                 grep logs for the same heuristic.

# shellcheck disable=SC2034
ENDY_STATUS_ERR_REGEX_BASIC='(^|[^A-Za-z])(Error:|ERROR:|Exception:|Traceback)'
ENDY_STATUS_ERR_REGEX_PROVIDER='(ProviderModelNotFoundError|Unauthorized|forbidden|model not found|auto-rejecting)'
ENDY_STATUS_ERR_REGEX_TURNS='Reached maximum (conversation )?turns|response may be incomplete'

endy_log_status() {
  local log="$1"
  local task_id="${2:-}"
  local kind="${3:-spawn}"
  local session="${4:-${SESSION:-endy}}"

  local exists_in_tmux=0
  local expected_window="task-${task_id}"
  [[ "$kind" == "chat" ]] && expected_window="chat-${task_id}"
  if [[ -n "$task_id" ]] \
     && tmux list-windows -t "$session" -F '#W' 2>/dev/null \
        | grep -qx "$expected_window"; then
    exists_in_tmux=1
  fi

  if [[ ! -f "$log" ]]; then
    if [[ -n "$task_id" && "$exists_in_tmux" == "0" ]]; then
      echo "ABANDONED"
    elif [[ "$kind" == "chat" ]]; then
      echo "CHAT"
    else
      echo "PENDING"
    fi
    return
  fi

  if grep -qE '^ENDY_EXIT=[0-9]+' "$log" 2>/dev/null; then
    local ec
    ec="$(grep -E '^ENDY_EXIT=[0-9]+' "$log" | tail -1 | cut -d= -f2)"
    if [[ "$ec" == "0" ]]; then
      if grep -qE "$ENDY_STATUS_ERR_REGEX_BASIC"    "$log" 2>/dev/null \
         || grep -qE "$ENDY_STATUS_ERR_REGEX_PROVIDER" "$log" 2>/dev/null \
         || grep -qE "$ENDY_STATUS_ERR_REGEX_TURNS"    "$log" 2>/dev/null
      then echo "DONE-ERR"
      else echo "DONE"
      fi
    else
      echo "FAIL($ec)"
    fi
    return
  fi

  if [[ -n "$task_id" && "$exists_in_tmux" == "0" ]]; then
    echo "ABANDONED"
  elif [[ "$kind" == "chat" ]]; then
    echo "CHAT"
  else
    echo "RUN"
  fi
}
