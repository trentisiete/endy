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
# shellcheck source=lib/worktree.sh
. "${ENDY_ROOT}/scripts/lib/worktree.sh"
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

if [[ -n "${ENDY_FORCE_COLOR:-}" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then
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
  # An id resolution is inherently global — the same id never appears in
  # two log dirs. Always look across every per-dir/* so commands like
  # `endy watch log <id>` work no matter which session you're in.
  local saved="${AGGREGATE}"
  AGGREGATE=1
  while IFS= read -r m; do
    [[ "$(basename "$m")" == "task-${id}.meta" ]] && { printf '%s\n' "$m"; AGGREGATE="$saved"; return 0; }
  done < <(_iter_meta_files)
  AGGREGATE="$saved"
  return 1
}

# Resolve a task id prefix to a full task id (errors if 0 or >1 matches).
resolve_id() {
  local prefix="$1"
  local matches=()
  local m id
  local saved="${AGGREGATE}"
  AGGREGATE=1
  while IFS= read -r m; do
    id="$(basename "$m" .meta | sed 's/^task-//')"
    if [[ "$id" == "$prefix"* || "$id" == *"$prefix"* ]]; then
      matches+=("$id")
    fi
  done < <(_iter_meta_files)
  AGGREGATE="$saved"
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

# Compact token formatter: 17758 -> 17.7k, 1393649 -> 1.4M. Locale-free.
_endy_fmt_short() {
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '?'; return; }
  if   [[ "$n" -ge 1000000 ]]; then printf '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [[ "$n" -ge 1000    ]]; then printf '%d.%dk' $((n/1000))    $(((n%1000)/100))
  else                              printf '%d' "$n"
  fi
}

# 10-cell context-fill bar (▰ used, ░ free). Always 10 chars wide.
_endy_bar() {
  local pct="${1:-0}"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [[ "$pct" -gt 100 ]] && pct=100
  local filled=$((pct / 10))
  local empty=$((10 - filled))
  local s="" i
  for ((i=0; i<filled; i++)); do s+="▰"; done
  for ((i=0; i<empty;  i++)); do s+="░"; done
  printf '%s' "$s"
}

# "in 3h12m" — given an epoch, return a tight relative interval until then.
_endy_resets_in() {
  local r="${1:-0}"
  [[ "$r" =~ ^[0-9]+$ && "$r" -gt 0 ]] || { printf '?'; return; }
  local now; now=$(date +%s)
  local diff=$((r - now))
  if   [[ "$diff" -lt 0     ]]; then printf 'now'
  elif [[ "$diff" -lt 3600  ]]; then printf '%dm' $((diff/60))
  elif [[ "$diff" -lt 86400 ]]; then printf '%dh%02dm' $((diff/3600)) $(((diff%3600)/60))
  else                              printf '%dd' $((diff/86400))
  fi
}

# Best-effort stats helpers per agent. Always succeed; emit empty string when
# no data exists. Read-only — never block or modify the caller's state.
_endy_codex_stats() {
  local cwd="${1:-}"
  [[ -n "$cwd" && "$cwd" != "—" && "$cwd" != "?" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local helper="${ENDY_ROOT}/scripts/_endy-codex-stats.py"
  [[ -f "$helper" ]] || return 0
  python3 "$helper" "$cwd" 2>/dev/null || true
}

_endy_opencode_stats() {
  local cwd="${1:-}"
  [[ -n "$cwd" && "$cwd" != "—" && "$cwd" != "?" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local helper="${ENDY_ROOT}/scripts/_endy-opencode-stats.py"
  [[ -f "$helper" ]] || return 0
  python3 "$helper" "$cwd" 2>/dev/null || true
}

# Print one compact statusline under an agent row. No-op if no stats. Style
# borrowed from opencode's own bottom bar: bar + percentage + tight numbers
# joined by middle dots, so the eye can scan a row in one look.
_endy_print_agent_stats_line() {
  local indent="$1" agent="$2" cwd="$3"
  case "$agent" in
    codex)
      local stats; stats="$(_endy_codex_stats "$cwd")"
      [[ -n "$stats" ]] || return 0
      local ctx pct total window h5p wkp plan resets
      IFS='|' read -r ctx pct total window h5p wkp plan resets <<< "$stats"
      [[ -n "$ctx" && "$ctx" != "0" ]] || return 0
      local bar; bar="$(_endy_bar "$pct")"
      local line
      printf -v line '%s%s%s %s%d%%%s  %sctx %s/%s%s' \
        "$indent" "$C_BLU" "$bar" "$C_BOLD" "$pct" "$C_RST" \
        "$C_DIM" "$(_endy_fmt_short "$ctx")" "$(_endy_fmt_short "$window")" "$C_RST"
      if [[ -n "$h5p" ]]; then
        line+="  ${C_DIM}·${C_RST} 5h ${C_YLW}${h5p}%${C_RST}"
        [[ -n "$resets" ]] && line+=" ${C_DIM}(↺$(_endy_resets_in "$resets"))${C_RST}"
      fi
      [[ -n "$wkp"  ]] && line+="  ${C_DIM}·${C_RST} wk ${C_YLW}${wkp}%${C_RST}"
      [[ -n "$plan" ]] && line+="  ${C_DIM}· ${plan}${C_RST}"
      printf '%s\n' "$line"
      ;;
    opencode)
      local stats; stats="$(_endy_opencode_stats "$cwd")"
      [[ -n "$stats" ]] || return 0
      local ctx pct tin tout tcr tcw tres cost model window
      IFS='|' read -r ctx pct tin tout tcr tcw tres cost model window <<< "$stats"
      [[ -n "$ctx" && "$ctx" != "0" ]] || return 0
      local bar; bar="$(_endy_bar "$pct")"
      local model_short="${model##*/}"
      local cost_str="$cost"
      [[ "$cost" =~ ^[0-9.]+$ ]] && cost_str="$(printf '%.2f' "$cost" 2>/dev/null || printf '%s' "$cost")"
      local line
      printf -v line '%s%s%s %s%d%%%s  %sctx %s/%s%s  %s·%s ↑%s ↓%s' \
        "$indent" "$C_BLU" "$bar" "$C_BOLD" "$pct" "$C_RST" \
        "$C_DIM" "$(_endy_fmt_short "$ctx")" "$(_endy_fmt_short "$window")" "$C_RST" \
        "$C_DIM" "$C_RST" "$(_endy_fmt_short "$tin")" "$(_endy_fmt_short "$tout")"
      [[ -n "$cost_str"    ]] && line+="  ${C_DIM}·${C_RST} \$${cost_str}"
      [[ -n "$model_short" ]] && line+="  ${C_DIM}· ${model_short}${C_RST}"
      printf '%s\n' "$line"
      ;;
  esac
}

# Classify the agent running inside a tmux pane.
#
# Window name wins (explicit user/orchestrator naming). Otherwise we walk the
# pane's process tree up to 4 levels deep and look for a known CLI binary —
# this is what catches `node /usr/bin/codex`, `node /usr/bin/cmd`, etc., which
# tmux reports as `pane_current_command=node` and which the old name-only
# classifier left mislabelled as the literal string "node".
#
# Returns one of: codex|opencode|cmd|claude|hermes|gemini|shell|<wcmd>
# - "shell" is reserved for plain bash/zsh/sh/fish panes whose process tree
#   contains no recognized agent — callers can filter those out so the agents
#   view doesn't list empty terminals as agents.
_endy_detect_pane_agent() {
  local target="$1" wname="$2" wcmd="$3"
  case "$wname" in
    *claude*)             printf 'claude';   return ;;
    *codex*)              printf 'codex';    return ;;
    *opencode*|oc-*)      printf 'opencode'; return ;;
    *cmd-*|*commandcode*) printf 'cmd';      return ;;
    *hermes*)             printf 'hermes';   return ;;
    *gemini*)             printf 'gemini';   return ;;
  esac

  local pane_pid
  pane_pid="$(tmux display -p -t "$target" '#{pane_pid}' 2>/dev/null)"
  if [[ -n "$pane_pid" && "$pane_pid" =~ ^[0-9]+$ ]]; then
    local frontier="$pane_pid" all="$pane_pid" depth=0 next cur kids p args first second
    while [[ -n "$frontier" && "$depth" -lt 4 ]]; do
      next=""
      for cur in $frontier; do
        kids="$(pgrep -P "$cur" 2>/dev/null)"
        [[ -n "$kids" ]] && { all+=" $kids"; next+=" $kids"; }
      done
      frontier="$next"
      depth=$((depth + 1))
    done
    for p in $all; do
      args="$(ps -p "$p" -o args= 2>/dev/null)"
      [[ -z "$args" ]] && continue
      # shellcheck disable=SC2086
      set -- $args
      first="${1##*/}"
      second=""
      [[ $# -ge 2 ]] && second="${2##*/}"
      case "$first" in
        node|node[0-9]*|python|python[0-9]*|deno|bun|java|ruby|perl)
          [[ -n "$second" ]] && first="$second"
          ;;
      esac
      first="${first%.js}"
      first="${first%.mjs}"
      case "$first" in
        codex|codex-*)   printf 'codex';    return ;;
        opencode|oc)     printf 'opencode'; return ;;
        cmd|commandcode) printf 'cmd';      return ;;
        claude)          printf 'claude';   return ;;
        hermes)          printf 'hermes';   return ;;
        gemini)          printf 'gemini';   return ;;
      esac
    done
  fi

  case "$wcmd" in
    bash|zsh|sh|fish|-bash|-zsh|dash|ksh) printf 'shell'; return ;;
  esac
  printf '%s' "$wcmd"
}

# Strip the `## endy environment` ... `---` injected block from a stream so
# peek's body shows what the agent actually said, not the prompt prelude.
# stub agents output nothing else, so without this their preview is just
# the env block over and over. awk gates: skip from the marker line until
# the closing `---` separator the spawn writer adds, then resume.
_endy_strip_env_block() {
  awk '
    /^\[stub agent — prompt follows\]$/ { next }
    /^## endy environment$/ { skipping=1; next }
    skipping && /^---$/      { skipping=0; next }
    skipping                  { next }
                              { print }
  '
}

# Stable color rotation for session blocks. Same name → same color across
# refreshes, so a session keeps its visual identity. Falls back to no color
# when the caller has no ANSI palette (C_RST unset → NO_COLOR or non-tty
# decided at script init). We can't probe `-t 1` here because callers invoke
# us via $(...), which makes stdout a pipe inside the subshell.
_endy_session_color() {
  local name="$1"
  [[ -n "${C_RST:-}" ]] || { printf ''; return; }
  local sum=0 i ch
  for ((i=0; i<${#name}; i++)); do
    ch="${name:i:1}"
    sum=$((sum + $(printf '%d' "'$ch")))
  done
  case $((sum % 5)) in
    0) printf '\033[35m' ;; # magenta
    1) printf '\033[36m' ;; # cyan
    2) printf '\033[34m' ;; # blue
    3) printf '\033[33m' ;; # yellow
    4) printf '\033[95m' ;; # bright magenta
  esac
}

# Single-glyph status indicator with color. Mirrors opencode's status-dot
# convention so users coming from there don't need to relearn it.
#   ● green  = running / working / live
#   ○ dim    = idle / pending
#   ▲ yellow = warn (DONE-ERR / handoff origin)
#   ✕ red    = dead (FAIL / ABANDONED)
# Same caveat as _endy_session_color about $(...) hiding the tty.
_endy_status_bullet() {
  local status="$1"
  local rst="${C_RST:-}"
  local on=""
  case "$status" in
    RUN|running|live|working|ready)
      [[ -n "$rst" ]] && on=$'\033[32m'
      printf '%s●%s' "$on" "$rst" ;;
    PENDING|idle|—)
      [[ -n "$rst" ]] && on=$'\033[2m'
      printf '%s○%s' "$on" "$rst" ;;
    DONE)
      [[ -n "$rst" ]] && on=$'\033[2m\033[32m'
      printf '%s●%s' "$on" "$rst" ;;
    DONE-ERR|warn|WARN)
      [[ -n "$rst" ]] && on=$'\033[33m'
      printf '%s▲%s' "$on" "$rst" ;;
    FAIL*|ABANDONED|dead)
      [[ -n "$rst" ]] && on=$'\033[31m'
      printf '%s✕%s' "$on" "$rst" ;;
    *)
      [[ -n "$rst" ]] && on=$'\033[2m'
      printf '%s·%s' "$on" "$rst" ;;
  esac
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

cmd_list_picker() {
  local cwd_filter="$1"
  local orch_filter="$2"

  if ! command -v fzf >/dev/null 2>&1; then
    echo "endy watch list --picker needs fzf. Install fzf or run without --picker." >&2
    exit 2
  fi
  AGGREGATE=1   # picker is implicitly cross-session — that's the point

  local now; now="$(date +%s)"
  # Build the picker rows: one task per line, tab-separated columns. The
  # display column comes first; the rest are payload that the preview and
  # bindings parse back from the selected line.
  local picker_lines=()
  local m id log kind status agent cwd window task_session orch orch_label
  local spawned_iso spawned_epoch runtime last sc_glyph
  while IFS= read -r m; do
    id="$(basename "$m" .meta | sed 's/^task-//')"
    log="$(task_log_path "$m" "$id")"
    kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    window="$(meta_field "$m" window)"
    task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"
    status="$(log_status "$log" "$id" "$kind" "$task_session")"
    agent="$(meta_field "$m" agent)"; agent="${agent:-?}"
    cwd="$(meta_field "$m" cwd)"
    orch_label="$(task_orchestrator_label "$m")"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    orch="$(task_orchestrator "$m")"
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    spawned_iso="$(meta_field "$m" spawned_at)"
    spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    runtime="?"
    [[ "$spawned_epoch" != "0" ]] && runtime="$(human_runtime $((now - spawned_epoch)))"
    last="—"
    [[ -f "$log" ]] && last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null \
                                 | tail -1 | strip_ansi | tr -d '\r\n' | head -c 60)"
    case "$status" in
      RUN)        sc_glyph="●" ;;
      PENDING)    sc_glyph="○" ;;
      DONE)       sc_glyph="●" ;;
      DONE-ERR)   sc_glyph="▲" ;;
      FAIL*)      sc_glyph="✕" ;;
      ABANDONED)  sc_glyph="✕" ;;
      *)          sc_glyph="·" ;;
    esac
    picker_lines+=("$(printf '%s  %-22s  %-9s  %-9s  %-7s  %-22s  %s' \
                       "$sc_glyph" "$id" "$status" "$agent" "$runtime" \
                       "$(printf '%.22s' "$orch_label")" "$last")")
  done < <(_iter_meta_files)

  if [[ "${#picker_lines[@]}" -eq 0 ]]; then
    echo "(no tasks across all sessions)"
    echo "spawn one with: endy spawn <agent> -- \"<prompt>\""
    sleep 2
    return 0
  fi

  # fzf's {N} placeholder hands over field N already stripped of ANSI, which
  # is much safer than re-parsing {} with awk. Picker lines are
  # `   ●  <id>  <status>  <agent>  ...`, so {2} is the task id.
  # Pick a clipboard helper available on the host.
  local copy_cmd=""
  if   command -v pbcopy   >/dev/null 2>&1; then copy_cmd="pbcopy"
  elif command -v wl-copy  >/dev/null 2>&1; then copy_cmd="wl-copy"
  elif command -v xclip    >/dev/null 2>&1; then copy_cmd="xclip -selection clipboard"
  elif command -v clip.exe >/dev/null 2>&1; then copy_cmd="clip.exe"
  fi

  # Two lines so every key fits regardless of preview width. fzf renders
  # \n inside header verbatim.
  local fzf_header
  printf -v fzf_header ' %s   %s   %s   %s\n %s   %s   %s   %s' \
    'enter→pane'      'ctrl-space→split'   'ctrl-l→log'   'ctrl-v→view' \
    'ctrl-y→copy id'  'ctrl-k→kill'        'ctrl-x→clean abandoned' 'esc→salir'
  local binds=(
    --bind "enter:execute(${ENDY_ROOT}/bin/endy watch attach {2})+abort"
    --bind "ctrl-space:execute(${ENDY_ROOT}/bin/endy watch live {2})"
    --bind "ctrl-l:execute(${ENDY_ROOT}/bin/endy watch log {2})"
    --bind "ctrl-v:execute(${ENDY_ROOT}/bin/endy watch view {2})"
    --bind "ctrl-k:execute(${ENDY_ROOT}/bin/endy watch kill {2})+abort"
    --bind "ctrl-x:execute(${ENDY_ROOT}/bin/endy watch clean-abandoned)+abort"
  )
  if [[ -n "$copy_cmd" ]]; then
    binds+=(--bind "ctrl-y:execute-silent(printf %s {2} | ${copy_cmd})")
  fi

  printf '%s\n' "${picker_lines[@]}" \
    | fzf --no-sort --reverse --ansi --header="$fzf_header" --header-first \
          --header-lines=0 \
          --preview-window='right:50%:wrap' \
          --preview "ENDY_FORCE_COLOR=1 ENDY_PEEK_WIDTH=50 ${ENDY_ROOT}/bin/endy watch peek {2} 2>&1" \
          "${binds[@]}" >/dev/null
  return 0
}

cmd_list() {
  local cwd_filter=""
  local orch_filter=""
  local picker=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd|--dir) cwd_filter="$2"; shift 2 ;;
      --orch|--orchestrator) orch_filter="$2"; shift 2 ;;
      --overview|--all-sessions) AGGREGATE=1; shift ;;
      --live) LIVE_ONLY=1; shift ;;
      --all|-a) shift ;; # accepted for symmetry with tree; list always shows everything
      --picker|-i) picker=1; shift ;;
      *) echo "usage: endy watch list [--cwd <dir>] [--orch <name>] [--overview] [--live] [--picker]" >&2; exit 2 ;;
    esac
  done
  [[ -n "$cwd_filter" ]] && cwd_filter="$(cd "$cwd_filter" 2>/dev/null && pwd || printf '%s\n' "$cwd_filter")"

  if [[ "$picker" == "1" ]]; then
    cmd_list_picker "$cwd_filter" "$orch_filter"
    return 0
  fi

  local now; now="$(date +%s)"
  local rows=()

  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"

    local agent;       agent="$(meta_field "$m" agent)"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local kind;        kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local parent;      parent="$(meta_field "$m" parent_task)"
    local handoff_from;   handoff_from="$(meta_field "$m" handoff_from)"
    local handoff_reason; handoff_reason="$(meta_field "$m" handoff_reason)"
    local orch;        orch="$(task_orchestrator "$m")"
    local orch_label;  orch_label="$(task_orchestrator_label "$m")"
    local model;       model="$(model_label "$m" "$log" "$agent")"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue

    local spawned_epoch; spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local runtime="?"
    [[ "$spawned_epoch" != "0" ]] && runtime="$(human_runtime $((now - spawned_epoch)))"

    # Use the task's own tmux session for liveness — log_status defaults to
    # $SESSION which in overview mode is "endy", and no per-dir task lives
    # there, so without this every overview row would show ABANDONED.
    local task_window_meta; task_window_meta="$(meta_field "$m" window)"
    local task_session_meta="${task_window_meta%%:*}"
    [[ -z "$task_session_meta" || "$task_session_meta" == "$task_window_meta" ]] && task_session_meta="$SESSION"
    local status; status="$(log_status "$log" "$id" "$kind" "$task_session_meta")"

    local last
    if [[ "$kind" == "chat" ]]; then
      last="(interactive pane captured)"
    elif [[ -f "$log" ]]; then
      last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\]|[[:space:]]*$)' "$log" 2>/dev/null \
              | tail -n 200 | strip_ansi | tr -d '\r' \
              | awk '/[[:alnum:]]/ { line=$0 } END { print line }' \
              | head -c 90)"
      [[ -z "$last" ]] && last="(empty)"
    else
      last="(no log yet)"
    fi

    # Bash `read` collapses consecutive tabs when IFS is a single whitespace
    # char, so empty fields would shift the row. Use a sentinel for emptiness
    # and strip it back to "" after the read.
    rows+=("${orch_label:-—}"$'\t'"${id:-—}"$'\t'"${status:-—}"$'\t'"${agent:-—}"$'\t'"${model:-—}"$'\t'"${kind:-—}"$'\t'"${parent:-—}"$'\t'"${handoff_from:-—}"$'\t'"${handoff_reason:-—}"$'\t'"${runtime:-—}"$'\t'"${cwd:-—}"$'\t'"${last:-—}")
  done < <(_iter_meta_files)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    if [[ "$AGGREGATE" == "1" ]]; then
      printf '\n  %s(no tasks across all sessions)%s\n' "${C_DIM:-}" "${C_RST:-}"
      printf '  %sspawn one with: endy spawn <agent> -- "<prompt>"%s\n\n' "${C_DIM:-}" "${C_RST:-}"
    else
      printf '\n  %s(no tasks in this session)%s\n' "${C_DIM:-}" "${C_RST:-}"
      printf '  %s%s%s\n' "${C_DIM:-}" "${LOG_DIR}" "${C_RST:-}"
      printf '  %sspawn one with: endy spawn <agent> -- "<prompt>"%s\n\n' "${C_DIM:-}" "${C_RST:-}"
    fi
    return 0
  fi

  # Group by orchestrator label, then sort by status priority within.
  local sorted=()
  while IFS= read -r line; do sorted+=("$line"); done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k3,3)

  local prev_orch=""
  local sess_color=""
  local sess_count=0
  for row in "${sorted[@]}"; do
    IFS=$'\t' read -r orch_label id status agent model kind parent handoff_from handoff_reason runtime cwd last <<< "$row"
    # Strip the sentinel back to "" so downstream checks (`-n`, `!= "—"`)
    # behave as the original meta intended.
    [[ "$orch_label"     == "—" ]] && orch_label=""
    [[ "$id"             == "—" ]] && id=""
    [[ "$status"         == "—" ]] && status=""
    [[ "$agent"          == "—" ]] && agent=""
    [[ "$model"          == "—" ]] && model=""
    [[ "$kind"           == "—" ]] && kind=""
    [[ "$parent"         == "—" ]] && parent=""
    [[ "$handoff_from"   == "—" ]] && handoff_from=""
    [[ "$handoff_reason" == "—" ]] && handoff_reason=""
    [[ "$runtime"        == "—" ]] && runtime=""
    [[ "$cwd"            == "—" ]] && cwd=""
    [[ "$last"           == "—" ]] && last=""

    if [[ "$orch_label" != "$prev_orch" ]]; then
      [[ -n "$prev_orch" ]] && printf '\n'
      sess_color="$(_endy_session_color "$orch_label")"
      printf '%s▎%s %s%s%s%s\n' \
        "$sess_color" "$C_RST" \
        "$C_BOLD" "$sess_color" "$orch_label" "$C_RST"
      printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..78})" "$C_RST"
      prev_orch="$orch_label"
    fi

    local status_str; status_str="$(printf '%s' "$status" | strip_ansi)"
    local bullet; bullet="$(_endy_status_bullet "$status_str")"
    printf '   %s  %s%s%s  %s%-9s%s  %s%-9s%s  %s%-7s%s  %s%s%s\n' \
      "$bullet" \
      "$C_BOLD" "$id" "$C_RST" \
      "" "$status_str" "" \
      "$C_BLU" "$agent" "$C_RST" \
      "$C_DIM" "$runtime" "$C_RST" \
      "$C_DIM" "$(printf '%.70s' "$last")" "$C_RST"

    local meta_bits=""
    [[ "$model" != "—" && -n "$model" ]] && meta_bits+="${model} ${C_DIM}·${C_RST} "
    [[ "$kind" != "—" && -n "$kind"  && "$kind" != "spawn" ]] && meta_bits+="${kind} ${C_DIM}·${C_RST} "
    [[ -n "$cwd" ]] && meta_bits+="${cwd}"
    [[ -n "$meta_bits" ]] && printf '       %s%s%s\n' "$C_DIM" "$meta_bits" "$C_RST"

    if [[ -n "$handoff_from" ]]; then
      printf '       %s↪ handoff from %s%s%s\n' "$C_DIM" "$(short_task_ref "$handoff_from")" "$C_RST" \
        "${handoff_reason:+  ${C_DIM}· ${handoff_reason}${C_RST}}"
    elif [[ -n "$parent" && "$parent" != "—" ]]; then
      printf '       %s↺ parent %s%s\n' "$C_DIM" "$(short_task_ref "$parent")" "$C_RST"
    fi
  done
  printf '\n  %sendy watch log <id>   ·   endy watch chat <id>   ·   endy watch followup <id>%s\n\n' "$C_DIM" "$C_RST"
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
  if [[ -n "${ENDY_FORCE_COLOR:-}" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then have_color=1; fi

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

  for entry in "${sessions[@]}"; do
    local session_name="${entry%%$'\t'*}"
    local log_dir="${entry#*$'\t'}"
    local sess_color; sess_color="$(_endy_session_color "$session_name")"

    # Detect every agent currently running in this tmux session by inspecting
    # the process tree under each pane. Skips overview/manager windows and
    # plain shells, so the chip line only shows real CLI agents.
    local -A agent_counts=()
    local agent_total=0
    local first_cwd=""
    while IFS=$'\t' read -r wname wcmd wpath; do
      [[ -n "$wname" ]] || continue
      case "$wname" in
        watch|browse|docs|tree|sessions|agents|panel|help|logs|__bootstrap) continue ;;
        task-*|chat-*|follow-*|diag*) continue ;;
      esac
      local detected; detected="$(_endy_detect_pane_agent "${session_name}:${wname}" "$wname" "$wcmd")"
      [[ "$detected" == "shell" ]] && continue
      agent_counts[$detected]=$(( ${agent_counts[$detected]:-0} + 1 ))
      agent_total=$((agent_total + 1))
      [[ -z "$first_cwd" && -n "$wpath" ]] && first_cwd="$wpath"
    done < <(tmux list-windows -t "$session_name" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' 2>/dev/null)

    # Header line: ▎ session_name                                  cwd
    printf '\n%s▎%s %s%s%-40s%s' \
      "$sess_color" "$C_RST" \
      "$C_BOLD" "$sess_color" "$session_name" "$C_RST"
    if [[ -n "$first_cwd" ]]; then
      printf '  %s%s%s' "$C_DIM" "$first_cwd" "$C_RST"
    fi
    printf '\n  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..78})" "$C_RST"

    # Agents chip line
    if [[ "$agent_total" -gt 0 ]]; then
      local -a chips=()
      local a count
      for a in "${!agent_counts[@]}"; do
        count="${agent_counts[$a]}"
        if [[ "$count" -eq 1 ]]; then
          chips+=("${C_BOLD}${a}${C_RST}")
        else
          chips+=("${C_BOLD}${a}${C_RST}${C_DIM} ×${count}${C_RST}")
        fi
      done
      local chip_str
      printf -v chip_str '  %s' "${chips[@]}"
      printf '   %sagentes%s %s\n' "$C_DIM" "$C_RST" "$chip_str"
    else
      printf '   %sagentes%s  %s—  (sin agentes activos)%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
    fi

    # Tasks: count from .logs/ if a log dir exists for this session
    if [[ -d "$log_dir" ]]; then
      local run_count=0 pending_count=0 done_count=0 fail_count=0 abandoned_count=0 task_total=0
      shopt -s nullglob
      local m id log kind status
      for m in "${log_dir}"/task-*.meta; do
        id="$(basename "$m" .meta | sed 's/^task-//')"
        log="${log_dir}/task-${id}.log"
        [[ -f "$log" ]] || log="${log_dir}/chat-${id}.log"
        kind="$(meta_field "$m" kind 2>/dev/null)"; kind="${kind:-spawn}"
        # Use the task's own session (not the caller's $SESSION) for the
        # tmux-liveness probe: overview shows tasks owned by every per-dir
        # session, and they're alive in their own session, not in "endy".
        local _tw _ts
        _tw="$(meta_field "$m" window 2>/dev/null)"
        _ts="${_tw%%:*}"
        [[ -z "$_ts" || "$_ts" == "$_tw" ]] && _ts="$session_name"
        status="$(log_status "$log" "$id" "$kind" "$_ts" 2>/dev/null)"
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

      local -a task_parts=()
      [[ "$run_count"       -gt 0 ]] && task_parts+=("${C_GRN}${run_count} RUN${C_RST}")
      [[ "$pending_count"   -gt 0 ]] && task_parts+=("${C_YLW}${pending_count} PENDING${C_RST}")
      [[ "$done_count"      -gt 0 ]] && task_parts+=("${C_DIM}${done_count} DONE${C_RST}")
      [[ "$fail_count"      -gt 0 ]] && task_parts+=("${C_RED}${fail_count} FAIL${C_RST}")
      [[ "$abandoned_count" -gt 0 ]] && task_parts+=("${C_RED}${abandoned_count} ABANDONED${C_RST}")
      if [[ "$task_total" -eq 0 ]]; then
        printf '   %stasks%s    %s—%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
      else
        local task_str
        printf -v task_str '  %s' "${task_parts[@]}"
        printf '   %stasks%s   %s\n' "$C_DIM" "$C_RST" "$task_str"
      fi
    else
      printf '   %stasks%s    %s(log dir external)%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
    fi
  done
  printf '\n  %stmux attach -t <session>%s\n\n' "$C_DIM" "$C_RST"
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
  if [[ -n "${ENDY_FORCE_COLOR:-}" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then have_color=1; fi

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
    local window; window="$(meta_field "$m" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"
    local status; status="$(log_status "$log" "$id" "$kind" "$task_session")"
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
        watch|browse|docs|tree|sessions|agents|panel|help|logs|__bootstrap) continue ;;
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

      local twagent
      twagent="$(_endy_detect_pane_agent "${tsess}:${wname}" "$wname" "$wcmd")"
      # Plain shells with no recognized agent process running aren't agents.
      [[ "$twagent" == "shell" ]] && continue

      local twruntime="?"
      [[ -n "$wact" && "$wact" != "0" ]] && twruntime="$(human_runtime $((now - wact)))"
      local twlast
      twlast="$(tmux capture-pane -t "${tsess}:${wname}" -p -S -10 2>/dev/null \
                  | strip_ansi | tr -d '\r' | tr '\t' ' ' \
                  | awk '/[[:alnum:]]/ { line=$0 } END { print line }' | head -c 100)"
      [[ -z "$twlast" ]] && twlast="(idle)"

      rows+=("${tsess}"$'\t'"${C_BLU}running${C_RST}"$'\t'"${twagent}"$'\t'"${twagent}"$'\t'"${wname}"$'\t'"${twruntime}"$'\t'"${wpath}"$'\t'"${twlast}"$'\t'"${C_CYN}T${C_RST}"$'\t'"${tsess}"$'\t'"—"$'\t'"—")
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

  # Render as session-grouped cards. Sort by session, then by status
  # (running first → idle/done last) inside each session.
  local sorted=()
  while IFS= read -r line; do sorted+=("$line"); done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k2,2)

  local prev_session=""
  local sess_color=""
  local sess_count=0
  local sess_buffer=()

  _flush_card() {
    [[ -z "$prev_session" ]] && return
    [[ "${#sess_buffer[@]}" -eq 0 ]] && return
    local label="${sess_count} agente"
    [[ "$sess_count" -ne 1 ]] && label="${sess_count} agentes"
    printf '\n%s▎%s %s%s%-50s%s  %s%s%s\n' \
      "$sess_color" "$C_RST" \
      "$C_BOLD" "$sess_color" "$prev_session" "$C_RST" \
      "$C_DIM" "$label" "$C_RST"
    printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..78})" "$C_RST"
    local row
    for row in "${sess_buffer[@]}"; do
      printf '%s' "$row"
    done
  }

  local row
  for row in "${sorted[@]}"; do
    IFS=$'\t' read -r session status agent agent_label name runtime cwd last type_icon orch model persona <<< "$row"
    local status_str; status_str="$(printf '%s' "$status" | strip_ansi)"

    if [[ "$session" != "$prev_session" ]]; then
      _flush_card
      prev_session="$session"
      sess_color="$(_endy_session_color "$session")"
      sess_count=0
      sess_buffer=()
    fi
    sess_count=$((sess_count + 1))

    local bullet; bullet="$(_endy_status_bullet "$status_str")"
    local last_short; last_short="$(printf '%.80s' "$last")"
    local agent_show="$agent_label"
    [[ -z "$agent_show" || "$agent_show" == "—" ]] && agent_show="$agent"

    local entry
    printf -v entry '   %s  %s%-10s%s %-9s  %s%-7s%s  %s%s%s\n' \
      "$bullet" \
      "$C_BOLD" "$agent_show" "$C_RST" \
      "$status_str" \
      "$C_DIM" "$runtime" "$C_RST" \
      "$C_DIM" "$last_short" "$C_RST"
    sess_buffer+=("$entry")

    if [[ "$agent" == "codex" || "$agent" == "opencode" ]]; then
      local stats_line; stats_line="$(_endy_print_agent_stats_line "       " "$agent" "$cwd")"
      [[ -n "$stats_line" ]] && sess_buffer+=("$stats_line"$'\n')
    fi
  done
  _flush_card
  if [[ -n "$prev_session" ]]; then
    printf '\n  %stmux attach -t <session>  Ctrl-b w  to focus a window%s\n\n' "$C_DIM" "$C_RST"
  fi
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
    local window; window="$(meta_field "$m" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"
    local status; status="$(log_status "$log" "$id" "$kind" "$task_session")"
    case "$status" in
      DONE|DONE-ERR|FAIL\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac

    local cwd; cwd="$(meta_field "$m" cwd)"
    local agent; agent="$(meta_field "$m" agent)"
    local orch; orch="$(task_orchestrator "$m")"
    local orch_label; orch_label="$(task_orchestrator_label "$m")"
    local model; model="$(model_label "$m" "$log" "$agent")"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    local parent; parent="$(meta_field "$m" parent_task)"; parent="${parent:-—}"
    local handoff_from;   handoff_from="$(meta_field "$m" handoff_from)"
    local handoff_reason; handoff_reason="$(meta_field "$m" handoff_reason)"
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
    rows+=("${orch_label}"$'\t'"${orch_label}"$'\t'"${cwd}"$'\t'"${task_session}"$'\t'"${id}"$'\t'"${status}"$'\t'"${agent}"$'\t'"${model}"$'\t'"${kind}"$'\t'"${parent}"$'\t'"${runtime}"$'\t'"${last}"$'\t'"${handoff_from}"$'\t'"${handoff_reason}")
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
      rows+=("${lsess}"$'\t'"${lsess}"$'\t'"${lcwd}"$'\t'"${lsess}"$'\t'"${lid}"$'\t'"${lstatus}"$'\t'"${lagent}"$'\t'"${lmodel}"$'\t'"live"$'\t'"—"$'\t'"${lruntime}"$'\t'"${llast}"$'\t'""$'\t'"")
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
        watch|browse|docs|tree|sessions|agents|panel|help|logs|__bootstrap) continue ;;
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

      local twagent
      twagent="$(_endy_detect_pane_agent "${tsess}:${wname}" "$wname" "$wcmd")"
      [[ "$twagent" == "shell" ]] && continue

      local twruntime="?"
      [[ -n "$wact" && "$wact" != "0" ]] && twruntime="$(human_runtime $((now - wact)))"
      local twlast
      twlast="$(tmux capture-pane -t "${tsess}:${wname}" -p -S -10 2>/dev/null \
                  | strip_ansi | tr -d '\r' | tr '\t' ' ' \
                  | awk '/[[:alnum:]]/ { line=$0 } END { print line }' | head -c 90)"
      [[ -z "$twlast" ]] && twlast="(idle)"

      rows+=("${tsess}"$'\t'"${tsess}"$'\t'"${wpath}"$'\t'"${tsess}"$'\t'"${wname}"$'\t'"running"$'\t'"${twagent}"$'\t'"—"$'\t'"tmux"$'\t'"—"$'\t'"${twruntime}"$'\t'"${twlast}"$'\t'""$'\t'"")
    done < <(tmux list-windows -t "$tsess" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}'$'\t''#{window_activity}' 2>/dev/null)
  done < <(
    # In overview mode walk every endy* session. In per-dir mode the tree is
    # local — restrict discovery to $SESSION so endy-projA:tree doesn't list
    # agents from endy-Noetiklab, endy-endy, etc.
    if [[ "$AGGREGATE" == "1" ]]; then
      tmux list-sessions -F '#S' 2>/dev/null | grep -E '^endy(-|$)' || true
    else
      tmux has-session -t "$SESSION" 2>/dev/null && printf '%s\n' "$SESSION"
    fi
  )

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
  local sess_color=""
  printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k3,3 -k4,4 -k5,5 | while IFS=$'\t' read -r orch orch_label cwd task_session id status agent model kind parent runtime last handoff_from handoff_reason; do
    if [[ "$orch" != "$last_orch" ]]; then
      [[ -n "$last_orch" ]] && printf '\n'
      sess_color="$(_endy_session_color "$orch")"
      printf '%s▎%s %s%s%s%s\n' \
        "$sess_color" "$C_RST" \
        "$C_BOLD" "$sess_color" "$orch_label" "$C_RST"
      printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..78})" "$C_RST"
      last_orch="$orch"
      last_cwd_key=""
    fi
    local cwd_key="${cwd}"$'\t'"${task_session}"
    if [[ "$cwd_key" != "$last_cwd_key" ]]; then
      [[ -n "$last_cwd_key" ]] && printf '\n'
      printf '   %s%s%s\n' "$C_DIM" "$cwd" "$C_RST"
      last_cwd_key="$cwd_key"
    fi
    local status_str; status_str="$(printf '%s' "$status" | strip_ansi)"
    local bullet; bullet="$(_endy_status_bullet "$status_str")"
    local id_short
    if [[ "$id" == live:* ]]; then
      id_short="${id#live:}"
      id_short="${id_short##*:}"
    else
      id_short="$(printf '%s' "$id" | head -c 16)"
    fi
    # Build the secondary line only when it carries real info (model, parent,
    # task id for spawned tasks). For tmux-discovered windows there's no useful
    # id beyond the agent name itself, so skip the line entirely.
    local meta_bits=""
    [[ "$model" != "—" && -n "$model" ]] && meta_bits+="${C_DIM}·${C_RST} ${model} "
    [[ "$parent" != "—" && -n "$parent" ]] && meta_bits+="${C_DIM}· parent ${C_RST}$(short_task_ref "$parent") "
    local show_id=""
    [[ "$kind" != "tmux" && -n "$id_short" ]] && show_id="$id_short"

    printf '   %s  %s%-9s%s  %-9s  %s%-7s%s  %s%s%s\n' \
      "$bullet" \
      "$C_BOLD" "$agent" "$C_RST" \
      "$status_str" \
      "$C_DIM" "$runtime" "$C_RST" \
      "$C_DIM" "$(printf '%.70s' "$last")" "$C_RST"

    if [[ -n "$show_id" || -n "$meta_bits" ]]; then
      printf '       %s%s%s  %s\n' "$C_DIM" "$show_id" "$C_RST" "$meta_bits"
    fi
    if [[ -n "$handoff_from" ]]; then
      printf '       %s↪ handoff from %s%s%s\n' "$C_DIM" "$(short_task_ref "$handoff_from")" "$C_RST" \
        "${handoff_reason:+  ${C_DIM}· ${handoff_reason}${C_RST}}"
    fi
    if [[ "$agent" == "codex" || "$agent" == "opencode" ]]; then
      _endy_print_agent_stats_line "       " "$agent" "$cwd"
    fi
  done
  # Trailing hint so first-time users discover the interactive panes — tree
  # itself is read-only by design, but `list` and `browse` next to it let
  # the cursor pick up where the eye stopped.
  printf '\n  %s· lectura · para interactuar: %sCtrl-b 1%s %slist%s · %sCtrl-b 2%s %sbrowse%s\n' \
    "$C_DIM" "$C_BOLD" "$C_RST" "$C_DIM" "$C_RST" "$C_BOLD" "$C_RST" "$C_DIM" "$C_RST"
}

cmd_dir() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || { echo "usage: endy watch dir <path> [--all] [--orch <name>]" >&2; exit 2; }
  shift
  # Querying by directory is inherently cross-session: a path under /work/X
  # might be the cwd of agents owned by endy-x, endy-y, or both. Defaulting
  # to overview/aggregate mode avoids "no agents" false negatives when the
  # caller runs `endy watch dir` from a different session than the target.
  cmd_tree --cwd "$dir" --overview "$@"
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
# peek — colorful, structured preview of one task. Designed for fzf
# --preview, but works as a CLI command on its own.
# ---------------------------------------------------------------------------

cmd_peek() {
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy watch peek <id-prefix> | live:<session>:<window> | ext:<session>" >&2; exit 2; }

  # Chip width: when invoked from fzf's preview pane (right:55%) the
  # terminal width is narrow, so a fixed 78 wraps ugly. ENDY_PEEK_WIDTH
  # lets the caller (fzf/preview) shrink it. Default 60.
  local _W="${ENDY_PEEK_WIDTH:-60}"
  local _RULE; _RULE="$(printf '─%.0s' $(seq 1 "$_W"))"

  # Live pane row (from browse): caja meta arriba + tmux capture del pane.
  if [[ "$prefix" == live:* ]]; then
    local payload="${prefix#live:}"
    local lsess="${payload%%:*}"
    local lname="${payload#*:}"
    local lcolor; lcolor="$(_endy_session_color "$lsess")"
    local llabel=" ${lsess} "
    local lbar_right=$(( _W - 3 - ${#llabel} ))
    [[ "$lbar_right" -lt 1 ]] && lbar_right=1
    printf '%s╭──%s%s%s%s%s\n' \
      "$lcolor" "$C_BOLD" "$llabel" "$C_RST" \
      "$lcolor" "$(printf '─%.0s' $(seq 1 "$lbar_right"))${C_RST}"

    # Detect agent inside the pane for the meta card.
    local lwcmd=""
    lwcmd="$(tmux display -p -t "${lsess}:${lname}" '#{pane_current_command}' 2>/dev/null)"
    local lagent; lagent="$(_endy_detect_pane_agent "${lsess}:${lname}" "$lname" "${lwcmd:-bash}")"
    [[ "$lagent" == "shell" ]] && lagent="$lname"

    local kvfmt='%s│%s   %s%-9s%s  %s\n'
    printf "$kvfmt" "$lcolor" "$C_RST" "$C_DIM" "id"      "$C_RST" "${C_BOLD}live:${lname}${C_RST}"
    printf "$kvfmt" "$lcolor" "$C_RST" "$C_DIM" "session" "$C_RST" "${lsess}"
    printf "$kvfmt" "$lcolor" "$C_RST" "$C_DIM" "agent"   "$C_RST" "${C_BOLD}${lagent}${C_RST}"
    printf "$kvfmt" "$lcolor" "$C_RST" "$C_DIM" "kind"    "$C_RST" "live pane (interactive)"
    printf '%s╰%s%s\n\n' "$lcolor" "$_RULE" "$C_RST"

    printf '%s── output del agente ──%s\n\n' "$C_DIM" "$C_RST"
    if tmux has-session -t "$lsess" 2>/dev/null \
         && tmux list-windows -t "$lsess" -F '#W' 2>/dev/null | grep -qxF "$lname"; then
      tmux capture-pane -t "${lsess}:${lname}" -p -e -S -200 2>/dev/null \
        | _endy_strip_env_block | tail -n 60 | head -c 32768
    else
      printf '  %s(window cerrada)%s\n' "$C_DIM" "$C_RST"
    fi
    return 0
  fi

  # External tmux session row: chip + agentes detectados + lista de ventanas.
  if [[ "$prefix" == ext:* ]]; then
    local esess="${prefix#ext:}"
    local ecolor; ecolor="$(_endy_session_color "$esess")"
    printf '%s╭%s%s\n' "$ecolor" "$_RULE" "$C_RST"
    printf '%s│%s %s  %s%s%s  %s· external (sin log dir local)%s\n' \
      "$ecolor" "$C_RST" \
      "$(_endy_status_bullet running)" \
      "$C_BOLD" "$esess" "$C_RST" \
      "$C_DIM" "$C_RST"
    printf '%s│%s %s· tmux attach -t %s%s\n' "$ecolor" "$C_RST" "$C_DIM" "$esess" "$C_RST"
    printf '%s╰%s%s\n\n' "$ecolor" "$_RULE" "$C_RST"
    if tmux has-session -t "$esess" 2>/dev/null; then
      printf '  %sagentes detectados%s\n' "$C_DIM" "$C_RST"
      local printed=0
      while IFS=$'\t' read -r wname wcmd wpath; do
        [[ -n "$wname" ]] || continue
        case "$wname" in
          watch|browse|docs|tree|sessions|agents|panel|help|logs|list|__bootstrap) continue ;;
          task-*|chat-*|follow-*|diag*) continue ;;
        esac
        local twagent; twagent="$(_endy_detect_pane_agent "${esess}:${wname}" "$wname" "$wcmd")"
        [[ "$twagent" == "shell" ]] && continue
        printf '   %s  %s%-9s%s   %s%s%s\n' \
          "$(_endy_status_bullet running)" \
          "$C_BOLD" "$twagent" "$C_RST" \
          "$C_DIM" "$wname" "$C_RST"
        printed=1
      done < <(tmux list-windows -t "$esess" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' 2>/dev/null)
      [[ "$printed" == "0" ]] && printf '   %s(no agents detected)%s\n' "$C_DIM" "$C_RST"
    fi
    return 0
  fi

  local id; id="$(resolve_id "$prefix")" || return 1
  local meta; meta="$(_meta_for_id "$id")"
  [[ -f "$meta" ]] || { echo "no meta for $id" >&2; return 1; }

  local agent;       agent="$(meta_field "$meta" agent)"
  local persona;     persona="$(meta_field "$meta" persona)"
  local model;       model="$(meta_field "$meta" model)"
  local cwd;         cwd="$(meta_field "$meta" cwd)"
  local spawned_iso; spawned_iso="$(meta_field "$meta" spawned_at)"
  local kind;        kind="$(meta_field "$meta" kind)"; kind="${kind:-spawn}"
  local window;      window="$(meta_field "$meta" window)"
  local task_session="${window%%:*}"
  local task_window="${window##*:}"
  local log;         log="$(task_log_path "$meta" "$id")"
  local parent;      parent="$(meta_field "$meta" parent_task)"
  local handoff_from;   handoff_from="$(meta_field "$meta" handoff_from)"
  local handoff_reason; handoff_reason="$(meta_field "$meta" handoff_reason)"
  local status; status="$(log_status "$log" "$id" "$kind" "$task_session")"
  local now; now="$(date +%s)"
  local spawned_epoch; spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
  local runtime="?"
  [[ "$spawned_epoch" != "0" ]] && runtime="$(human_runtime $((now - spawned_epoch)))"

  local sess_color; sess_color="$(_endy_session_color "$task_session")"
  local bullet; bullet="$(_endy_status_bullet "$status")"
  local cwd_short="${cwd:-—}"
  [[ ${#cwd_short} -gt $((_W - 14)) ]] && cwd_short="…${cwd_short: -$((_W - 16))}"

  # ── card meta arriba — caja completa con borde, datos como rows clave/valor ──
  # Borde superior con la sesión como label inline.
  local sess_label_visible="${sess_color}${C_BOLD} ${task_session} ${C_RST}"
  local label_text=" ${task_session} "
  local label_len=${#label_text}
  local bar_left=2
  local bar_right=$(( _W - bar_left - label_len ))
  [[ "$bar_right" -lt 1 ]] && bar_right=1
  printf '%s╭%s%s%s%s\n' \
    "$sess_color" "$(printf '─%.0s' $(seq 1 "$bar_left"))" \
    "$sess_label_visible" \
    "$sess_color" "$(printf '─%.0s' $(seq 1 "$bar_right"))${C_RST}"

  # Una key/value por línea, con el bullet de estado como "icono" en el row del status.
  local kvfmt='%s│%s   %s%-9s%s  %s\n'
  printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "id"      "$C_RST" "${C_BOLD}${id}${C_RST}"
  printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "status"  "$C_RST" "${bullet}  ${status}"
  printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "agent"   "$C_RST" "${C_BOLD}${agent:-?}${C_RST}${persona:+ ${C_DIM}[$persona]${C_RST}}${model:+  ${C_DIM}·${C_RST} ${model}}"
  printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "runtime" "$C_RST" "$runtime"
  printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "cwd"     "$C_RST" "${cwd_short}"
  if [[ -n "$handoff_from" ]]; then
    printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "handoff" "$C_RST" "↪ from $(short_task_ref "$handoff_from")${handoff_reason:+ ${C_DIM}· ${handoff_reason}${C_RST}}"
  fi
  if [[ "$agent" == "codex" || "$agent" == "opencode" ]]; then
    local stats; stats="$(_endy_print_agent_stats_line "" "$agent" "$cwd")"
    if [[ -n "$stats" ]]; then
      # strip leading whitespace from the stats line so it aligns with the values column
      stats="${stats#"${stats%%[! ]*}"}"
      printf "$kvfmt" "$sess_color" "$C_RST" "$C_DIM" "usage" "$C_RST" "$stats"
    fi
  fi
  printf '%s╰%s%s\n' "$sess_color" "$_RULE" "$C_RST"

  # ── body: el TUI no se puede "embeber" en el preview de fzf — tmux no
  # permite que un mismo pane viva en dos windows. Lo mejor que puede dar
  # un preview es una captura de texto, que para CLIs muy interactivos
  # (codex, opencode, claude) se siente plana. Por eso aquí mostramos:
  #   - solo metadata estructurada (la caja arriba)
  #   - un footer guía con cómo VER el TUI vivo: enter, o split lateral.
  # Se puede activar el body de capture-pane con ENDY_PEEK_BODY=1 si
  # alguien lo prefiere para grep en CI o vistas no-interactivas.
  local target="${task_session}:${task_window}"
  local target_alive=0
  if tmux has-session -t "$task_session" 2>/dev/null \
       && tmux list-windows -t "$task_session" -F '#W' 2>/dev/null \
            | grep -qxF "$task_window"; then
    target_alive=1
  fi

  if [[ "${ENDY_PEEK_BODY:-0}" == "1" ]]; then
    # Legacy/CI mode: print the captured pane as text below the card.
    printf '\n%s── output (snapshot) ──%s\n\n' "$C_DIM" "$C_RST"
    if [[ "$target_alive" == "1" ]]; then
      tmux capture-pane -t "$target" -p -e -S - 2>/dev/null \
        | _endy_strip_env_block | tail -n 200 | head -c 65536
    elif [[ -f "$log" ]]; then
      printf '  %s(window cerrada — mostrando log)%s\n\n' "$C_DIM" "$C_RST"
      grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null \
        | _endy_strip_env_block | tail -n 200 | tr -d '\r'
    else
      printf '  %s(no window, no log)%s\n' "$C_DIM" "$C_RST"
    fi
    return 0
  fi

  # Default: footer guía. The picker keys take you to the live thing.
  printf '\n'
  if [[ "$target_alive" == "1" ]]; then
    printf '  %s── chat del agente (vivo en tmux) ──%s\n\n' "$C_DIM" "$C_RST"
    printf '  %s%senter%s    abre el pane vivo (\033[2mtmux switch a %s\033[0m)\n' "" "$C_BOLD" "$C_RST" "$target"
    printf '  %s%sctrl-space%s   split lateral persistente (sigue capturando cada 2s)\n' "" "$C_BOLD" "$C_RST"
    printf '  %s%sctrl-l%s    log estructurado en less +F\n' "" "$C_BOLD" "$C_RST"
    printf '  %s%sctrl-v%s    snapshot completo (meta + log)\n' "" "$C_BOLD" "$C_RST"
  elif [[ -f "$log" ]]; then
    printf '  %s── log (window cerrada) ──%s\n\n' "$C_DIM" "$C_RST"
    grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$log" 2>/dev/null \
      | _endy_strip_env_block | tail -n 60 | tr -d '\r'
  else
    printf '  %s(no window, no log)%s\n' "$C_DIM" "$C_RST"
  fi
}

# handoffs — dedicated view of every handoff chain across every session.
#
# A "chain" is a linked list of tasks where each .meta has a non-empty
# handoff_from pointing at its predecessor. We collect every leaf (a task
# that nobody else handed off from, i.e. the chain's end) and walk back
# to its origin, then render the whole chain horizontally as
# `agent A → agent B → agent C`.
cmd_handoffs() {
  AGGREGATE=1
  local now; now="$(date +%s)"

  # Build maps id → meta, id → handoff_from, id → has-successor.
  declare -A META_OF FROM_OF HAS_SUCC AGENT_OF STATUS_OF REASON_OF SESSION_OF SPAWNED_OF
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    META_OF[$id]="$m"
    AGENT_OF[$id]="$(meta_field "$m" agent)"
    SPAWNED_OF[$id]="$(meta_field "$m" spawned_at)"
    REASON_OF[$id]="$(meta_field "$m" handoff_reason)"
    local hf; hf="$(meta_field "$m" handoff_from)"
    if [[ -n "$hf" ]]; then
      FROM_OF[$id]="$hf"
      HAS_SUCC[$hf]=1
    fi
    local w; w="$(meta_field "$m" window)"
    SESSION_OF[$id]="${w%%:*}"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    STATUS_OF[$id]="$(log_status "$log" "$id" "$kind" "${SESSION_OF[$id]}")"
  done < <(_iter_meta_files)

  # No top-level branded header here — the wrapping bash loop in
  # open_view_window already prints `▌ endy › <title>`. Adding another
  # would duplicate it inside the management window.

  # Find chain leaves (id with no successor, but with at least one handoff_from
  # somewhere in its lineage).
  local found=0
  local leaf
  for leaf in "${!META_OF[@]}"; do
    [[ -n "${HAS_SUCC[$leaf]:-}" ]] && continue
    [[ -n "${FROM_OF[$leaf]:-}" ]] || continue   # not part of any chain
    found=1

    # Walk back to origin
    local chain=("$leaf")
    local cur="$leaf"
    while [[ -n "${FROM_OF[$cur]:-}" ]]; do
      cur="${FROM_OF[$cur]}"
      chain=("$cur" "${chain[@]}")
    done

    local origin="${chain[0]}"
    local origin_session="${SESSION_OF[$origin]:-?}"
    local sess_color; sess_color="$(_endy_session_color "$origin_session")"

    printf '%s▎%s %s%s%s%s   %s%s links%s\n' \
      "$sess_color" "$C_RST" \
      "$C_BOLD" "$sess_color" "$origin_session" "$C_RST" \
      "$C_DIM" "${#chain[@]}" "$C_RST"
    printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..70})" "$C_RST"

    # Render horizontally: bullet · agent (id) → bullet · agent (id) → ...
    local i first=1
    for i in "${!chain[@]}"; do
      local lid="${chain[$i]}"
      local lagent="${AGENT_OF[$lid]:-?}"
      local lstatus="${STATUS_OF[$lid]:-?}"
      local lbullet; lbullet="$(_endy_status_bullet "$lstatus")"
      if [[ "$first" == "1" ]]; then
        printf '   '
        first=0
      else
        printf '  %s→%s  ' "$C_DIM" "$C_RST"
      fi
      printf '%s %s%s%s %s(%s)%s' \
        "$lbullet" "$C_BOLD" "$lagent" "$C_RST" \
        "$C_DIM" "$(short_task_ref "$lid")" "$C_RST"
    done
    printf '\n'

    # Reasons line: show each link's reason (the "why this handoff happened")
    local r
    for i in "${!chain[@]}"; do
      [[ "$i" == "0" ]] && continue
      local lid="${chain[$i]}"
      r="${REASON_OF[$lid]:-}"
      [[ -n "$r" ]] && printf '       %s↪ %s → %s · %s%s\n' \
        "$C_DIM" "${AGENT_OF[${chain[$((i-1))]}]:-?}" "${AGENT_OF[$lid]:-?}" "$r" "$C_RST"
    done
    printf '\n'
  done

  if [[ "$found" == "0" ]]; then
    printf '  %s(no handoff chains yet)%s\n' "$C_DIM" "$C_RST"
    printf '  %screa una con: endy handoff <task-id> --to <agent>%s\n\n' "$C_DIM" "$C_RST"
  fi
}

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
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch follow <id-prefix>

Opens a NEW tmux window named follow-<id> with the task's prompt header
and the live log tail (less +F). Multiple calls = multiple windows so you
can watch agent A and agent B side-by-side.
EOF
    return 0
  fi
  require_session
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy watch follow <id-prefix>  (try 'endy watch follow --help')" >&2; exit 2; }
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

  local copy_cmd
  if   command -v pbcopy   >/dev/null 2>&1; then copy_cmd="pbcopy"
  elif command -v wl-copy  >/dev/null 2>&1; then copy_cmd="wl-copy"
  elif command -v xclip    >/dev/null 2>&1; then copy_cmd="xclip -selection clipboard"
  elif command -v clip.exe >/dev/null 2>&1; then copy_cmd="clip.exe"
  else copy_cmd=""
  fi

  local rows=()
  local now; now="$(date +%s)"

  # First pass: collect every visible task into parallel maps so we can
  # later walk the handoff chains (id → ... ) and emit them as `↪` arrows
  # under their origin. We can't render rows on the fly because chain
  # order matters: the origin task must come first, then its descendants
  # in handoff order, regardless of spawn time.
  local -a IDS=()
  local -A AGENT_OF PERS_OF CWD_OF SESS_OF STATUS_OF RT_OF FROM_OF HAS_SUCC ROW_OF
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local agent;       agent="$(meta_field "$m" agent)"
    local persona;     persona="$(meta_field "$m" persona)"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local kind;        kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    cwd_matches_filter "$cwd" "$cwd_filter" || continue
    local orch;        orch="$(task_orchestrator "$m")"
    [[ -z "$orch_filter" || "$orch" == "$orch_filter" ]] || continue
    local spawned_epoch; spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
    local rt="?"; [[ "$spawned_epoch" != "0" ]] && rt="$(human_runtime $((now - spawned_epoch)))"
    local _bw _bs
    _bw="$(meta_field "$m" window 2>/dev/null)"
    _bs="${_bw%%:*}"
    [[ -z "$_bs" || "$_bs" == "$_bw" ]] && _bs="$SESSION"
    local st; st="$(log_status "$log" "$id" "$kind" "$_bs")"
    case "$st" in
      DONE|DONE-ERR|FAIL\(*\)|FAILED\(*\)|ABANDONED)
        [[ "$include_all" == "1" ]] || continue ;;
    esac
    IDS+=("$id")
    AGENT_OF[$id]="$agent"
    PERS_OF[$id]="$persona"
    CWD_OF[$id]="$cwd"
    SESS_OF[$id]="$_bs"
    STATUS_OF[$id]="$st"
    RT_OF[$id]="$rt"
    local hf; hf="$(meta_field "$m" handoff_from)"
    if [[ -n "$hf" ]]; then
      FROM_OF[$id]="$hf"
      HAS_SUCC[$hf]=1
    fi
  done < <(_iter_meta_files)

  # Build a row string for each id (saved for both direct emission and
  # chain emission so we don't recompute).
  local _id
  for _id in "${IDS[@]}"; do
    local _agent="${AGENT_OF[$_id]}" _persona="${PERS_OF[$_id]}" _cwd="${CWD_OF[$_id]}"
    local _bs="${SESS_OF[$_id]}" _st="${STATUS_OF[$_id]}" _rt="${RT_OF[$_id]}"
    local sess_color; sess_color="$(_endy_session_color "$_bs")"
    local bullet; bullet="$(_endy_status_bullet "$_st")"
    local cwd_short="${_cwd:-—}"
    [[ ${#cwd_short} -gt 36 ]] && cwd_short="…${cwd_short: -35}"
    local pers_chip=""
    [[ -n "$_persona" && "$_persona" != "—" && "$_persona" != "ad-hoc" ]] && pers_chip="  ${C_DIM}[$_persona]${C_RST}"

    # Column 1 is always a single glyph so fzf's {2} extraction (the id)
    # stays consistent regardless of whether the row is a chain origin
    # or a handoff continuation. `·` for origin (visual placeholder),
    # `↪` cyan for tasks that came from a previous handoff.
    local link
    if [[ -n "${FROM_OF[$_id]:-}" ]]; then
      link="${C_CYN}↪${C_RST}"
    else
      link="${C_DIM}·${C_RST}"
    fi
    ROW_OF[$_id]="$(printf '%s  %-22s  %s  %s%s▎%s %-12s%s %s%-9s%s %s· %-9s%s %s· %-7s%s  %s· %s%s%s' \
      "$link" "$_id" \
      "$bullet" \
      "$sess_color" "$C_BOLD" "$C_RST" "$_bs" "$C_RST" \
      "$C_BOLD" "$_agent" "$C_RST" \
      "$C_DIM" "$_st" "$C_RST" \
      "$C_DIM" "$_rt" "$C_RST" \
      "$C_DIM" "$cwd_short" "$C_RST" "$pers_chip")"
  done

  # Emit in chain order: each origin (no handoff_from) followed by its
  # descendants reached via handoff_from links. Standalone tasks (no
  # chain) come out as themselves.
  local emitted=" "
  for _id in "${IDS[@]}"; do
    [[ "$emitted" == *" $_id "* ]] && continue
    [[ -n "${FROM_OF[$_id]:-}" ]] && continue   # not an origin
    rows+=("${ROW_OF[$_id]}")
    emitted+="$_id "
    # Walk the chain forward from this origin.
    local prev="$_id"
    local found_next=1
    while [[ "$found_next" == "1" ]]; do
      found_next=0
      local cand
      for cand in "${IDS[@]}"; do
        if [[ "${FROM_OF[$cand]:-}" == "$prev" && "$emitted" != *" $cand "* ]]; then
          rows+=("${ROW_OF[$cand]}")
          emitted+="$cand "
          prev="$cand"
          found_next=1
          break
        fi
      done
    done
  done
  # Any orphaned continuation tasks whose origin was filtered out — emit
  # them on their own so the user can still see them.
  for _id in "${IDS[@]}"; do
    [[ "$emitted" == *" $_id "* ]] && continue
    rows+=("${ROW_OF[$_id]}")
    emitted+="$_id "
  done

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
      local lcwd_short="$lcwd"
      [[ ${#lcwd_short} -gt 36 ]] && lcwd_short="…${lcwd_short: -35}"
      local lid="live:${lsess}:${lname}"
      local lsess_color; lsess_color="$(_endy_session_color "$lsess")"
      local lbullet; lbullet="$(_endy_status_bullet "$lstatus")"

      rows+=("$(printf '%s  %-22s  %s  %s%s▎%s %-12s%s %s%-9s%s %s· %-9s%s %s· %-7s%s  %s· %s%s' \
        "${C_DIM}·${C_RST}" \
        "$lid" \
        "$lbullet" \
        "$lsess_color" "$C_BOLD" "$C_RST" "$lsess" "$C_RST" \
        "$C_BOLD" "$lagent" "$C_RST" \
        "$C_DIM" "live" "$C_RST" \
        "$C_DIM" "$luptime" "$C_RST" \
        "$C_DIM" "$lcwd_short" "$C_RST")")
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
    # Detect agents in the external session by walking process trees.
    local agents_chip="" twagent
    while IFS=$'\t' read -r wname wcmd wpath; do
      [[ -n "$wname" ]] || continue
      case "$wname" in
        watch|browse|docs|tree|sessions|agents|panel|help|logs|list|__bootstrap) continue ;;
        task-*|chat-*|follow-*|diag*) continue ;;
      esac
      twagent="$(_endy_detect_pane_agent "${tsess}:${wname}" "$wname" "$wcmd")"
      [[ "$twagent" == "shell" ]] && continue
      agents_chip+="${twagent} "
    done < <(tmux list-windows -t "$tsess" -F '#W'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' 2>/dev/null)
    agents_chip="${agents_chip% }"
    [[ -z "$agents_chip" ]] && agents_chip="—"
    local eid="ext:${tsess}"
    local esess_color; esess_color="$(_endy_session_color "$tsess")"
    rows+=("$(printf '%s  %-22s  %s  %s%s▎%s %-12s%s %s%-25s%s %s· external%s' \
      "${C_DIM}·${C_RST}" \
      "$eid" \
      "$(_endy_status_bullet running)" \
      "$esess_color" "$C_BOLD" "$C_RST" "$tsess" "$C_RST" \
      "$C_BOLD" "$agents_chip" "$C_RST" \
      "$C_DIM" "$C_RST")")
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
    "--bind=enter:execute(${BASH_SOURCE[0]} _jump {2})+abort"
    "--bind=ctrl-space:execute(${ENDY_ROOT}/bin/endy watch live {2})"
    "--bind=ctrl-g:execute(${BASH_SOURCE[0]} _jump {2})+abort"
    "--bind=ctrl-v:execute(${BASH_SOURCE[0]} view {2})"
    "--bind=ctrl-l:execute(${BASH_SOURCE[0]} log {2})"
    "--bind=ctrl-f:execute(${BASH_SOURCE[0]} follow {2})+abort"
    "--bind=ctrl-o:execute-silent(${BASH_SOURCE[0]} chat {2} --no-attach)+refresh-preview"
    "--bind=ctrl-k:execute(${BASH_SOURCE[0]} kill {2})"
    "--bind=ctrl-d:execute(${BASH_SOURCE[0]} purge {2} --from-picker)+abort"
    "--bind=ctrl-r:refresh-preview"
  )
  local header
  if [[ -n "$copy_cmd" ]]; then
    binds+=("--bind=ctrl-y:execute-silent(printf %s {2} | ${copy_cmd})+abort")
    printf -v header ' %s   %s   %s   %s\n %s   %s   %s   %s   %s' \
      'enter→chat'    'ctrl-o→chat bg' 'ctrl-f→follow'  'ctrl-v→view' \
      'ctrl-l→log'    'ctrl-y→copy id' 'ctrl-k→kill'    'ctrl-d→purge'   'esc→salir'
  else
    printf -v header ' %s   %s   %s   %s\n %s   %s   %s   %s' \
      'enter→chat'    'ctrl-o→chat bg' 'ctrl-f→follow'  'ctrl-v→view' \
      'ctrl-l→log'    'ctrl-k→kill'    'ctrl-d→purge'   'esc→salir   (install xclip/clip.exe for copy)'
  fi

  local picked
  picked="$(printf '%s\n' "${rows[@]}" \
    | fzf --ansi --reverse \
          --header="$header" \
          --header-first \
          --preview "ENDY_FORCE_COLOR=1 ENDY_PEEK_WIDTH=50 ${ENDY_ROOT}/bin/endy watch peek {2} 2>&1" \
          --preview-window=right:50%:wrap \
          --no-mouse \
          "${binds[@]}")"
  [[ -z "$picked" ]] && return 0

  # Strip ANSI from the picked row to extract the id (column 2 — column 1
  # is the chain glyph `·` or `↪`).
  local picked_id; picked_id="$(printf '%s' "$picked" | strip_ansi | awk '{print $2}')"
  [[ -z "$picked_id" ]] && return 0
}

# ---------------------------------------------------------------------------
# panel — tile view (warn if >4)
# ---------------------------------------------------------------------------

cmd_panel() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch panel [--all|-a]

Tile view of running task logs. Warns if more than 4 tasks would be
tiled (suggest browse / follow instead). --all includes finished tasks.

Requires an interactive terminal — opens a `panel` window in tmux and
attaches to it.
EOF
    return 0
  fi
  if [[ ! -t 1 ]]; then
    echo "endy watch panel needs an interactive terminal (stdout is not a tty)" >&2
    echo "usage: endy watch panel [--all|-a]" >&2
    exit 2
  fi
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
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch attach [<id-prefix>] [--strict]

Attaches the current terminal to the endy tmux session. Default mode is
read-write (Ctrl-b N still navigates). --strict makes it true read-only
(blocks the tmux prefix too — use only when you really do not want to
type into agent panes).

If <id-prefix> is given, focuses that task's window after attach.
EOF
    return 0
  fi
  if [[ ! -t 1 ]]; then
    echo "endy watch attach needs an interactive terminal (stdout is not a tty)" >&2
    echo "usage: endy watch attach [<id-prefix>] [--strict]" >&2
    exit 2
  fi
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
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch followup <id-prefix> [-- <new-prompt>]

Continues the conversation of an existing task. opencode/hermes resume
natively; cmd resumes by title (.meta.json) and falls back to context
injection. Spawns a NEW tmux window with a new TASK_ID whose
parent_task points back to <id>.
EOF
    return 0
  fi
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
      local _kw _ks
      _kw="$(meta_field "$m" window 2>/dev/null)"
      _ks="${_kw%%:*}"
      [[ -z "$_ks" || "$_ks" == "$_kw" ]] && _ks="$SESSION"
      local st; st="$(log_status "$log" "$id" "$kind" "$_ks")"
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
    local window; window="$(meta_field "$m" window)"
    [[ -z "$window" ]] && { [[ "$kind" == "chat" ]] && window="${SESSION}:chat-${id}" || window="${SESSION}:task-${id}"; }
    local _ws="${window%%:*}"
    [[ -z "$_ws" || "$_ws" == "$window" ]] && _ws="$SESSION"
    local status; status="$(log_status "$log" "$id" "$kind" "$_ws")"
    case "$status" in DONE|DONE-ERR|FAIL\(*\)|ABANDONED) ;; *) continue ;; esac
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

cmd_split_live() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch live <id>

Splits the current tmux pane horizontally and shows a live mirror of
the task's window: `tmux capture-pane` refreshing every 2 s. Closes
the split when you Ctrl-C.

Use this when you want the picker AND the agent's chat side-by-side
without losing your spot in the picker.

Note: tmux can't link the same pane into two windows, so the split is
a refreshing snapshot of the agent's TUI, not the live pane itself.
For the actual live interaction, use `endy watch attach <id>`.
EOF
    return 0
  fi
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy watch live <id>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local meta; meta="$(_meta_for_id "$id")"
  local window; window="$(meta_field "$meta" window)"
  local target_session="${window%%:*}"
  local target_window="${window##*:}"
  if ! tmux has-session -t "$target_session" 2>/dev/null \
       || ! tmux list-windows -t "$target_session" -F '#W' 2>/dev/null \
              | grep -qxF "$target_window"; then
    echo "endy watch live: window ${window} no longer exists (try 'endy watch view ${id}')" >&2
    exit 1
  fi
  if [[ -z "${TMUX:-}" ]]; then
    echo "endy watch live needs to be run from inside tmux (we split the current pane)" >&2
    echo "alternatives: 'endy watch attach ${id}' or 'endy watch view ${id}'" >&2
    exit 1
  fi
  # Watch -c keeps ANSI colours; -t suppresses the watch header line.
  tmux split-window -h -p 50 \
    "watch -c -n 2 -t \"tmux capture-pane -t '${window}' -p -e -S -\"; sleep 0.2"
}

cmd_clean_abandoned() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
usage: endy watch clean-abandoned [--dry-run] [-y|--yes]

Purges every task in state ABANDONED, DONE-ERR, or FAIL across every
session: removes its .meta / .log / .prompt.md from .logs/ and closes
the tmux window if it still exists. DONE tasks are kept (they finished
correctly).

  --dry-run     show what would be removed without touching anything
  -y, --yes     skip the confirmation prompt
EOF
    return 0
  fi
  local dry_run=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      -y|--yes)  yes=1; shift ;;
      *) echo "endy watch clean-abandoned: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  AGGREGATE=1
  local victims=()
  while IFS= read -r m; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log; log="$(task_log_path "$m" "$id")"
    local kind; kind="$(meta_field "$m" kind)"; kind="${kind:-spawn}"
    local window; window="$(meta_field "$m" window)"
    local task_session="${window%%:*}"
    [[ -z "$task_session" || "$task_session" == "$window" ]] && task_session="$SESSION"
    local status; status="$(log_status "$log" "$id" "$kind" "$task_session")"
    case "$status" in
      ABANDONED|DONE-ERR|FAIL\(*\)) victims+=("${id}|${m}|${log}|${window}|${status}") ;;
    esac
  done < <(_iter_meta_files)

  if [[ "${#victims[@]}" -eq 0 ]]; then
    printf '%s(no abandoned/error/failed tasks)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  printf '%s%d task(s) to clean:%s\n' "$C_BOLD" "${#victims[@]}" "$C_RST"
  local v
  for v in "${victims[@]}"; do
    IFS='|' read -r id m log window status <<< "$v"
    printf '  %s · %s%s%s\n' "$id" "$C_DIM" "$status" "$C_RST"
  done

  if [[ "$dry_run" == "1" ]]; then
    printf '\n%s(--dry-run, nothing removed)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  if [[ "$yes" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      printf '\n%scommit with: endy watch clean-abandoned --yes%s\n' "$C_DIM" "$C_RST"
      return 0
    fi
    printf '\nproceed? type "yes" to confirm: '
    local reply; read -r reply
    [[ "$reply" == "yes" ]] || { echo "aborted"; return 0; }
  fi

  local removed=0 windows_closed=0
  for v in "${victims[@]}"; do
    IFS='|' read -r id m log window status <<< "$v"
    local d; d="$(dirname "$m")"
    rm -f "${d}/task-${id}.meta" "${d}/task-${id}.log" "${d}/task-${id}.prompt.md" \
          "${d}/chat-${id}.meta" "${d}/chat-${id}.log"
    removed=$((removed + 1))
    if [[ -n "$window" ]] && tmux has-session -t "${window%%:*}" 2>/dev/null; then
      if tmux list-windows -t "${window%%:*}" -F '#W' 2>/dev/null \
           | grep -qxF "${window##*:}"; then
        tmux kill-window -t "$window" 2>/dev/null && windows_closed=$((windows_closed + 1))
      fi
    fi
  done
  printf '\n%scleaned %d task(s), closed %d tmux window(s)%s\n' "$C_GRN" "$removed" "$windows_closed" "$C_RST"
}

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
  local worktrees_to_remove=()
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

    # Phase 5: collect worktrees we own (created, not inherited). Inherited
    # rows are skipped — the parent task that created the worktree is the
    # owner; cleanup happens when that owner is purged.
    local wt_dir; wt_dir="$(meta_field "$meta" worktree_dir)"
    local wt_inherited; wt_inherited="$(meta_field "$meta" worktree_inherited)"
    if [[ -n "$wt_dir" && -z "$wt_inherited" ]]; then
      echo "    worktree: ${wt_dir}"
      worktrees_to_remove+=("$wt_dir")
    elif [[ -n "$wt_dir" && -n "$wt_inherited" ]]; then
      echo "    worktree: ${wt_dir}  (inherited — left for owner task to clean up)"
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

  # Phase 5: worktree cleanup. Run AFTER kill-window (otherwise git refuses
  # because the index is "in use") and AFTER file deletion (so meta is
  # already gone — we already collected wt info above). Only remove
  # worktrees whose porcelain is clean; leave dirty ones with a hint so
  # the user can `git worktree remove --force` themselves if they really
  # want to throw away uncommitted edits.
  local wt_removed=0
  local wt_skipped_dirty=0
  local wt_missing=0
  # Dedup worktree list — two children sharing an owner would otherwise be
  # listed twice (shouldn't happen with the inherited= rule, but cheap).
  local unique_worktrees=()
  if [[ ${#worktrees_to_remove[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && unique_worktrees+=("$line")
    done < <(printf '%s\n' "${worktrees_to_remove[@]}" | sort -u)
  fi
  for wt in ${unique_worktrees[@]+"${unique_worktrees[@]}"}; do
    if [[ ! -d "$wt" ]]; then
      wt_missing=$((wt_missing + 1))
      continue
    fi
    if _endy_worktree_safe_to_remove "$wt"; then
      if _endy_worktree_remove "$wt"; then
        wt_removed=$((wt_removed + 1))
      fi
    else
      wt_skipped_dirty=$((wt_skipped_dirty + 1))
      echo "  SKIP worktree (uncommitted edits): $wt"
      echo "       → keep working in it, or to drop edits: git worktree remove --force $wt"
    fi
  done

  echo ""
  echo "Purge complete: ${task_count} task(s), ${killed_count} window(s) killed, ${deleted_count} file(s) deleted"
  if [[ ${#unique_worktrees[@]} -gt 0 ]]; then
    echo "Worktree cleanup: ${wt_removed} removed, ${wt_skipped_dirty} skipped (dirty), ${wt_missing} already gone"
  fi
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
  peek)          shift; cmd_peek "$@" ;;
  handoffs)      shift; cmd_handoffs "$@" ;;
  live)          shift; cmd_split_live "$@" ;;
  clean-abandoned|clean) shift; cmd_clean_abandoned "$@" ;;
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
