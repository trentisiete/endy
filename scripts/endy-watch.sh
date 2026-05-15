#!/usr/bin/env bash
# endy-watch — read-only monitoring of the endy tmux session.
#
# Passive observer: never sends keystrokes to the agent windows. The
# orchestrator drives the session; you watch.
#
# Commands:
#   endy-watch                    Attach to the 'endy' tmux session
#                                 (read-write by default — Ctrl-b N navigates).
#   endy-watch attach [<id>] [--strict]
#                                 If <id> given, opens with that task window
#                                 active. --strict re-enables read-only mode
#                                 (blocks navigation too — rarely what you want).
#   endy-watch list               Enriched table: id / status / parent /
#                                 orchestrator / agent / persona / cwd / runtime / last.
#                                 Designed to scan
#                                 even with 15+ active tasks.
#   endy-watch tree [--all]       Group tasks by orchestrator and working directory.
#   endy-watch dir <path>         Group tasks under one working directory.
#   endy-watch log <id>           Open that task's log in `less +F` (follow mode).
#                                 q quits, /pattern searches, F re-enters follow.
#                                 <id> matches by prefix; one match required.
#   endy-watch view <id>          One-shot dump: meta + original prompt + last
#                                 200 lines of log, paged through less. Doesn't
#                                 touch tmux — pure stdout-then-quit.
#   endy-watch follow <id>        Open a NEW tmux window named 'follow-<id>'
#                                 showing the prompt header + live log tail.
#                                 Multiple calls → multiple windows so you can
#                                 watch agent A and agent B side-by-side without
#                                 either being interrupted. Switch with Ctrl-b N.
#   endy-watch chat <id>          Open an interactive chat window for that task's
#                                 agent/cwd. opencode/hermes resume natively when
#                                 a session id can be found; cmd injects context
#                                 for headless spawn tasks.
#   endy-watch browse [--all] [--cwd <dir>] [--orch <name>]
#                                 Interactive picker. Uses fzf if installed
#                                 (live preview in side pane); falls back to
#                                 the table otherwise. Enter opens/focuses chat
#                                 in foreground and exits the picker.
#                                 ^O always opens chat in background.
#                                 ^G is an explicit foreground alias.
#   endy-watch panel [--all]      Tile view of running task logs. Warns if >4
#                                 (suggest 'browse' or 'follow' instead).
#   endy-watch followup <id> [-- <new-prompt>]
#                                 Continue the conversation of an existing task.
#                                 hermes/opencode → native session resume.
#                                 cmd → native resume by title (.meta.json),
#                                 falls back to context injection. New tmux
#                                 window, new TASK_ID, with parent_task
#                                 pointing back to <id>.
#   endy-watch kill <id>          Kill a stuck task (closes its tmux window AND
#                                 writes ENDY_EXIT=130 to the log so it's not
#                                 reported as RUNNING forever).
#   endy-watch gc [--dry-run]     Clean up dead windows (DONE / DONE-ERR / FAIL /
#                                 ABANDONED). Safe, idempotent, zero risk to active tasks.
#   endy-watch kill-all --agent <name> | --cwd <dir> | --orch <name> | --everything | --done
#                                 Close every matching task/chat/follow window.
#                                 --done limits scope to finished/failed/abandoned tasks.
#   endy-watch purge <id> [--dry-run]
#                                 Purge one task and all its descendants from
#                                 .logs/ and kill their tmux windows. Double
#                                 confirmation required (type '&', then the full
#                                 task id). Aliases: delete, purge-session.
#   endy-watch help               This text.

set -u

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-$(_endy_session_name "$(pwd)")}"
LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"

# Per-command --overview / --all-sessions flag toggles aggregator mode where
# we scan every per-dir log dir AND the global one. Subcommands set
# AGGREGATE=1 then call _aggregate_log_dirs to iterate.
AGGREGATE=0
LIVE_ONLY=0
_aggregate_log_dirs() {
  if [[ "$AGGREGATE" == "1" ]]; then
    _endy_list_per_dir_log_dirs
  else
    printf '%s\n' "$LOG_DIR"
  fi
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'
  C_MAG=$'\033[35m'
  C_CYN=$'\033[36m'
  C_GRY=$'\033[90m'
else
  C_RST=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_MAG=""; C_CYN=""; C_GRY=""
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

require_session() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "no '$SESSION' tmux session running — start it with scripts/start.sh" >&2
    exit 1
  fi
}

# Strip ANSI escapes so the table stays aligned.
strip_ansi() {
  perl -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\eP.*?\e\\//g; s/\e_.*?\e\\//g; s/\e\[[0-9;?<>]*[ -\/]*[@-~]//g; s/\e[()][A-Za-z0-9]//g; s/\e[=>]//g; s/\e\\//g; s/\e//g'
}

# List every meta file across the active scope (one dir in default scope,
# all per-dir dirs + global in --overview/aggregate scope). Newline-separated.
_iter_meta_files() {
  shopt -s nullglob
  local dir m
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    for m in "${dir}"/task-*.meta; do
      [[ -f "$m" ]] && printf '%s\n' "$m"
    done
  done < <(_aggregate_log_dirs)
  shopt -u nullglob
}

# Locate the meta file for a given task id, searching the active scope.
_meta_for_id() {
  local id="$1"
  local m
  while IFS= read -r m; do
    [[ "$(basename "$m")" == "task-${id}.meta" ]] && { printf '%s\n' "$m"; return 0; }
  done < <(_iter_meta_files)
  return 1
}

# Resolve a task id prefix to a full task id (errors if 0 or >1 matches).
resolve_id() {
  local prefix="$1"
  local matches=()
  local m id
  while IFS= read -r m; do
    id="$(basename "$m" .meta | sed 's/^task-//')"
    if [[ "$id" == "$prefix"* || "$id" == *"$prefix"* ]]; then
      matches+=("$id")
    fi
  done < <(_iter_meta_files)
  case "${#matches[@]}" in
    0) echo "no task matching '$prefix'" >&2; return 1 ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *) echo "ambiguous '$prefix' matches:" >&2
       printf '  %s\n' "${matches[@]}" >&2
       return 1 ;;
  esac
}

human_runtime() {
  local secs="$1"
  if   [[ $secs -lt 60     ]]; then printf '%ds' "$secs"
  elif [[ $secs -lt 3600   ]]; then printf '%dm%02ds' $((secs/60)) $((secs%60))
  elif [[ $secs -lt 86400  ]]; then printf '%dh%02dm' $((secs/3600)) $(((secs%3600)/60))
  else                              printf '%dd%02dh' $((secs/86400)) $(((secs%86400)/3600))
  fi
}

# Read a key=value field from a meta file.
meta_field() {
  local meta="$1" field="$2"
  grep "^${field}=" "$meta" 2>/dev/null | head -1 | cut -d= -f2-
}

task_meta_path() {
  local id="$1"
  local found
  found="$(_meta_for_id "$id" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
  else
    printf '%s/task-%s.meta\n' "$LOG_DIR" "$id"
  fi
}

task_prompt_path() {
  local meta="$1" id="$2"
  local path; path="$(meta_field "$meta" prompt)"
  [[ -n "$path" ]] || path="${LOG_DIR}/task-${id}.prompt.md"
  printf '%s\n' "$path"
}

task_log_path() {
  local meta="$1" id="$2"
  local path; path="$(meta_field "$meta" log)"
  [[ -n "$path" ]] || path="${LOG_DIR}/task-${id}.log"
  printf '%s\n' "$path"
}

task_window_name() {
  local meta="$1" id="$2"
  local window; window="$(meta_field "$meta" window)"
  if [[ -n "$window" ]]; then
    printf '%s\n' "${window##*:}"
    return
  fi
  printf 'task-%s\n' "$id"
}

print_task_commands() {
  local id="$1" window_name="$2"
  cat <<EOF
tmux commands:
  tmux attach -t ${SESSION}
  tmux select-window -t ${SESSION}:${window_name}
  tmux list-windows -t ${SESSION}
  tmux kill-window -t ${SESSION}:${window_name}

endy commands:
  endy watch view ${id}
  endy watch follow ${id}
  endy watch chat ${id}
  endy watch followup ${id} -- "<next prompt>"
  endy watch kill ${id}
EOF
}

short_task_ref() {
  local id="$1"
  local short="${id#*-}"
  [[ ${#short} -gt 13 ]] && short="…${short: -12}"
  printf '%s\n' "$short"
}

task_orchestrator() {
  local meta="$1"
  local orch; orch="$(meta_field "$meta" orchestrator)"
  local origin_window; origin_window="$(meta_field "$meta" origin_window)"
  orch="${orch:-${origin_window:-manual}}"
  printf '%s\n' "$orch"
}

task_orchestrator_label() {
  local meta="$1"
  local orch; orch="$(task_orchestrator "$meta")"
  local orch_agent; orch_agent="$(meta_field "$meta" orchestrator_agent)"
  if [[ -n "$orch_agent" ]]; then
    printf '%s[%s]\n' "$orch" "$orch_agent"
  else
    printf '%s\n' "$orch"
  fi
}

cmd_active_model() {
  local cfg="${HOME}/.commandcode/config.json"
  [[ -f "$cfg" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.model // empty' "$cfg" 2>/dev/null
  else
    python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('model',''))" "$cfg" 2>/dev/null
  fi
}

model_label() {
  local meta="$1" log="$2" agent="$3"
  local model; model="$(meta_field "$meta" model)"
  if [[ -z "$model" && -f "$log" ]]; then
    case "$agent" in
      opencode)
        model="$(strip_ansi < "$log" 2>/dev/null \
          | awk -F ' · ' '/^> / { print $2; exit }' \
          | tr -d '\r')"
        ;;
      cmd|commandcode)
        model="$(cmd_active_model)"
        model="${model##*/}"
        ;;
    esac
  fi
  [[ -n "$model" ]] || model="—"
  printf '%s\n' "$model"
}

cwd_matches_filter() {
  local cwd="$1" filter="$2"
  [[ -z "$filter" ]] && return 0
  [[ "$cwd" == "$filter" || "$cwd" == "$filter"/* ]]
}

status_color() {
  case "$1" in
    RUN|PENDING|CHAT) printf '%s' "$C_BLU" ;;
    DONE) printf '%s' "$C_GRN" ;;
    DONE-ERR) printf '%s' "$C_YLW" ;;
    FAIL*|FAILED*) printf '%s' "$C_RED" ;;
    ABANDONED) printf '%s' "$C_GRY" ;;
    *) printf '%s' "$C_RST" ;;
  esac
}

tail_pane_command() {
  local id="$1" log="$2" label="$3"
  local quoted_log; quoted_log="$(printf '%q' "$log")"
  local script="
clear
printf '\033[1;36m%s\033[0m\n' '${label}'
printf '\033[1;33mtmux: attach=%s | picker=Ctrl-b w | detach=Ctrl-b d | kill-pane=Ctrl-b x\033[0m\n' '${SESSION}'
printf '\033[1;33mendy: view=%s | chat=%s | followup=%s | kill=%s\033[0m\n\n' 'endy watch view ${id}' 'endy watch chat ${id}' 'endy watch followup ${id} -- \"<next prompt>\"' 'endy watch kill ${id}'
exec tail -F ${quoted_log}
"
  printf 'bash -c %s' "$(printf '%q' "$script")"
}

focus_window() {
  local window="$1"
  tmux_window_alive "$window" || { echo "tmux window missing: $window" >&2; return 1; }
  tmux select-window -t "$window" 2>/dev/null || return 1
  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$window"
  fi
  exec tmux attach -t "$window"
}

tmux_window_alive() {
  local window="$1"
  [[ -n "$window" ]] || return 1
  local session="$SESSION"
  local window_name="$window"
  if [[ "$window" == *:* ]]; then
    session="${window%%:*}"
    window_name="${window#*:}"
  fi
  window_name="${window_name%%.*}"
  tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null \
    | grep -Fx -- "$window_name" >/dev/null || return 1
  local pane_dead
  pane_dead="$(tmux display-message -p -t "${session}:${window_name}.0" '#{pane_dead}' 2>/dev/null || true)"
  [[ -n "$pane_dead" && "$pane_dead" != "1" ]]
}

resume_id_for_task() {
  local agent="$1" cwd="$2" log="$3"
  local sid=""
  case "$agent" in
    hermes)
      sid="$(grep -oE '^session_id: +[0-9]{8}_[0-9]{6}_[a-f0-9]{6}$' "$log" 2>/dev/null \
            | tail -1 | awk '{print $2}')"
      ;;
    opencode)
      local opencode_db="${HOME}/.local/share/opencode/opencode.db"
      if [[ -f "$opencode_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
        sid="$(sqlite3 "$opencode_db" \
          "SELECT id FROM session WHERE directory = '$(printf %s "$cwd" | sed "s/'/''/g")' \
           ORDER BY time_created DESC LIMIT 1;" 2>/dev/null)"
      fi
      ;;
    cmd|commandcode)
      local slug="${cwd//\//-}"
      slug="${slug#-}"  # strip leading dash from absolute paths
      slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
      local pdir="${HOME}/.commandcode/projects/${slug}"
      if [[ -d "$pdir" ]] && command -v jq >/dev/null 2>&1; then
        local newest_meta
        newest_meta="$(ls -t "$pdir"/*.meta.json 2>/dev/null | head -1)"
        [[ -n "$newest_meta" ]] && sid="$(jq -r '.title // empty' "$newest_meta" 2>/dev/null)"
      fi
      ;;
  esac
  printf '%s\n' "$sid"
}

# Status heuristic lives in scripts/lib/status.sh so the preview pane can
# reuse it. Patch that file when adding new error patterns. NOTE: web/server.py
# and check-long-task.sh have their own (parallel) copies — keep them in sync.
# shellcheck source=lib/status.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"

log_status() { endy_log_status "$@"; }

# ---------------------------------------------------------------------------
# list — enriched table
# ---------------------------------------------------------------------------

cmd_list() {
  local cwd_filter=""
  local orch_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      --overview|--all-sessions) AGGREGATE=1; shift ;;
      --live) LIVE_ONLY=1; shift ;;
      *) echo "usage: endy watch list [--cwd <dir>] [--orch <name>] [--overview] [--live]" >&2; exit 2 ;;
    esac
  done
  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

  local now; now="$(date +%s)"
  local found=0

  # Header
  printf '%b%-22s %-9s %-13s %-14s %-9s %-16s %-30s %-7s %s%b\n' \
    "$C_BOLD$C_CYN" "ID" "STATUS" "PARENT" "ORCH" "AGENT" "MODEL" "CWD" "RUN" "LAST" "$C_RST"
  printf '%b%-22s %-9s %-13s %-14s %-9s %-16s %-30s %-7s %s%b\n' \
    "$C_DIM" "──────────────────────" "─────────" "─────────────" "──────────────" "─────────" "────────────────" "──────────────────────────────" "───────" "──────────" "$C_RST"

  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"

    local agent;       agent="$(meta_field "$m" agent)"
    local persona;     persona="$(meta_field "$m" persona)"; persona="${persona:-—}"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local kind;        kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local parent;      parent="$(meta_field "$m" parent_task)"
    local orch;        orch="$(task_orchestrator "$m")"
    local orch_label;  orch_label="$(task_orchestrator_label "$m")"
    local model;       model="$(model_label "$m" "$log" "$agent")"
    local window;      window="$(meta_field "$m" window)"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    found=1
    local parent_short="—"
    [[ -n "$parent" ]] && parent_short="$(short_task_ref "$parent")"

    # spawned_iso is ISO-8601 UTC like 2026-05-05T10:18:27Z. Uses _endy_iso_to_epoch (portable).
    local spawned_epoch
    spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local runtime
    if [[ "$spawned_epoch" != "0" ]]; then
      runtime="$(human_runtime $((now - spawned_epoch)))"
    else
      runtime="?"
    fi

    local status; status="$(log_status "$log" "$id" "$kind")"

    local last
    if [[ "$kind" == "chat" ]]; then
      last="(interactive pane captured)"
    elif [[ -f "$log" ]]; then
      # Show the last meaningful line: skip blank lines and the ENDY_EXIT
      # marker so the column reflects what the agent actually said last.
      last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\]|[[:space:]]*$)' "$log" 2>/dev/null \
              | tail -n 200 | strip_ansi | tr -d '\r' \
              | awk '/[[:alnum:]]/ { line=$0 } END { print line }' \
              | head -c 80)"
      [[ -z "$last" ]] && last="(empty)"
    else
      last="(no log yet)"
    fi

    # Truncate cwd to fit
    local cwd_short
    if [[ ${#cwd} -gt 30 ]]; then
      cwd_short="…${cwd: -29}"
    else
      cwd_short="$cwd"
    fi

    local sc; sc="$(status_color "$status")"
    printf '%b%-22s%b %b%-9s%b %-13s %b%-14s%b %b%-9s%b %-16s %-30s %-7s %s\n' \
      "$C_BOLD" "$id" "$C_RST" "$sc" "$status" "$C_RST" "$parent_short" \
      "$C_MAG" "$orch_label" "$C_RST" "$C_BLU" "$agent" "$C_RST" "$model" "$cwd_short" "$runtime" "$last"
  done < <(_iter_meta_files)

  if [[ "$found" == "0" ]]; then
    if [[ "$AGGREGATE" == "1" ]]; then
      echo "(no tasks across all sessions)"
    else
      echo "(no tasks in ${LOG_DIR})"
    fi
  fi
}

# ---------------------------------------------------------------------------
# tree — group tasks by working directory
# ---------------------------------------------------------------------------
# sessions — per-session summary with task counts and live panes
# ---------------------------------------------------------------------------

cmd_sessions() {
  local include_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) include_all=1; shift ;;
      *) echo "usage: endy watch sessions [--all]" >&2; exit 2 ;;
    esac
  done

  local now; now="$(date +%s)"
  local have_color=0
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && have_color=1

  local C_RST="" C_DIM="" C_BOLD="" C_BLU="" C_GRN="" C_YLW="" C_RED="" C_CYN=""
  if [[ "$have_color" == "1" ]]; then
    C_RST=$'\033[0m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_BLU=$'\033[34m'
    C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYN=$'\033[36m'
  fi

  # Enumerate every running tmux session named endy / endy-* so the dashboard
  # reflects ALL active endy tmuxes, including those owned by another endy
  # install (e.g. the npm @noetiklab/endy package) whose log dir lives outside
  # our ENDY_ROOT — those are shown as "external" with the attach hint but no
  # stats, so nothing is silently invisible.
  local sessions=()
  while IFS= read -r session_name; do
    [[ -n "$session_name" ]] || continue
    local d
    if [[ "$session_name" == "endy" ]]; then
      d="${ENDY_ROOT}/.logs/"
    else
      d="${ENDY_ROOT}/.logs/per-dir/${session_name}/"
    fi
    sessions+=("$session_name"$'\t'"$d")
  done < <(tmux list-sessions -F '#S' 2>/dev/null | grep -E '^endy(-|$)' || true)

  if [[ "${#sessions[@]}" -eq 0 ]]; then
    echo "(no active sessions)"
    echo "start one with: endy start  (or: endy overview)"
    return 0
  fi

  # Header
  printf '%s%-28s  %-44s  %s%s%s\n'     "" "SESSION" "TASKS" "$C_DIM" "LIVE PANES" "$C_RST"
  printf '%s\n' "$(printf '─%.0s' {1..120})"

  for entry in "${sessions[@]}"; do
    local session_name="${entry%%$'\t'*}"
    local log_dir="${entry#*$'\t'}"

    # External session: tmux session is alive but no log dir under this endy
    # (typically a session created by a different endy install — e.g. the npm
    # @noetiklab/endy package). Show it so it's not invisible.
    if [[ ! -d "$log_dir" ]]; then
      local nwin; nwin="$(tmux list-windows -t "$session_name" -F '#W' 2>/dev/null | wc -l | tr -d ' ')"
      printf '%-28s  %s%s%s  %s%s%s\n' \
        "$session_name" \
        "$C_DIM" "${nwin} ventanas tmux (sesion externa)" "$C_RST" \
        "$C_DIM" "—" "$C_RST"
      printf '  %stmux attach -t %s%s\n\n' "$C_DIM" "$session_name" "$C_RST"
      continue
    fi

    # Count tasks by status
    local run_count=0 pending_count=0 done_count=0 fail_count=0 abandoned_count=0
    local task_total=0

    shopt -s nullglob
    local m id log kind status
    for m in "${log_dir}"/task-*.meta; do
      id="$(basename "$m" .meta | sed 's/^task-//')"
      log="${log_dir}/task-${id}.log"
      [[ -f "$log" ]] || { log="${log_dir}/chat-${id}.log"; }
      kind="$(meta_field "$m" kind 2>/dev/null)"; kind="${kind:-spawn}"
      status="$(log_status "$log" "$id" "$kind" 2>/dev/null)"

      case "$status" in
        RUN)        ((run_count++)) ;;
        PENDING)    ((pending_count++)) ;;
        DONE)       ((done_count++)) ;;
        DONE-ERR)   ((done_count++)) ;;
        FAIL*)      ((fail_count++)) ;;
        ABANDONED)  ((abandoned_count++)) ;;
      esac
      ((task_total++))
    done
    shopt -u nullglob

    # Build task summary
    local task_parts=()
    [[ "$task_total" -eq 0 ]] && task_parts+=("${C_DIM}0 tasks${C_RST}")
    [[ "$run_count" -gt 0 ]] && task_parts+=("${C_GRN}${run_count} RUN${C_RST}")
    [[ "$pending_count" -gt 0 ]] && task_parts+=("${C_YLW}${pending_count} PENDING${C_RST}")
    [[ "$done_count" -gt 0 ]] && task_parts+=("${C_DIM}${done_count} DONE${C_RST}")
    [[ "$fail_count" -gt 0 ]] && task_parts+=("${C_RED}${fail_count} FAIL${C_RST}")
    [[ "$abandoned_count" -gt 0 ]] && task_parts+=("${C_RED}${abandoned_count} ABANDONED${C_RST}")
    [[ "$include_all" == "0" && "$task_total" -gt 0 && "$run_count" -eq 0 && "$pending_count" -eq 0 ]] && task_parts=("${C_DIM}${task_total} tasks (all finished)${C_RST}")

    local task_str
    printf -v task_str '%s, ' "${task_parts[@]}"
    task_str="${task_str%, }"

    # Find live panes for this session
    local live_panes=()
    shopt -s nullglob
    local lm lname lagent lstatus lname_clean
    for lm in "${log_dir}"/live-*.meta; do
      lname_clean="$(basename "$lm" .meta | sed 's/^live-//')"
      # Check if window exists in session
      if ! tmux list-windows -t "$session_name" -F '#W' 2>/dev/null | grep -qxF "$lname_clean"; then
        continue
      fi
      lagent="$(grep '^agent=' "$lm" 2>/dev/null | head -1 | cut -d= -f2-)"
      lagent="${lagent:-?}"

      # Quick status from log freshness
      local llog="${log_dir}/live-${lname_clean}.log"
      local lstatus="ready"
      if [[ -f "$llog" ]]; then
        local lmtime; lmtime="$(stat -c %Y "$llog" 2>/dev/null || echo 0)"
        [[ $((now - lmtime)) -lt 10 ]] && lstatus="working"
      fi

      local lcolor=""
      case "$lstatus" in working) lcolor="$C_GRN" ;; ready) lcolor="$C_BLU" ;; *) lcolor="$C_DIM" ;; esac
      live_panes+=("${lcolor}${lname_clean}(${lagent})${C_RST}")
    done
    shopt -u nullglob

    local live_str="${C_DIM}—${C_RST}"
    [[ "${#live_panes[@]}" -gt 0 ]] && printf -v live_str '%s, ' "${live_panes[@]}" && live_str="${live_str%, }"

    printf '%-28s  %-44s  %s\n'       "$session_name"       "$task_str"       "$live_str"

    # Attach hint
    printf '  %stmux attach -t %s%s\n' "$C_DIM" "$session_name" "$C_RST"
    printf '\n'
  done
}

# ---------------------------------------------------------------------------
# agents — unified view: spawned tasks + live panes in one table
# ---------------------------------------------------------------------------

cmd_agents() {
  AGGREGATE=1
  local include_all=0
  local cwd_filter=""
  local orch_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) include_all=1; shift ;;
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      *) echo "usage: endy watch agents [--all] [--cwd <dir>] [--orch <name>]" >&2; exit 2 ;;
    esac
  done
  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

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

  # Collect all rows: spawned tasks from meta files + live panes from live meta
  local rows=()

  # --- Spawned tasks ---
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local status; status="$(log_status "$log" "$id" "$kind")"
    case "$status" in
      DONE|DONE-ERR|FAIL\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac

    local cwd; cwd="$(meta_field "$m" cwd)"
    local agent; agent="$(meta_field "$m" agent)"
    local agent_label="${agent:-?}"
    local persona; persona="$(meta_field "$m" persona)"; persona="${persona:---}"
    [[ "$persona" != "---" ]] && agent_label="${agent_label}[${persona}]"
    local model; model="$(meta_field "$m" model)"; model="${model:---}"
    local orch; orch="$(task_orchestrator "$m")"
    local window; window="$(meta_field "$m" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"

    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue

    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local spawned_epoch; spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local runtime="?"
    [[ "$spawned_epoch" != "0" ]] && runtime="$(human_runtime $((now - spawned_epoch)))"

    local last="—"
    [[ -f "$log" ]] && last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null | tail -1 | strip_ansi | tr -d '\r\n' | head -c 100)"

    local sc; sc="$(status_color "$status")"
    local type_icon="${C_MAG}S${C_RST}"
    [[ "$kind" == "chat" ]] && type_icon="${C_CYN}C${C_RST}"

    rows+=("${task_session}"$'\t'"${status}"$'\t'"${agent}"$'\t'"${agent_label}"$'\t'"${id}"$'\t'"${runtime}"$'\t'"${cwd}"$'\t'"${last}"$'\t'"${type_icon}"$'\t'"${orch:-—}"$'\t'"${model}"$'\t'"${persona}")
  done < <(_iter_meta_files)

  # --- Live panes ---
  # Enumerate live-*.meta across all log dirs
  local log_dirs=()
  while IFS= read -r dir; do
    log_dirs+=("$dir")
  done < <(_aggregate_log_dirs)

  for log_dir in "${log_dirs[@]}"; do
    shopt -s nullglob
    local lm lname lagent lcwd lpersona lmodel
    for lm in "${log_dir}"/live-*.meta; do
      lname="$(basename "$lm" .meta | sed 's/^live-//')"
      lagent="$(grep '^agent=' "$lm" 2>/dev/null | head -1 | cut -d= -f2-)"
      lcwd="$(grep '^cwd=' "$lm" 2>/dev/null | head -1 | cut -d= -f2-)"
      lpersona="$(grep '^persona=' "$lm" 2>/dev/null | head -1 | cut -d= -f2-)"
      lmodel="$(grep '^model=' "$lm" 2>/dev/null | head -1 | cut -d= -f2-)"

      lagent="${lagent:-?}"
      lcwd="${lcwd:-?}"

      cwd_matches_filter "$lcwd" "$cwd_filter" || continue

      # Which session owns this pane?
      local lsess=""
      if [[ "$log_dir" == "${ENDY_ROOT}/.logs" ]]; then
        lsess="endy"
      else
        lsess="$(basename "$log_dir")"
      fi

      # Check if window is alive in that session
      if ! tmux list-windows -t "$lsess" -F '#W' 2>/dev/null | grep -qxF "$lname"; then
        continue
      fi

      # Status from log activity
      local llog="${log_dir}/live-${lname}.log"
      local lstatus="ready"
      if [[ -f "$llog" ]]; then
        local lmtime; lmtime="$(stat -c %Y "$llog" 2>/dev/null || echo 0)"
        [[ $((now - lmtime)) -lt 10 ]] && lstatus="working"
      fi

      local llast="—"
      [[ -f "$llog" ]] && llast="$(tail -1 "$llog" 2>/dev/null | strip_ansi | tr -d '\r\n' | head -c 100)"

      # Uptime from meta file
      local lmeta_mtime; lmeta_mtime="$(stat -c %Y "$lm" 2>/dev/null || echo "$now")"
      local luptime; luptime="$(human_runtime $((now - lmeta_mtime)))"

      local lagent_label="$lagent"
      [[ -n "$lpersona" ]] && lagent_label="${lagent_label}[${lpersona}]"

      local lcolor
      case "$lstatus" in working) lcolor="$C_GRN" ;; ready) lcolor="$C_BLU" ;; *) lcolor="$C_DIM" ;; esac

      rows+=("${lsess}"$'\t'"${lcolor}live${C_RST}"$'\t'"${lagent}"$'\t'"${lagent_label}"$'\t'"${lname}"$'\t'"${luptime}"$'\t'"${lcwd}"$'\t'"${llast}"$'\t'"${C_GRN}L${C_RST}"$'\t'"—"$'\t'"${lmodel:---}"$'\t'"${lpersona:---}")
    done
    shopt -u nullglob
  done

  # --- Discovered tmux windows ---
  # Any window in a running endy* session that isn't already covered by a
  # task or live-pane meta. Covers panes opened manually (tmux new-window
  # claude) and sessions owned by a different endy install (e.g. npm
  # @noetiklab/endy) whose meta files don't live in our ENDY_ROOT.
  local seen_windows=()
  local _r
  for _r in "${rows[@]}"; do
    local _rs _rn
    IFS=$'\t' read -r _rs _ _ _ _rn _ <<< "$_r"
    seen_windows+=("${_rs}:${_rn}")
  done

  local tsess
  while IFS= read -r tsess; do
    [[ -n "$tsess" ]] || continue
    while IFS=$'\t' read -r wname wcmd wpath wact; do
      [[ -n "$wname" ]] || continue
      case "$wname" in
        orchestrator|watch|browse|docs|tree|sessions|agents|panel|help|opencode|logs|__bootstrap) continue ;;
        task-*|chat-*|follow-*|diag*) continue ;;
      esac
      local key="${tsess}:${wname}"
      local already=0 sw
      for sw in "${seen_windows[@]}"; do
        [[ "$sw" == "$key" ]] && { already=1; break; }
      done
      [[ "$already" == "1" ]] && continue

      cwd_matches_filter "$wpath" "$cwd_filter" || continue
      [[ -z "$orch_filter" || "$tsess" == "$orch_filter" ]] || continue

      local twagent="$wcmd"
      case "$wname" in
        *claude*)                twagent="claude" ;;
        *codex*)                 twagent="codex" ;;
        *opencode*|oc-*)         twagent="opencode" ;;
        *cmd-*|*commandcode*)    twagent="cmd" ;;
        *hermes*)                twagent="hermes" ;;
      esac

      local twruntime="?"
      [[ -n "$wact" && "$wact" != "0" ]] && twruntime="$(human_runtime $((now - wact)))"
      local twlast
      twlast="$(tmux capture-pane -t "${tsess}:${wname}" -p -S -10 2>/dev/null \
                  | strip_ansi | tr -d '\r' | tr '\t' ' ' \
                  | awk '/[[:alnum:]]/ { line=$0 } END { print line }' | head -c 100)"
      [[ -z "$twlast" ]] && twlast="(idle)"

      rows+=("${tsess}"$'\t'"${C_BLU}running${C_RST}"$'\t'"${twagent}"$'\t'"${wname}"$'\t'"${wname}"$'\t'"${twruntime}"$'\t'"${wpath}"$'\t'"${twlast}"$'\t'"${C_CYN}T${C_RST}"$'\t'"${tsess}"$'\t'"—"$'\t'"—")
    done < <(tmux list-windows -t "$tsess" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}'$'\t''#{window_activity}' 2>/dev/null)
  done < <(tmux list-sessions -F '#S' 2>/dev/null | grep -E '^endy(-|$)' || true)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    if [[ "$include_all" == "1" ]]; then
      echo "(no agents across any session)"
    else
      echo "(no active agents — use '--all' to include finished tasks)"
    fi
    return 0
  fi

  # Header
  printf '%s%-28s  %-8s  %-16s  %-28s  %-8s  %-42s  %s%s%s\n'     "" "SESSION" "TYPE" "AGENT" "NAME/ID" "RUNTIME" "CWD" "$C_DIM" "LAST OUTPUT" "$C_RST"
  printf '%s\n' "$(printf '─%.0s' {1..160})"

  # Sort by session, then status priority (RUN/working first)
  printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k2,2 | while IFS=$'\t' read -r session status agent agent_label name runtime cwd last type_icon orch model persona; do
    local status_str="$status"
    # Strip ANSI from status if it's a live status
    status_str="$(printf '%s' "$status_str" | strip_ansi)"

    printf '%-28s  %s%-8s%s  %-16s  %-28s  %-8s  %-42s  %s%s%s\n'       "$(printf '%.28s' "$session")"       "" "${type_icon}" ""       "$(printf '%.16s' "$agent_label")"       "$(printf '%.28s' "$name")"       "$runtime"       "$(printf '%.42s' "$cwd")"       "$C_DIM" "$(printf '%.80s' "$last")" "$C_RST"

    # Attach hint for live panes and discovered tmux-window agents
    if [[ "$status_str" == "live" || "$status_str" == "working" || "$status_str" == "running" ]]; then
      printf '  %stmux attach -t %s  →  Ctrl-b w  →  select %s%s\n' "$C_DIM" "$session" "$name" "$C_RST"
    fi
  done
}

# ---------------------------------------------------------------------------

cmd_tree() {
  local include_all=0
  local cwd_filter=""
  local orch_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) include_all=1; shift ;;
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      --overview|--all-sessions) AGGREGATE=1; shift ;;
      --live) LIVE_ONLY=1; shift ;;
      *) echo "usage: endy watch tree [--all] [--cwd <dir>] [--orch <name>] [--overview] [--live]" >&2; exit 2 ;;
    esac
  done
  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

  local now; now="$(date +%s)"
  local rows=()
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local status; status="$(log_status "$log" "$id" "$kind")"
    case "$status" in
      DONE|DONE-ERR|FAIL\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac

    local cwd; cwd="$(meta_field "$m" cwd)"
    local agent; agent="$(meta_field "$m" agent)"
    local orch; orch="$(task_orchestrator "$m")"
    local orch_label; orch_label="$(task_orchestrator_label "$m")"
    local model; model="$(model_label "$m" "$log" "$agent")"
    local window; window="$(meta_field "$m" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    local parent; parent="$(meta_field "$m" parent_task)"; parent="${parent:-—}"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local spawned_epoch; spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local runtime="?"
    [[ "$spawned_epoch" != "0" ]] && runtime="$(human_runtime $((now - spawned_epoch)))"
    local last="(no log yet)"
    if [[ "$kind" == "chat" ]]; then
      last="(interactive pane captured)"
    elif [[ -f "$log" ]]; then
      last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\]|[[:space:]]*$)' "$log" 2>/dev/null \
              | tail -n 200 | strip_ansi | tr -d '\r' | tr '\t' ' ' \
              | awk '/[[:alnum:]]/ { line=$0 } END { print line }' \
              | head -c 90)"
      [[ -z "$last" ]] && last="(empty)"
    fi
    rows+=("${orch_label}"$'\t'"${orch_label}"$'\t'"${cwd}"$'\t'"${task_session}"$'\t'"${id}"$'\t'"${status}"$'\t'"${agent}"$'\t'"${model}"$'\t'"${kind}"$'\t'"${parent}"$'\t'"${runtime}"$'\t'"${last}")
  done < <(_iter_meta_files)

  # --- Live panes (endy live open) ---
  # Each live-*.meta in scope contributes a row, grouped under its owning
  # session-as-orchestrator and its cwd, so the tree reflects both ways of
  # launching agents (spawned tasks + interactive live panes).
  local log_dir lm
  while IFS= read -r log_dir; do
    [[ -d "$log_dir" ]] || continue
    local lsess
    if [[ "$log_dir" == "${ENDY_ROOT}/.logs" ]]; then
      lsess="endy"
    else
      lsess="$(basename "$log_dir")"
    fi
    shopt -s nullglob
    for lm in "${log_dir}"/live-*.meta; do
      local lname; lname="$(basename "$lm" .meta | sed 's/^live-//')"
      tmux list-windows -t "$lsess" -F '#W' 2>/dev/null | grep -qxF "$lname" || continue

      local lcwd; lcwd="$(meta_field "$lm" cwd)"; lcwd="${lcwd:-?}"
      local lagent; lagent="$(meta_field "$lm" agent)"; lagent="${lagent:-?}"
      local lmodel; lmodel="$(meta_field "$lm" model)"; lmodel="${lmodel:-—}"
      cwd_matches_filter "$lcwd" "$cwd_filter" || continue
      [[ -z "$orch_filter" || "$lsess" == "$orch_filter" ]] || continue

      local llog="${log_dir}/live-${lname}.log"
      local lstatus="ready"
      if [[ -f "$llog" ]]; then
        local lmtime; lmtime="$(stat -c %Y "$llog" 2>/dev/null || echo 0)"
        [[ $((now - lmtime)) -lt 10 ]] && lstatus="working"
      fi
      local lmeta_mtime; lmeta_mtime="$(stat -c %Y "$lm" 2>/dev/null || echo "$now")"
      local lruntime; lruntime="$(human_runtime $((now - lmeta_mtime)))"
      local llast="(idle)"
      if [[ -f "$llog" ]]; then
        llast="$(tail -n 80 "$llog" 2>/dev/null | strip_ansi | tr -d '\r' | tr '\t' ' ' \
                  | awk '/[[:alnum:]]/ { line=$0 } END { print line }' | head -c 90)"
        [[ -z "$llast" ]] && llast="(idle)"
      fi
      local lid="live:${lsess}:${lname}"
      rows+=("${lsess}"$'\t'"${lsess}"$'\t'"${lcwd}"$'\t'"${lsess}"$'\t'"${lid}"$'\t'"${lstatus}"$'\t'"${lagent}"$'\t'"${lmodel}"$'\t'"live"$'\t'"—"$'\t'"${lruntime}"$'\t'"${llast}")
    done
    shopt -u nullglob
  done < <(_aggregate_log_dirs)

  # --- Discovered tmux windows ---
  # Any agent-looking window in a running endy* session that isn't already
  # covered by a meta file (task or live). Catches panes opened manually
  # (tmux new-window claude) AND sessions owned by a different endy install
  # (e.g. npm @noetiklab/endy) whose meta files live elsewhere — without
  # this, those agents are invisible.
  local _seen=()
  local _r
  for _r in "${rows[@]}"; do
    local _rs5  # row column 5 = id (live:sess:name) or task id
    IFS=$'\t' read -r _ _ _ _ _rs5 _ <<< "$_r"
    if [[ "$_rs5" == live:* ]]; then
      _seen+=("${_rs5#live:}")
    fi
  done

  local tsess
  while IFS= read -r tsess; do
    [[ -n "$tsess" ]] || continue
    while IFS=$'\t' read -r wname wcmd wpath wact; do
      [[ -n "$wname" ]] || continue
      case "$wname" in
        orchestrator|watch|browse|docs|tree|sessions|agents|panel|help|opencode|logs|__bootstrap) continue ;;
        task-*|chat-*|follow-*|diag*) continue ;;
      esac
      local key="${tsess}:${wname}"
      local already=0 sw
      for sw in "${_seen[@]}"; do
        [[ "$sw" == "$key" ]] && { already=1; break; }
      done
      [[ "$already" == "1" ]] && continue

      cwd_matches_filter "$wpath" "$cwd_filter" || continue
      [[ -z "$orch_filter" || "$tsess" == "$orch_filter" ]] || continue

      local twagent="$wcmd"
      case "$wname" in
        *claude*)                twagent="claude" ;;
        *codex*)                 twagent="codex" ;;
        *opencode*|oc-*)         twagent="opencode" ;;
        *cmd-*|*commandcode*)    twagent="cmd" ;;
        *hermes*)                twagent="hermes" ;;
      esac

      local twruntime="?"
      [[ -n "$wact" && "$wact" != "0" ]] && twruntime="$(human_runtime $((now - wact)))"
      local twlast
      twlast="$(tmux capture-pane -t "${tsess}:${wname}" -p -S -10 2>/dev/null \
                  | strip_ansi | tr -d '\r' | tr '\t' ' ' \
                  | awk '/[[:alnum:]]/ { line=$0 } END { print line }' | head -c 90)"
      [[ -z "$twlast" ]] && twlast="(idle)"

      rows+=("${tsess}"$'\t'"${tsess}"$'\t'"${wpath}"$'\t'"${tsess}"$'\t'"${wname}"$'\t'"running"$'\t'"${twagent}"$'\t'"—"$'\t'"tmux"$'\t'"—"$'\t'"${twruntime}"$'\t'"${twlast}")
    done < <(tmux list-windows -t "$tsess" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}'$'\t''#{window_activity}' 2>/dev/null)
  done < <(tmux list-sessions -F '#S' 2>/dev/null | grep -E '^endy(-|$)' || true)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    if [[ "$include_all" == "1" ]]; then
      [[ "$AGGREGATE" == "1" ]] && echo "(no agents across all sessions)" || echo "(no agents in ${LOG_DIR})"
    elif [[ "$AGGREGATE" == "1" ]]; then
      echo "(no active agents; use 'endy watch tree --overview --all' to include finished tasks across sessions)"
    else
      echo "(no active agents; use 'endy watch tree --all' to include finished tasks)"
    fi
    return
  fi

  local last_orch=""
  local last_cwd_key=""
  printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k3,3 -k4,4 -k5,5 | while IFS=$'\t' read -r orch orch_label cwd task_session id status agent model kind parent runtime last; do
    if [[ "$orch" != "$last_orch" ]]; then
      [[ -n "$last_orch" ]] && printf '\n'
      printf '%bORCH%b %b%s%b\n' "$C_DIM" "$C_RST" "$C_MAG$C_BOLD" "$orch_label" "$C_RST"
      last_orch="$orch"
      last_cwd_key=""
    fi
    local cwd_key="${cwd}"$'\t'"${task_session}"
    if [[ "$cwd_key" != "$last_cwd_key" ]]; then
      [[ -n "$last_cwd_key" ]] && printf '\n'
      printf '  %bDIR%b %b%s%b\n' "$C_DIM" "$C_RST" "$C_CYN" "$cwd" "$C_RST"
      printf '    %btmux attach -t %s%b    # Ctrl-b w opens the window picker\n' "$C_DIM" "$task_session" "$C_RST"
      last_cwd_key="$cwd_key"
    fi
    local sc; sc="$(status_color "$status")"
    if [[ "$parent" == "—" ]]; then
      printf '    %b%-22s%b %b%-9s%b %b%-9s%b %-16s %-5s %-7s %s\n' \
        "$C_BOLD" "$id" "$C_RST" "$sc" "$status" "$C_RST" "$C_BLU" "$agent" "$C_RST" "$model" "$kind" "$runtime" "$last"
    else
      printf '    %b%-22s%b %b%-9s%b %b%-9s%b %-16s %-5s %-7s parent:%s  %s\n' \
        "$C_BOLD" "$id" "$C_RST" "$sc" "$status" "$C_RST" "$C_BLU" "$agent" "$C_RST" "$model" "$kind" "$runtime" "$(short_task_ref "$parent")" "$last"
    fi
  done
}

cmd_dir() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || { echo "usage: endy watch dir <path> [--all] [--orch <name>]" >&2; exit 2; }
  shift
  cmd_tree --cwd "$dir" "$@"
}

# ---------------------------------------------------------------------------
# log — follow one task's log (single-task, blocks the terminal)
# ---------------------------------------------------------------------------

cmd_log() {
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy-watch log <id-prefix>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  local log; log="$(task_log_path "$meta" "$id")"
  if [[ ! -f "$log" ]]; then
    echo "task $id has no log yet (still starting up)" >&2
    exit 1
  fi
  exec less +F -R "$log"
}

# ---------------------------------------------------------------------------
# view — one-shot dump (meta + prompt + last 200 log lines), through less
# ---------------------------------------------------------------------------

cmd_view() {
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy-watch view <id-prefix>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  local prompt; prompt="$(task_prompt_path "$meta" "$id")"
  local log; log="$(task_log_path "$meta" "$id")"

  {
    echo "════════════════════════════════════════════════════════════════"
    echo " task $id"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "──── meta ────"
    [[ -f "$meta" ]] && cat "$meta" || echo "(no meta)"
    echo
    echo "──── prompt ────"
    [[ -f "$prompt" ]] && cat "$prompt" || echo "(no prompt)"
    echo
    echo "──── log (last 200 lines) ────"
    [[ -f "$log" ]] && tail -n 200 "$log" || echo "(no log)"
  } | less -R +G
}

# ---------------------------------------------------------------------------
# follow — open a NEW tmux window with prompt header + live tail
# ---------------------------------------------------------------------------
#
# The point: monitoring agent A doesn't get interrupted when you also want
# to follow agent B. Each `follow` call adds a window; tmux does the rest.

cmd_follow() {
  require_session
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy-watch follow <id-prefix>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  local prompt; prompt="$(task_prompt_path "$meta" "$id")"
  local log; log="$(task_log_path "$meta" "$id")"

  if [[ ! -f "$log" ]]; then
    echo "task $id has no log yet (still starting up)" >&2
    exit 1
  fi

  local window; window="$(meta_field "$meta" window)"
  local task_session="${window%%:*}"
  [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"

  if ! tmux has-session -t "$task_session" 2>/dev/null; then
    echo "task session '$task_session' is not running" >&2
    exit 1
  fi

  local window_name="follow-${id}"

  # If a follow window for this id already exists, just point at it.
  if tmux list-windows -t "$task_session" -F '#W' 2>/dev/null | grep -qx "$window_name"; then
    tmux select-window -t "${task_session}:${window_name}"
    echo "follow window already open: ${task_session}:${window_name}"
    print_task_commands "$id" "$window_name"
    return 0
  fi

  # Build a small inner shell command that prints the prompt header then tails.
  # Use bash explicitly so the heredoc-style semantics are predictable.
  local quoted_prompt; quoted_prompt="$(printf '%q' "$prompt")"
  local quoted_log;    quoted_log="$(printf '%q' "$log")"
  local q_task_session; q_task_session="$(printf '%q' "$task_session")"
  local inner="bash -c $(printf '%q' "
clear
printf '\033[1;36m──── prompt for task %s ────\033[0m\n' '${id}'
printf '\033[1;33mtmux: attach=%s | select=%s | picker=Ctrl-b w | detach=Ctrl-b d\033[0m\n' '${q_task_session}' '${q_task_session}:${window_name}'
printf '\033[1;33mendy: view=%s | chat=%s | followup=%s | kill=%s\033[0m\n\n' 'endy watch view ${id}' 'endy watch chat ${id}' 'endy watch followup ${id} -- \"<next prompt>\"' 'endy watch kill ${id}'
[[ -f ${quoted_prompt} ]] && cat ${quoted_prompt} || echo '(no prompt file)'
echo
printf '\033[1;36m──── log (live) ────\033[0m\n'
exec tail -F ${quoted_log}
")"

  tmux new-window -t "$task_session" -n "$window_name" "$inner"
  tmux set-window-option -t "${task_session}:${window_name}" remain-on-exit on 2>/dev/null || true

  echo "follow window opened: ${task_session}:${window_name}"
  print_task_commands "$id" "$window_name"
}

# ---------------------------------------------------------------------------
# browse — interactive picker, fzf if available
# ---------------------------------------------------------------------------

cmd_browse() {
  local include_all=0
  local cwd_filter=""
  local orch_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) include_all=1; shift ;;
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      --overview|--all-sessions) AGGREGATE=1; shift ;;
      --live) LIVE_ONLY=1; shift ;;
      *) echo "usage: endy watch browse [--all] [--cwd <dir>] [--orch <name>] [--overview] [--live]" >&2; exit 2 ;;
    esac
  done
  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not installed — falling back to 'list'." >&2
    echo "  (install with: brew install fzf — gives you a live preview picker)" >&2
    local list_args=()
    [[ -n "$cwd_filter" ]] && list_args+=(--cwd "$cwd_filter")
    [[ -n "$orch_filter" ]] && list_args+=(--orch "$orch_filter")
    cmd_list "${list_args[@]}"
    return
  fi

  local preview_script="${ENDY_ROOT}/scripts/_endy-preview.sh"
  local copy_cmd
  if   command -v pbcopy >/dev/null 2>&1; then copy_cmd="pbcopy"
  elif command -v wl-copy >/dev/null 2>&1; then copy_cmd="wl-copy"
  elif command -v xclip   >/dev/null 2>&1; then copy_cmd="xclip -selection clipboard"
  else copy_cmd=""
  fi

  # ANSI palette for the list rows.
  local C_RST=$'\033[0m' C_DIM=$'\033[2m' C_BOLD=$'\033[1m'
  local C_BLU=$'\033[34m' C_GRN=$'\033[32m' C_YLW=$'\033[33m' C_RED=$'\033[31m' C_GREY=$'\033[90m'

  local rows=()
  local now; now="$(date +%s)"
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local agent;       agent="$(meta_field "$m" agent)"
    local persona;     persona="$(meta_field "$m" persona)"; persona="${persona:-ad-hoc}"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local kind;        kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local parent;      parent="$(meta_field "$m" parent_task)"
    local orch;        orch="$(task_orchestrator "$m")"
    local orch_label;  orch_label="$(task_orchestrator_label "$m")"
    local model;       model="$(model_label "$m" "$log" "$agent")"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    local spawned_epoch
    spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local rt="?"
    [[ "$spawned_epoch" != "0" ]] && rt="$(human_runtime $((now - spawned_epoch)))"
    local st; st="$(log_status "$log" "$id" "$kind")"
    case "$st" in
      DONE|DONE-ERR|FAIL\(*\)|FAILED\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac

    local dot_color
    case "$st" in
      RUN|PENDING|CHAT) dot_color="$C_BLU" ;;
      DONE)        dot_color="$C_GRN" ;;
      DONE-ERR)    dot_color="$C_YLW" ;;
      FAILED*)     dot_color="$C_RED" ;;
      *)           dot_color="$C_GREY" ;;
    esac

    # Truncate cwd
    local cwd_short
    if [[ ${#cwd} -gt 38 ]]; then
      cwd_short="…${cwd: -37}"
    else
      cwd_short="$cwd"
    fi

    local window; window="$(meta_field "$m" window)"
    local session_label=""
    if [[ "$AGGREGATE" == "1" ]]; then
      local browse_session="${window%%:*}"
      [[ -z "$browse_session" || "$browse_session" == "$window" ]] && browse_session="$SESSION"
      session_label=" [${browse_session}]"
    fi
    local relation=""
    [[ -n "$parent" ]] && relation=" parent:$(short_task_ref "$parent")"

    rows+=("$(printf '%s%-22s%s  %s● %-9s%s  %s%-12s%s  %s%-9s%s  %-16s  %-14s  %s%-7s%s  %s%s%s%s' \
      "$C_BOLD" "$id" "$C_RST" \
      "$dot_color" "$st" "$C_RST" \
      "$C_GRN" "$orch_label" "$C_RST" \
      "$C_BLU" "$agent" "$C_RST" \
      "$model" \
      "$persona" \
      "$C_DIM" "$rt" "$C_RST" \
      "$C_DIM" "$cwd_short${session_label}" "$C_RST" \
      "$relation")")
  done < <(_iter_meta_files)

  # --- Live panes ---
  # Each live-*.meta represents a tmux window driven by `endy live open`.
  # Add one picker row per live pane whose tmux window is still alive, with
  # an id of the form `live:<session>:<name>` so the enter dispatcher can
  # tell it apart from a task id and jump to the right tmux window.
  local log_dir
  while IFS= read -r log_dir; do
    [[ -d "$log_dir" ]] || continue
    local lm lname lagent lcwd lpersona lmodel lsess
    if [[ "$log_dir" == "${ENDY_ROOT}/.logs" ]]; then
      lsess="endy"
    else
      lsess="$(basename "$log_dir")"
    fi
    shopt -s nullglob
    for lm in "${log_dir}"/live-*.meta; do
      lname="$(basename "$lm" .meta | sed 's/^live-//')"
      tmux list-windows -t "$lsess" -F '#W' 2>/dev/null | grep -qxF "$lname" || continue
      lagent="$(meta_field "$lm" agent)"; lagent="${lagent:-?}"
      lcwd="$(meta_field "$lm" cwd)"; lcwd="${lcwd:-?}"
      lpersona="$(meta_field "$lm" persona)"; lpersona="${lpersona:-—}"
      lmodel="$(meta_field "$lm" model)"; lmodel="${lmodel:-—}"

      cwd_matches_filter "$lcwd" "$cwd_filter" || continue

      local lmeta_mtime; lmeta_mtime="$(stat -c %Y "$lm" 2>/dev/null || echo "$now")"
      local luptime; luptime="$(human_runtime $((now - lmeta_mtime)))"
      local llog="${log_dir}/live-${lname}.log"
      local lstatus="ready"
      if [[ -f "$llog" ]]; then
        local lmtime; lmtime="$(stat -c %Y "$llog" 2>/dev/null || echo 0)"
        [[ $((now - lmtime)) -lt 10 ]] && lstatus="working"
      fi
      local lcolor
      case "$lstatus" in working) lcolor="$C_GRN" ;; *) lcolor="$C_BLU" ;; esac
      local lcwd_short="$lcwd"
      [[ ${#lcwd_short} -gt 38 ]] && lcwd_short="…${lcwd_short: -37}"
      local lid="live:${lsess}:${lname}"

      rows+=("$(printf '%s%-22s%s  %s● %-9s%s  %s%-12s%s  %s%-9s%s  %-16s  %-14s  %s%-7s%s  %s%s [%s]%s' \
        "$C_BOLD" "$lid" "$C_RST" \
        "$lcolor" "$lstatus" "$C_RST" \
        "$C_GRN" "live" "$C_RST" \
        "$C_BLU" "$lagent" "$C_RST" \
        "$lmodel" \
        "$lpersona" \
        "$C_DIM" "$luptime" "$C_RST" \
        "$C_DIM" "$lcwd_short" "$lsess" "$C_RST")")
    done
    shopt -u nullglob
  done < <(_aggregate_log_dirs)

  # --- External tmux sessions ---
  # Any running tmux session matching ^endy(-|$) that doesn't have a log dir
  # under THIS ENDY_ROOT (e.g. spawned by the npm @noetiklab/endy install).
  # One row per external session with id `ext:<session>` so Enter attaches.
  local known_sessions=()
  while IFS= read -r log_dir; do
    local s
    if [[ "$log_dir" == "${ENDY_ROOT}/.logs" ]]; then s="endy"; else s="$(basename "$log_dir")"; fi
    known_sessions+=("$s")
  done < <(_aggregate_log_dirs)
  local tsess
  while IFS= read -r tsess; do
    [[ -n "$tsess" ]] || continue
    local found=0 ks
    for ks in "${known_sessions[@]}"; do
      [[ "$ks" == "$tsess" ]] && { found=1; break; }
    done
    [[ "$found" == "1" ]] && continue
    local nwin; nwin="$(tmux list-windows -t "$tsess" -F '#W' 2>/dev/null | wc -l | tr -d ' ')"
    local eid="ext:${tsess}"
    rows+=("$(printf '%s%-22s%s  %s● %-9s%s  %s%-12s%s  %s%-9s%s  %-16s  %-14s  %s%-7s%s  %s%s%s' \
      "$C_BOLD" "$eid" "$C_RST" \
      "$C_GREY" "external" "$C_RST" \
      "$C_GREY" "—" "$C_RST" \
      "$C_GREY" "tmux" "$C_RST" \
      "—" \
      "—" \
      "$C_DIM" "—" "$C_RST" \
      "$C_DIM" "${nwin} ventanas tmux" "$C_RST")")
  done < <(tmux list-sessions -F '#S' 2>/dev/null | grep -E '^endy(-|$)' || true)

  if [[ ${#rows[@]} -eq 0 ]]; then
    if [[ "$include_all" == "1" ]]; then
      echo "(no matching tasks — spawn one with: endy spawn <agent> -- \"<prompt>\")"
    else
      echo "(no active matching tasks — use: endy watch browse --all)"
    fi
    return
  fi

  # Build the bind list. ctrl-y copies the id to the system clipboard so the
  # user never has to wrestle with terminal selection.
  local binds=(
    "--bind=enter:execute(${BASH_SOURCE[0]} _jump {1})+abort"
    "--bind=ctrl-g:execute(${BASH_SOURCE[0]} _jump {1})+abort"
    "--bind=ctrl-v:execute(${BASH_SOURCE[0]} view {1})"
    "--bind=ctrl-l:execute(${BASH_SOURCE[0]} log {1})"
    "--bind=ctrl-f:execute(${BASH_SOURCE[0]} follow {1})+abort"
    "--bind=ctrl-o:execute-silent(${BASH_SOURCE[0]} chat {1} --no-attach)+refresh-preview"
    "--bind=ctrl-k:execute(${BASH_SOURCE[0]} kill {1})"
    "--bind=ctrl-d:execute(${BASH_SOURCE[0]} purge {1} --from-picker)+abort"
    "--bind=ctrl-r:refresh-preview"
  )
  local header
  if [[ -n "$copy_cmd" ]]; then
    binds+=("--bind=ctrl-y:execute-silent(printf %s {1} | ${copy_cmd})+abort")
    header="enter→chat fg+exit  Ctrl-O chat bg  Ctrl-G chat fg+exit  Ctrl-F follow  Ctrl-V view  Ctrl-L log  Ctrl-Y copy id  Ctrl-K kill  Ctrl-D purge  Ctrl-R refresh  esc cancel"
  else
    header="enter→chat fg+exit  Ctrl-O chat bg  Ctrl-G chat fg+exit  Ctrl-F follow  Ctrl-V view  Ctrl-L log  Ctrl-K kill  Ctrl-D purge  Ctrl-R refresh  esc cancel  (install pbcopy/xclip for Ctrl-Y copy)"
  fi

  local picked
  picked="$(printf '%s\n' "${rows[@]}" \
    | fzf --ansi --reverse \
          --header="$header" \
          --header-first \
          --preview="${preview_script} {1}" \
          --preview-window=right:30%:wrap:follow \
          --no-mouse \
          "${binds[@]}")"
  [[ -z "$picked" ]] && return 0

  # Strip ANSI from the picked row to extract the id.
  local picked_id; picked_id="$(printf '%s' "$picked" | strip_ansi | awk '{print $1}')"
  [[ -z "$picked_id" ]] && return 0
}

# ---------------------------------------------------------------------------
# panel — tile view (warn if >4)
# ---------------------------------------------------------------------------

cmd_panel() {
  require_session
  local include_all=0
  [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]] && include_all=1

  local entries=()
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local status; status="$(log_status "$log" "$id" "$kind")"
    case "$status" in
      DONE|DONE-ERR|FAIL\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac
    entries+=("${id}|${log}")
  done < <(_iter_meta_files)

  if [[ "${#entries[@]}" -eq 0 ]]; then
    if [[ "$include_all" == "1" ]]; then
      echo "no tasks at all" >&2
    else
      echo "no running tasks (use 'panel --all' to include finished, or 'list' to see everything)" >&2
    fi
    exit 0
  fi

  if [[ "${#entries[@]}" -gt 4 ]]; then
    echo "warning: ${#entries[@]} task logs would tile into unreadable panes." >&2
    echo "use 'endy-watch list' for a scannable table, then 'endy-watch log <id>' for one." >&2
    echo "continue anyway? [y/N] " >&2
    read -r reply
    case "$reply" in y|Y|yes|Yes) : ;; *) echo "aborted" >&2; exit 0 ;; esac
  fi

  tmux kill-window -t "${SESSION}:panel" 2>/dev/null || true
  local first_id="${entries[0]%%|*}"
  local first_log="${entries[0]#*|}"
  tmux new-window -t "$SESSION" -n panel \
    "$(tail_pane_command "$first_id" "$first_log" "task-${first_id}")"
  local i
  for ((i=1; i<${#entries[@]}; i++)); do
    local id="${entries[$i]%%|*}"
    local log="${entries[$i]#*|}"
    tmux split-window -t "${SESSION}:panel" \
      "$(tail_pane_command "$id" "$log" "task-${id}")"
    tmux select-layout -t "${SESSION}:panel" tiled
  done
  tmux select-window -t "${SESSION}:panel"
  tmux select-layout -t "${SESSION}:panel" tiled
  exec tmux attach -t "$SESSION" -r
}

# ---------------------------------------------------------------------------
# attach — read-only attach (optionally selecting a window)
# ---------------------------------------------------------------------------

cmd_attach() {
  require_session
  local strict=0
  local prefix=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict|-r) strict=1; shift ;;
      *)           prefix="$1"; shift ;;
    esac
  done

  local flags=()
  # Default: read-write so you can navigate between windows (Ctrl-b N etc.).
  # tmux's '-r' read-only mode blocks the prefix key too, which makes the
  # session unusable for monitoring more than one task. Use --strict only
  # when you specifically want to prevent typing into running agent panes.
  [[ "$strict" == "1" ]] && flags+=(-r)

  if [[ -n "$prefix" ]]; then
    local id; id="$(resolve_id "$prefix")" || exit 1
    local meta; meta="$(task_meta_path "$id")"
    local window; window="$(meta_field "$meta" window)"
    [[ -n "$window" ]] || window="${SESSION}:task-${id}"
    exec tmux attach "${flags[@]+${flags[@]}}" -t "$window"
  else
    exec tmux attach "${flags[@]+${flags[@]}}" -t "$SESSION"
  fi
}

# ---------------------------------------------------------------------------
# open — smart dispatcher used by picker bindings that should keep browse alive:
#        chat-kind → focus existing window; spawn-kind → open/focus new chat.
# ---------------------------------------------------------------------------

cmd_open() {
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || return 0
  prefix="$(printf '%s' "$prefix" | strip_ansi | awk '{print $1}')"
  [[ -n "$prefix" ]] || return 0
  local id; id="$(resolve_id "$prefix" 2>/dev/null)" || return 0
  cmd_chat "$id"
}

# ---------------------------------------------------------------------------
# chat — open an interactive chat for an existing task
# ---------------------------------------------------------------------------

cmd_chat() {
  require_session
  local prefix=""
  local attach=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-attach) attach=0; shift ;;
      *)           if [[ -z "$prefix" ]]; then prefix="$1"; fi; shift ;;
    esac
  done
  prefix="$(printf '%s' "$prefix" | strip_ansi | awk '{print $1}')"
  [[ -n "$prefix" ]] || { echo "usage: endy watch chat <id-prefix> [--no-attach]" >&2; exit 2; }

  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  [[ -f "$meta" ]] || { echo "no meta for $id" >&2; exit 1; }

  local kind window log agent persona model cwd orch orch_agent
  kind="$(meta_field "$meta" kind)"; kind="${kind:-spawn}"
  window="$(meta_field "$meta" window)"
  log="$(task_log_path "$meta" "$id")"
  agent="$(meta_field "$meta" agent)"
  persona="$(meta_field "$meta" persona)"
  model="$(meta_field "$meta" model)"
  cwd="$(meta_field "$meta" cwd)"
  orch="$(task_orchestrator "$meta")"
  orch_agent="$(meta_field "$meta" orchestrator_agent)"

  if [[ "$kind" == "chat" ]]; then
    [[ -n "$window" ]] || window="${SESSION}:chat-${id}"
    if ! tmux_window_alive "$window"; then
      local parent; parent="$(meta_field "$meta" parent_task)"
      if [[ -n "$parent" && -f "$(task_meta_path "$parent")" ]]; then
        echo "chat window missing for $id; reopening from parent task $parent"
        local reopen_args=("$parent")
        [[ "$attach" == "0" ]] && reopen_args+=(--no-attach)
        cmd_chat "${reopen_args[@]}"
        return 0
      fi
      echo "chat window missing for $id: $window" >&2
      return 1
    fi
    echo "chat window: $window"
    local chat_session="${window%%:*}"
    [[ -z "$chat_session" || "$chat_session" == "$window" ]] && chat_session="$SESSION"
    echo "tmux commands:"
    echo "  tmux attach -t ${chat_session}"
    echo "  tmux select-window -t ${window}"
    echo "  tmux kill-window -t ${window}"
    echo
    echo "endy commands:"
    echo "  endy watch view ${id}"
    echo "  endy watch follow ${id}"
    echo "  endy watch kill ${id}"
    [[ "$attach" == "1" ]] && focus_window "$window"
    return 0
  fi

  local sid=""
  local initial_message=""
  if [[ "$agent" == "cmd" || "$agent" == "commandcode" ]]; then
    # cmd spawn-tasks have no reliable native resume path:
    #  - cmd -p (the headless run) does NOT persist a session.
    #  - Sessions in ~/.commandcode/projects/<slug>/ belong to UNRELATED
    #    interactive chats; resume_id_for_task picks the newest, which
    #    would resume the wrong conversation. Don't even try.
    # Always inject the parent's prompt + log tail as the opening message.
    local prompt_path; prompt_path="$(meta_field "$meta" prompt)"
    [[ -n "$prompt_path" && -f "$prompt_path" ]] || prompt_path="${LOG_DIR}/task-${id}.prompt.md"
    local original_prompt="" log_excerpt=""
    [[ -f "$prompt_path" ]] && original_prompt="$(head -c 2000 "$prompt_path" 2>/dev/null)"
    [[ -f "$log" ]] && log_excerpt="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null \
                                      | strip_ansi | tail -n 60 | head -c 3000)"
    if [[ -n "$original_prompt" || -n "$log_excerpt" ]]; then
      initial_message="[endy: continuing from spawn-task ${id} — cmd headless runs don't persist, so context is injected here]

--- original prompt ---
${original_prompt}

--- last output ---
${log_excerpt}

--- end of injected context ---
"
      echo "opening cmd chat for task $id (context injected; cmd -p doesn't persist sessions)"
    else
      echo "opening fresh cmd chat for task $id (no log/prompt to inject)"
    fi
  else
    sid="$(resume_id_for_task "$agent" "$cwd" "$log")"
    if [[ -n "$sid" ]]; then
      echo "opening interactive $agent chat resumed from task $id: $sid"
    else
      echo "opening fresh interactive $agent chat for task $id (no session id found)"
    fi
  fi

  local spawn_args=(--agent "$agent" --cwd "$cwd" --parent-task "$id" --orchestrator "$orch")
  [[ "$attach" == "0" ]] && spawn_args+=(--no-select)
  [[ -n "$orch_agent" ]] && spawn_args+=(--orchestrator-agent "$orch_agent")
  [[ -n "$sid"     ]] && spawn_args+=(--resume "$sid")
  [[ -n "$persona" ]] && spawn_args+=(--persona "$persona")
  [[ -n "$model"   ]] && spawn_args+=(--model "$model")
  [[ -n "$initial_message" ]] && spawn_args+=(--initial-message "$initial_message")

  local out
  out="$("${ENDY_ROOT}/scripts/spawn-chat.sh" "${spawn_args[@]}")" || {
    printf '%s\n' "$out"
    exit 1
  }
  printf '%s\n' "$out"
  echo
  echo "PARENT_TASK=$id"
  echo "SESSION_RESUMED=$([[ -n "$sid" ]] && echo true || echo false)"

  local new_window
  new_window="$(printf '%s\n' "$out" | grep '^TMUX_WINDOW=' | head -1 | cut -d= -f2-)"
  [[ -n "$new_window" ]] || return 0
  [[ "$attach" == "1" ]] && focus_window "$new_window"
  return 0
}

# ---------------------------------------------------------------------------
# followup — continue a task's conversation with a new prompt
# ---------------------------------------------------------------------------
#
# Per-CLI strategy (validated May 2026):
#   hermes   → native: --resume <session_id>; id from `^session_id: ...$` in -Q
#   opencode → native: --session <id>; id from sqlite (default log doesn't emit)
#   cmd      → native resume by title from .meta.json; falls back to context injection
#   claude   → untested; treated as "no native"

cmd_followup() {
  require_session
  local prefix=""
  local prompt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; prompt="$*"; break ;;
      *)  if [[ -z "$prefix" ]]; then prefix="$1"; fi; shift ;;
    esac
  done
  [[ -n "$prefix" ]] || { echo "usage: endy watch followup <id> [-- <new-prompt>]" >&2; exit 2; }

  if [[ -z "$prompt" ]]; then
    if [[ ! -t 0 ]]; then
      prompt="$(cat)"
    else
      echo "no prompt — pass after '--' or pipe via stdin" >&2; exit 2
    fi
  fi

  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  local log; log="$(task_log_path "$meta" "$id")"
  [[ -f "$meta" ]] || { echo "no meta for $id" >&2; exit 1; }

  local agent persona model cwd orch orch_agent
  agent="$(meta_field "$meta" agent)"
  persona="$(meta_field "$meta" persona)"
  model="$(meta_field "$meta" model)"
  cwd="$(meta_field "$meta" cwd)"
  orch="$(task_orchestrator "$meta")"
  orch_agent="$(meta_field "$meta" orchestrator_agent)"

  # Harvest session_id per agent.
  local sid; sid="$(resume_id_for_task "$agent" "$cwd" "$log")"

  echo
  if [[ -n "$sid" ]]; then
    echo "▸ resuming $agent session: $sid"
  else
    echo "▸ no native session resume for $agent — falling back to context injection"
    # Prepend last 50 useful log lines + parent meta as context for the new task.
    local excerpt
    excerpt="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null \
              | strip_ansi | tail -n 80 | head -c 4000)"
    prompt="[endy followup — parent task ${id} (${agent})]

--- previous output (last excerpt) ---
${excerpt}
--- end of previous ---

${prompt}"
  fi

  # Build spawn args. Always --full-auto (followups are unsupervised by definition).
  local spawn_args=(--agent "$agent" --cwd "$cwd" --full-auto --parent-task "$id" --orchestrator "$orch" --prompt "$prompt")
  [[ -n "$orch_agent" ]] && spawn_args+=(--orchestrator-agent "$orch_agent")
  [[ -n "$sid"     ]] && spawn_args+=(--resume "$sid")
  [[ -n "$persona" ]] && spawn_args+=(--persona "$persona")
  [[ -n "$model"   ]] && spawn_args+=(--model "$model")

  "${ENDY_ROOT}/scripts/spawn-long-task.sh" "${spawn_args[@]}"
  echo
  echo "PARENT_TASK=$id"
  echo "SESSION_RESUMED=$([[ -n "$sid" ]] && echo true || echo false)"
}

# ---------------------------------------------------------------------------
# kill — terminate a stuck task cleanly
# ---------------------------------------------------------------------------

cmd_kill() {
  require_session
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy-watch kill <id-prefix>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(task_meta_path "$id")"
  local log; log="$(task_log_path "$meta" "$id")"
  local window; window="$(meta_field "$meta" window)"
  [[ -n "$window" ]] || window="${SESSION}:task-${id}"

  echo "killing $window …"
  if tmux_window_alive "$window"; then
    tmux kill-window -t "$window" 2>/dev/null || echo "  (window already gone)"
  else
    echo "  (window already gone)"
  fi

  # Append a synthetic exit marker so check-long-task.sh stops reporting RUNNING.
  if [[ -f "$log" ]] && ! grep -qE '^ENDY_EXIT=' "$log" 2>/dev/null; then
    printf '\n[endy-watch] killed by user\nENDY_EXIT=130\n' >> "$log"
    echo "  marked log as ENDY_EXIT=130"
  fi
}

cmd_kill_all() {
  require_session
  local agent_filter=""
  local cwd_filter=""
  local orch_filter=""
  local everything=0
  local dry_run=0
  local done_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent_filter="$2"; shift 2 ;;
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      --everything) everything=1; shift ;;
      --done) done_only=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "usage: endy watch kill-all (--agent <name> | --cwd <dir> | --orch <name> | --everything | --done) [--dry-run]" >&2; exit 2 ;;
    esac
  done

  if [[ -z "$agent_filter" && -z "$cwd_filter" && -z "$orch_filter" && "$everything" != "1" && "$done_only" != "1" ]]; then
    echo "refusing to close every task without a filter; pass --everything if that is intentional" >&2
    exit 2
  fi

  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

  local closed=0 matched=0
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local agent; agent="$(meta_field "$m" agent)"
    local cwd; cwd="$(meta_field "$m" cwd)"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local orch; orch="$(task_orchestrator "$m")"

    [[ "$everything" == "1" || -z "$agent_filter" || "$agent" == "$agent_filter" ]] || continue
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    matched=$((matched + 1))

    local log; log="$(task_log_path "$m" "$id")"
    if [[ "${done_only:-0}" == "1" ]]; then
      local st; st="$(log_status "$log" "$id" "$kind")"
      case "$st" in DONE|DONE-ERR|FAIL\(*\)|ABANDONED) ;; *) continue ;; esac
    fi
    local window; window="$(meta_field "$m" window)"
    if [[ -z "$window" ]]; then
      if [[ "$kind" == "chat" ]]; then
        window="${SESSION}:chat-${id}"
      else
        window="${SESSION}:task-${id}"
      fi
    fi

    local window_name="${window##*:}"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window_name" ]] && task_session="$SESSION"
    local exists=0
    if tmux list-windows -t "$task_session" -F '#W' 2>/dev/null | grep -qx "$window_name"; then
      exists=1
    fi

    local follow_window="follow-${id}"
    local follow_exists=0
    if tmux list-windows -t "$task_session" -F '#W' 2>/dev/null | grep -qx "$follow_window"; then
      follow_exists=1
    fi

    [[ "$exists" == "1" || "$follow_exists" == "1" ]] || continue

    echo "closing $id  agent=${agent:-?}  orch=${orch:-?}  cwd=${cwd:-?}"
    echo "  tmux kill-window -t ${window}"
    [[ "$follow_exists" == "1" ]] && echo "  tmux kill-window -t ${task_session}:${follow_window}"

    if [[ "$dry_run" == "1" ]]; then
      continue
    fi

    [[ "$exists" == "1" ]] && tmux kill-window -t "$window" 2>/dev/null || true
    [[ "$follow_exists" == "1" ]] && tmux kill-window -t "${task_session}:${follow_window}" 2>/dev/null || true

    if [[ -f "$log" ]] && ! grep -qE '^ENDY_EXIT=' "$log" 2>/dev/null; then
      printf '\n[endy-watch] killed by kill-all\nENDY_EXIT=130\n' >> "$log"
    fi
    closed=$((closed + 1))
  done < <(_iter_meta_files)

  echo
  echo "matched=${matched}"
  echo "closed=${closed}"
  echo
  echo "tmux commands:"
  echo "  tmux attach -t ${SESSION}"
  echo "  tmux list-windows -t ${SESSION}"
  echo "  tmux kill-session -t ${SESSION}    # stop the entire endy tmux session"
}

cmd_gc() {
  require_session
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1
  local cleaned=0
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local status; status="$(log_status "$log" "$id" "$kind")"
    case "$status" in DONE|DONE-ERR|FAIL\(*\)|ABANDONED) ;; *) continue ;; esac
    local window; window="$(meta_field "$m" window)"
    [[ -z "$window" ]] && { [[ "$kind" == "chat" ]] && window="${SESSION}:chat-${id}" || window="${SESSION}:task-${id}"; }
    local wn="${window##*:}"
    if tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$wn"; then
      [[ "$dry_run" == "1" ]] && echo "[dry] kill-window $window" || tmux kill-window -t "$window" 2>/dev/null
      cleaned=$((cleaned + 1))
    fi
  done < <(_iter_meta_files)
  echo "gc: cleaned $cleaned dead window(s)"
}

# ---------------------------------------------------------------------------
# purge — delete a task family from .logs/ and kill its tmux windows
# ---------------------------------------------------------------------------

cmd_purge() {
  local prefix=""
  local dry_run=0
  local from_picker=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --from-picker) from_picker=1; shift ;;
      *)
        if [[ -z "$prefix" ]]; then
          prefix="$1"
        else
          echo "usage: endy watch purge <id-prefix> [--dry-run] [--from-picker]" >&2
          exit 2
        fi
        shift ;;
    esac
  done
  [[ -n "$prefix" ]] || { echo "usage: endy watch purge <id-prefix> [--dry-run] [--from-picker]" >&2; exit 2; }
  prefix="$(printf '%s' "$prefix" | strip_ansi | awk '{print $1}')"
  [[ -n "$prefix" ]] || { echo "no task id found after stripping ansi" >&2; exit 1; }

  local root_id; root_id="$(resolve_id "$prefix")" || exit 1

  # Collect root task plus all transitive descendants whose parent_task chain reaches the root.
  local purge_set=("$root_id")
  local changed=1
  while [[ "$changed" == "1" ]]; do
    changed=0
    while IFS= read -r m; do
      local id; id="$(basename "$m" .meta | sed 's/^task-//')"
      local in_set=0
      for existing in "${purge_set[@]}"; do
        [[ "$existing" == "$id" ]] && { in_set=1; break; }
      done
      [[ "$in_set" == "1" ]] && continue

      local parent; parent="$(meta_field "$m" parent_task)"
      [[ -n "$parent" ]] || continue

      for existing in "${purge_set[@]}"; do
        [[ "$existing" == "$parent" ]] && { purge_set+=("$id"); changed=1; break; }
      done
    done < <(_iter_meta_files)
  done

  echo "Purge plan for root: ${root_id}"
  echo ""

  local task_count=0
  local windows_to_kill=()
  local files_to_delete=()
  for id in "${purge_set[@]}"; do
    task_count=$((task_count + 1))
    local meta; meta="$(task_meta_path "$id")"
    local log; log="$(task_log_path "$meta" "$id")"
    local prompt; prompt="$(task_prompt_path "$meta" "$id")"
    local kind; kind="$(meta_field "$meta" kind)"; kind="${kind:-spawn}"
    local window; window="$(meta_field "$meta" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"

    echo "  task: ${id}"
    if [[ -n "$window" ]]; then
      local wname; wname="${window##*:}"
      if tmux list-windows -t "$task_session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$wname"; then
        echo "    tmux window: ${window}"
        windows_to_kill+=("$window")
      fi
    fi

    local follow_window="follow-${id}"
    if tmux list-windows -t "$task_session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$follow_window"; then
      echo "    tmux follow: ${task_session}:${follow_window}"
      windows_to_kill+=("${task_session}:${follow_window}")
    fi

    if [[ "$kind" == "chat" && -z "$window" ]]; then
      local chat_window="chat-${id}"
      if tmux list-windows -t "$task_session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$chat_window"; then
        echo "    tmux chat: ${task_session}:${chat_window}"
        windows_to_kill+=("${task_session}:${chat_window}")
      fi
    fi

    if [[ -z "$window" && "$kind" != "chat" ]]; then
      local task_window="task-${id}"
      if tmux list-windows -t "$task_session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$task_window"; then
        echo "    tmux task: ${task_session}:${task_window}"
        windows_to_kill+=("${task_session}:${task_window}")
      fi
    fi

    if [[ -f "$meta" ]]; then
      echo "    meta: ${meta}"
      files_to_delete+=("$meta")
    fi
    if [[ -f "$prompt" ]]; then
      echo "    prompt: ${prompt}"
      files_to_delete+=("$prompt")
    fi
    if [[ -f "$log" ]]; then
      echo "    log: ${log}"
      files_to_delete+=("$log")
    fi
    local default_log="${LOG_DIR}/task-${id}.log"
    [[ "$kind" == "chat" ]] && default_log="${LOG_DIR}/chat-${id}.log"
    if [[ "$default_log" != "$log" && -f "$default_log" ]]; then
      echo "    fallback log: ${default_log}"
      files_to_delete+=("$default_log")
    fi
  done

  # Deduplicate
  local unique_windows=()
  if [[ ${#windows_to_kill[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && unique_windows+=("$line")
    done < <(printf '%s\n' "${windows_to_kill[@]}" | sort -u)
  fi

  local unique_files=()
  if [[ ${#files_to_delete[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && unique_files+=("$line")
    done < <(printf '%s\n' "${files_to_delete[@]}" | sort -u)
  fi

  # Validate files are under .logs
  local safe_files=()
  local skipped_files=()
  for f in ${unique_files[@]+"${unique_files[@]}"}; do
    if [[ "$f" == "${LOG_DIR}"/* ]]; then
      safe_files+=("$f")
    else
      skipped_files+=("$f")
    fi
  done

  if [[ ${#skipped_files[@]} -gt 0 ]]; then
    echo ""
    echo "WARNING: skipping files outside .logs/:"
    for f in "${skipped_files[@]}"; do
      echo "  $f"
    done
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo ""
    echo "[dry-run] no changes made"
    exit 0
  fi

  # Confirmation: '&' arms; CLI also requires retyping the full id.
  echo ""
  echo "Type '&' to arm purge:"
  read -r confirm1
  if [[ "$confirm1" != "&" ]]; then
    echo "aborted (first confirmation not '&')" >&2
    exit 1
  fi

  if [[ "$from_picker" != "1" ]]; then
    echo "Type the full root task id to purge:"
    read -r confirm2
    if [[ "$confirm2" != "$root_id" ]]; then
      echo "aborted (second confirmation did not match ${root_id})" >&2
      exit 1
    fi
  fi

  # Execute
  local killed_count=0
  local deleted_count=0

  for w in ${unique_windows[@]+"${unique_windows[@]}"}; do
    tmux kill-window -t "$w" 2>/dev/null && killed_count=$((killed_count + 1))
  done

  for f in ${safe_files[@]+"${safe_files[@]}"}; do
    rm -f "$f" && deleted_count=$((deleted_count + 1))
  done

  echo ""
  echo "Purge complete: ${task_count} task(s), ${killed_count} window(s) killed, ${deleted_count} file(s) deleted"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

cmd_jump() {
  # Dispatcher for the browse picker enter binding. Routes the row id
  # to the right tmux action based on its prefix:
  #   live:<sess>:<name>  → select the tmux window
  #   ext:<sess>          → attach/switch to that tmux session
  #   <task-id>           → fall back to chat (existing behavior)
  local key="${1:-}"
  [[ -n "$key" ]] || return 0
  case "$key" in
    live:*|ext:*)
      local target="${key#*:}"
      local sess="${target%%:*}"
      tmux has-session -t "$sess" 2>/dev/null || { echo "endy watch jump: session '$sess' is not running" >&2; return 1; }
      if [[ "$target" == *:* ]]; then
        tmux select-window -t "$target" 2>/dev/null || true
      fi
      if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$target" 2>/dev/null || tmux switch-client -t "$sess"
      else
        exec tmux attach -t "$sess"
      fi
      ;;
    *)
      cmd_chat "$key" ;;
  esac
}

case "${1:-attach}" in
  attach|"")     shift || true; cmd_attach "$@" ;;
  list|ls)       shift; cmd_list "$@" ;;
  tree)          shift; cmd_tree "$@" ;;
  dir)           shift; cmd_dir "$@" ;;
  sessions)      shift; cmd_sessions "$@" ;;
  agents)        shift; cmd_agents "$@" ;;
  log)           shift; cmd_log "$@" ;;
  view)          shift; cmd_view "$@" ;;
  follow)        shift; cmd_follow "$@" ;;
  chat)          shift; cmd_chat "$@" ;;
  _open)         shift; cmd_open "$@" ;;
  _jump)         shift; cmd_jump "$@" ;;
  browse)        shift; cmd_browse "$@" ;;
  panel)         shift; cmd_panel "$@" ;;
  followup)      shift; cmd_followup "$@" ;;
  kill)          shift; cmd_kill "$@" ;;
  gc)            shift; cmd_gc "$@" ;;
  kill-all|close-all) shift; cmd_kill_all "$@" ;;
  purge|delete|purge-session) shift; cmd_purge "$@" ;;
  -h|--help|help)
    sed -n '2,59p' "$0"
    ;;
  *)
    echo "usage: $(basename "$0") [attach [<id>] | list | tree [--all] | dir <path> | log <id> | view <id> | follow <id> | chat <id> | browse [--all] [--cwd <dir>] [--orch <name>] | panel [--all] | followup <id> [-- <prompt>] | kill <id> | gc [--dry-run] | kill-all --agent <name>|--cwd <dir>|--orch <name>|--everything | purge <id> [--dry-run]]" >&2
    exit 2
    ;;
esac
