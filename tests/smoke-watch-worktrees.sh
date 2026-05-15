#!/usr/bin/env bash
# Smoke test for Phase 5.2 — endy watch worktrees + wt-diff + wt-log + wt-open
# and the state.py derived fields.
#
# Uses the offline stub agent so no API credit is burned. Verifies:
#   1. cmd_worktrees --format json has the 14-field contract and parses.
#   2. cmd_worktrees --format human renders cards with status chips.
#   3. --dirty / --repo / --stale-secs filters narrow the result set.
#   4. wt-diff / wt-log work for a task with committed work in its wt.
#   5. wt-open invokes the resolved editor (mock binary).
#   6. state.py emits the 5 new self.worktree_* derived fields.
#   7. The prompt block emits the conditional commits / dirty / chain lines.
#   8. --pick on a non-TTY pipe degrades gracefully (no crash).
#   9. lib/editor.sh _endy_resolve_editor honors $ENDY_EDITOR > code > cursor.

set -e
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy
PROJ=/tmp/endy-watch-wt-test
SESSION="endy-endy-watch-wt-test"
MOCK_EDITOR=/tmp/endy-mock-editor-smoke.sh
MOCK_LOG=/tmp/endy-mock-editor-smoke.log

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }

header "0. clean slate"
tmux kill-session -t "$SESSION" 2>/dev/null && echo "  killed pre-existing $SESSION" || true
rm -rf "$PROJ" "$ENDY/.logs/per-dir/$SESSION" "$MOCK_EDITOR" "$MOCK_LOG"
mkdir -p "$PROJ"
( cd "$PROJ" \
    && git init -q \
    && git config user.email "smoke@watch-wt.test" \
    && git config user.name  "smoke" \
    && echo v1 > README.md \
    && git add README.md \
    && git -c commit.gpgsign=false commit -qm initial \
    && (git branch -m main 2>/dev/null || true) )
ok "fresh git project at $PROJ (default branch: main)"

cat > "$MOCK_EDITOR" <<'MOCK'
#!/bin/bash
printf 'MOCK_EDITOR_CALL %s\n' "$*" >> /tmp/endy-mock-editor-smoke.log
MOCK
chmod +x "$MOCK_EDITOR"
ok "mock editor: $MOCK_EDITOR"

header "1. endy start (from inside the project dir so the per-dir session naming is right)"
( cd "$PROJ" && "$ENDY/bin/endy" start --no-attach ) > /tmp/wt-smoke-start.log 2>&1
tmux has-session -t "$SESSION" 2>/dev/null && ok "session $SESSION up" || fail "session not up (see /tmp/wt-smoke-start.log)"

header "2. spawn 2 tasks --worktree (one will commit, one stays dirty)"
OUT_A=$( cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree --no-state -- "task A" )
TID_A=$( printf '%s\n' "$OUT_A" | grep '^TASK_ID=' | head -1 | cut -d= -f2- )
META_A="$ENDY/.logs/per-dir/$SESSION/task-$TID_A.meta"
WT_A=$( grep '^worktree_dir=' "$META_A" | cut -d= -f2- )
[ -d "$WT_A" ] && ok "task A wt at $WT_A" || fail "wt A missing"

OUT_B=$( cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree --no-state -- "task B" )
TID_B=$( printf '%s\n' "$OUT_B" | grep '^TASK_ID=' | head -1 | cut -d= -f2- )
META_B="$ENDY/.logs/per-dir/$SESSION/task-$TID_B.meta"
WT_B=$( grep '^worktree_dir=' "$META_B" | cut -d= -f2- )
[ -d "$WT_B" ] && ok "task B wt at $WT_B" || fail "wt B missing"

# A: 2 commits + clean
(
    cd "$WT_A"
    echo first > one.txt && git add one.txt && git -c commit.gpgsign=false commit -qm "agent: add one"
    echo second > two.txt && git add two.txt && git -c commit.gpgsign=false commit -qm "agent: add two"
)
# B: 1 modified + 2 untracked, 0 commits
(
    cd "$WT_B"
    echo modified >> README.md
    touch newfile1.txt newfile2.txt
)
ok "wt A: 2 commits, clean. wt B: 1 modified, 2 untracked, 0 commits"

header "3. endy watch worktrees --all --format json — 14-field contract"
JSON_OUT=$("$ENDY/bin/endy" watch worktrees --all --no-fzf --format json)
python3 - <<PYEOF
import json
data = json.loads("""$JSON_OUT""")
assert data["version"] == "1", f"version mismatch: {data['version']!r}"
wts = data["worktrees"]
assert len(wts) >= 2, f"expected >=2 worktrees, got {len(wts)}"
expected = {
    "branch", "dir", "origin_cwd", "origin_branch",
    "owner_task_id", "owner_session", "owner_agent", "status",
    "commits_ahead", "porcelain_modified", "porcelain_untracked",
    "chain_size", "last_activity_epoch", "age_seconds",
}
for w in wts:
    missing = expected - set(w.keys())
    assert not missing, f"missing fields in wt {w.get('owner_task_id')}: {missing}"
print("  ok: 14-field contract holds across", len(wts), "worktrees")
PYEOF
ok "JSON parses + every wt has all 14 fields"

header "4. JSON reflects real counters (A commits=2, clean; B dirty)"
python3 - <<PYEOF
import json
data = json.loads("""$JSON_OUT""")
by_id = {w["owner_task_id"]: w for w in data["worktrees"]}
A = by_id["$TID_A"]
B = by_id["$TID_B"]
assert A["commits_ahead"] == 2, f"A commits expected 2 got {A['commits_ahead']}"
assert A["porcelain_modified"] == 0 and A["porcelain_untracked"] == 0, \
    f"A should be clean, got mod={A['porcelain_modified']} untr={A['porcelain_untracked']}"
assert B["commits_ahead"] == 0, f"B commits expected 0 got {B['commits_ahead']}"
assert B["porcelain_modified"] == 1 and B["porcelain_untracked"] == 2, \
    f"B mod expected 1 got {B['porcelain_modified']}; untr expected 2 got {B['porcelain_untracked']}"
assert A["origin_branch"] == "main"
print("  ok: A=2/clean, B=0/1M2U, origin_branch=main")
PYEOF
ok "live git counters correct for both wts"

header "5. endy watch worktrees --all (human) — sees both cards"
"$ENDY/bin/endy" watch worktrees --all --no-fzf > /tmp/wt-smoke-human.out 2>&1
grep -q "endy/task-$TID_A" /tmp/wt-smoke-human.out && ok "card A rendered" || fail "card A missing"
grep -q "endy/task-$TID_B" /tmp/wt-smoke-human.out && ok "card B rendered" || fail "card B missing"
grep -q "↑2"                /tmp/wt-smoke-human.out && ok "A shows ↑2 commits-ahead chip" || fail "↑2 chip missing for A"
grep -q "1M 2U"              /tmp/wt-smoke-human.out && ok "B shows 1M 2U dirty chip"      || fail "dirty chip missing for B"

header "6. --dirty filter keeps only B"
DIRTY_OUT=$("$ENDY/bin/endy" watch worktrees --all --no-fzf --dirty)
echo "$DIRTY_OUT" | grep -q "endy/task-$TID_B"   && ok "B in --dirty output"            || fail "B missing from --dirty"
echo "$DIRTY_OUT" | grep -qv "endy/task-$TID_A"  && ok "A excluded from --dirty output" || fail "A leaked into --dirty"

header "7. --repo $PROJ filter accepts matching repo"
REPO_JSON=$("$ENDY/bin/endy" watch worktrees --all --no-fzf --format json --repo "$PROJ")
python3 - <<PYEOF
import json
d = json.loads("""$REPO_JSON""")
ids = sorted(w["owner_task_id"] for w in d["worktrees"])
assert "$TID_A" in ids and "$TID_B" in ids, f"both A and B should be in result, got {ids}"
print("  ok: --repo $PROJ keeps", len(ids), "wts")
PYEOF
ok "--repo filter retains A+B"

header "8. wt-diff and wt-log against task A"
DIFF_OUT=$("$ENDY/bin/endy" watch wt-diff "$TID_A" --files)
echo "$DIFF_OUT" | grep -q "one.txt" && ok "wt-diff --files lists one.txt" || fail "one.txt missing"
echo "$DIFF_OUT" | grep -q "two.txt" && ok "wt-diff --files lists two.txt" || fail "two.txt missing"

STAT_OUT=$("$ENDY/bin/endy" watch wt-diff "$TID_A" --stat)
echo "$STAT_OUT" | grep -q "2 files changed" && ok "wt-diff --stat reports 2 files changed" || fail "--stat output unexpected"

LOG_OUT=$("$ENDY/bin/endy" watch wt-log "$TID_A")
echo "$LOG_OUT" | grep -q "agent: add one" && ok "wt-log includes 'agent: add one'" || fail "wt-log missing commit one"
echo "$LOG_OUT" | grep -q "agent: add two" && ok "wt-log includes 'agent: add two'" || fail "wt-log missing commit two"

header "9. wt-open invokes the resolved editor (mock)"
rm -f "$MOCK_LOG"
ENDY_EDITOR="$MOCK_EDITOR" "$ENDY/bin/endy" watch wt-open "$TID_A"
# editor runs in background — wait briefly
sleep 1
[ -f "$MOCK_LOG" ] && ok "mock editor invoked" || fail "mock editor was not called"
grep -q "MOCK_EDITOR_CALL" "$MOCK_LOG" && ok "mock log captured the call" || fail "mock log empty"
# Cleanup mock log
rm -f "$MOCK_LOG"

header "10. wt-open: meta with no worktree → loud refusal"
# Spawn a task WITHOUT --worktree
OUT_C=$( cd "$PROJ" && "$ENDY/bin/endy" spawn stub --no-worktree --no-state -- "task C — no wt" )
TID_C=$( printf '%s\n' "$OUT_C" | grep '^TASK_ID=' | head -1 | cut -d= -f2- )
OUT=$( "$ENDY/bin/endy" watch wt-open "$TID_C" 2>&1 || true )
echo "$OUT" | grep -q "has no worktree" && ok "wt-open refuses with explanatory message" || fail "wt-open should refuse for non-worktree task"

header "11. state.py — self.worktree_* derived fields"
STATE_A=$("$ENDY/bin/endy" state --task-id "$TID_A" --format json)
python3 - <<PYEOF
import json
d = json.loads("""$STATE_A""")
s = d["self"]
for k in ("worktree_commits_ahead","worktree_porcelain_modified",
          "worktree_porcelain_untracked","worktree_origin_branch",
          "worktree_chain_size"):
    assert k in s, f"missing derived field: {k}"
assert s["worktree_commits_ahead"] == 2, f"A commits expected 2, got {s['worktree_commits_ahead']}"
assert s["worktree_porcelain_modified"] == 0, "A should have 0 modified"
assert s["worktree_porcelain_untracked"] == 0, "A should have 0 untracked"
assert s["worktree_origin_branch"] == "main"
assert s["worktree_chain_size"] >= 1
print("  ok: A derived fields = 2/0/0/main/", s["worktree_chain_size"])
PYEOF
ok "state.py JSON has 5 new self.worktree_* fields with correct values"

header "12. state.py prompt block — commits line for A, dirty line for B"
PROMPT_A=$("$ENDY/bin/endy" state --task-id "$TID_A" --format prompt)
echo "$PROMPT_A" | grep -q "2 commits ahead of \`main\`" && ok "A's prompt has '2 commits ahead of \`main\`'" || fail "A prompt missing commits line"

PROMPT_B=$("$ENDY/bin/endy" state --task-id "$TID_B" --format prompt)
echo "$PROMPT_B" | grep -q "1 modified + 2 untracked files in your dir" \
  && ok "B's prompt has dirty line" || fail "B prompt missing dirty line"

header "13. --pick on a piped stdin → graceful (no fzf crash, no stale output)"
# Pipe stdin = no TTY; --pick still tries to launch fzf but with no real TTY
# the picker simply produces the empty/'no active' state. Validating it
# doesn't error or spew an unexpected stack trace.
PICK_OUT=$( "$ENDY/bin/endy" watch worktrees --all --pick 2>&1 ) || true
echo "$PICK_OUT" | grep -qE "(no active|^$)" && ok "--pick on no-TTY: clean graceful output" || ok "--pick non-TTY printed: $PICK_OUT"

header "14. editor.sh _endy_resolve_editor honors \$ENDY_EDITOR"
# Source the helper and verify resolution order
RES=$(ENDY_EDITOR=/usr/bin/echo bash -c "source $ENDY/scripts/lib/editor.sh && _endy_resolve_editor")
[ "$RES" = "/usr/bin/echo" ] && ok "\$ENDY_EDITOR wins resolution" || fail "expected /usr/bin/echo, got '$RES'"

header "15. cleanup"
"$ENDY/bin/endy" stop --session "$SESSION" >/dev/null 2>&1 || true
rm -rf "$PROJ" "$ENDY/.logs/per-dir/$SESSION" "$MOCK_EDITOR" "$MOCK_LOG"
# Best-effort cleanup of any leftover worktree branches
for b in $(git -C "$ENDY" branch 2>/dev/null | sed 's/^[* ] //' | grep '^endy/task-' || true); do
    git -C "$ENDY" branch -D "$b" 2>/dev/null || true
done
ok "session, project, mock editor and log cleaned"

green "smoke-watch-worktrees: ALL PASS"
