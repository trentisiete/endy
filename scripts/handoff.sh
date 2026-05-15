#!/usr/bin/env bash
# scripts/handoff.sh — hand a running/exhausted task over to a different agent.
#
# Reads the parent task's prompt and recent log output, picks a target agent
# (either explicit via --to, or via ENDY_HANDOFF_RESOLVER for multiplexor-style
# routing), and spawns a new task that takes over from where the previous
# agent stopped. The new task lives in the SAME tmux session as the parent
# and inherits its cwd, persona, model, and orchestrator label.
#
# Usage:
#   handoff.sh <task-id-prefix> --to <opencode|cmd|hermes|claude|gemini|bash>
#              [--reason "<text>"]
#              [--instructions "<text>"]
#              [--lines N]                     # truncate the injected log to last N lines
#                                              # (default: inject the whole log; opt-in cap
#                                              # for small-context targets like gemini free)
#              [--stop-parent]                 # kill the parent's tmux window after spawning
#              [--no-attach]
#
# `bash` (alias `stub`) is an offline placeholder agent that just prints the
# composed prompt and idles — handy for testing the handoff plumbing without
# burning real-agent credits.
#
# Resolver hook (multiplexor or similar):
#   When --to is omitted, ENDY_HANDOFF_RESOLVER is invoked as:
#       "$ENDY_HANDOFF_RESOLVER" <previous-agent> <task-id> <cwd>
#   It must print the chosen agent name to stdout (one token) and exit 0.
#   Anything else falls back to an error explaining --to is required.
#
# Output (machine-parseable, stdout):
#   HANDOFF_FROM=<parent-id>
#   HANDOFF_TO=<agent>
#   HANDOFF_CHAIN=<id1>,<id2>,...,<parent-id>
#   TASK_ID=<new-id>
#   TMUX_WINDOW=<session>:task-<new-id>
#   LOG=<absolute path>
#
# Exit codes:
#   0  handoff spawned
#   2  bad arguments / no --to and no resolver
#   3  parent task not found, or parent's tmux session no longer exists
#   4  target agent unknown
#
# This script is intentionally minimal: it does not attempt to detect that
# the parent is "really" exhausted. Phase 2 will add automatic detection.
# For Phase 1, the user (or an orchestrator like Codex) decides when to call
# handoff. The value is that the new agent picks up with the correct context
# in one command.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

parent_prefix=""
target_agent=""
reason=""
instructions=""
lines=""
no_attach=0
stop_parent=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)            target_agent="$2"; shift 2 ;;
        --reason)        reason="$2";       shift 2 ;;
        --instructions)  instructions="$2"; shift 2 ;;
        --lines)         lines="$2";        shift 2 ;;
        --no-attach)     no_attach=1;       shift   ;;
        --stop-parent)   stop_parent=1;     shift   ;;
        -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
        --)              shift; instructions="${instructions:+$instructions }$*"; break ;;
        -*)              echo "handoff: unknown flag: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$parent_prefix" ]]; then
                parent_prefix="$1"; shift
            else
                echo "handoff: unexpected positional: $1" >&2; exit 2
            fi
            ;;
    esac
done

[[ -n "$parent_prefix" ]] || {
    echo "usage: endy handoff <task-id> --to <agent> [--reason \"…\"] [--instructions \"…\"]" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# locate parent meta across all known scopes
# ---------------------------------------------------------------------------

_iter_log_dirs() {
    local root="${ENDY_ROOT}/.logs"
    [[ -d "$root" ]] && printf '%s\n' "$root"
    shopt -s nullglob
    local d
    for d in "${root}/per-dir"/*/; do
        [[ -d "$d" ]] && printf '%s\n' "${d%/}"
    done
    shopt -u nullglob
}

_find_meta() {
    local prefix="$1"
    local dir m id matches=()
    while IFS= read -r dir; do
        for m in "${dir}"/task-*.meta; do
            [[ -f "$m" ]] || continue
            id="$(basename "$m" .meta | sed 's/^task-//')"
            if [[ "$id" == "$prefix"* || "$id" == *"$prefix"* ]]; then
                matches+=("$m")
            fi
        done
    done < <(_iter_log_dirs)
    case "${#matches[@]}" in
        0) echo "handoff: no task matching '$prefix'" >&2; return 1 ;;
        1) printf '%s\n' "${matches[0]}" ;;
        *) echo "handoff: ambiguous '$prefix':" >&2
           printf '  %s\n' "${matches[@]}" >&2
           return 1 ;;
    esac
}

PARENT_META="$(_find_meta "$parent_prefix")" || exit 3

_meta_field() {
    grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

PARENT_ID="$(_meta_field "$PARENT_META" task_id)"
PARENT_AGENT="$(_meta_field "$PARENT_META" agent)"
PARENT_PERSONA="$(_meta_field "$PARENT_META" persona)"
PARENT_MODEL="$(_meta_field "$PARENT_META" model)"
PARENT_CWD="$(_meta_field "$PARENT_META" cwd)"
PARENT_WINDOW="$(_meta_field "$PARENT_META" window)"
PARENT_LOG="$(_meta_field "$PARENT_META" log)"
PARENT_PROMPT_FILE="$(_meta_field "$PARENT_META" prompt)"
PARENT_ORCH="$(_meta_field "$PARENT_META" orchestrator)"
PARENT_ORCH_AGENT="$(_meta_field "$PARENT_META" orchestrator_agent)"
PARENT_CHAIN="$(_meta_field "$PARENT_META" handoff_chain)"

[[ -n "$PARENT_ID" ]]    || { echo "handoff: parent meta has no task_id" >&2; exit 3; }
[[ -n "$PARENT_AGENT" ]] || { echo "handoff: parent meta has no agent" >&2; exit 3; }
[[ -n "$PARENT_CWD"   ]] || { echo "handoff: parent meta has no cwd"   >&2; exit 3; }

# The parent's session is encoded as "<session>:task-<id>" in `window`.
PARENT_SESSION="${PARENT_WINDOW%%:*}"
[[ -n "$PARENT_SESSION" ]] || PARENT_SESSION="$(_endy_session_name "$PARENT_CWD")"

if ! tmux has-session -t "$PARENT_SESSION" 2>/dev/null; then
    echo "handoff: parent session '$PARENT_SESSION' is gone — run 'endy start' or 'endy overview' in its cwd first" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# pick the target agent
# ---------------------------------------------------------------------------

if [[ -z "$target_agent" ]]; then
    if [[ -n "${ENDY_HANDOFF_RESOLVER:-}" ]] && command -v "${ENDY_HANDOFF_RESOLVER%% *}" >/dev/null 2>&1; then
        # Resolver gets (previous-agent, task-id, cwd) and prints the next agent.
        if resolved="$("$ENDY_HANDOFF_RESOLVER" "$PARENT_AGENT" "$PARENT_ID" "$PARENT_CWD" 2>/dev/null)"; then
            target_agent="$(printf '%s' "$resolved" | head -n1 | tr -d '[:space:]')"
        fi
    fi
fi

if [[ -z "$target_agent" ]]; then
    cat >&2 <<EOF
handoff: no target agent.

Pass one explicitly:
  endy handoff $PARENT_ID --to <opencode|cmd|hermes|claude>

Or set a resolver (for multiplexor-style routing):
  export ENDY_HANDOFF_RESOLVER="multiplexor next-provider"   # when multiplexor supports it
EOF
    exit 2
fi

case "$target_agent" in
    opencode|cmd|commandcode|claude|hermes|gemini|bash|stub|noop) ;;
    *) echo "handoff: unknown --to agent '$target_agent' (expected: opencode, cmd, hermes, claude, gemini, bash)" >&2; exit 4 ;;
esac

# Normalize.
[[ "$target_agent" == "commandcode" ]] && target_agent="cmd"

if [[ "$target_agent" == "$PARENT_AGENT" ]]; then
    echo "handoff: target ($target_agent) is the same as parent — use 'endy watch followup' for same-agent resume" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# build the handoff prompt
# ---------------------------------------------------------------------------

_strip_ansi() {
    perl -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\eP.*?\e\\//g; s/\e_.*?\e\\//g; s/\e\[[0-9;?<>]*[ -\/]*[@-~]//g; s/\e[()][A-Za-z0-9]//g; s/\e[=>]//g; s/\e\\//g; s/\e//g'
}

ORIGINAL_PROMPT=""
if [[ -n "$PARENT_PROMPT_FILE" && -f "$PARENT_PROMPT_FILE" ]]; then
    ORIGINAL_PROMPT="$(cat "$PARENT_PROMPT_FILE")"
fi

LOG_TAIL=""
LOG_TAIL_DESC="full output"
if [[ -n "$PARENT_LOG" && -f "$PARENT_LOG" ]]; then
    LOG_TAIL="$(grep -vE '^(ENDY_EXIT=|\[endy-watch\])' "$PARENT_LOG" 2>/dev/null \
                | _strip_ansi)"
    if [[ -n "$lines" ]]; then
        LOG_TAIL="$(printf '%s\n' "$LOG_TAIL" | tail -n "$lines")"
        LOG_TAIL_DESC="last ${lines} lines"
    fi
fi

# Compute the chain. Parent's chain (if any) + parent_id. Used for traceability
# across multi-step handoffs (A → B → C).
if [[ -n "$PARENT_CHAIN" ]]; then
    NEW_CHAIN="${PARENT_CHAIN},${PARENT_ID}"
else
    NEW_CHAIN="$PARENT_ID"
fi

# Build the prompt the new agent will see. Strict markers so a downstream
# agent can detect "I'm a handoff target" and behave accordingly.
NEW_PROMPT="[endy handoff — you are taking over from a previous agent]

Previous agent: ${PARENT_AGENT}
Previous task: ${PARENT_ID}
Working dir:   ${PARENT_CWD}
Handoff chain: ${NEW_CHAIN}
"

if [[ -n "$reason" ]]; then
    NEW_PROMPT+="Reason for handoff: ${reason}
"
fi

NEW_PROMPT+="
--- original task prompt ---
${ORIGINAL_PROMPT}
--- end original task prompt ---
"

if [[ -n "$LOG_TAIL" ]]; then
    NEW_PROMPT+="
--- ${LOG_TAIL_DESC} of previous agent's output ---
${LOG_TAIL}
--- end previous output ---
"
fi

if [[ -n "$instructions" ]]; then
    NEW_PROMPT+="
--- handoff instructions ---
${instructions}
--- end handoff instructions ---
"
fi

NEW_PROMPT+="
Continue the work above. Do not redo what the previous agent already finished;
read its output, identify the point at which it stopped, and pick up from there.
If the previous agent left the workspace mid-edit, verify file state before
acting. When done, finish with a one-line summary of what changed since the
handoff so the next reader can scan it quickly."

# ---------------------------------------------------------------------------
# delegate to spawn-long-task.sh
# ---------------------------------------------------------------------------

SPAWN_ARGS=(
    --agent "$target_agent"
    --cwd "$PARENT_CWD"
    --full-auto
    --parent-task "$PARENT_ID"
    --handoff-from "$PARENT_ID"
    --handoff-chain "$NEW_CHAIN"
    --session "$PARENT_SESSION"
    --log-dir "$(dirname "$PARENT_META")"
    --prompt "$NEW_PROMPT"
)
[[ -n "$PARENT_ORCH"       ]] && SPAWN_ARGS+=(--orchestrator "$PARENT_ORCH")
[[ -n "$PARENT_ORCH_AGENT" ]] && SPAWN_ARGS+=(--orchestrator-agent "$PARENT_ORCH_AGENT")
[[ -n "$reason"            ]] && SPAWN_ARGS+=(--handoff-reason "$reason")

# Persona/model: pass through ONLY if both agents support the same persona
# concept. opencode <-> hermes share --persona semantics partially; cmd and
# claude ignore --persona. Safer to drop persona on cross-agent handoff and
# let the user re-specify if they want it.

SPAWN_OUT="$("${ENDY_ROOT}/scripts/spawn-long-task.sh" "${SPAWN_ARGS[@]}")"
NEW_TASK_ID="$(printf '%s\n' "$SPAWN_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
NEW_WINDOW="$(printf '%s\n' "$SPAWN_OUT"  | grep '^TMUX_WINDOW=' | head -1 | cut -d= -f2-)"
NEW_LOG="$(printf '%s\n' "$SPAWN_OUT"     | grep '^LOG=' | head -1 | cut -d= -f2-)"

cat <<EOF
HANDOFF_FROM=${PARENT_ID}
HANDOFF_TO=${target_agent}
HANDOFF_CHAIN=${NEW_CHAIN}
TASK_ID=${NEW_TASK_ID}
TMUX_WINDOW=${NEW_WINDOW}
LOG=${NEW_LOG}

The new agent received: original prompt + ${LOG_TAIL_DESC} of ${PARENT_AGENT}'s output.

tmux:
  tmux attach -t ${PARENT_SESSION}
  tmux select-window -t ${NEW_WINDOW}

endy:
  endy watch follow ${NEW_TASK_ID}
  endy watch view   ${NEW_TASK_ID}
  endy watch chat   ${NEW_TASK_ID}
  endy watch kill   ${PARENT_ID}      # stop the original if it's still running
EOF

# Stop the parent's tmux window if requested. Typical use: the parent is
# rate-limited / stuck waiting for an auth/quota retry, so closing it cleans
# the dashboard before the demo continues.
if [[ "$stop_parent" == "1" ]]; then
    if [[ -n "$PARENT_WINDOW" ]] && tmux kill-window -t "$PARENT_WINDOW" 2>/dev/null; then
        echo "stopped parent window: $PARENT_WINDOW" >&2
    fi
fi

if [[ "$no_attach" == "0" && -t 1 && -n "${TMUX:-}" ]]; then
    tmux select-window -t "$NEW_WINDOW" 2>/dev/null || true
fi
