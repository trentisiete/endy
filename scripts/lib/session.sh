#!/usr/bin/env bash
# scripts/lib/session.sh — per-directory session name + log dir derivation.
#
# Sourced by bin/endy and the various spawn/watch/start scripts. Provides:
#
#   _endy_session_name <cwd>     prints the tmux session name for a cwd:
#                                  endy-<sanitized-basename>           if free / unique
#                                  endy-<sanitized-basename>-<hash4>   on collision or reserved name
#
#   _endy_log_dir <session>      prints the log dir path for a session name
#                                  (overview session "endy" -> $ENDY_ROOT/.logs;
#                                   any per-dir session     -> $ENDY_ROOT/.logs/per-dir/<session>)
#
#   _endy_resolve_session [cwd]  prints the active session for a cwd, picking
#                                a hash suffix proactively if needed.
#
#   _endy_short_hash <string>    prints a 4-hex-char digest of the input
#                                (uses shasum or openssl dgst — handles
#                                'openssl sha256' broken `head -c 4` bug).
#
# All callers should:
#   1. source this file once,
#   2. use _endy_resolve_session "$(pwd)" or honor $ENDY_SESSION if set,
#   3. use _endy_log_dir "$ENDY_SESSION" or honor $ENDY_LOG_DIR if set.

# ENDY_ROOT must be set by the caller before sourcing.
: "${ENDY_ROOT:?ENDY_ROOT must be set before sourcing session.sh}"

# Reserved names that must NOT be used as a per-dir session basename, to avoid
# collisions with the global overview session or future top-level subcommand
# windows.
_endy_reserved_session() {
  case "$1" in
    endy|endy-overview|endy-help|endy-tree|endy-watch|endy-docs) return 0 ;;
    *) return 1 ;;
  esac
}

# 4-hex-char digest. Works around `openssl sha256 | head -c 4` returning the
# literal "(std" prefix on macOS.
_endy_short_hash() {
  local s="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}' | head -c 4
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | awk '{print $1}' | head -c 4
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$s" | openssl dgst -sha256 | sed 's/.* //' | head -c 4
  else
    # Last-resort cksum (32-bit) — formatted to 4 hex chars.
    printf '%04x' $(($(printf '%s' "$s" | cksum | awk '{print $1}') & 0xffff))
  fi
}

# Sanitize a basename to be safe in a tmux session name: alphanumerics,
# underscore, dot and dash are kept; everything else collapses to a dash.
# Length-capped at 32 chars.
_endy_sanitize_basename() {
  local in="$1"
  local out
  out="$(printf '%s' "$in" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-//; s/-$//')"
  [[ -z "$out" ]] && out="root"
  out="${out:0:32}"
  printf '%s' "$out"
}

# _endy_session_name <cwd> [--hash|--force-hash]
# Default: returns "endy-<sanitized>" unless a tmux session of that name
# already exists for a DIFFERENT cwd, OR the basename is reserved — then
# appends a 4-hex-char hash of the absolute cwd.
_endy_session_name() {
  local cwd="${1:-$(pwd)}"
  local force_hash=0
  case "${2:-}" in --hash|--force-hash) force_hash=1 ;; esac

  # Resolve to absolute path for stable hashing without mutating the caller's cwd.
  local resolved
  resolved="$(cd "$cwd" 2>/dev/null && pwd)" && cwd="$resolved"

  local base; base="$(basename "$cwd")"
  local sanitized; sanitized="$(_endy_sanitize_basename "$base")"
  local candidate="endy-${sanitized}"

  if [[ "$force_hash" == "1" ]] || _endy_reserved_session "$candidate"; then
    candidate="${candidate}-$(_endy_short_hash "$cwd")"
    printf '%s' "$candidate"
    return 0
  fi

  # Check tmux for an existing session of this name. If it exists AND a
  # marker file inside our log dir says it belongs to a DIFFERENT cwd,
  # add a hash suffix to disambiguate.
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$candidate" 2>/dev/null; then
    local owner_marker="${ENDY_ROOT}/.logs/per-dir/${candidate}/.cwd"
    if [[ -f "$owner_marker" ]]; then
      local owner; owner="$(cat "$owner_marker" 2>/dev/null)"
      if [[ -n "$owner" && "$owner" != "$cwd" ]]; then
        candidate="${candidate}-$(_endy_short_hash "$cwd")"
      fi
    fi
  fi

  printf '%s' "$candidate"
}

# _endy_log_dir <session-name>
_endy_log_dir() {
  local session="${1:-endy}"
  if [[ "$session" == "endy" ]]; then
    printf '%s/.logs' "$ENDY_ROOT"
  else
    printf '%s/.logs/per-dir/%s' "$ENDY_ROOT" "$session"
  fi
}

# _endy_resolve_session [cwd]
# Honors $ENDY_SESSION if already set in the environment; otherwise
# derives from cwd.
_endy_resolve_session() {
  if [[ -n "${ENDY_SESSION:-}" ]]; then
    printf '%s' "$ENDY_SESSION"
    return 0
  fi
  _endy_session_name "${1:-$(pwd)}"
}

# _endy_resolve_log_dir
# Honors $ENDY_LOG_DIR; otherwise derives from $ENDY_SESSION (which must be
# resolved first by the caller).
_endy_resolve_log_dir() {
  if [[ -n "${ENDY_LOG_DIR:-}" ]]; then
    printf '%s' "$ENDY_LOG_DIR"
    return 0
  fi
  local s="${ENDY_SESSION:-endy}"
  _endy_log_dir "$s"
}

# _endy_list_per_dir_log_dirs
# Print every log dir endy knows about, one per line:
#   - the global $ENDY_ROOT/.logs (always first if it exists)
#   - every $ENDY_ROOT/.logs/per-dir/*/  subdir
_endy_list_per_dir_log_dirs() {
  local root="${ENDY_ROOT}/.logs"
  [[ -d "$root" ]] && printf '%s\n' "$root"
  shopt -s nullglob
  local d session_name
  for d in "${root}/per-dir"/*/; do
    [[ -d "$d" ]] || continue
    if [[ "${LIVE_ONLY:-0}" == "1" ]]; then
      session_name="$(basename "${d%/}")"
      tmux has-session -t "$session_name" 2>/dev/null || continue
    fi
    printf '%s\n' "${d%/}"
  done
  shopt -u nullglob
}

# _endy_record_session_owner <session> <cwd>
# Drop a .cwd marker file inside the per-dir log dir so the next caller from
# a different cwd can detect a collision and add a hash suffix.
_endy_record_session_owner() {
  local session="$1" cwd="$2"
  [[ "$session" == "endy" ]] && return 0
  local dir; dir="$(_endy_log_dir "$session")"
  mkdir -p "$dir"
  printf '%s\n' "$cwd" > "${dir}/.cwd"
}

# shellcheck source=lib/timefmt.sh
. "$(dirname "${BASH_SOURCE[0]}")/timefmt.sh"

# _endy_worktree_root [path]
# If <path> (default: pwd) is inside a git worktree, print the worktree's
# root absolute path. Otherwise print pwd.
_endy_worktree_root() {
  local p="${1:-$(pwd)}"
  if command -v git >/dev/null 2>&1; then
    local top
    top="$(cd "$p" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -n "$top" ]]; then
      printf '%s' "$top"
      return 0
    fi
  fi
  (cd "$p" 2>/dev/null && pwd) || printf '%s' "$p"
}

# _endy_purge_empty_log_dir <session>
# After a session is killed, remove its per-dir log directory if it contains
# no task logs or other valuable data. Never touches the global .logs dir.
_endy_purge_empty_log_dir() {
  local session="$1"
  local dir; dir="$(_endy_log_dir "$session")"

  # Never touch the global overview log dir.
  [[ "$dir" == "${ENDY_ROOT}/.logs" ]] && return 0

  # Directory might not exist (already cleaned, or never created).
  [[ -d "$dir" ]] || return 0

  # Refuse to purge if task log/meta files exist.
  if [[ -n "$(find "$dir" -maxdepth 1 \( -name 'task-*.log' -o -name 'task-*.meta' \) -print -quit)" ]]; then
    printf '! kept .logs/per-dir/%s/ (has task logs)\n' "$session" >&2
    return 0
  fi

  # Refuse if anything besides known transient artifacts is present.
  if [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 \
    ! -name '.cwd' \
    ! -name 'opencode-serve.log' \
    -print -quit)" ]]; then
    printf '! kept .logs/per-dir/%s/ (has task logs)\n' "$session" >&2
    return 0
  fi

  rm -rf "$dir"
  printf '✓ purged log dir .logs/per-dir/%s/\n' "$session"
}

# _endy_sibling_worktrees [path]
# Print every git worktree path other than the current one (newline-separated).
# Empty output if not in a git repo.
_endy_sibling_worktrees() {
  local p="${1:-$(pwd)}"
  command -v git >/dev/null 2>&1 || return 0
  local cur; cur="$(_endy_worktree_root "$p")"
  (cd "$p" 2>/dev/null && git worktree list --porcelain 2>/dev/null) \
    | awk '/^worktree / {print $2}' \
    | while IFS= read -r wt; do
        [[ -n "$wt" && "$wt" != "$cur" ]] && printf '%s\n' "$wt"
      done
}
