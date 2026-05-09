#!/usr/bin/env bash
# Preview-pane renderer for `endy watch browse`. Called by fzf with the task
# id as the argument. Emits a structured, ANSI-coloured view that ends with
# `tail -F` of the task log so the preview tracks live activity.
#
# Not meant to be invoked directly by humans — use `endy watch view <id>`
# for an interactive read.

set -u

ID="${1:-}"
if [[ -z "$ID" ]]; then
  echo "(no task id)"
  exit 0
fi

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-$(_endy_session_name "$(pwd)")}"
LOG_DIR="${ENDY_LOG_DIR:-$(_endy_log_dir "$SESSION")}"
META="${LOG_DIR}/task-${ID}.meta"
# Fallback: search every per-dir scope if the meta isn't in our default LOG_DIR
# (preview is invoked by fzf with just an ID; LOG_DIR is whatever scope the
# parent watch invocation was in, but if the ID actually lives in another
# per-dir session, find it).
if [[ ! -f "$META" ]]; then
  while IFS= read -r _dir; do
    if [[ -f "${_dir}/task-${ID}.meta" ]]; then
      LOG_DIR="$_dir"
      META="${_dir}/task-${ID}.meta"
      break
    fi
  done < <(_endy_list_per_dir_log_dirs)
  unset _dir
fi

# ── colours ────────────────────────────────────────────────────────────────
RED='\033[31m'
GRN='\033[32m'
YLW='\033[33m'
BLU='\033[34m'
CYAN='\033[36m'
GREY='\033[90m'
DIM='\033[2m'
BOLD='\033[1m'
RST='\033[0m'

field() { grep "^$1=" "$META" 2>/dev/null | head -1 | cut -d= -f2-; }

if [[ ! -f "$META" ]]; then
  printf "${RED}task ${ID} has no meta file${RST}\n"
  exit 0
fi

agent="$(field agent)"
kind="$(field kind)"; kind="${kind:-spawn}"
persona="$(field persona)"
model="$(field model)"
cwd="$(field cwd)"
spawned_iso="$(field spawned_at)"
parent_task="$(field parent_task)"
orchestrator="$(field orchestrator)"
orchestrator_agent="$(field orchestrator_agent)"
origin_window="$(field origin_window)"
origin_cwd="$(field origin_cwd)"
window="$(field window)"
window_name="${window##*:}"
PROMPT="$(field prompt)"; PROMPT="${PROMPT:-${LOG_DIR}/task-${ID}.prompt.md}"
LOG="$(field log)"; LOG="${LOG:-${LOG_DIR}/task-${ID}.log}"

if [[ -z "$model" && -f "$LOG" ]]; then
  case "$agent" in
    opencode)
      model="$(perl -pe 's/\e\[[0-9;?<>]*[ -\/]*[@-~]//g; s/\e\]([^\a]*)(\a|\e\\)//g' "$LOG" 2>/dev/null \
        | awk -F ' · ' '/^> / { print $2; exit }' \
        | tr -d '\r')"
      ;;
    cmd|commandcode)
      model="$(perl -pe 's/\e\[[0-9;?<>]*[ -\/]*[@-~]//g; s/\e\]([^\a]*)(\a|\e\\)//g' "$LOG" 2>/dev/null \
        | awk -F 'model: ' '/model: / { print $2; exit }' \
        | tr -d '\r')"
      ;;
  esac
fi

# Status heuristic — shared with endy-watch.sh.
# shellcheck source=lib/status.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"

_session_for_status="${window%%:*}"
[[ -z "$_session_for_status" || "$_session_for_status" == "$window" ]] && _session_for_status="$SESSION"
st="$(endy_log_status "$LOG" "$ID" "$kind" "$_session_for_status")"
unset _session_for_status
case "$st" in
  RUN|PENDING|CHAT) stc="${BLU}● ${st}${RST}" ;;
  DONE)          stc="${GRN}● ${st}${RST}" ;;
  DONE-ERR)      stc="${YLW}● ${st}${RST}" ;;
  FAIL*)         stc="${RED}● ${st}${RST}" ;;
  *)             stc="${GREY}● ${st}${RST}" ;;
esac

# ── runtime ────────────────────────────────────────────────────────────────
human_runtime() {
  local secs="$1"
  if   [[ $secs -lt 60     ]]; then printf '%ds' "$secs"
  elif [[ $secs -lt 3600   ]]; then printf '%dm%02ds' $((secs/60)) $((secs%60))
  elif [[ $secs -lt 86400  ]]; then printf '%dh%02dm' $((secs/3600)) $(((secs%3600)/60))
  else                              printf '%dd%02dh' $((secs/86400)) $(((secs%86400)/3600))
  fi
}
spawned_epoch="$(_endy_iso_to_epoch "$spawned_iso")"
runtime=""
if [[ "$spawned_epoch" != "0" ]]; then
  now="$(date +%s)"
  runtime="$(human_runtime $((now - spawned_epoch)))"
fi

# ── render ─────────────────────────────────────────────────────────────────
printf '\n'
printf "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${RST}\n"
printf "${BOLD}${CYAN}║${RST}  ${BOLD}%s${RST}   %b\n" "$ID" "$stc"
printf "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${RST}\n"
printf '\n'
printf "  ${DIM}AGENT     ${RST}${BLU}%s${RST}\n" "$agent"
printf "  ${DIM}KIND      ${RST}%s\n" "$kind"
orch_label="${orchestrator:-${origin_window:-manual}}"
[[ -n "$orchestrator_agent" ]] && orch_label="${orch_label}[${orchestrator_agent}]"
printf "  ${DIM}ORCH      ${RST}${GRN}%s${RST}\n" "$orch_label"
printf "  ${DIM}PERSONA   ${RST}%s\n" "${persona:-${GREY}—${RST}}"
[[ -n "$model" ]] && printf "  ${DIM}MODEL     ${RST}%s\n" "$model"
[[ -n "$parent_task" ]] && printf "  ${DIM}PARENT    ${RST}%s\n" "$parent_task"
printf "  ${DIM}CWD       ${RST}%s\n" "$cwd"
[[ -n "$origin_cwd" && "$origin_cwd" != "$cwd" ]] && printf "  ${DIM}FROM      ${RST}%s\n" "$origin_cwd"
printf "  ${DIM}SPAWNED   ${RST}%s${GREY}  (${runtime} ago)${RST}\n" "$spawned_iso"
printf '\n'

_tmux_session="${window%%:*}"
[[ -z "$_tmux_session" || "$_tmux_session" == "$window" ]] && _tmux_session="$SESSION"
printf "${CYAN}──── tmux commands ───────────────────────────────────────────${RST}\n"
printf "tmux attach -t %s\n" "$_tmux_session"
[[ -n "$window_name" ]] && printf "tmux select-window -t %s:%s\n" "$_tmux_session" "$window_name"
[[ -n "$window_name" ]] && printf "tmux kill-window -t %s:%s\n" "$_tmux_session" "$window_name"
unset _tmux_session
printf "endy watch view %s\n" "$ID"
printf "endy watch chat %s\n" "$ID"
printf "endy watch followup %s -- \"<next prompt>\"\n" "$ID"
printf "endy watch kill %s\n" "$ID"
printf '\n'

printf "${CYAN}──── prompt ──────────────────────────────────────────────────${RST}\n"
if [[ -f "$PROMPT" ]]; then
  # Wrap long lines visually (fzf preview doesn't soft-wrap on its own)
  fold -s -w 70 "$PROMPT" | head -25
  lines="$(wc -l < "$PROMPT" 2>/dev/null || echo 0)"
  [[ "$lines" -gt 25 ]] && printf "${GREY}    … (%d more lines, full text in 'view')${RST}\n" $((lines - 25))
else
  printf "${GREY}(no prompt file)${RST}\n"
fi
printf '\n'

printf "${CYAN}──── log (live tail) ─────────────────────────────────────────${RST}\n"
if [[ -f "$LOG" ]]; then
  exec tail -F -n 40 "$LOG"
fi
printf "${GREY}(no log yet — task still starting)${RST}\n"
