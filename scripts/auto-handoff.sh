#!/usr/bin/env bash
# scripts/auto-handoff.sh — fire `endy handoff` automatically when a task
# exits non-zero with a known exhaustion signal in its log.
#
# Invoked by scripts/spawn-long-task.sh at the end of every task's
# INNER_CMD (after the agent has exited and ENDY_EXIT=<n> has landed in
# the log). Best-effort: never fails the parent task; logs a clear
# `[endy] auto-handoff: ...` line either way so the trail is visible.
#
# Usage:
#   scripts/auto-handoff.sh <task-id>
#
# Behavior:
#   1. Locate the task's meta + log (across global + per-dir scopes).
#   2. Check opt-outs (in order):
#        - ENDY_AUTO_HANDOFF=0 in env
#        - auto_handoff=0 in the task's meta (set by --no-auto-handoff)
#        - <cwd>/.endy/no-auto-handoff marker file (per-project opt-out)
#        - handoff_chain depth >= 5 (loop prevention)
#   3. Require ENDY_EXIT != 0.
#   4. Run _endy_detect_exhaustion <agent> <log-path>. Empty → no signal,
#      stop.
#   5. Require a resolver (ENDY_HANDOFF_RESOLVER set + on PATH, OR the
#      multiplexor-next-provider binary on PATH). If absent, log and
#      stop — auto-handoff is meaningful only when there's somewhere to
#      go.
#   6. Append a `[endy] auto-handoff triggered: ...` line to the parent
#      log, then invoke `endy handoff <task-id> --reason "auto: <signal>"
#      --no-attach`. Capture its stdout/stderr into the parent log.
#
# Exit code: always 0. The point of auto-handoff is to not surface
# errors that interrupt the user's flow. If something goes wrong, the
# log carries the diagnostic.

set -uo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/exhaustion.sh
. "${ENDY_ROOT}/scripts/lib/exhaustion.sh"

TASK_ID="${1:-}"
[[ -n "$TASK_ID" ]] || exit 0

# ---------------------------------------------------------------------------
# 1. locate meta
# ---------------------------------------------------------------------------

_find_meta() {
    local id="$1"
    local candidates=()
    candidates+=("${ENDY_ROOT}/.logs/task-${id}.meta")
    shopt -s nullglob
    local d
    for d in "${ENDY_ROOT}/.logs/per-dir"/*/; do
        candidates+=("${d}task-${id}.meta")
    done
    shopt -u nullglob
    local c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

META_PATH="$(_find_meta "$TASK_ID")" || exit 0

_field() {
    # Robust against absent fields: pipefail would otherwise abort on a
    # missing optional key (handoff_chain=, auto_handoff=, etc.).
    { grep "^${2}=" "$1" 2>/dev/null || true; } | head -1 | cut -d= -f2-
}

LOG_PATH="$(_field "$META_PATH" log)"
AGENT="$(_field "$META_PATH" agent)"
CWD="$(_field "$META_PATH" cwd)"
HANDOFF_CHAIN="$(_field "$META_PATH" handoff_chain)"
META_AUTO_HANDOFF="$(_field "$META_PATH" auto_handoff)"

[[ -n "$LOG_PATH" && -f "$LOG_PATH" ]] || exit 0
[[ -n "$AGENT" ]] || exit 0

# ---------------------------------------------------------------------------
# 2. opt-outs
# ---------------------------------------------------------------------------

# Global env override.
if [[ "${ENDY_AUTO_HANDOFF:-1}" == "0" ]]; then
    exit 0
fi
# Per-task opt-out via --no-auto-handoff at spawn time.
if [[ "$META_AUTO_HANDOFF" == "0" ]]; then
    exit 0
fi
# Per-project marker file.
if [[ -n "$CWD" && -f "${CWD}/.endy/no-auto-handoff" ]]; then
    exit 0
fi
# Loop prevention: if we're already 5 hops deep, stop. Each entry in
# handoff_chain is one previous task id (comma-separated).
if [[ -n "$HANDOFF_CHAIN" ]]; then
    chain_depth="$(printf '%s' "$HANDOFF_CHAIN" | awk -F, '{print NF}')"
    if [[ "${chain_depth:-0}" -ge 5 ]]; then
        printf '\n[endy] auto-handoff suppressed: chain depth %d >= 5 (loop prevention)\n' "$chain_depth" >> "$LOG_PATH"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# 3. exit code must be non-zero
# ---------------------------------------------------------------------------

EXIT_CODE="$(grep '^ENDY_EXIT=' "$LOG_PATH" 2>/dev/null | tail -1 | cut -d= -f2-)"
if [[ -z "$EXIT_CODE" || "$EXIT_CODE" == "0" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. detect a known signal
# ---------------------------------------------------------------------------

REASON="$(_endy_detect_exhaustion "$AGENT" "$LOG_PATH")"
if [[ -z "$REASON" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. require a resolver
# ---------------------------------------------------------------------------

resolver_ok=0
if [[ -n "${ENDY_HANDOFF_RESOLVER:-}" ]]; then
    if command -v "${ENDY_HANDOFF_RESOLVER%% *}" >/dev/null 2>&1; then
        resolver_ok=1
    fi
fi
if [[ "$resolver_ok" == "0" ]] && command -v multiplexor-next-provider >/dev/null 2>&1; then
    # multiplexor is installed but the user didn't export the env var.
    # Use it implicitly — they clearly intended this path.
    export ENDY_HANDOFF_RESOLVER=multiplexor-next-provider
    resolver_ok=1
fi
if [[ "$resolver_ok" == "0" ]]; then
    {
        printf '\n[endy] auto-handoff: detected exhaustion signal "%s" but no resolver is available.\n' "$REASON"
        printf '       Set ENDY_HANDOFF_RESOLVER=multiplexor-next-provider, or call manually:\n'
        printf '         endy handoff %s --to <opencode|cmd|hermes|claude|gemini>\n' "$TASK_ID"
    } >> "$LOG_PATH"
    exit 0
fi

# ---------------------------------------------------------------------------
# 6. fire the handoff
# ---------------------------------------------------------------------------

{
    printf '\n[endy] auto-handoff triggered: agent=%s reason=%s — invoking endy handoff %s\n' \
        "$AGENT" "$REASON" "$TASK_ID"
} >> "$LOG_PATH"

# Run handoff. Its stdout/stderr both go to the parent log so the chain
# of events is visible in one place.
"${ENDY_ROOT}/bin/endy" handoff "$TASK_ID" \
    --reason "auto: $REASON" \
    --no-attach \
    >> "$LOG_PATH" 2>&1 \
    || printf '[endy] auto-handoff: endy handoff exited non-zero — see above\n' >> "$LOG_PATH"

exit 0
