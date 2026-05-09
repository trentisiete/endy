#!/usr/bin/env bash
# endy install — wires this project into the live agent dirs (idempotent).
#
# Steps (each is announced before running; one confirmation up front):
#   1. ~/.codex/agents/                  ← symlink each codex/agents/*.toml
#   2. ~/.codex/skills/<skill>/          ← symlink each codex/skills/* dir
#   3. ~/.config/opencode/agents/        ← symlink each opencode/agents/*.md
#   4. ~/.commandcode/agents/            ← symlink each commandcode/agents/*.md
#   5. ~/.codex/config.toml              ← append/refresh endy block (currently
#                                          MCP servers commented out — hybrid
#                                          bash mode is active)
#
# Real files at target paths are moved aside as .bak.<ts>, not deleted.
# Re-running this script is safe and idempotent.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%s)"

# --yes / -y skips the interactive confirmation prompt. Useful for CI,
# Docker images, and `curl | bash` quickstart flows.
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      cat <<EOF
endy install [--yes|-y]
  Symlink endy's agents/skills/AGENTS.md into the live agent dirs and
  put bin/endy on PATH. Idempotent — safe to re-run.
EOF
      exit 0 ;;
    *) printf 'install: unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

CODEX_DIR="${HOME}/.codex"
CODEX_SKILLS_DIR="${CODEX_DIR}/skills"
OPENCODE_DIR="${HOME}/.config/opencode"
CMDCODE_DIR="${HOME}/.commandcode"
LOCAL_BIN="${HOME}/.local/bin"

CODEX_CONFIG="${CODEX_DIR}/config.toml"
MARKER_BEGIN="# >>> endy v0.1 (managed by ${ENDY_ROOT}/scripts/install.sh)"
MARKER_END="# <<< endy v0.1"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

confirm() {
  printf '\033[1m%s\033[0m [y/N] ' "$1"
  read -r reply
  case "$reply" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# 0. Sanity
# ----------------------------------------------------------------------------
[[ -d "$CODEX_DIR"    ]] || warn "no ~/.codex yet — will create it"
[[ -d "$OPENCODE_DIR" ]] || warn "no ~/.config/opencode — will create on link"
mkdir -p "$CODEX_DIR"

cat <<EOF

endy install
============
ENDY_ROOT = ${ENDY_ROOT}

Will symlink:
  ${ENDY_ROOT}/codex/agents/*.toml         →  ${CODEX_DIR}/agents/
  ${ENDY_ROOT}/codex/skills/*              →  ${CODEX_SKILLS_DIR}/
  ${ENDY_ROOT}/opencode/agents/*.md        →  ${OPENCODE_DIR}/agents/
  ${ENDY_ROOT}/commandcode/agents/*.md     →  ${CMDCODE_DIR}/agents/
  ${ENDY_ROOT}/AGENTS.md                   →  ${CODEX_DIR}/AGENTS.md
  ${ENDY_ROOT}/AGENTS.md                   →  ${CMDCODE_DIR}/AGENTS.md
  ${ENDY_ROOT}/bin/endy                    →  ${LOCAL_BIN}/endy   (if confirmed)

Will modify (with backup):
  ${CODEX_CONFIG}   (append/replace endy v0.1 block)

EOF

if [[ "$ASSUME_YES" == "1" ]]; then
  ok "auto-confirmed via --yes"
else
  confirm "Proceed?" || { say "aborted"; exit 0; }
fi

# ----------------------------------------------------------------------------
# 1. Symlink agent personas
# ----------------------------------------------------------------------------
link_dir() {
  local src="$1" dst="$2" ext="$3"   # ext: "toml" or "md"
  mkdir -p "$dst"
  shopt -s nullglob
  for f in "$src"/*."$ext"; do
    [[ -e "$f" ]] || continue
    local base="$(basename "$f")"
    # Skip our own documentation files — they're for the repo, not the agent runtime.
    [[ "$base" == "README.md" ]] && continue
    local target="${dst}/${base}"
    if [[ -L "$target" ]]; then
      ln -sfn "$f" "$target"
      ok "relinked $target"
    elif [[ -e "$target" ]]; then
      mv "$target" "${target}.bak.${TS}"
      ln -s "$f" "$target"
      ok "linked $target (existing file → ${target}.bak.${TS})"
    else
      ln -s "$f" "$target"
      ok "linked $target"
    fi
  done
  shopt -u nullglob
}

say "1/8 Codex agents …"
link_dir "${ENDY_ROOT}/codex/agents" "${CODEX_DIR}/agents" toml

say "2/8 Codex skills …"
mkdir -p "${CODEX_SKILLS_DIR}"
shopt -s nullglob
for skill_src in "${ENDY_ROOT}/codex/skills"/*/; do
  [[ -d "$skill_src" ]] || continue
  skill_name="$(basename "$skill_src")"
  target="${CODEX_SKILLS_DIR}/${skill_name}"
  if [[ -L "$target" ]]; then
    ln -sfn "${skill_src%/}" "$target"
    ok "relinked $target"
  elif [[ -e "$target" ]]; then
    mv "$target" "${target}.bak.${TS}"
    ln -s "${skill_src%/}" "$target"
    ok "linked $target (existing → ${target}.bak.${TS})"
  else
    ln -s "${skill_src%/}" "$target"
    ok "linked $target"
  fi
done
shopt -u nullglob

say "3/8 OpenCode agents …"
link_dir "${ENDY_ROOT}/opencode/agents" "${OPENCODE_DIR}/agents" md

say "4/8 CommandCode agents …"
link_dir "${ENDY_ROOT}/commandcode/agents" "${CMDCODE_DIR}/agents" md

# ----------------------------------------------------------------------------
# 5. Symlink AGENTS.md so every agent loads endy context globally.
# ----------------------------------------------------------------------------
say "5/8 Global AGENTS.md (so codex/cmd auto-load endy context) …"
link_one_file() {
  local src="$1" target="$2"
  if [[ -L "$target" ]]; then
    ln -sfn "$src" "$target"
    ok "relinked $target"
  elif [[ -e "$target" ]]; then
    mv "$target" "${target}.bak.${TS}"
    ln -s "$src" "$target"
    ok "linked $target (existing → ${target}.bak.${TS})"
  else
    ln -s "$src" "$target"
    ok "linked $target"
  fi
}
link_one_file "${ENDY_ROOT}/AGENTS.md" "${CODEX_DIR}/AGENTS.md"
mkdir -p "${CMDCODE_DIR}"
link_one_file "${ENDY_ROOT}/AGENTS.md" "${CMDCODE_DIR}/AGENTS.md"

# ----------------------------------------------------------------------------
# 6. Optionally put `endy` on PATH via ~/.local/bin.
# ----------------------------------------------------------------------------
say "6/8 endy CLI entry-point …"
mkdir -p "${LOCAL_BIN}"
link_one_file "${ENDY_ROOT}/bin/endy" "${LOCAL_BIN}/endy"
case ":$PATH:" in
  *":${LOCAL_BIN}:"*) ok "${LOCAL_BIN} already on PATH" ;;
  *)
    rc=""
    case "$(basename "${SHELL:-zsh}")" in
      zsh)  rc="${HOME}/.zshrc"  ;;
      bash) rc="${HOME}/.bashrc" ;;
      *)    rc="" ;;
    esac
    path_line='export PATH="$HOME/.local/bin:$PATH"'
    if [[ -n "$rc" ]]; then
      touch "$rc"
      if grep -Fq "${LOCAL_BIN}" "$rc" || grep -Fq "$path_line" "$rc"; then
        ok "${LOCAL_BIN} already configured in $rc"
      else
        {
          printf '\n# >>> endy PATH (managed by endy install)\n'
          printf '%s\n' "$path_line"
          printf '# <<< endy PATH\n'
        } >> "$rc"
        ok "added ${LOCAL_BIN} to PATH in $rc"
      fi
      warn "reload your shell before using plain 'endy': exec \"\$SHELL\" -l"
    else
      warn "${LOCAL_BIN} is NOT on your PATH — add this to your shell rc:"
      printf '       %s\n' "$path_line" >&2
    fi
    ;;
esac

# ----------------------------------------------------------------------------
# 7. Append/replace the MCP-server block in ~/.codex/config.toml
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# 7. Shell completion — offer to add a source line to the user's rc file.
# ----------------------------------------------------------------------------
say "7/8 Shell completion (zsh + bash) …"
COMPLETION_SRC="${ENDY_ROOT}/scripts/endy-completion.sh"
if [[ -f "$COMPLETION_SRC" ]]; then
  # Pick the rc that matches the user's login shell. Default to zsh on macOS.
  rc=""
  case "$(basename "${SHELL:-zsh}")" in
    zsh)  rc="${HOME}/.zshrc"  ;;
    bash) rc="${HOME}/.bashrc" ;;
    *)    rc="" ;;
  esac
  src_line="source \"${COMPLETION_SRC}\""
  bashcompinit_block="autoload -Uz compinit bashcompinit && compinit && bashcompinit"
  if [[ -n "$rc" ]]; then
    if [[ -f "$rc" ]] && grep -Fq "$src_line" "$rc"; then
      ok "completion already sourced from $rc"
    else
      printf '\n# >>> endy completion (managed by endy install)\n' >> "$rc"
      if [[ "$(basename "$rc")" == ".zshrc" ]]; then
        # Ensure bashcompinit is enabled — only add if not already present.
        if ! grep -Fq "bashcompinit" "$rc" 2>/dev/null; then
          printf '%s\n' "$bashcompinit_block" >> "$rc"
        fi
      fi
      printf '%s\n' "$src_line"           >> "$rc"
      printf '# <<< endy completion\n'    >> "$rc"
      ok "added completion source line to $rc — restart your shell to pick it up"
    fi
  else
    warn "unknown shell '${SHELL:-?}' — source manually: $src_line"
  fi
else
  warn "completion script not found at $COMPLETION_SRC"
fi

# ----------------------------------------------------------------------------
# 8. Append/replace the MCP-server block in ~/.codex/config.toml
# ----------------------------------------------------------------------------
say "8/8 Codex MCP server config (currently commented out — bash mode active) …"

# Render the snippet with __ENDY_ROOT__ substituted.
RENDERED="$(sed "s|__ENDY_ROOT__|${ENDY_ROOT}|g" "${ENDY_ROOT}/codex/config.snippet.toml")"

# Backup once per run.
if [[ -f "$CODEX_CONFIG" ]]; then
  cp "$CODEX_CONFIG" "${CODEX_CONFIG}.bak.${TS}"
  ok "backed up ${CODEX_CONFIG} → ${CODEX_CONFIG}.bak.${TS}"
fi

# Strip any prior endy block, then append fresh.
TMP="$(mktemp)"
if [[ -f "$CODEX_CONFIG" ]]; then
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip   { print }
  ' "$CODEX_CONFIG" > "$TMP"
else
  : > "$TMP"
fi

{
  cat "$TMP"
  printf '\n%s\n%s\n%s\n' "$MARKER_BEGIN" "$RENDERED" "$MARKER_END"
} > "$CODEX_CONFIG"
rm -f "$TMP"
ok "Codex MCP block written"

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
cat <<EOF

$(ok "install complete")

You now have a single CLI:  endy
  endy doctor                  → check python3, tmux, agents, config, and sessions
  endy start                   → launch this cwd's per-dir tmux gateway
  endy overview                → launch the global all-session overview
  endy watch list              → see all tasks (status / agent / cwd / runtime / last)
  endy spawn opencode -- "..."  → fire a long detached task
  endy codex --root            → start codex from endy project root with full context
  endy help                    → all subcommands

If \`endy\` is not found in this terminal yet, reload your shell:
  exec "\$SHELL" -l

To flip the MCP path on later (still hybrid bash by default):
  cd ${ENDY_ROOT}/mcp-shims && npm install
  \$EDITOR ${ENDY_ROOT}/codex/config.snippet.toml   # uncomment the 3 blocks
  endy install                                       # re-run, idempotent
EOF
