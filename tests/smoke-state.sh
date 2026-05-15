#!/usr/bin/env bash
# Smoke test for the Phase 3 `endy state` path.
# Uses the offline stub/noop/bash agents so no API credit is burned. Verifies:
#   1. A 3-link handoff chain (stub → noop → bash) accumulates handoff_chain.
#   2. endy state --task-id <link-3> --format json composes the expected
#      shape: self.task_id, lineage.handoff_chain (2 entries),
#      peers.in_session non-empty, tiers covers all six agents.
#   3. endy state --task-id <link-3> --format prompt renders the '3rd link'
#      line and the most-recent handoff reason.
#   4. spawn-long-task.sh prepends '## endy environment' to every PROMPT_PATH
#      (auto-injection), and re-handoff carries that prepend through.

set -e
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy
PROJ=/tmp/endy-state-test
SESSION="endy-endy-state-test"   # what _endy_session_name will derive

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }

header "0. clean slate"
tmux kill-session -t "$SESSION" 2>/dev/null && echo "  killed pre-existing $SESSION" || true
rm -rf "$PROJ"
rm -rf "$ENDY/.logs/per-dir/$SESSION"
mkdir -p "$PROJ"
echo "demo project for endy state" > "$PROJ/README.md"
ok "fresh $PROJ"

header "1. endy start in fresh project"
( cd "$PROJ" && "$ENDY/bin/endy" start --no-attach 2>&1 | tail -3 )
tmux has-session -t "$SESSION" 2>/dev/null && ok "session $SESSION up" || fail "session not up"

header "2. build a 3-link chain: stub → noop → bash"
# L1: parent stub task. Origin (no handoff).
L1_OUT="$(
  cd "$PROJ" && ENDY_ORCHESTRATOR=state-test ENDY_ORCHESTRATOR_AGENT=codex \
  "$ENDY/bin/endy" spawn stub -- "Implement a calculator. Save to calc.py."
)"
L1_ID="$(printf '%s\n' "$L1_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
[[ -n "$L1_ID" ]] && ok "L1 spawned: $L1_ID (agent=stub)" || fail "L1 spawn failed"
sleep 0.5

# L2: handoff L1 → noop. Simulates 'codex rate-limited'.
L2_OUT="$(
  cd "$PROJ" && \
  "$ENDY/bin/endy" handoff "$L1_ID" --to noop --reason "codex 5h cap" --no-attach
)"
L2_ID="$(printf '%s\n' "$L2_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
[[ -n "$L2_ID" ]] && ok "L2 spawned: $L2_ID (agent=noop, handoff from stub)" || fail "L2 handoff failed"
sleep 0.5

# L3: handoff L2 → bash. The link we're going to inspect.
L3_OUT="$(
  cd "$PROJ" && \
  "$ENDY/bin/endy" handoff "$L2_ID" --to bash --reason "noop quota exhausted" --no-attach
)"
L3_ID="$(printf '%s\n' "$L3_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
[[ -n "$L3_ID" ]] && ok "L3 spawned: $L3_ID (agent=bash, handoff from noop)" || fail "L3 handoff failed"
sleep 0.5

L3_META="$ENDY/.logs/per-dir/$SESSION/task-$L3_ID.meta"
EXPECTED_CHAIN="$L1_ID,$L2_ID"
grep -q "^handoff_chain=$EXPECTED_CHAIN$" "$L3_META" \
  && ok "L3 meta has handoff_chain=$EXPECTED_CHAIN" \
  || fail "L3 meta chain mismatch (expected $EXPECTED_CHAIN)"

header "3. endy state --task-id <L3> --format json"
JSON_OUT="$("$ENDY/bin/endy" state --task-id "$L3_ID" --format json)"
echo "$JSON_OUT" | head -40

python3 - <<PYEOF
import json
import sys

data = json.loads("""$JSON_OUT""")

assert data.get("version") == "1", f"version mismatch: {data.get('version')!r}"
print("  ✓ schema version = 1")

self_block = data.get("self") or {}
assert self_block.get("task_id") == "$L3_ID", f"self.task_id: {self_block.get('task_id')!r}"
assert self_block.get("agent") == "bash", f"self.agent: {self_block.get('agent')!r}"
print("  ✓ self.task_id and self.agent")

lineage = data.get("lineage") or {}
chain = lineage.get("handoff_chain") or []
assert len(chain) == 2, f"chain length: {len(chain)} (expected 2)"
assert chain[0].get("task_id") == "$L1_ID", f"chain[0].task_id: {chain[0].get('task_id')!r}"
assert chain[0].get("agent") == "stub", f"chain[0].agent: {chain[0].get('agent')!r}"
assert chain[1].get("task_id") == "$L2_ID", f"chain[1].task_id: {chain[1].get('task_id')!r}"
assert chain[1].get("agent") == "noop", f"chain[1].agent: {chain[1].get('agent')!r}"
print("  ✓ lineage.handoff_chain = [stub, noop]")

assert lineage.get("handoff_reason") == "noop quota exhausted", \
    f"handoff_reason: {lineage.get('handoff_reason')!r}"
print("  ✓ lineage.handoff_reason carries L3's reason")

peers = data.get("peers") or {}
in_sess = peers.get("in_session") or []
in_sess_ids = {p.get("task_id") for p in in_sess}
assert "$L1_ID" in in_sess_ids, f"L1 missing from peers.in_session: {in_sess_ids}"
assert "$L2_ID" in in_sess_ids, f"L2 missing from peers.in_session: {in_sess_ids}"
print("  ✓ peers.in_session has L1 and L2")

tiers = data.get("tiers") or {}
for agent in ("codex", "opencode", "claude", "gemini", "hermes", "cmd"):
    assert agent in tiers, f"tier {agent!r} missing from tiers keys"
    assert "source" in tiers[agent], f"tier {agent!r} has no 'source' field"
print("  ✓ tiers has all 6 agents (codex/opencode/claude/gemini/hermes/cmd), each with 'source'")
PYEOF

header "4. endy state --task-id <L3> --format prompt"
PROMPT_OUT="$("$ENDY/bin/endy" state --task-id "$L3_ID" --format prompt)"
echo "$PROMPT_OUT"

echo "$PROMPT_OUT" | grep -q "^## endy environment" \
  && ok "prompt block starts with '## endy environment'" \
  || fail "prompt does not start with '## endy environment'"
echo "$PROMPT_OUT" | grep -q "3rd link in handoff chain" \
  && ok "prompt mentions '3rd link in handoff chain'" \
  || fail "prompt missing '3rd link' phrasing"
echo "$PROMPT_OUT" | grep -q "noop quota exhausted" \
  && ok "prompt carries L3's handoff reason" \
  || fail "prompt missing handoff reason"
echo "$PROMPT_OUT" | grep -q "endy handoff" \
  && ok "prompt mentions 'endy handoff' hint" \
  || fail "prompt missing 'endy handoff' hint"

header "5. auto-injection: spawn-long-task.sh prepends '## endy environment'"
# Every spawn writes a prompt file. L3 came through handoff.sh → spawn-long-task.sh,
# so its prompt file should already have the '## endy environment' block prepended
# to the [endy handoff …] section.
L3_PROMPT_FILE="$ENDY/.logs/per-dir/$SESSION/task-$L3_ID.prompt.md"
[[ -f "$L3_PROMPT_FILE" ]] || fail "L3 prompt file missing: $L3_PROMPT_FILE"
head -1 "$L3_PROMPT_FILE" | grep -q "^## endy environment" \
  && ok "L3 PROMPT_PATH starts with '## endy environment'" \
  || fail "L3 PROMPT_PATH first line is: $(head -1 "$L3_PROMPT_FILE")"
grep -q "endy handoff — you are taking over" "$L3_PROMPT_FILE" \
  && ok "L3 PROMPT_PATH still contains the handoff markers below the env block" \
  || fail "L3 PROMPT_PATH lost the handoff section"

header "6. --no-state bypass (offline-clean prompt)"
NS_OUT="$(
  cd "$PROJ" && \
  "$ENDY/scripts/spawn-long-task.sh" --agent stub --no-state --full-auto \
    --prompt "throwaway clean-prompt task"
)"
NS_ID="$(printf '%s\n' "$NS_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
NS_PROMPT="$ENDY/.logs/per-dir/$SESSION/task-$NS_ID.prompt.md"
[[ -f "$NS_PROMPT" ]] || fail "no-state prompt file missing"
if head -1 "$NS_PROMPT" | grep -q "^## endy environment"; then
  fail "--no-state still injected the environment block"
else
  ok "--no-state produced a clean prompt (no env block)"
fi

header "7. teardown"
tmux kill-session -t "$SESSION" 2>/dev/null || true
green "SMOKE TEST PASSED"
