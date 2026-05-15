#!/usr/bin/env bash
# endy install — wires this project into the live agent dirs (idempotent).
#
# Steps (each is announced before running; one confirmation up front):
#   1. ~/.codex/agents/                  ← symlink each codex/agents/*.toml
#   2. Skills — symlink each codex/skills/<skill>/ into every CLI's actual
#      auto-discovery path:
#        ~/.agents/skills/<skill>/       Codex (canonical, per agentskills.io)
#        ~/.codex/skills/<skill>/        Codex (legacy back-compat)
#        ~/.claude/skills/<skill>/       Claude Code (live change detection)
#        ~/.hermes/skills/<skill>/       Hermes (auto-registers as /slash)
#      OpenCode picks them up via the Claude-Code compat path. Gemini CLI
#      doesn't have a skills directory — it loads context via GEMINI.md.
#   3. ~/.config/opencode/agents/        ← symlink each opencode/agents/*.md
#   4. ~/.commandcode/agents/            ← symlink each commandcode/agents/*.md
#   5. Memory hooks so every CLI auto-loads endy context on startup:
#        ~/.codex/AGENTS.md              ← symlink to ENDY_ROOT/AGENTS.md
#        ~/.commandcode/AGENTS.md        ← symlink to ENDY_ROOT/AGENTS.md
#        ~/.config/opencode/AGENTS.md    ← symlink to ENDY_ROOT/AGENTS.md
#        ~/.claude/CLAUDE.md             ← append marked endy block (preserves
#                                          user prefs above/below the markers)
#        ~/.gemini/GEMINI.md             ← append marked endy block
#        ~/.hermes/SOUL.md               ← append marked endy block
#   6. ~/.local/bin/endy                 ← symlink so `endy` is on PATH
#   7. Shell completion (zsh + bash)    ← sourced from rc file
#   8. ~/.codex/config.toml              ← append/refresh endy block (currently
#                                          MCP servers commented out — hybrid
#                                          bash mode is active)
#
# Files mentioned in step 5 are managed in two modes:
#   - SYMLINK targets (codex/cmd/opencode AGENTS.md): any existing file is
#     moved aside as .bak.<ts> and replaced with a symlink to ENDY_ROOT/AGENTS.md.
#     Re-running just refreshes the symlink — no backup churn.
#   - APPEND targets (claude/gemini/hermes): a `# >>> endy v0.1` marked block
#     is appended on first run and replaced in-place on subsequent runs. The
#     user's content outside the markers is left untouched. This is the right
#     mode for files that double as personal-preferences memory.
#
# Re-running this script is safe and idempotent.

set -euo pipefail

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%s)"

# --yes / -y skips the interactive confirmation prompt. Useful for CI,
# Docker images, and `curl | bash` quickstart flows.
# --no-multiplexor skips the multiplexor bootstrap (you can install it yourself
# later or use endy with manual --to on every handoff).
ASSUME_YES=0
INSTALL_MULTIPLEXOR=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-multiplexor) INSTALL_MULTIPLEXOR=0 ;;
    -h|--help)
      cat <<EOF
endy install [--yes|-y] [--no-multiplexor]
  Symlink endy's agents/skills/AGENTS.md into the live agent dirs,
  put bin/endy on PATH, and bootstrap multiplexor (the routing policy
  endy hands off to). Idempotent — safe to re-run.

Options:
  --yes, -y            Assume yes for the confirmation prompt.
  --no-multiplexor     Skip the multiplexor bootstrap step entirely.
EOF
      exit 0 ;;
    *) printf 'install: unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

CODEX_DIR="${HOME}/.codex"
CODEX_SKILLS_DIR="${CODEX_DIR}/skills"        # legacy Codex skills path (kept for back-compat)
AGENTSKILLS_DIR="${HOME}/.agents/skills"      # canonical path per agentskills.io — Codex scans this
OPENCODE_DIR="${HOME}/.config/opencode"
CMDCODE_DIR="${HOME}/.commandcode"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SKILLS_DIR="${CLAUDE_DIR}/skills"
GEMINI_DIR="${HOME}/.gemini"
HERMES_DIR="${HOME}/.hermes"
HERMES_SKILLS_DIR="${HERMES_DIR}/skills"
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
  ${ENDY_ROOT}/codex/skills/<name>/        →  ${AGENTSKILLS_DIR}/<name>/  (Codex canonical)
                                           +  ${CODEX_SKILLS_DIR}/<name>/  (Codex legacy)
                                           +  ${CLAUDE_SKILLS_DIR}/<name>/ (Claude Code)
                                           +  ${HERMES_SKILLS_DIR}/<name>/ (Hermes)
  ${ENDY_ROOT}/opencode/agents/*.md        →  ${OPENCODE_DIR}/agents/
  ${ENDY_ROOT}/commandcode/agents/*.md     →  ${CMDCODE_DIR}/agents/
  ${ENDY_ROOT}/AGENTS.md                   →  ${CODEX_DIR}/AGENTS.md
  ${ENDY_ROOT}/AGENTS.md                   →  ${CMDCODE_DIR}/AGENTS.md
  ${ENDY_ROOT}/AGENTS.md                   →  ${OPENCODE_DIR}/AGENTS.md
  ${ENDY_ROOT}/bin/endy                    →  ${LOCAL_BIN}/endy   (if confirmed)

Will append/refresh marked endy block in (preserves your existing prefs):
  ${CLAUDE_DIR}/CLAUDE.md   (Claude Code memory)
  ${GEMINI_DIR}/GEMINI.md   (Gemini CLI memory)
  ${HERMES_DIR}/SOUL.md     (Hermes memory)

Will modify (with backup):
  ${CODEX_CONFIG}   (append/replace endy v0.1 block)

Will also bootstrap multiplexor (the routing policy for endy handoff):
  pip install --user endy-multiplexor   (from PyPI or local clone, if not present)
  multiplexor init                      (creates ~/.config/multiplexor/config.yaml)
  ENDY_HANDOFF_RESOLVER                 (export added to your shell startup)
  (pass --no-multiplexor to skip)

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

say "2/8 Skills (agentskills.io standard — auto-discovered by every CLI) …"
# Each endy skill is a directory with SKILL.md + frontmatter. Per official
# docs (May 2026):
#   - Codex scans $HOME/.agents/skills/ (canonical agentskills.io path) and
#     $CWD/.agents/skills/ from the project. The old $HOME/.codex/skills/
#     was never a documented location — we keep it as a back-compat link
#     in case some users rely on it, but the real wire is .agents/skills/.
#   - Claude Code scans $HOME/.claude/skills/ (auto-discovers, live change
#     detection).
#   - Hermes scans $HOME/.hermes/skills/ (each skill auto-registers as a
#     /slash-command).
#   - OpenCode reads skills via its Claude Code compat path (~/.claude/skills/)
#     when no native skills dir is configured.
#   - Gemini CLI loads context via GEMINI.md imports, not a skills dir.
# So we symlink each skill into all four canonical homes. Same SKILL.md,
# four pickup paths.
link_skill_into() {
  local skill_src="$1" base="$2"
  local skill_name; skill_name="$(basename "$skill_src")"
  mkdir -p "$base"
  local target="${base}/${skill_name}"
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
}

shopt -s nullglob
for skill_src in "${ENDY_ROOT}/codex/skills"/*/; do
  [[ -d "$skill_src" ]] || continue
  link_skill_into "${skill_src%/}" "${AGENTSKILLS_DIR}"     # Codex canonical
  link_skill_into "${skill_src%/}" "${CODEX_SKILLS_DIR}"    # Codex legacy (back-compat)
  link_skill_into "${skill_src%/}" "${CLAUDE_SKILLS_DIR}"   # Claude Code
  link_skill_into "${skill_src%/}" "${HERMES_SKILLS_DIR}"   # Hermes (auto /slash-command)
done
shopt -u nullglob

say "3/8 OpenCode agents …"
link_dir "${ENDY_ROOT}/opencode/agents" "${OPENCODE_DIR}/agents" md

say "4/8 CommandCode agents …"
link_dir "${ENDY_ROOT}/commandcode/agents" "${CMDCODE_DIR}/agents" md

# ----------------------------------------------------------------------------
# 5. Symlink AGENTS.md so every agent loads endy context globally.
# ----------------------------------------------------------------------------
say "5/8 Memory hooks (every CLI auto-loads endy context on startup) …"
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

# Append/refresh a marked endy block at the bottom of a memory file the user
# also uses for their own preferences (Claude CLAUDE.md, Gemini GEMINI.md,
# Hermes SOUL.md). Content outside the markers is preserved verbatim. The
# block is rewritten on every install run so context updates flow through.
endy_block_label="endy v0.1"
append_endy_block() {
  local target="$1" comment_open comment_close
  case "$target" in
    *.md|*.markdown) comment_open='<!--'; comment_close='-->' ;;
    *)               comment_open='#';    comment_close='' ;;
  esac
  local marker_begin="${comment_open} >>> ${endy_block_label} (managed by endy install — do not edit between markers) ${comment_close}"
  local marker_end="${comment_open} <<< ${endy_block_label} ${comment_close}"
  local block
  block=$(cat <<BLOCK
${marker_begin}

You're running inside **endy**, a tmux-based control plane that hands a coding
task between CLI agents (codex, opencode, cmd, hermes, claude, gemini) when
one runs out of free tier.

On startup, glance at:
- ${ENDY_ROOT}/AGENTS.md — full reference (delegation primitives, personas, CLI gotchas)
- \`endy watch tree\` — what other agents are working on right now in this project
- \`endy doctor\` — which agents are installed + which sessions are live

When you hit a rate limit, tell the user to run:
\`endy handoff <task-id> --to <other-agent> --reason "<short>"\`
The next agent picks up with your prompt + the last 80 lines of your output.
You can list yourself with \`endy watch list\` to find your task-id.

${marker_end}
BLOCK
)

  mkdir -p "$(dirname "$target")"
  if [[ ! -e "$target" ]]; then
    printf '%s\n' "$block" > "$target"
    ok "created $target with endy block"
    return 0
  fi

  # Strip any prior endy block (between markers) and append fresh.
  local tmp
  tmp="$(mktemp)"
  awk -v b="$marker_begin" -v e="$marker_end" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip   { print }
  ' "$target" > "$tmp"
  # Trim trailing blank lines so we don't keep accreting whitespace.
  sed -i -e ':a' -e '/^$/{$d;N;ba' -e '}' "$tmp" 2>/dev/null || true
  # Re-append.
  printf '%s\n\n%s\n' "$(cat "$tmp")" "$block" > "$target"
  rm -f "$tmp"
  ok "refreshed endy block in $target"
}

# 5a — symlink AGENTS.md for the CLIs that use the AGENTS.md convention
#      (codex, cmd, opencode). They expect endy to own that file globally.
link_one_file "${ENDY_ROOT}/AGENTS.md" "${CODEX_DIR}/AGENTS.md"
mkdir -p "${CMDCODE_DIR}"
link_one_file "${ENDY_ROOT}/AGENTS.md" "${CMDCODE_DIR}/AGENTS.md"
mkdir -p "${OPENCODE_DIR}"
link_one_file "${ENDY_ROOT}/AGENTS.md" "${OPENCODE_DIR}/AGENTS.md"

# 5b — append-block for CLIs whose memory file doubles as user preferences
#      (Claude, Gemini, Hermes). We never clobber the user's own content.
append_endy_block "${CLAUDE_DIR}/CLAUDE.md"
append_endy_block "${GEMINI_DIR}/GEMINI.md"
append_endy_block "${HERMES_DIR}/SOUL.md"

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
# 9. Bootstrap multiplexor — the routing policy endy hands off to.
# ----------------------------------------------------------------------------
# Why this lives in endy install: the whole pitch is "never run out of tier".
# Without a router, endy handoff still works but you have to pass --to every
# time. Wiring multiplexor here means `endy handoff <id>` (no --to) just works.
#
# Strategy (in order of preference):
#   1. If `multiplexor-next-provider` is already on PATH: nothing to do.
#   2. Look for a local multiplexor checkout — sibling dir of endy, or the
#      MULTIPLEXOR_REPO env var. pip install --user -e from there. This is
#      the developer-friendly path.
#   3. pip install --user from PyPI / GitHub URL fallback.
#
# Then: multiplexor init (no-op if config exists) + add ENDY_HANDOFF_RESOLVER
# to the user's shell rc as a separate marked block.
#
# Soft-fails on every error. multiplexor is optional infra — if pip is missing
# or offline, the install still finishes and the user gets a clear warning
# pointing at the manual steps.

if [[ "$INSTALL_MULTIPLEXOR" == "1" ]]; then
  say "9/9 multiplexor (routing policy for endy handoff) …"

  multiplexor_install_status="skipped"
  multiplexor_install_reason=""

  # Locate a source for multiplexor. Order: explicit env, sibling dir, PyPI.
  # The sibling-dir path keeps the developer workflow snappy. PyPI is the
  # default for end users (`pip install endy-multiplexor` — the plain
  # `multiplexor` name on PyPI is owned by an unrelated 2020 websockets
  # package). GitHub URL stays as a last-resort fallback in case PyPI is
  # down or the user has a custom index.
  MULTIPLEXOR_SRC=""
  MULTIPLEXOR_REMOTE="endy-multiplexor"
  MULTIPLEXOR_REMOTE_FALLBACK="git+https://github.com/trentisiete/multiplexor"
  if [[ -n "${MULTIPLEXOR_REPO:-}" && -f "${MULTIPLEXOR_REPO}/pyproject.toml" ]]; then
    MULTIPLEXOR_SRC="$MULTIPLEXOR_REPO"
  elif [[ -f "${ENDY_ROOT}/../multiplexor/pyproject.toml" ]]; then
    MULTIPLEXOR_SRC="$(cd "${ENDY_ROOT}/../multiplexor" && pwd)"
  fi

  # Pick an installer. Order of preference:
  #   1. pipx  — cleanest, isolated env, binaries on PATH automatically.
  #   2. uv tool install  — modern, fast, same outcome as pipx.
  #   3. pip --user  — universal fallback.
  # The first one that works wins; subsequent ones are not tried.
  INSTALLER=""
  INSTALLER_KIND=""
  if command -v pipx >/dev/null 2>&1; then
    INSTALLER="pipx"; INSTALLER_KIND="pipx"
  elif command -v uv >/dev/null 2>&1; then
    INSTALLER="uv"; INSTALLER_KIND="uv"
  elif command -v pip3 >/dev/null 2>&1; then
    INSTALLER="$(command -v pip3)"; INSTALLER_KIND="pip"
  elif command -v pip >/dev/null 2>&1; then
    INSTALLER="$(command -v pip)"; INSTALLER_KIND="pip"
  fi

  if command -v multiplexor-next-provider >/dev/null 2>&1; then
    ok "multiplexor-next-provider already on PATH ($(command -v multiplexor-next-provider))"
    multiplexor_install_status="already-installed"
  elif [[ -z "$INSTALLER" ]]; then
    warn "no installer found (pipx / uv / pip) — skipping multiplexor install"
    warn "  install one of these, then re-run 'endy install':"
    warn "    Debian/Ubuntu:  sudo apt install pipx  (or python3-pip)"
    warn "    macOS:          brew install pipx       (or uv)"
    warn "    Anywhere:       curl -LsSf https://astral.sh/uv/install.sh | sh"
    multiplexor_install_reason="no installer (pipx/uv/pip) found"
  else
    # Build the install command per installer kind. SOURCE is either a local
    # directory or a git URL; pipx and uv accept both shapes natively, pip
    # needs an extra `-e` for the editable-from-local path.
    SOURCE="${MULTIPLEXOR_SRC:-$MULTIPLEXOR_REMOTE}"
    SOURCE_KIND="GitHub"; [[ -n "$MULTIPLEXOR_SRC" ]] && SOURCE_KIND="local checkout: $MULTIPLEXOR_SRC"
    say "  installing multiplexor via $INSTALLER_KIND from $SOURCE_KIND"
    case "$INSTALLER_KIND" in
      pipx)
        # pipx install puts both `multiplexor` and `multiplexor-next-provider`
        # in ~/.local/bin (or pipx's bin dir, which it ensures is on PATH).
        if pipx install --force "$SOURCE" 2>/tmp/endy-mxp-pip.log; then
          ok "multiplexor installed via pipx"
          multiplexor_install_status="installed-pipx"
        else
          warn "pipx install failed — see /tmp/endy-mxp-pip.log"
          multiplexor_install_reason="pipx install failed"
        fi
        ;;
      uv)
        # uv tool install is pipx's equivalent in uv. Drops binaries in
        # ~/.local/bin/ via `uv tool` defaults.
        if uv tool install --force "$SOURCE" >/tmp/endy-mxp-pip.log 2>&1; then
          ok "multiplexor installed via uv tool"
          multiplexor_install_status="installed-uv"
        else
          warn "uv tool install failed — see /tmp/endy-mxp-pip.log"
          multiplexor_install_reason="uv tool install failed"
        fi
        ;;
      pip)
        # pip needs --user, and -e for editable installs of local dirs.
        pip_args=(install --user --quiet)
        [[ -n "$MULTIPLEXOR_SRC" ]] && pip_args+=(-e)
        if "$INSTALLER" "${pip_args[@]}" "$SOURCE" 2>/tmp/endy-mxp-pip.log; then
          ok "multiplexor installed via pip --user"
          multiplexor_install_status="installed-pip"
        else
          warn "pip install failed — see /tmp/endy-mxp-pip.log"
          multiplexor_install_reason="pip install failed"
        fi
        ;;
    esac
  fi

  # If the install succeeded just now (i.e. the binary was NOT on PATH at the
  # top of this block but should be after pip --user), re-check PATH. pip
  # --user puts scripts in ~/.local/bin which we already added to PATH above,
  # but for the current process we need to hash -r.
  hash -r 2>/dev/null || true

  if command -v multiplexor >/dev/null 2>&1; then
    # multiplexor init is idempotent — it's a no-op if the config exists.
    if multiplexor init 2>/dev/null | grep -qE 'Created|already exists'; then
      ok "multiplexor config seeded"
    else
      # Don't fail just because the first run prints something unexpected.
      ok "multiplexor init ran"
    fi
  fi

  # Set ENDY_HANDOFF_RESOLVER in the user's shell startup files so it
  # propagates to BOTH interactive and non-interactive shells. Two-block
  # strategy because shells differ on what they source when:
  #
  #   bash interactive non-login:  ~/.bashrc
  #   bash login (incl. bash -lc): ~/.profile (or ~/.bash_profile if present)
  #                                Ubuntu's ~/.bashrc has an early-return
  #                                guard for non-interactive shells, so a
  #                                block in ~/.bashrc alone misses bash -lc.
  #   zsh (all modes):             ~/.zshenv — single best target.
  #
  # Idempotent: re-running rewrites the same managed block in place.
  resolver_begin="# >>> endy ENDY_HANDOFF_RESOLVER (managed by endy install)"
  resolver_end="# <<< endy ENDY_HANDOFF_RESOLVER"

  write_resolver_block() {
    local target="$1"
    [[ -z "$target" ]] && return 0
    touch "$target"
    local tmp; tmp="$(mktemp)"
    awk -v b="$resolver_begin" -v e="$resolver_end" '
      $0 == b { skip=1; next }
      $0 == e { skip=0; next }
      !skip   { print }
    ' "$target" > "$tmp"
    {
      cat "$tmp"
      printf '\n%s\n' "$resolver_begin"
      printf 'export ENDY_HANDOFF_RESOLVER="multiplexor-next-provider"\n'
      printf '%s\n'   "$resolver_end"
    } > "$target"
    rm -f "$tmp"
    ok "wired ENDY_HANDOFF_RESOLVER in $target"
  }

  case "$(basename "${SHELL:-zsh}")" in
    zsh)
      # ~/.zshenv is sourced for ALL zsh modes (interactive, login,
      # non-interactive). One file, full coverage.
      write_resolver_block "${HOME}/.zshenv"
      ;;
    bash)
      # Two targets:
      #   ~/.bashrc       → interactive non-login (e.g. opening a terminal)
      #   ~/.profile or ~/.bash_profile → login (incl. bash -lc 'cmd')
      # Both export the same value; idempotent. ~/.bash_profile shadows
      # ~/.profile when present, so write to whichever exists.
      bash_profile_target="${HOME}/.profile"
      [[ -f "${HOME}/.bash_profile" ]] && bash_profile_target="${HOME}/.bash_profile"
      write_resolver_block "${HOME}/.bashrc"
      write_resolver_block "$bash_profile_target"
      ;;
    *)
      warn "unknown shell '${SHELL:-?}' — add this to your shell startup manually:"
      printf '       export ENDY_HANDOFF_RESOLVER="multiplexor-next-provider"\n' >&2
      ;;
  esac

  if [[ -n "$multiplexor_install_reason" ]]; then
    warn "multiplexor was NOT installed: $multiplexor_install_reason"
    warn "  endy handoff still works with --to <agent>; install multiplexor later for auto-routing."
  fi
else
  say "9/9 multiplexor … skipped (--no-multiplexor)"
fi

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
