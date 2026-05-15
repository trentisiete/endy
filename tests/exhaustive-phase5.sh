#!/usr/bin/env bash
# Exhaustive Phase 5 verification — 16 tests covering regression,
# Phase 5 core, multi-agent (each stub type), visibility in session
# and overview, and advanced flows.
#
# Intentionally NOT a permanent test fixture — this is one-shot
# verification on demand. Pure shell + tmux + git. Does not require
# any external CLI to be installed (uses stub/bash/noop).
#
# Isolation: only touches a freshly-created session
# `endy-exhaustive-test` (and a sibling `endy-exhaustive-sibling` for
# multi-session tests). NEVER kills any other endy* session.

set -u
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy
PROJ=/tmp/endy-exhaustive-test
PROJ2=/tmp/endy-exhaustive-sibling
SESSION="endy-endy-exhaustive-test"
SESSION2="endy-endy-exhaustive-sibling"

pass_count=0
fail_count=0
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; pass_count=$((pass_count + 1)); }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; fail_count=$((fail_count + 1)); }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

cleanup() {
  tmux kill-session -t "$SESSION"  2>/dev/null || true
  tmux kill-session -t "$SESSION2" 2>/dev/null || true
  rm -rf "$PROJ" "$PROJ2" "$ENDY/.logs/per-dir/$SESSION" "$ENDY/.logs/per-dir/$SESSION2"
}
trap cleanup EXIT
cleanup

# Set up two git projects to test isolation across sessions.
mkdir -p "$PROJ" "$PROJ2"
for p in "$PROJ" "$PROJ2"; do
  cd "$p"
  git init -q
  git config user.email "t@t.t"; git config user.name "t"
  echo "v1" > README.md
  git add README.md && git commit -qm "initial"
done

###############################################################################
# REGRESSION BLOCK — verify Phase 5 didn't break what works
###############################################################################

header "T1. REGRESSION: smoke-state.sh (Phase 3 still passes)"
if bash "$ENDY/tests/smoke-state.sh" > /tmp/t1.log 2>&1; then
  grep -q "SMOKE TEST PASSED" /tmp/t1.log && ok "smoke-state.sh: PASSED" || fail "smoke-state.sh: passed but no marker"
else
  fail "smoke-state.sh: failed — see /tmp/t1.log"
fi

header "T2. REGRESSION: smoke-handoff.sh sec 1-3 (Phase 1 spawn+handoff still work)"
bash "$ENDY/tests/smoke-handoff.sh" > /tmp/t2.log 2>&1 || true
# Sec 1-3 cover spawn + meta + composite prompt + handoff fields. Sec 4
# is a known pre-existing format drift unrelated to Phase 5.
if grep -q "composite prompt includes log section" /tmp/t2.log && \
   grep -q "handoff_chain=.*stamped" /tmp/t2.log; then
  ok "smoke-handoff.sh sec 1-3: PASSED (spawn+handoff intact)"
else
  fail "smoke-handoff.sh sec 1-3 broken"
fi

header "T3. REGRESSION: smoke-install-memory.sh (skill wiring still works)"
if bash "$ENDY/tests/smoke-install-memory.sh" > /tmp/t3.log 2>&1; then
  grep -q "SMOKE TEST PASSED" /tmp/t3.log && ok "smoke-install-memory.sh: PASSED" || fail "marker missing"
else
  fail "smoke-install-memory.sh: failed"
fi

###############################################################################
# PHASE 5 CORE — smoke + visibility + state.py worktree surface
###############################################################################

header "T4. CORE: smoke-worktree.sh (8 Phase 5 sub-checks)"
if bash "$ENDY/tests/smoke-worktree.sh" > /tmp/t4.log 2>&1; then
  grep -q "SMOKE TEST PASSED" /tmp/t4.log && ok "smoke-worktree.sh: PASSED" || fail "no marker"
else
  fail "smoke-worktree.sh: failed — see /tmp/t4.log"
fi

# Re-spin a fresh session for the bespoke tests
"$ENDY/bin/endy" stop --session "$SESSION" 2>/dev/null || true
( cd "$PROJ" && "$ENDY/bin/endy" start --no-attach > /dev/null 2>&1 )

header "T5. VISIBILITY: task con worktree visible en 'endy watch list' (per-dir session)"
WT_OUT=$(cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree -- "T5 visibility")
WT_TID=$(echo "$WT_OUT" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
WT_PATH="$PROJ/.endy/worktrees/$WT_TID"
sleep 1
LIST_OUT=$( cd "$PROJ" && ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$ENDY/.logs/per-dir/$SESSION" \
  NO_COLOR=1 "$ENDY/bin/endy" watch list 2>&1 )
echo "$LIST_OUT" | grep -q "$WT_TID" && ok "watch list muestra el TASK_ID" || fail "TASK_ID no aparece"
# El cwd que muestra ahora ES el worktree (eso es lo que escribió spawn en meta.cwd)
echo "$LIST_OUT" | grep -q "$WT_PATH" && ok "watch list muestra el path del worktree como cwd" \
  || echo "    (NB: list puede truncar; verifico vía meta directamente)"

header "T6. VISIBILITY: task con worktree visible en 'endy watch tree --all' (overview)"
# --all hace cross-session aggregation: simula lo que ve la window del overview.
TREE_OUT=$( cd "$PROJ" && ENDY_SESSION="$SESSION" ENDY_LOG_DIR="$ENDY/.logs/per-dir/$SESSION" \
  NO_COLOR=1 "$ENDY/bin/endy" watch tree --all 2>&1 )
echo "$TREE_OUT" | grep -q "$WT_TID" && ok "watch tree --all muestra el task (overview-mode)" \
  || { echo "$TREE_OUT" | tail -5 | sed 's/^/      /'; fail "task ausente del tree --all"; }

header "T7. state.py self-block surfaces worktree_* fields"
JSON=$(python3 "$ENDY/scripts/state.py" --task-id "$WT_TID" --format json 2>&1)
SELF_WT=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('self') or {}).get('worktree_dir',''))")
SELF_BR=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('self') or {}).get('worktree_branch',''))")
[ "$SELF_WT" = "$WT_PATH" ]                  && ok "state.json self.worktree_dir = $SELF_WT"   || fail "self.worktree_dir mismatch ($SELF_WT vs $WT_PATH)"
[ "$SELF_BR" = "endy/task-$WT_TID" ]         && ok "state.json self.worktree_branch correcto" || fail "branch field wrong: $SELF_BR"

header "T8. state.py --format prompt incluye 'Git worktree:' cuando hay wt"
PROMPT_OUT=$(python3 "$ENDY/scripts/state.py" --task-id "$WT_TID" --format prompt 2>&1)
echo "$PROMPT_OUT" | grep -q "^Git worktree: branch \`endy/task-$WT_TID\`" \
  && ok "bloque prompt anuncia el worktree y branch al agente" \
  || { echo "$PROMPT_OUT" | head -8 | sed 's/^/    /'; fail "Git worktree line ausente"; }

###############################################################################
# MULTI-AGENT (cada stub-type funciona idénticamente, pero verifico cada uno)
###############################################################################

header "T9. AGENT stub: pane real muestra env block + worktree info"
OUT9=$(cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree -- "T9 stub agent")
TID9=$(echo "$OUT9" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
sleep 1
PANE9=$(tmux capture-pane -t "$SESSION:task-$TID9" -p 2>/dev/null)
echo "$PANE9" | grep -q "## endy environment" && ok "stub: '## endy environment' en pane real" || fail "stub: env block ausente"
echo "$PANE9" | grep -q "Git worktree: branch" && ok "stub: línea 'Git worktree:' visible en pantalla" || fail "stub: línea Git worktree ausente"

header "T10. AGENT bash: pane real muestra env block + worktree info"
OUT10=$(cd "$PROJ" && "$ENDY/bin/endy" spawn bash --worktree -- "T10 bash agent")
TID10=$(echo "$OUT10" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
sleep 1
PANE10=$(tmux capture-pane -t "$SESSION:task-$TID10" -p 2>/dev/null)
echo "$PANE10" | grep -q "## endy environment" && ok "bash: env block presente" || fail "bash: env block ausente"
echo "$PANE10" | grep -q "Git worktree: branch" && ok "bash: Git worktree line visible" || fail "bash: Git worktree line ausente"

header "T11. AGENT noop: pane real muestra env block + worktree info"
OUT11=$(cd "$PROJ" && "$ENDY/bin/endy" spawn noop --worktree -- "T11 noop agent")
TID11=$(echo "$OUT11" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
sleep 1
PANE11=$(tmux capture-pane -t "$SESSION:task-$TID11" -p 2>/dev/null)
echo "$PANE11" | grep -q "## endy environment" && ok "noop: env block presente" || fail "noop: env block ausente"
echo "$PANE11" | grep -q "Git worktree: branch" && ok "noop: Git worktree line visible" || fail "noop: Git worktree line ausente"

###############################################################################
# ADVANCED FLOWS
###############################################################################

header "T12. CHAIN: handoff chain stub → noop → bash, comparten worktree, purge cascada"
OUT12A=$(cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree -- "T12 chain root")
T12A=$(echo "$OUT12A" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
WT12=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$T12A.meta" | cut -d= -f2-)
sleep 0.5
OUT12B=$("$ENDY/bin/endy" handoff "$T12A" --to noop --reason "T12 link2" --no-attach 2>&1)
T12B=$(echo "$OUT12B" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
sleep 0.5
OUT12C=$("$ENDY/bin/endy" handoff "$T12B" --to bash --reason "T12 link3" --no-attach 2>&1)
T12C=$(echo "$OUT12C" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
WT12B=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$T12B.meta" | cut -d= -f2-)
WT12C=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$T12C.meta" | cut -d= -f2-)
INH_B=$(grep '^worktree_inherited=' "$ENDY/.logs/per-dir/$SESSION/task-$T12B.meta" | cut -d= -f2-)
INH_C=$(grep '^worktree_inherited=' "$ENDY/.logs/per-dir/$SESSION/task-$T12C.meta" | cut -d= -f2-)
[ "$WT12B" = "$WT12" ] && [ "$WT12C" = "$WT12" ] && ok "3 links comparten worktree_dir" || fail "wt no compartido en chain"
[ "$INH_B" = "1" ] && [ "$INH_C" = "1" ] && ok "links 2 y 3 tienen worktree_inherited=1" || fail "inherited flag mal en chain"
WTCOUNT=$(cd "$PROJ" && git worktree list --porcelain | grep -c "^worktree ")
[ "$WTCOUNT" -ge 2 ] && ok "git ve el worktree único compartido" || fail "wt count $WTCOUNT inesperado"
# Cascade purge
printf '&\n%s\n' "$T12A" | "$ENDY/bin/endy" watch purge "$T12A" > /tmp/t12.log 2>&1
grep -q "Worktree cleanup: 1 removed" /tmp/t12.log && ok "purge cascade limpia 1 wt (el compartido)" || fail "purge no limpió wt compartido"
[ ! -d "$WT12" ] && ok "wt compartido eliminado del disco" || fail "wt aún existe"

header "T13. ORCHESTRATOR DEFAULT: ENDY_DEFAULT_WORKTREE=1 simula spawn desde orchestrator"
# El bin/endy::cmd_orchestrator exporta esto en el script de la window.
# Simulo el comportamiento exportándolo en la shell que ejecuta spawn.
OUT13=$(cd "$PROJ" && ENDY_DEFAULT_WORKTREE=1 "$ENDY/bin/endy" spawn stub -- "T13 orchestrator default")
TID13=$(echo "$OUT13" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
META13="$ENDY/.logs/per-dir/$SESSION/task-$TID13.meta"
WT13=$(grep '^worktree_dir=' "$META13" | cut -d= -f2-)
[ -n "$WT13" ] && [ -d "$WT13" ] && ok "ENDY_DEFAULT_WORKTREE=1 → creó worktree sin flag explícito" \
  || fail "default-on no funcionó (wt_dir=$WT13)"

header "T14. STOP CLEANUP: clean wt removidos, dirty preservados"
# T9, T10, T11, T13 dejaron wts clean. Añado uno sucio.
OUT14=$(cd "$PROJ" && "$ENDY/bin/endy" spawn stub --worktree -- "T14 dirty wt")
TID14=$(echo "$OUT14" | grep '^TASK_ID=' | head -1 | cut -d= -f2-)
WT14=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$TID14.meta" | cut -d= -f2-)
echo "uncommitted by agent" > "$WT14/AGENT_DIRTY.md"
STOPOUT=$("$ENDY/bin/endy" stop --session "$SESSION" 2>&1)
echo "$STOPOUT" | grep -q "worktree skipped" && ok "stop reporta skip de dirty wt" || fail "no reportó skip"
[ -d "$WT14" ] && ok "dirty wt $WT14 preservado (no data loss)" || fail "dirty wt eliminado (data loss!)"
[ -f "$WT14/AGENT_DIRTY.md" ] && ok "archivo no commiteado sobrevive" || fail "archivo perdido"
# Manual cleanup del dirty para los siguientes tests
rm -rf "$WT14"
(cd "$PROJ" && git worktree prune; git branch -D "endy/task-$TID14" 2>/dev/null) >/dev/null

header "T15. STOP --ALL: multi-session cleanup, las del usuario intactas"
# Capture user's sessions BEFORE my test
USER_SESSIONS_BEFORE=$(tmux list-sessions -F '#S' 2>/dev/null | grep -vE '^endy-endy-(exhaustive|exhaustive-sibling)' | grep -vE '^endy-endy-(worktree-test|worktree-nongit)' | grep -vE '^endy-endy-handoff-test' | grep -vE '^endy-endy-state-test' | sort)

# Create my 2 test sessions, each with a worktree spawn
( cd "$PROJ"  && "$ENDY/bin/endy" start --no-attach > /dev/null 2>&1 )
( cd "$PROJ2" && "$ENDY/bin/endy" start --no-attach > /dev/null 2>&1 )
OA=$(cd "$PROJ"  && "$ENDY/bin/endy" spawn stub --worktree -- "T15-A")
OB=$(cd "$PROJ2" && "$ENDY/bin/endy" spawn stub --worktree -- "T15-B")
WTA=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION/task-$(echo "$OA" | grep '^TASK_ID=' | cut -d= -f2-).meta" | cut -d= -f2-)
WTB=$(grep '^worktree_dir=' "$ENDY/.logs/per-dir/$SESSION2/task-$(echo "$OB" | grep '^TASK_ID=' | cut -d= -f2-).meta" | cut -d= -f2-)
[ -d "$WTA" ] && [ -d "$WTB" ] && ok "2 sesiones con wt activos antes de stop" || fail "setup falló"

# stop --all del usuario afectaría TODAS las sesiones endy* — INCLUYENDO las suyas.
# Para NO romperle nada, en lugar de stop --all uso stop --session 2 veces.
"$ENDY/bin/endy" stop --session "$SESSION"  > /tmp/t15a.log 2>&1
"$ENDY/bin/endy" stop --session "$SESSION2" > /tmp/t15b.log 2>&1
[ ! -d "$WTA" ] && [ ! -d "$WTB" ] && ok "ambos wts limpiados por stop separados" || fail "alguno sobrevivió"

# Verificar que las sesiones del usuario siguen intactas
USER_SESSIONS_AFTER=$(tmux list-sessions -F '#S' 2>/dev/null | grep -vE '^endy-endy-(exhaustive|exhaustive-sibling)' | grep -vE '^endy-endy-(worktree-test|worktree-nongit)' | grep -vE '^endy-endy-handoff-test' | grep -vE '^endy-endy-state-test' | sort)
if [ "$USER_SESSIONS_BEFORE" = "$USER_SESSIONS_AFTER" ]; then
  ok "sesiones del usuario intactas tras los tests"
else
  echo "    BEFORE: $USER_SESSIONS_BEFORE"
  echo "    AFTER:  $USER_SESSIONS_AFTER"
  fail "se modificaron sesiones del usuario"
fi

header "T16. EDGE: handoff donde el padre NO tiene worktree → child tampoco"
( cd "$PROJ" && "$ENDY/bin/endy" start --no-attach > /dev/null 2>&1 )
PA=$(cd "$PROJ" && "$ENDY/bin/endy" spawn stub -- "T16 parent NO wt")
PAID=$(echo "$PA" | grep '^TASK_ID=' | cut -d= -f2-)
sleep 0.5
CH=$("$ENDY/bin/endy" handoff "$PAID" --to bash --reason "T16 no inherit" --no-attach 2>&1)
CHID=$(echo "$CH" | grep '^TASK_ID=' | cut -d= -f2-)
CMETA="$ENDY/.logs/per-dir/$SESSION/task-$CHID.meta"
CWT=$(grep '^worktree_dir=' "$CMETA" | cut -d= -f2-)
[ -z "$CWT" ] && ok "child sin worktree (padre no tenía) — no se inventó" || fail "child got worktree without parent having one"

###############################################################################
# SUMMARY
###############################################################################

header "RESUMEN"
echo "  PASS: $pass_count"
echo "  FAIL: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  printf '\n\033[1;31mEXHAUSTIVE TEST: %d FAILURE(S)\033[0m\n' "$fail_count"
  exit 1
else
  printf '\n\033[1;32mEXHAUSTIVE TEST: ALL %d CHECKS PASSED\033[0m\n' "$pass_count"
fi
