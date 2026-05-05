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
#   endy-watch list               Enriched table: id / status / agent / persona /
#                                 cwd / runtime / last log line. Designed to scan
#                                 even with 15+ active tasks.
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
#   endy-watch browse             Interactive picker. Uses fzf if installed
#                                 (live preview in side pane); falls back to
#                                 the table otherwise. Enter on a row → follow.
#   endy-watch panel [--all]      Tile view of running task logs. Warns if >4
#                                 (suggest 'browse' or 'follow' instead).
#   endy-watch followup <id> [-- <new-prompt>]
#                                 Continue the conversation of an existing task.
#                                 hermes/opencode → native session resume.
#                                 cmd → context injection (no native headless
#                                 resume). New tmux window, new TASK_ID, with
#                                 parent_task pointing back to <id>.
#   endy-watch kill <id>          Kill a stuck task (closes its tmux window AND
#                                 writes ENDY_EXIT=130 to the log so it's not
#                                 reported as RUNNING forever).
#   endy-watch help               This text.

set -u

SESSION="endy"
ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ENDY_ROOT}/.logs"

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
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g'
}

# Resolve a task id prefix to a full task id (errors if 0 or >1 matches).
resolve_id() {
  local prefix="$1"
  local matches=()
  shopt -s nullglob
  for m in "${LOG_DIR}"/task-*.meta; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    if [[ "$id" == "$prefix"* || "$id" == *"$prefix"* ]]; then
      matches+=("$id")
    fi
  done
  shopt -u nullglob
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

# Single source of truth for the task-status heuristic. When adding new
# patterns, also update check-long-task.sh's log_looks_failed() and the
# matching block in web/server.py.
log_status() {
  local log="$1"
  local task_id="${2:-}"

  exists_in_tmux=0
  if [[ -n "$task_id" ]] \
     && tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null \
        | grep -qx "task-${task_id}"; then
    exists_in_tmux=1
  fi

  if [[ ! -f "$log" ]]; then
    if [[ -n "$task_id" && "$exists_in_tmux" == "0" ]]; then
      echo "ABANDONED"
    else
      echo "PENDING"
    fi
    return
  fi

  if grep -qE '^ENDY_EXIT=[0-9]+' "$log" 2>/dev/null; then
    local ec; ec="$(grep -E '^ENDY_EXIT=[0-9]+' "$log" | tail -1 | cut -d= -f2)"
    if [[ "$ec" == "0" ]]; then
      if grep -qE '(^|[^A-Za-z])(Error:|ERROR:|Exception:|Traceback)' "$log" 2>/dev/null \
         || grep -qE '(ProviderModelNotFoundError|Unauthorized|forbidden|model not found|auto-rejecting)' "$log" 2>/dev/null \
         || grep -qE 'Reached maximum (conversation )?turns|response may be incomplete' "$log" 2>/dev/null
      then echo "DONE-ERR"
      else echo "DONE"
      fi
    else
      echo "FAIL($ec)"
    fi
    return
  fi

  # No ENDY_EXIT yet. If the tmux window is also gone, the task died silently.
  if [[ -n "$task_id" && "$exists_in_tmux" == "0" ]]; then
    echo "ABANDONED"
  else
    echo "RUN"
  fi
}

# ---------------------------------------------------------------------------
# list — enriched table
# ---------------------------------------------------------------------------

cmd_list() {
  local now; now="$(date +%s)"
  local found=0

  # Header
  printf '%-22s %-9s %-9s %-14s %-30s %-7s %s\n' \
    "ID" "STATUS" "AGENT" "PERSONA" "CWD" "RUN" "LAST"
  printf '%-22s %-9s %-9s %-14s %-30s %-7s %s\n' \
    "──────────────────────" "─────────" "─────────" "──────────────" "──────────────────────────────" "───────" "──────────"

  shopt -s nullglob
  for m in "${LOG_DIR}"/task-*.meta; do
    found=1
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log="${LOG_DIR}/task-${id}.log"

    local agent;       agent="$(meta_field "$m" agent)"
    local persona;     persona="$(meta_field "$m" persona)"; persona="${persona:-—}"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"

    # spawned_iso is ISO-8601 UTC like 2026-05-05T10:18:27Z. macOS date -j -f.
    local spawned_epoch
    spawned_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$spawned_iso" +%s 2>/dev/null || echo 0)"
    local runtime
    if [[ "$spawned_epoch" != "0" ]]; then
      runtime="$(human_runtime $((now - spawned_epoch)))"
    else
      runtime="?"
    fi

    local status; status="$(log_status "$log" "$id")"

    local last
    if [[ -f "$log" ]]; then
      # Show the last meaningful line: skip blank lines and the ENDY_EXIT
      # marker so the column reflects what the agent actually said last.
      last="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\]|[[:space:]]*$)' "$log" 2>/dev/null \
              | tail -1 | strip_ansi | tr -d '\r' | head -c 80)"
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

    printf '%-22s %-9s %-9s %-14s %-30s %-7s %s\n' \
      "$id" "$status" "$agent" "$persona" "$cwd_short" "$runtime" "$last"
  done
  shopt -u nullglob

  if [[ "$found" == "0" ]]; then
    echo "(no tasks in ${LOG_DIR})"
  fi
}

# ---------------------------------------------------------------------------
# log — follow one task's log (single-task, blocks the terminal)
# ---------------------------------------------------------------------------

cmd_log() {
  local prefix="${1:-}"
  [[ -n "$prefix" ]] || { echo "usage: endy-watch log <id-prefix>" >&2; exit 2; }
  local id; id="$(resolve_id "$prefix")" || exit 1
  local log="${LOG_DIR}/task-${id}.log"
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
  local meta="${LOG_DIR}/task-${id}.meta"
  local prompt="${LOG_DIR}/task-${id}.prompt.md"
  local log="${LOG_DIR}/task-${id}.log"

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
  local prompt="${LOG_DIR}/task-${id}.prompt.md"
  local log="${LOG_DIR}/task-${id}.log"

  if [[ ! -f "$log" ]]; then
    echo "task $id has no log yet (still starting up)" >&2
    exit 1
  fi

  local window_name="follow-${id}"

  # If a follow window for this id already exists, just point at it.
  if tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$window_name"; then
    tmux select-window -t "${SESSION}:${window_name}"
    echo "follow window already open: ${SESSION}:${window_name}"
    return 0
  fi

  # Build a small inner shell command that prints the prompt header then tails.
  # Use bash explicitly so the heredoc-style semantics are predictable.
  local quoted_prompt; quoted_prompt="$(printf '%q' "$prompt")"
  local quoted_log;    quoted_log="$(printf '%q' "$log")"
  local inner="bash -c $(printf '%q' "
clear
printf '\033[1;36m──── prompt for task %s ────\033[0m\n' '${id}'
[[ -f ${quoted_prompt} ]] && cat ${quoted_prompt} || echo '(no prompt file)'
echo
printf '\033[1;36m──── log (live) ────\033[0m\n'
exec tail -F ${quoted_log}
")"

  tmux new-window -t "$SESSION" -n "$window_name" "$inner"
  tmux set-window-option -t "${SESSION}:${window_name}" remain-on-exit on 2>/dev/null || true

  echo "follow window opened: ${SESSION}:${window_name}"
  echo "attach with: endy watch attach   (Ctrl-b N to switch windows)"
}

# ---------------------------------------------------------------------------
# browse — interactive picker, fzf if available
# ---------------------------------------------------------------------------

cmd_browse() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not installed — falling back to 'list'." >&2
    echo "  (install with: brew install fzf — gives you a live preview picker)" >&2
    cmd_list
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

  shopt -s nullglob
  local rows=()
  local now; now="$(date +%s)"
  for m in "${LOG_DIR}"/task-*.meta; do
    local id; id="$(basename "$m" .meta | sed 's/^task-//')"
    local log="${LOG_DIR}/task-${id}.log"
    local agent;       agent="$(meta_field "$m" agent)"
    local persona;     persona="$(meta_field "$m" persona)"; persona="${persona:-ad-hoc}"
    local cwd;         cwd="$(meta_field "$m" cwd)"
    local spawned_iso; spawned_iso="$(meta_field "$m" spawned_at)"
    local spawned_epoch
    spawned_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$spawned_iso" +%s 2>/dev/null || echo 0)"
    local rt="?"
    [[ "$spawned_epoch" != "0" ]] && rt="$(human_runtime $((now - spawned_epoch)))"
    local st; st="$(log_status "$log" "$id")"

    local dot_color
    case "$st" in
      RUN|PENDING) dot_color="$C_BLU" ;;
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

    rows+=("$(printf '%s%s  %s●%s %s%-9s%s  %s%-9s%s  %-14s  %s%-7s%s  %s%s%s' \
      "$C_BOLD" "$id" "$C_RST" \
      "$dot_color" "$C_RST" \
      "$dot_color" "$st" "$C_RST" \
      "$C_BLU" "$agent" "$C_RST" \
      "$persona" \
      "$C_DIM" "$rt" "$C_RST" \
      "$C_DIM" "$cwd_short" "$C_RST")")
  done
  shopt -u nullglob

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "(no tasks — spawn one with: endy spawn <agent> -- \"<prompt>\")"
    return
  fi

  # Build the bind list. ctrl-y copies the id to the system clipboard so the
  # user never has to wrestle with terminal selection.
  local binds=(
    "--bind=ctrl-v:execute(${BASH_SOURCE[0]} view {1})"
    "--bind=ctrl-l:execute(${BASH_SOURCE[0]} log {1})"
    "--bind=ctrl-k:execute(${BASH_SOURCE[0]} kill {1})"
    "--bind=ctrl-r:refresh-preview"
  )
  local header
  if [[ -n "$copy_cmd" ]]; then
    binds+=("--bind=ctrl-y:execute-silent(printf %s {1} | ${copy_cmd})+abort")
    header="enter→follow  ^V view  ^L log  ^Y copy id  ^K kill  ^R refresh  esc cancel"
  else
    header="enter→follow  ^V view  ^L log  ^K kill  ^R refresh  esc cancel  (install pbcopy/xclip for ^Y copy)"
  fi

  local picked
  picked="$(printf '%s\n' "${rows[@]}" \
    | fzf --ansi --reverse \
          --header="$header" \
          --header-first \
          --preview="${preview_script} {1}" \
          --preview-window=right:65%:wrap:follow \
          --no-mouse \
          "${binds[@]}")"
  [[ -z "$picked" ]] && return 0

  # Strip ANSI from the picked row to extract the id.
  local picked_id; picked_id="$(printf '%s' "$picked" | strip_ansi | awk '{print $1}')"
  [[ -z "$picked_id" ]] && return 0

  cmd_follow "$picked_id"
}

# ---------------------------------------------------------------------------
# panel — tile view (warn if >4)
# ---------------------------------------------------------------------------

cmd_panel() {
  require_session
  local include_all=0
  [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]] && include_all=1

  local logs=() log
  shopt -s nullglob
  for log in "${LOG_DIR}"/task-*.log; do
    if grep -qE '^ENDY_EXIT=' "$log" 2>/dev/null; then
      [[ "$include_all" == "1" ]] && logs+=("$log")
    else
      logs+=("$log")
    fi
  done
  shopt -u nullglob

  if [[ "${#logs[@]}" -eq 0 ]]; then
    if [[ "$include_all" == "1" ]]; then
      echo "no tasks at all" >&2
    else
      echo "no running tasks (use 'panel --all' to include finished, or 'list' to see everything)" >&2
    fi
    exit 0
  fi

  if [[ "${#logs[@]}" -gt 4 ]]; then
    echo "warning: ${#logs[@]} task logs would tile into unreadable panes." >&2
    echo "use 'endy-watch list' for a scannable table, then 'endy-watch log <id>' for one." >&2
    echo "continue anyway? [y/N] " >&2
    read -r reply
    case "$reply" in y|Y|yes|Yes) : ;; *) echo "aborted" >&2; exit 0 ;; esac
  fi

  tmux kill-window -t "${SESSION}:panel" 2>/dev/null || true
  local first="${logs[0]}"
  local first_label; first_label="$(basename "$first" .log)"
  tmux new-window -t "$SESSION" -n panel \
    "printf '\n──── %s ────\n' '${first_label}'; tail -F '${first}'"
  local i
  for ((i=1; i<${#logs[@]}; i++)); do
    local label; label="$(basename "${logs[$i]}" .log)"
    tmux split-window -t "${SESSION}:panel" \
      "printf '\n──── %s ────\n' '${label}'; tail -F '${logs[$i]}'"
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
    exec tmux attach "${flags[@]+${flags[@]}}" -t "${SESSION}:task-${id}"
  else
    exec tmux attach "${flags[@]+${flags[@]}}" -t "$SESSION"
  fi
}

# ---------------------------------------------------------------------------
# followup — continue a task's conversation with a new prompt
# ---------------------------------------------------------------------------
#
# Per-CLI strategy (validated May 2026):
#   hermes   → native: --resume <session_id>; id from `^session_id: ...$` in -Q
#   opencode → native: --session <id>; id from sqlite (default log doesn't emit)
#   cmd      → fallback: -p has no headless resume; we inject context
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
  local meta="${LOG_DIR}/task-${id}.meta"
  local log="${LOG_DIR}/task-${id}.log"
  [[ -f "$meta" ]] || { echo "no meta for $id" >&2; exit 1; }

  local agent persona model cwd
  agent="$(meta_field "$meta" agent)"
  persona="$(meta_field "$meta" persona)"
  model="$(meta_field "$meta" model)"
  cwd="$(meta_field "$meta" cwd)"

  # Harvest session_id per agent.
  local sid=""
  case "$agent" in
    hermes)
      sid="$(grep -oE '^session_id: +[0-9]{8}_[0-9]{6}_[a-f0-9]{6}$' "$log" 2>/dev/null \
            | tail -1 | awk '{print $2}')"
      ;;
    opencode)
      local opencode_db="${HOME}/.local/share/opencode/opencode.db"
      if [[ -f "$opencode_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
        # Latest session for this directory — best heuristic without --format json.
        sid="$(sqlite3 "$opencode_db" \
          "SELECT id FROM session WHERE directory = '$(printf %s "$cwd" | sed "s/'/''/g")' \
           ORDER BY time_created DESC LIMIT 1;" 2>/dev/null)"
      fi
      ;;
    cmd|commandcode|claude)
      sid="" ;;
  esac

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
  local spawn_args=(--agent "$agent" --cwd "$cwd" --full-auto --parent-task "$id" --prompt "$prompt")
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
  local log="${LOG_DIR}/task-${id}.log"
  local window="${SESSION}:task-${id}"

  echo "killing $window …"
  tmux kill-window -t "$window" 2>/dev/null || echo "  (window already gone)"

  # Append a synthetic exit marker so check-long-task.sh stops reporting RUNNING.
  if [[ -f "$log" ]] && ! grep -qE '^ENDY_EXIT=' "$log" 2>/dev/null; then
    printf '\n[endy-watch] killed by user\nENDY_EXIT=130\n' >> "$log"
    echo "  marked log as ENDY_EXIT=130"
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${1:-attach}" in
  attach|"")     shift || true; cmd_attach "$@" ;;
  list|ls)       cmd_list ;;
  log)           shift; cmd_log "$@" ;;
  view)          shift; cmd_view "$@" ;;
  follow)        shift; cmd_follow "$@" ;;
  browse)        cmd_browse ;;
  panel)         shift; cmd_panel "$@" ;;
  followup)      shift; cmd_followup "$@" ;;
  kill)          shift; cmd_kill "$@" ;;
  -h|--help|help)
    sed -n '2,22p' "$0"
    ;;
  *)
    echo "usage: $(basename "$0") [attach [<id>] | list | log <id> | view <id> | follow <id> | browse | panel [--all] | followup <id> [-- <prompt>] | kill <id>]" >&2
    exit 2
    ;;
esac
