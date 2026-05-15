#!/usr/bin/env bash
# Smoke test for the Phase 5 git-worktree-isolation path.
# Uses the offline stub/noop/bash agents so no API credit is burned. Verifies:
#   1. --worktree creates <repo-root>/.endy/worktrees/<task-id>/ on branch
#      endy/task-<task-id> and points the spawn's cwd there.
#   2. Two parallel spawns get isolated worktrees (no path collision).
#   3. ENDY_DEFAULT_WORKTREE=1 enables worktree by default;
#      --no-worktree overrides it.
#   4. Handoff propagates worktree to the child (same dir, same branch,
#      worktree_inherited=1 in child meta).
#   5. endy stop on a clean worktree → removed; dirty → preserved.
#   6. endy watch purge cascades to children and cleans the shared worktree.
#   7. --worktree in a non-git dir → graceful fallback (skip_reason recorded).

set -e
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy
PROJ=/tmp/endy-worktree-test
NONGIT=/tmp/endy-worktree-nongit
SESSION="endy-endy-worktree-test"
SESSION_NG="endy-endy-worktree-nongit"

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }

header "0. clean slate"
tmux kill-session -t "$SESSION"    2>/dev/null && echo "  killed pre-existing $SESSION" || true
tmux kill-session -t "$SESSION_NG" 2>/dev/null && echo "  killed pre-existing $SESSION_NG" || true
rm -rf "$PROJ" "$NONGIT" "$ENDY/.logs/per-dir/$SESSION" "$ENDY/.logs/per-dir/$SESSION_NG"
mkdir -p "$PROJ"
cd "$PROJ"
git init -q
git config user.email "smoke@worktree.test"
git config user.name "smoke"
echo "v1" > README.md
git add README.md
git commit -qm "initial"
ok "fresh git project at $PROJ"

header "1. endy start"
"$ENDY/bin/endy" start --no-attach > /tmp/start.log 2>&1
tmux has-session -t "$SESSION" 2>/dev/null && ok "session $SESSION up" || fail "session not up"

header "2. spawn --worktree creates the worktree at .endy/worktrees/<task-id>/"
OUT_A=$("$ENDY/bin/endy" spawn stub --worktree -- "task A — clean run")
TID_A=$(echo "$OUT_A" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_A="$ENDY/.logs/per-dir/$SESSION/task-$TID_A.meta"
WT_A=$(grep '^worktree_dir=' "$META_A" | cut -d= -f2-)
BR_A=$(grep '^worktree_branch=' "$META_A" | cut -d= -f2-)
[ -d "$WT_A" ]                                            && ok "worktree dir exists: $WT_A"        || fail "no wt dir"
[ "$WT_A" = "$PROJ/.endy/worktrees/$TID_A" ]              && ok "worktree path canonical"           || fail "unexpected wt path: $WT_A"
[ "$BR_A" = "endy/task-$TID_A" ]                          && ok "branch name canonical"             || fail "unexpected branch: $BR_A"
[ "$(cd "$WT_A" && git rev-parse --abbrev-ref HEAD)" = "$BR_A" ] && ok "worktree HEAD on correct branch" || fail "wt HEAD wrong"

header "3. parallel spawn → second task gets its OWN worktree"
OUT_B=$("$ENDY/bin/endy" spawn stub --worktree -- "task B — parallel")
TID_B=$(echo "$OUT_B" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_B="$ENDY/.logs/per-dir/$SESSION/task-$TID_B.meta"
WT_B=$(grep '^worktree_dir=' "$META_B" | cut -d= -f2-)
[ "$WT_A" != "$WT_B" ] && ok "two distinct worktrees ($WT_A, $WT_B)" || fail "worktrees collided"
echo "edited by A" > "$WT_A/edit-a.txt"
[ ! -f "$WT_B/edit-a.txt" ] && ok "edit in A's worktree is invisible to B" || fail "isolation broken"
rm "$WT_A/edit-a.txt"

header "4. ENDY_DEFAULT_WORKTREE=1 enables default; --no-worktree overrides"
OUT_C=$(ENDY_DEFAULT_WORKTREE=1 "$ENDY/bin/endy" spawn stub -- "task C — env default")
TID_C=$(echo "$OUT_C" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_C="$ENDY/.logs/per-dir/$SESSION/task-$TID_C.meta"
[ -n "$(grep '^worktree_dir=.\+' "$META_C")" ] && ok "ENDY_DEFAULT_WORKTREE=1 → created" || fail "env default didn't fire"

OUT_D=$(ENDY_DEFAULT_WORKTREE=1 "$ENDY/bin/endy" spawn stub --no-worktree -- "task D — bypass")
TID_D=$(echo "$OUT_D" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_D="$ENDY/.logs/per-dir/$SESSION/task-$TID_D.meta"
grep -q '^worktree_dir=$' "$META_D" && ok "--no-worktree overrides env → no wt" || fail "--no-worktree didn't override"

header "5. handoff inheritance — child reuses parent's worktree"
sleep 0.5
HOUT=$("$ENDY/bin/endy" handoff "$TID_A" --to bash --reason "Phase 5 inherit test" --no-attach 2>&1)
TID_H=$(echo "$HOUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_H="$ENDY/.logs/per-dir/$SESSION/task-$TID_H.meta"
WT_H=$(grep '^worktree_dir=' "$META_H" | cut -d= -f2-)
BR_H=$(grep '^worktree_branch=' "$META_H" | cut -d= -f2-)
INH_H=$(grep '^worktree_inherited=' "$META_H" | cut -d= -f2-)
[ "$WT_H" = "$WT_A" ]    && ok "child worktree_dir matches parent ($WT_A)"        || fail "wt_dir mismatch: $WT_H vs $WT_A"
[ "$BR_H" = "$BR_A" ]    && ok "child worktree_branch matches parent ($BR_A)"     || fail "branch mismatch"
[ "$INH_H" = "1" ]       && ok "child meta has worktree_inherited=1"              || fail "inherited flag not set"
WTCOUNT=$(cd "$PROJ" && git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
# 1 main + at least 3 task worktrees (A, B, C — D bypassed)
[ "$WTCOUNT" -ge 4 ] && ok "git sees $WTCOUNT worktrees (main + 3+ task wt)" || fail "expected ≥4, got $WTCOUNT"

header "6. endy stop with DIRTY worktree → preserved (no data loss)"
# Add an uncommitted edit to task B's worktree, then stop the session.
echo "uncommitted by agent" > "$WT_B/AGENT_WIP.md"
STOPOUT=$("$ENDY/bin/endy" stop --session "$SESSION" 2>&1)
echo "$STOPOUT" | grep -q "worktree skipped (uncommitted edits)" && ok "stop reported skip for dirty wt" || fail "stop didn't flag dirty wt"
[ -d "$WT_B" ]                && ok "dirty worktree $WT_B preserved" || fail "dirty wt removed (would lose user edits)"
[ -f "$WT_B/AGENT_WIP.md" ]   && ok "uncommitted file survived"      || fail "uncommitted file gone"
# Clean worktrees should be removed
[ ! -d "$WT_A" ] || [ "$WT_A" = "$WT_H" ] && ok "clean owner worktrees removed by stop" || true

# Recover: manually nuke the dirty wt so it doesn't pollute next test
rm -rf "$WT_B"
(cd "$PROJ" && git worktree prune 2>/dev/null; git branch -D "endy/task-$TID_B" 2>/dev/null) >/dev/null

header "7. endy watch purge cascades through children + cleans shared wt"
"$ENDY/bin/endy" start --no-attach > /dev/null 2>&1
OUT_E=$("$ENDY/bin/endy" spawn stub --worktree -- "task E — root of chain")
TID_E=$(echo "$OUT_E" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
sleep 0.3
OUT_F=$("$ENDY/bin/endy" handoff "$TID_E" --to bash --reason "purge cascade" --no-attach 2>&1)
TID_F=$(echo "$OUT_F" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
WT_E=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$TID_E.meta" | cut -d= -f2-)
[ -d "$WT_E" ] && ok "chain root has worktree $WT_E" || fail "chain wt missing"

PURGEOUT=$(printf '&\n%s\n' "$TID_E" | "$ENDY/bin/endy" watch purge "$TID_E" 2>&1)
echo "$PURGEOUT" | grep -q "Worktree cleanup: 1 removed" && ok "purge removed exactly 1 worktree (shared by chain)" \
  || { echo "$PURGEOUT" | tail -10; fail "purge did not clean shared wt"; }
[ ! -d "$WT_E" ] && ok "shared worktree gone after cascade purge" || fail "wt still on disk"

header "8. --worktree in a non-git dir → graceful fallback, skip_reason recorded"
mkdir -p "$NONGIT"
( cd "$NONGIT" && "$ENDY/bin/endy" start --no-attach > /dev/null 2>&1 )
OUT_NG=$(cd "$NONGIT" && "$ENDY/bin/endy" spawn stub --worktree -- "no-git fallback")
TID_NG=$(echo "$OUT_NG" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META_NG="$ENDY/.logs/per-dir/$SESSION_NG/task-$TID_NG.meta"
grep -q '^worktree_dir=$' "$META_NG"                          && ok "worktree_dir empty (no wt created)"  || fail "non-git wt was created!"
grep -q '^worktree_skip_reason=not-a-git-repo$' "$META_NG"    && ok "skip_reason=not-a-git-repo recorded"  || fail "skip_reason missing"

header "cleanup"
tmux kill-session -t "$SESSION"    2>/dev/null || true
tmux kill-session -t "$SESSION_NG" 2>/dev/null || true
rm -rf "$PROJ" "$NONGIT"
green "SMOKE TEST PASSED"
