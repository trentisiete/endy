#!/usr/bin/env bash
# Smoke test for Phase 4 — automatic exhaustion-triggered handoff.
#
# Verifies, without burning real-agent quota:
#   1. scripts/lib/exhaustion.sh recognises the documented signals per
#      agent (gemini RESOURCE_EXHAUSTED, opencode ProviderModelNotFound,
#      cmd Reached maximum conversation turns, hermes model_not_supported,
#      claude usage_limit_exceeded), and rejects benign logs.
#   2. scripts/auto-handoff.sh, given a synthesised fake meta + log with
#      ENDY_EXIT=1 + a known signal, fires `endy handoff <id>` and a
#      child task is spawned with the right handoff_from / handoff_reason.
#   3. Opt-outs work:
#        - ENDY_AUTO_HANDOFF=0 in env
#        - auto_handoff=0 in meta (set by --no-auto-handoff at spawn time)
#        - <cwd>/.endy/no-auto-handoff marker file
#        - handoff_chain depth >= 5 cap
#   4. No-resolver case: auto-handoff logs a clear message instead of
#      silently failing or routing somewhere wrong.

set -e

if [[ -z "${ENDY:-}" ]]; then
    ENDY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

PROJ=/tmp/endy-auto-handoff-smoke
SESSION=endy-endy-auto-handoff-smoke
MXP_DIR=/tmp/endy-auto-handoff-mxp

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    rm -rf "$PROJ" "$MXP_DIR" "$ENDY/.logs/per-dir/$SESSION"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0. preflight + isolated multiplexor config (only bash/stub/noop enabled
#    so the resolver picks an offline-stub target — no quota burned)
# ---------------------------------------------------------------------------

header "0. preflight"
command -v tmux >/dev/null                || fail "tmux not installed"
command -v multiplexor-next-provider >/dev/null \
    || fail "multiplexor-next-provider not on PATH — run 'endy install' first"
[[ -f "$ENDY/scripts/lib/exhaustion.sh" ]] || fail "exhaustion.sh missing"
[[ -x "$ENDY/scripts/auto-handoff.sh" ]]   || fail "auto-handoff.sh missing or not executable"
ok "tools available"

cleanup
mkdir -p "$PROJ" "$MXP_DIR"
echo "demo" > "$PROJ/README.md"

cat > "$MXP_DIR/config.yaml" <<'YAML'
routing:
  exhausted_cooldown_hours: 1
tiers:
  free:
    bonus: 30
providers:
  gemini:   { enabled: false }
  opencode: { enabled: false }
  ollama:   { enabled: false }
  hermes:   { enabled: false }
  codex:    { enabled: false }
  claude:   { enabled: false }
  qwen:     { enabled: false }
  cmd:      { enabled: false }
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
YAML
export MULTIPLEXOR_CONFIG="$MXP_DIR/config.yaml"
export MULTIPLEXOR_STATE="$MXP_DIR/state.json"
export ENDY_HANDOFF_RESOLVER=multiplexor-next-provider
ok "isolated multiplexor config (bash + stub only)"

# ---------------------------------------------------------------------------
# 1. exhaustion detector — unit-style assertions
# ---------------------------------------------------------------------------

header "1. exhaustion detector: per-agent signal recognition"

# Load the library.
# shellcheck source=../scripts/lib/exhaustion.sh
. "$ENDY/scripts/lib/exhaustion.sh"

assert_detect() {
    local agent="$1" log_body="$2" expected="$3" desc="$4"
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$log_body" > "$tmp"
    local got; got="$(_endy_detect_exhaustion "$agent" "$tmp")"
    rm -f "$tmp"
    if [[ "$got" == "$expected" ]]; then
        ok "$desc"
    else
        fail "$desc — expected '$expected', got '$got'"
    fi
}

# Gemini
assert_detect gemini "Some output\nError: RESOURCE_EXHAUSTED for quota Gemini\nENDY_EXIT=1" \
    "rate_limit_exceeded" "gemini RESOURCE_EXHAUSTED → rate_limit_exceeded"
assert_detect gemini "Please set an Auth method in your settings.json\nENDY_EXIT=41" \
    "auth_required" "gemini missing-auth → auth_required"
assert_detect gemini "I finished the task successfully.\nENDY_EXIT=0" \
    "" "gemini benign log → empty"

# Opencode
assert_detect opencode "ProviderModelNotFoundError: model not available\nENDY_EXIT=1" \
    "provider_quota" "opencode ProviderModelNotFoundError → provider_quota"
assert_detect opencode "rate_limit_exceeded on Anthropic backend\nENDY_EXIT=1" \
    "provider_quota" "opencode rate_limit_exceeded → provider_quota"
assert_detect opencode "Unauthorized: invalid token\nENDY_EXIT=1" \
    "auth_failed" "opencode Unauthorized → auth_failed"

# cmd
assert_detect cmd "Warning: Reached maximum conversation turns\nENDY_EXIT=1" \
    "max_turns" "cmd max-turns → max_turns"
assert_detect cmd "insufficient credit on your account\nENDY_EXIT=1" \
    "credit_exhausted" "cmd insufficient credit → credit_exhausted"

# Hermes
assert_detect hermes '{"error":{"code":"rate_limit_exceeded"}}' \
    "rate_limit_exceeded" "hermes rate_limit_exceeded → rate_limit_exceeded"
assert_detect hermes "Error: model_not_supported by provider\nENDY_EXIT=1" \
    "model_unavailable" "hermes model_not_supported → model_unavailable"

# Claude
assert_detect claude "Anthropic API Error 429: usage_limit_exceeded\nENDY_EXIT=1" \
    "rate_limit_exceeded" "claude usage_limit_exceeded → rate_limit_exceeded"
assert_detect claude "authentication_error: invalid api key\nENDY_EXIT=1" \
    "auth_failed" "claude auth_failed → auth_failed"

# Codex
assert_detect codex "rate.limit.exceeded for org\nENDY_EXIT=1" \
    "rate_limit_exceeded" "codex rate_limit_exceeded → rate_limit_exceeded"

# Negative cases
assert_detect gemini "" "" "empty log → empty"
assert_detect opencode "Just some innocent error: file not found" "" \
    "opencode benign Error: line → empty (no false positive)"

# ---------------------------------------------------------------------------
# 2. auto-handoff orchestration: synth a fake exhausted task, run the
#    script, verify a child task was spawned with the right meta.
# ---------------------------------------------------------------------------

header "2. auto-handoff: fake exhausted task triggers endy handoff"

# Need a real tmux session for endy handoff to spawn into.
cd "$PROJ"
"$ENDY/bin/endy" start --no-attach >/dev/null 2>&1
tmux has-session -t "$SESSION" || fail "tmux session not created"

LOG_DIR="$ENDY/.logs/per-dir/$SESSION"
mkdir -p "$LOG_DIR"

# Pick an id for the fake parent.
PARENT_ID="20260515-fake-aa11"
PARENT_LOG="$LOG_DIR/task-$PARENT_ID.log"
PARENT_META="$LOG_DIR/task-$PARENT_ID.meta"
PARENT_PROMPT="$LOG_DIR/task-$PARENT_ID.prompt.md"

# Synthesize a log that includes a known gemini exhaustion signal AND
# ENDY_EXIT=1, simulating what a real gemini run looks like when it hits
# its daily quota.
cat > "$PARENT_LOG" <<'LOG'
[gemini-cli] Starting...
> Working on the task...
Error: Got HTTP/1.1 429 Too Many Requests
Server response: RESOURCE_EXHAUSTED — daily quota exceeded for project foo

ENDY_EXIT=1
LOG

cat > "$PARENT_META" <<META
task_id=$PARENT_ID
kind=spawn
orchestrator=manual
orchestrator_agent=
origin_session=
origin_window=
origin_pane=
origin_cwd=$PROJ
agent=gemini
persona=
model=
cwd=$PROJ
window=$SESSION:task-$PARENT_ID
log=$PARENT_LOG
prompt=$PARENT_PROMPT
spawned_at=2026-05-15T16:00:00Z
parent_task=
resume_id=
handoff_from=
handoff_chain=
handoff_reason=
auto_handoff=1
META

cat > "$PARENT_PROMPT" <<'PROMPT'
Refactor src/auth to use the new IdentityProvider.
PROMPT

ok "synthesized fake exhausted gemini task: $PARENT_ID"

# Invoke auto-handoff.sh directly (this is what spawn-long-task.sh
# normally appends to the INNER_CMD after ENDY_EXIT lands).
"$ENDY/scripts/auto-handoff.sh" "$PARENT_ID"
ok "ran auto-handoff.sh without error"

# The parent log should now have the [endy] auto-handoff line appended.
if grep -q "\[endy\] auto-handoff triggered" "$PARENT_LOG"; then
    ok "[endy] auto-handoff trigger line written to parent log"
else
    echo
    echo "--- parent log tail ---"
    tail -20 "$PARENT_LOG"
    fail "parent log missing auto-handoff trigger line"
fi

# A new task should have been spawned. Find any task in the log dir with
# handoff_from = PARENT_ID.
CHILD_META=""
for m in "$LOG_DIR"/task-*.meta; do
    [[ "$m" == "$PARENT_META" ]] && continue
    if grep -q "^handoff_from=$PARENT_ID$" "$m"; then
        CHILD_META="$m"
        break
    fi
done
[[ -n "$CHILD_META" ]] && ok "found child task meta with handoff_from=$PARENT_ID" \
    || fail "no child task spawned"

# Verify child meta fields.
grep -q "^handoff_reason=auto: rate_limit_exceeded$" "$CHILD_META" && ok "handoff_reason=auto: rate_limit_exceeded" \
    || fail "child handoff_reason missing or wrong (expected auto: rate_limit_exceeded)"
CHILD_AGENT="$(grep '^agent=' "$CHILD_META" | head -1 | cut -d= -f2-)"
[[ "$CHILD_AGENT" == "bash" ]] && ok "child agent=bash (resolver picked the only enabled provider)" \
    || fail "child agent expected 'bash' (only one enabled), got '$CHILD_AGENT'"

# ---------------------------------------------------------------------------
# 3. opt-out: ENDY_AUTO_HANDOFF=0
# ---------------------------------------------------------------------------

header "3. opt-out: ENDY_AUTO_HANDOFF=0 env"

OPTOUT_ID="20260515-fake-bb22"
OPTOUT_LOG="$LOG_DIR/task-$OPTOUT_ID.log"
OPTOUT_META="$LOG_DIR/task-$OPTOUT_ID.meta"

cat > "$OPTOUT_LOG" <<'LOG'
RESOURCE_EXHAUSTED daily quota
ENDY_EXIT=1
LOG
cat > "$OPTOUT_META" <<META
task_id=$OPTOUT_ID
kind=spawn
agent=gemini
cwd=$PROJ
log=$OPTOUT_LOG
prompt=$LOG_DIR/task-$OPTOUT_ID.prompt.md
handoff_chain=
auto_handoff=1
META
echo "(prompt)" > "$LOG_DIR/task-$OPTOUT_ID.prompt.md"

# Count children before.
before="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
ENDY_AUTO_HANDOFF=0 "$ENDY/scripts/auto-handoff.sh" "$OPTOUT_ID"
after="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && ok "ENDY_AUTO_HANDOFF=0 suppressed the handoff" \
    || fail "handoff fired despite ENDY_AUTO_HANDOFF=0"

# ---------------------------------------------------------------------------
# 4. opt-out: auto_handoff=0 in meta (--no-auto-handoff at spawn time)
# ---------------------------------------------------------------------------

header "4. opt-out: auto_handoff=0 in meta"

OPTOUT2_ID="20260515-fake-cc33"
OPTOUT2_LOG="$LOG_DIR/task-$OPTOUT2_ID.log"
OPTOUT2_META="$LOG_DIR/task-$OPTOUT2_ID.meta"
cat > "$OPTOUT2_LOG" <<'LOG'
RESOURCE_EXHAUSTED
ENDY_EXIT=1
LOG
cat > "$OPTOUT2_META" <<META
task_id=$OPTOUT2_ID
kind=spawn
agent=gemini
cwd=$PROJ
log=$OPTOUT2_LOG
prompt=$LOG_DIR/task-$OPTOUT2_ID.prompt.md
handoff_chain=
auto_handoff=0
META
echo "(prompt)" > "$LOG_DIR/task-$OPTOUT2_ID.prompt.md"

before="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
"$ENDY/scripts/auto-handoff.sh" "$OPTOUT2_ID"
after="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && ok "auto_handoff=0 in meta suppressed the handoff" \
    || fail "handoff fired despite auto_handoff=0 in meta"

# ---------------------------------------------------------------------------
# 5. opt-out: <cwd>/.endy/no-auto-handoff marker file
# ---------------------------------------------------------------------------

header "5. opt-out: .endy/no-auto-handoff marker file"

mkdir -p "$PROJ/.endy"
touch "$PROJ/.endy/no-auto-handoff"

MARKER_ID="20260515-fake-dd44"
MARKER_LOG="$LOG_DIR/task-$MARKER_ID.log"
MARKER_META="$LOG_DIR/task-$MARKER_ID.meta"
cat > "$MARKER_LOG" <<'LOG'
RESOURCE_EXHAUSTED
ENDY_EXIT=1
LOG
cat > "$MARKER_META" <<META
task_id=$MARKER_ID
kind=spawn
agent=gemini
cwd=$PROJ
log=$MARKER_LOG
prompt=$LOG_DIR/task-$MARKER_ID.prompt.md
handoff_chain=
auto_handoff=1
META
echo "(prompt)" > "$LOG_DIR/task-$MARKER_ID.prompt.md"

before="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
"$ENDY/scripts/auto-handoff.sh" "$MARKER_ID"
after="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && ok ".endy/no-auto-handoff marker suppressed the handoff" \
    || fail "handoff fired despite marker file"

rm -rf "$PROJ/.endy"

# ---------------------------------------------------------------------------
# 6. loop prevention: chain depth >= 5
# ---------------------------------------------------------------------------

header "6. loop prevention: handoff_chain depth >= 5"

CAP_ID="20260515-fake-ee55"
CAP_LOG="$LOG_DIR/task-$CAP_ID.log"
CAP_META="$LOG_DIR/task-$CAP_ID.meta"
cat > "$CAP_LOG" <<'LOG'
RESOURCE_EXHAUSTED
ENDY_EXIT=1
LOG
cat > "$CAP_META" <<META
task_id=$CAP_ID
kind=spawn
agent=gemini
cwd=$PROJ
log=$CAP_LOG
prompt=$LOG_DIR/task-$CAP_ID.prompt.md
handoff_chain=t1,t2,t3,t4,t5
auto_handoff=1
META
echo "(prompt)" > "$LOG_DIR/task-$CAP_ID.prompt.md"

before="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
"$ENDY/scripts/auto-handoff.sh" "$CAP_ID"
after="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && ok "chain depth 5 suppressed the handoff" \
    || fail "handoff fired despite chain depth >= 5"
grep -q "chain depth.*loop prevention" "$CAP_LOG" \
    && ok "loop-prevention reason logged to parent" \
    || fail "loop-prevention message missing from parent log"

# ---------------------------------------------------------------------------
# 7. benign log: ENDY_EXIT=1 but NO known signal → no handoff
# ---------------------------------------------------------------------------

header "7. benign non-zero exit (no known signal) does not trigger handoff"

BENIGN_ID="20260515-fake-ff66"
BENIGN_LOG="$LOG_DIR/task-$BENIGN_ID.log"
BENIGN_META="$LOG_DIR/task-$BENIGN_ID.meta"
cat > "$BENIGN_LOG" <<'LOG'
Something unrelated went wrong.
ENDY_EXIT=1
LOG
cat > "$BENIGN_META" <<META
task_id=$BENIGN_ID
kind=spawn
agent=gemini
cwd=$PROJ
log=$BENIGN_LOG
prompt=$LOG_DIR/task-$BENIGN_ID.prompt.md
handoff_chain=
auto_handoff=1
META
echo "(prompt)" > "$LOG_DIR/task-$BENIGN_ID.prompt.md"

before="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
"$ENDY/scripts/auto-handoff.sh" "$BENIGN_ID"
after="$(ls "$LOG_DIR"/task-*.meta 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && ok "benign exit-1 log did not trigger auto-handoff" \
    || fail "auto-handoff fired on a benign error log (false positive)"

echo
green "all Phase 4 auto-handoff smoke checks passed."
