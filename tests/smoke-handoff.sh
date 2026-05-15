#!/usr/bin/env bash
# Smoke test for the Phase 1 handoff path.
# Uses the offline `bash` stub agent so no API credit is burned. Verifies:
#   1. spawn-long-task.sh records handoff_from / handoff_chain / handoff_reason
#      in the new task's meta file.
#   2. handoff composes prompt = [markers] + [original prompt] + [last N lines].
#   3. endy watch tree shows the ↪ handoff line.
#   4. endy watch list shows ↪<short-ref> in the PARENT column.
#   5. A multi-step chain (A → B → C) accumulates ids in handoff_chain.
#   6. --stop-parent kills the parent tmux window.
#   7. Web API (server.py logic — called as a function, not via HTTP) exposes
#      handoff_from / handoff_chain / handoff_reason in the JSON.

set -e
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy
PROJ=/tmp/endy-handoff-test
SESSION="endy-endy-handoff-test"   # what _endy_session_name will derive

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
echo "demo project for handoff" > "$PROJ/README.md"
ok "fresh $PROJ"

header "1. endy start in fresh project"
( cd "$PROJ" && "$ENDY/bin/endy" start --no-attach 2>&1 | tail -3 )
tmux has-session -t "$SESSION" 2>/dev/null && ok "session $SESSION up" || fail "session not up"

header "2. spawn parent task with stub agent (playing the role of codex)"
PARENT_OUT="$(
  cd "$PROJ" && ENDY_ORCHESTRATOR=demo-orchestrator ENDY_ORCHESTRATOR_AGENT=codex \
  "$ENDY/bin/endy" spawn stub -- "Build a hello-world Python script that prints the current weekday. Save it as hello.py."
)"
PARENT_ID="$(printf '%s\n' "$PARENT_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
PARENT_LOG="$(printf '%s\n' "$PARENT_OUT" | grep '^LOG=' | head -1 | cut -d= -f2-)"
PARENT_META="$ENDY/.logs/per-dir/$SESSION/task-$PARENT_ID.meta"
[[ -f "$PARENT_META" ]] && ok "parent meta written: task-$PARENT_ID" || fail "no parent meta"

sleep 1
[[ -f "$PARENT_LOG" ]] && grep -q '\[stub agent' "$PARENT_LOG" && ok "stub agent printed marker in log" \
  || fail "stub agent did not write expected marker"

header "3. handoff parent → bash (simulating 'codex rate-limited')"
HANDOFF_OUT="$(
  cd "$PROJ" && \
  "$ENDY/bin/endy" handoff "$PARENT_ID" --to bash --reason "codex rate limit (5h window exhausted)" --no-attach
)"
echo "$HANDOFF_OUT"

CHILD_ID="$(printf '%s\n' "$HANDOFF_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
[[ -n "$CHILD_ID" ]] && ok "child task spawned: $CHILD_ID" || fail "no child TASK_ID"

CHILD_META="$ENDY/.logs/per-dir/$SESSION/task-$CHILD_ID.meta"
CHILD_PROMPT="$ENDY/.logs/per-dir/$SESSION/task-$CHILD_ID.prompt.md"
CHILD_LOG="$ENDY/.logs/per-dir/$SESSION/task-$CHILD_ID.log"

[[ -f "$CHILD_META" ]] && ok "child meta exists" || fail "no child meta"
grep -q "^handoff_from=$PARENT_ID$" "$CHILD_META" && ok "handoff_from=$PARENT_ID stamped" || fail "handoff_from missing"
grep -q "^handoff_chain=$PARENT_ID$" "$CHILD_META" && ok "handoff_chain=$PARENT_ID stamped" || fail "handoff_chain missing"
grep -q "^handoff_reason=codex rate limit" "$CHILD_META" && ok "handoff_reason stamped" || fail "handoff_reason missing"

grep -q "endy handoff — you are taking over" "$CHILD_PROMPT" && ok "composite prompt has handoff markers" || fail "no markers"
grep -q "original task prompt" "$CHILD_PROMPT" && ok "composite prompt includes parent prompt section" || fail "no original prompt section"
grep -q "hello-world Python script" "$CHILD_PROMPT" && ok "composite prompt carries parent's text" || fail "parent text not propagated"
grep -qE "(full output|last [0-9]+ lines) of previous agent" "$CHILD_PROMPT" && ok "composite prompt includes log section" || fail "no log section"

header "4. endy watch list shows ↪ handoff line under the child"
# The card-style watch list (post-0.5.0) prints the handoff hint on its own
# sub-line under the cwd of the child row. We assert two things:
#   (a) the child id appears somewhere in the output, and
#   (b) the child's ↪ handoff line references the short ref of the parent.
# The earlier "↪ on the same line as the child id" layout no longer holds.
LIST_OUT="$(NO_COLOR=1 ENDY_SESSION=$SESSION ENDY_LOG_DIR=$ENDY/.logs/per-dir/$SESSION "$ENDY/bin/endy" watch list)"
echo "$LIST_OUT"
echo "$LIST_OUT" | grep -q "$CHILD_ID" && ok "child row visible in list" \
  || fail "child row missing in list"
# Parent's short ref is the last 4-hex chunk of the id (e.g. "181517-a419").
PARENT_SHORT="${PARENT_ID#*-}"; PARENT_SHORT="${PARENT_SHORT#*-}"
PARENT_TIME_HEX="${PARENT_ID#*-}"
echo "$LIST_OUT" | grep -q "↪ handoff from $PARENT_TIME_HEX" && ok "↪ handoff line points at parent ($PARENT_TIME_HEX)" \
  || fail "no ↪ handoff line referencing parent $PARENT_TIME_HEX"

header "5. endy watch tree shows the ↪ handoff sub-line"
TREE_FILE="$(mktemp)"
# Scope to the test session — keeping it local makes the test self-contained
# and avoids scanning other unrelated sessions. The handoff rendering path
# is the same in both --overview and per-session modes. We deliberately
# do NOT let `set -e` abort on a non-zero from tree: we want to inspect
# the file regardless and fail with a clear message.
NO_COLOR=1 ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$ENDY/.logs/per-dir/$SESSION" \
  "$ENDY/bin/endy" watch tree --all > "$TREE_FILE" 2>&1 || true
echo "[tree exit=$? output size=$(wc -c < "$TREE_FILE") bytes]"
cat "$TREE_FILE"
if grep -q "↪ handoff from" "$TREE_FILE"; then ok "↪ handoff line in tree"; else fail "tree did not render handoff line"; fi
rm -f "$TREE_FILE"

header "6. multi-step chain: handoff again (child bash → grandchild noop)"
HANDOFF2_OUT="$(
  cd "$PROJ" && \
  "$ENDY/bin/endy" handoff "$CHILD_ID" --to noop --reason "opencode quota exhausted" --no-attach
)"
GRANDCHILD_ID="$(printf '%s\n' "$HANDOFF2_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
[[ -n "$GRANDCHILD_ID" ]] && ok "grandchild task spawned: $GRANDCHILD_ID" || fail "no grandchild TASK_ID"

GRANDCHILD_META="$ENDY/.logs/per-dir/$SESSION/task-$GRANDCHILD_ID.meta"
EXPECTED_CHAIN="$PARENT_ID,$CHILD_ID"
grep -q "^handoff_chain=$EXPECTED_CHAIN$" "$GRANDCHILD_META" && ok "chain accumulated: $EXPECTED_CHAIN" \
  || fail "expected chain $EXPECTED_CHAIN not in grandchild meta"

header "7. --stop-parent flag kills the parent's tmux window"
# Spawn a fresh pair and exercise --stop-parent. Parent is `stub`, child `bash`.
P2_OUT="$( cd "$PROJ" && "$ENDY/bin/endy" spawn stub -- "throwaway parent to be killed" )"
P2_ID="$(printf '%s\n' "$P2_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)"
P2_WIN="task-$P2_ID"
tmux list-windows -t "$SESSION" -F '#W' | grep -qxF "$P2_WIN" && ok "parent2 window exists" || fail "parent2 missing"

"$ENDY/bin/endy" handoff "$P2_ID" --to bash --reason "test --stop-parent" --stop-parent --no-attach 2>&1 | tail -5
sleep 0.5
if tmux list-windows -t "$SESSION" -F '#W' | grep -qxF "$P2_WIN"; then
  fail "--stop-parent did not kill window $P2_WIN"
else
  ok "--stop-parent closed window $P2_WIN"
fi

header "8. web JSON exposes handoff fields"
python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENDY/web")
import server
tasks = server.list_tasks()
child = next((t for t in tasks if t["task_id"] == "$CHILD_ID"), None)
assert child, "child task missing from list_tasks()"
assert child["handoff_from"] == "$PARENT_ID", f"handoff_from mismatch: {child['handoff_from']!r}"
assert child["handoff_chain"] == "$PARENT_ID", f"handoff_chain mismatch: {child['handoff_chain']!r}"
assert "codex rate limit" in child["handoff_reason"], f"reason mismatch: {child['handoff_reason']!r}"
print("  ✓ list_tasks() carries handoff_from, handoff_chain, handoff_reason")
detail = server.task_detail("$GRANDCHILD_ID")
assert detail["handoff_chain"] == "$EXPECTED_CHAIN", f"detail chain: {detail['handoff_chain']!r}"
print("  ✓ task_detail() carries the full chain")
PYEOF

header "9. teardown"
tmux kill-session -t "$SESSION" 2>/dev/null || true
green "SMOKE TEST PASSED"
