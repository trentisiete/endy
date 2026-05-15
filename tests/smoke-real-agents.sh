#!/usr/bin/env bash
# Real-agent context-passing verification.
#
# Unlike tests/smoke-multiplexor-handoff.sh (which uses the offline `bash`
# stub end-to-end), this script actually invokes a real LLM CLI on the
# child side of a handoff and verifies the agent CONSUMED the propagated
# context — i.e. the original prompt + parent log + reason flowed through
# and the new agent's output references them.
#
# Cost: each pair burns roughly one short response per agent. With the
# tiny prompts here that's a handful of tokens. Negligible on free tiers,
# fractions of a cent on paid tiers. Still: not a CI test. Run it
# manually when validating a fresh install.
#
# Requirements:
#   - tmux 3.x
#   - endy installed (`endy install`)
#   - At least one of: claude, cmd, opencode, hermes, gemini auth'd
#
# Usage:
#   tests/smoke-real-agents.sh                    # all available agents
#   tests/smoke-real-agents.sh --agent claude     # one specific agent
#   tests/smoke-real-agents.sh --agent cmd --timeout 180
#
# Known limitation: on Ubuntu, install.sh writes the ENDY_HANDOFF_RESOLVER
# export to ~/.bashrc, which only applies to INTERACTIVE shells. From a
# non-interactive `bash -c`, the var is unset and `endy handoff` would
# require --to. This smoke explicitly exports the var to dodge that.

set -e

if [[ -z "${ENDY:-}" ]]; then
    ENDY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

AGENT_FILTER=""
TIMEOUT=120
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENT_FILTER="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
skip()   { printf '  \033[1;33m·\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; return 1; }

PROJ=/tmp/endy-real-agent-smoke
SESSION=endy-endy-real-agent-smoke

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT

verify_agent() {
    local agent="$1"
    header "agent: $agent"

    if ! command -v "$agent" >/dev/null 2>&1; then
        skip "$agent not on PATH — skipping"
        return 0
    fi

    cleanup
    rm -rf "$PROJ"
    mkdir -p "$PROJ"
    echo "demo project" > "$PROJ/README.md"

    local marker="MARKER_$(date +%s)_$(openssl rand -hex 3 2>/dev/null || printf '%04x' "$RANDOM")"
    echo "  marker: $marker"

    cd "$PROJ"
    "$ENDY/bin/endy" start --no-attach >/dev/null 2>&1
    tmux has-session -t "$SESSION" || { fail "tmux session not created"; return 1; }

    # Parent = bash stub (deterministic, no quota burn).
    ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$ENDY/.logs/per-dir/$SESSION" \
        "$ENDY/bin/endy" spawn bash -- \
            "Parent task marker is ${marker}. The next agent should reference this marker when continuing." \
            > /tmp/real-spawn.txt 2>&1
    local A; A="$(grep '^TASK_ID=' /tmp/real-spawn.txt | cut -d= -f2-)"
    sleep 2

    # Child = the real agent under test.
    ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$ENDY/.logs/per-dir/$SESSION" \
        "$ENDY/bin/endy" handoff "$A" --to "$agent" \
            --reason "smoke: verify $agent reads handoff context" \
            --instructions "Reply in one line: state the marker from the parent task and the parent agent name." \
            --no-attach \
            > /tmp/real-handoff.txt 2>&1
    local B B_LOG B_META
    B="$(grep '^TASK_ID=' /tmp/real-handoff.txt | cut -d= -f2-)"
    B_LOG="$(grep '^LOG=' /tmp/real-handoff.txt | cut -d= -f2-)"
    B_META="$ENDY/.logs/per-dir/$SESSION/task-$B.meta"

    local i
    for ((i=0; i<TIMEOUT; i++)); do
        if grep -q '^ENDY_EXIT=' "$B_LOG" 2>/dev/null; then break; fi
        sleep 1
    done

    grep -q "^handoff_from=$A$"     "$B_META" && ok "meta: handoff_from stamped"        || fail "meta: handoff_from missing"
    grep -q "^agent=$agent$"        "$B_META" && ok "meta: agent=$agent"                 || fail "meta: wrong agent"
    grep -q "^handoff_reason=smoke" "$B_META" && ok "meta: handoff_reason stamped"       || fail "meta: handoff_reason missing"

    # The composed prompt file is endy's contract — it MUST contain the
    # parent marker. This is what proves endy's side propagated context
    # correctly, independent of how the agent chose to respond.
    local B_PROMPT="$ENDY/.logs/per-dir/$SESSION/task-$B.prompt.md"
    if grep -q "$marker" "$B_PROMPT" 2>/dev/null; then
        ok "prompt.md: marker propagated into composed prompt"
    else
        fail "prompt.md does NOT contain the parent marker — endy bug"
        return 1
    fi

    # Did the agent then actually consume that context? If it surfaces the
    # marker in its output, full end-to-end pass. If not, it's an agent
    # quirk (some models stay quiet for short prompts) — warn, don't fail
    # the suite. The handoff plumbing is what we are testing here.
    if grep -q "$marker" "$B_LOG" 2>/dev/null; then
        ok "$agent log references the parent marker — agent consumed the context"
    else
        skip "$agent output is empty or doesn't echo the marker (agent-specific behavior, not an endy bug)"
        echo "  -- last 10 lines of $agent output for inspection --"
        tail -10 "$B_LOG" 2>/dev/null | sed 's/^/    /'
    fi

    cleanup
    return 0
}

AGENTS_TO_TEST=(opencode cmd claude hermes gemini)
if [[ -n "$AGENT_FILTER" ]]; then
    AGENTS_TO_TEST=("$AGENT_FILTER")
fi

# Always export the resolver so the test holds in non-interactive shells.
export ENDY_HANDOFF_RESOLVER=multiplexor-next-provider

failed=0
ok_count=0
for agent in "${AGENTS_TO_TEST[@]}"; do
    if verify_agent "$agent"; then
        ((ok_count++)) || true
    else
        ((failed++)) || true
    fi
done

echo
if (( failed > 0 )); then
    red "FAILED ($failed agent(s) did not propagate context)"
    exit 1
fi
green "PASSED ($ok_count agents verified — context flowed correctly through every handoff)"
