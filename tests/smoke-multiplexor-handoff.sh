#!/usr/bin/env bash
# Smoke test for the endy ↔ multiplexor integration.
#
# Exercises the full auto-routing loop without burning any real-agent quota:
# uses endy's offline `bash` stub agent + a custom multiplexor config that
# only enables stub-style providers (bash / stub / noop, all → /bin/bash).
#
# What it proves:
#   1. multiplexor-next-provider is on PATH (endy install wired it).
#   2. ENDY_HANDOFF_RESOLVER works with the multiplexor-next-provider binary.
#   3. `endy handoff <id>` WITHOUT --to invokes the resolver, gets the next
#      provider, marks the previous as exhausted, and spawns the new agent.
#   4. handoff_from / handoff_chain / handoff_reason land in the child meta.
#   5. Multi-hop chain (bash → stub → noop) accumulates the chain correctly.
#   6. When all providers are exhausted, handoff exits cleanly with a clear
#      error message (it doesn't silently misroute).
#
# Tested on WSL/Ubuntu with tmux 3.4 and uv-installed multiplexor.

set -e

if [[ -z "${ENDY:-}" ]]; then
    ENDY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

PROJ=/tmp/endy-mxp-smoke
SESSION="endy-endy-mxp-smoke"
MXP_DIR="/tmp/endy-mxp-smoke-cfg"

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }

header "0. preflight"
command -v tmux >/dev/null                || fail "tmux not installed"
command -v multiplexor-next-provider >/dev/null \
    || fail "multiplexor-next-provider not on PATH — run 'endy install' first"
ok "tmux + multiplexor-next-provider available"

header "1. clean slate"
tmux kill-session -t "$SESSION" 2>/dev/null && echo "  killed pre-existing $SESSION" || true
rm -rf "$PROJ" "$MXP_DIR" "$ENDY/.logs/per-dir/$SESSION"
mkdir -p "$PROJ" "$MXP_DIR"
echo "demo project for multiplexor smoke" > "$PROJ/README.md"

# Test config: every default provider disabled; only bash / stub / noop are
# enabled, and all three point at /bin/bash so the offline stub picks them
# up via endy. Priorities chosen so the rotation order is bash → stub → noop.
cat > "$MXP_DIR/config.yaml" <<'YAML'
routing:
  exhausted_cooldown_hours: 1
tiers:
  free:
    bonus: 30
providers:
  gemini:
    enabled: false
  opencode:
    enabled: false
  ollama:
    enabled: false
  hermes:
    enabled: false
  codex:
    enabled: false
  claude:
    enabled: false
  qwen:
    enabled: false
  bash:
    enabled: true
    tier: free
    priority: 100
    command: bash
    interactive_command:
      - bash
  stub:
    enabled: true
    tier: free
    priority: 90
    command: bash
    interactive_command:
      - bash
  noop:
    enabled: true
    tier: free
    priority: 80
    command: bash
    interactive_command:
      - bash
YAML
export MULTIPLEXOR_CONFIG="$MXP_DIR/config.yaml"
export MULTIPLEXOR_STATE="$MXP_DIR/state.json"
export ENDY_HANDOFF_RESOLVER=multiplexor-next-provider
ok "isolated MULTIPLEXOR_CONFIG + MULTIPLEXOR_STATE; resolver wired"

header "2. resolver standalone"
[[ "$(multiplexor-next-provider 2>/dev/null)" == "bash" ]] \
    && ok "no prev → bash (highest score)" \
    || fail "no prev should return 'bash'"
rm -f "$MULTIPLEXOR_STATE"
[[ "$(multiplexor-next-provider bash task-x /tmp/p 2>/dev/null)" == "stub" ]] \
    && ok "prev=bash → stub (marked bash exhausted)" \
    || fail "prev=bash should return 'stub'"
rm -f "$MULTIPLEXOR_STATE"
[[ "$(multiplexor-next-provider gibberish 2>/dev/null)" == "bash" ]] \
    && ok "unknown prev silently skipped → bash" \
    || fail "unknown prev should still return 'bash'"
rm -f "$MULTIPLEXOR_STATE"

header "3. endy session"
cd "$PROJ"
"$ENDY/bin/endy" start --no-attach >/dev/null 2>&1
tmux has-session -t "$SESSION" && ok "session $SESSION up" || fail "session not created"

header "4. spawn parent (bash stub) + handoff WITHOUT --to"
ENDY_SESSION=$SESSION ENDY_LOG_DIR=$ENDY/.logs/per-dir/$SESSION \
    "$ENDY/bin/endy" spawn bash -- "do step 1" > /tmp/mxp-spawn.txt 2>&1
A=$(grep '^TASK_ID=' /tmp/mxp-spawn.txt | cut -d= -f2-)
[[ -n "$A" ]] && ok "parent task $A spawned (agent=bash)" || fail "spawn failed"
sleep 1

ENDY_SESSION=$SESSION ENDY_LOG_DIR=$ENDY/.logs/per-dir/$SESSION \
    "$ENDY/bin/endy" handoff "$A" --reason "rate limited hop 1" --no-attach > /tmp/mxp-h1.txt 2>&1
B=$(grep '^TASK_ID=' /tmp/mxp-h1.txt | cut -d= -f2-)
B_TO=$(grep '^HANDOFF_TO=' /tmp/mxp-h1.txt | cut -d= -f2-)
[[ "$B_TO" == "stub" ]] && ok "resolver picked stub (after exhausting bash)" \
    || fail "resolver should have returned stub, got '$B_TO'"
[[ -n "$B" ]] && ok "hop-1 task $B spawned" || fail "hop-1 spawn failed"

header "5. verify hop-1 child meta"
META="$ENDY/.logs/per-dir/$SESSION/task-$B.meta"
[[ -f "$META" ]] && ok "meta exists" || fail "no meta at $META"
grep -q "^agent=stub$" "$META"                   && ok "agent=stub" || fail "wrong agent in meta"
grep -q "^handoff_from=$A$" "$META"              && ok "handoff_from=$A" || fail "handoff_from missing"
grep -q "^handoff_chain=$A$" "$META"             && ok "handoff_chain=$A" || fail "handoff_chain wrong"
grep -q "^handoff_reason=rate limited hop 1$" "$META" && ok "handoff_reason captured" || fail "handoff_reason missing"

header "6. multi-hop: bash → stub → noop"
sleep 1
ENDY_SESSION=$SESSION ENDY_LOG_DIR=$ENDY/.logs/per-dir/$SESSION \
    "$ENDY/bin/endy" handoff "$B" --reason "hop 2" --no-attach > /tmp/mxp-h2.txt 2>&1
C=$(grep '^TASK_ID=' /tmp/mxp-h2.txt | cut -d= -f2-)
C_TO=$(grep '^HANDOFF_TO=' /tmp/mxp-h2.txt | cut -d= -f2-)
[[ "$C_TO" == "noop" ]] && ok "hop-2 resolver picked noop" \
    || fail "expected noop, got '$C_TO'"
GRAND_META="$ENDY/.logs/per-dir/$SESSION/task-$C.meta"
grep -q "^handoff_chain=$A,$B$" "$GRAND_META"   && ok "full chain in meta: $A,$B" \
    || fail "handoff_chain incorrect"

header "7. exhaustion exit: no eligible providers left"
sleep 1
set +e
ENDY_SESSION=$SESSION ENDY_LOG_DIR=$ENDY/.logs/per-dir/$SESSION \
    "$ENDY/bin/endy" handoff "$C" --reason "should fail" --no-attach > /tmp/mxp-h3.txt 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] && ok "handoff exited non-zero ($RC) as expected" \
    || fail "handoff should have failed when no provider is eligible"
grep -q "no target agent" /tmp/mxp-h3.txt && ok "error message clear" \
    || fail "error message missing 'no target agent'"

header "8. doctor surfaces multiplexor correctly"
DOCTOR_OUT="$("$ENDY/bin/endy" doctor 2>&1)"
echo "$DOCTOR_OUT" | grep -q "multiplexor .* ✓"        && ok "doctor sees multiplexor" || fail "doctor doesn't see multiplexor"
echo "$DOCTOR_OUT" | grep -q "next-provider .* ✓"      && ok "doctor sees next-provider binary" || fail "doctor doesn't see next-provider"
echo "$DOCTOR_OUT" | grep -q "handoff .* ✓ auto"       && ok "doctor sees resolver wired" || fail "doctor doesn't see resolver"

header "9. cleanup"
tmux kill-session -t "$SESSION" 2>/dev/null && ok "session killed" || true
rm -rf "$PROJ" "$MXP_DIR"

echo
green "all multiplexor-handoff smoke checks passed."
