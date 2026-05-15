#!/usr/bin/env bash
# Verifies `endy install` wires every CLI's memory file correctly:
# - AGENTS.md symlinks for codex / cmd / opencode (clean takeover, with .bak)
# - marked endy block appended to CLAUDE.md / GEMINI.md / SOUL.md
# - the user's existing preferences in those files survive untouched
# - re-running is idempotent (no block duplication)
#
# Runs install.sh with HOME pointed at a throwaway dir so the user's real
# config is never touched.

set -e
ENDY=/mnt/c/Users/maria/Downloads/Jose_lenovo/Proyectos/tools/endy

FAKE_HOME="$(mktemp -d)"
export HOME="$FAKE_HOME"
trap 'rm -rf "$FAKE_HOME"' EXIT

ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; exit 1; }
header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

header "0. seed fake HOME with user preferences"
mkdir -p "$HOME/.claude" "$HOME/.gemini" "$HOME/.hermes"
cat > "$HOME/.claude/CLAUDE.md" <<'PREFS'
# Mis preferencias

- Responde en castellano
- Indenta con 4 espacios
- No uses emojis
PREFS
cat > "$HOME/.gemini/GEMINI.md" <<'PREFS'
# Gemini preferences

Always cite sources.
PREFS
cat > "$HOME/.hermes/SOUL.md" <<'PREFS'
# Hermes soul

Be terse.
PREFS
ok "seeded user-prefs in CLAUDE.md / GEMINI.md / SOUL.md"

header "1. run endy install --yes"
"$ENDY/scripts/install.sh" --yes >/tmp/install.log 2>&1 || { cat /tmp/install.log; fail "install.sh failed"; }
ok "install.sh ran clean"

header "2. AGENTS.md symlinks for codex / cmd / opencode"
for target in "$HOME/.codex/AGENTS.md" "$HOME/.commandcode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"; do
  [[ -L "$target" ]] || fail "$target is not a symlink"
  resolved="$(readlink "$target")"
  [[ "$resolved" == "$ENDY/AGENTS.md" ]] || fail "$target → $resolved (expected $ENDY/AGENTS.md)"
  ok "$target → $ENDY/AGENTS.md"
done

header "3. CLAUDE.md keeps user prefs AND has endy block"
grep -q 'Responde en castellano' "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md lost user prefs"
grep -q 'No uses emojis'         "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md lost user prefs"
ok "CLAUDE.md user prefs preserved"
grep -q '>>> endy v0.1'           "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md missing endy begin marker"
grep -q '<<< endy v0.1'           "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md missing endy end marker"
grep -q "$ENDY/AGENTS.md"         "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md missing ENDY_ROOT pointer"
grep -q 'endy handoff'            "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md missing handoff hint"
ok "CLAUDE.md endy block present"

header "4. GEMINI.md keeps user prefs AND has endy block"
grep -q 'Always cite sources' "$HOME/.gemini/GEMINI.md" || fail "GEMINI.md lost user prefs"
grep -q '>>> endy v0.1'        "$HOME/.gemini/GEMINI.md" || fail "GEMINI.md missing endy block"
ok "GEMINI.md endy block + prefs preserved"

header "5. SOUL.md keeps user prefs AND has endy block"
grep -q 'Be terse'           "$HOME/.hermes/SOUL.md" || fail "SOUL.md lost user prefs"
grep -q '>>> endy v0.1'      "$HOME/.hermes/SOUL.md" || fail "SOUL.md missing endy block"
ok "SOUL.md endy block + prefs preserved"

header "6. re-run install is idempotent (block appears exactly once)"
"$ENDY/scripts/install.sh" --yes >/tmp/install.log 2>&1 || { cat /tmp/install.log; fail "second install failed"; }
for f in "$HOME/.claude/CLAUDE.md" "$HOME/.gemini/GEMINI.md" "$HOME/.hermes/SOUL.md"; do
  count_open=$(grep -c '>>> endy v0.1' "$f")
  count_close=$(grep -c '<<< endy v0.1' "$f")
  [[ "$count_open" == "1" && "$count_close" == "1" ]] \
    || fail "$f has $count_open begin / $count_close end markers (expected 1/1)"
  ok "$f: exactly one begin + one end marker after re-run"
done

header "7. AGENTS.md content reachable from each install path"
# Run each from its own dir to be sure the symlink resolves.
for target in "$HOME/.codex/AGENTS.md" "$HOME/.commandcode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"; do
  head -1 "$target" | grep -q "endy — multi-agent coding stack" \
    || fail "$target doesn't resolve to endy's AGENTS.md (got: $(head -1 "$target"))"
  ok "$target resolves correctly"
done

printf '\n\033[1;32mSMOKE TEST PASSED\033[0m\n'
