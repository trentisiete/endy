#!/usr/bin/env bash
# scripts/lib/editor.sh — open a filesystem path in the user's editor.
#
# Order of resolution (no hardcoded default — pure auto-detect):
#   1. $ENDY_EDITOR  (verbatim — may include flags, e.g. "code --wait")
#   2. `code`        (VS Code stable on PATH)
#   3. `cursor`      (Cursor IDE on PATH)
#   4. $EDITOR       (the user's shell-configured fallback)
#   5. error + manual path printout
#
# WSL note: when we are on WSL2 the GUI editor binaries (code, cursor) are
# typically interop shims to the Windows host, which expect a Windows path.
# We convert paths with `wslpath -w` so /mnt/c/Users/me/proj/.endy/worktrees/X
# opens correctly. On native Linux / macOS / Windows-native bash, the path
# passes through unchanged.
#
# Contract:
#   _endy_open_in_editor <abs-path> [--reuse]
#     exit:  0  launched (or attempted — editor process is detached)
#            2  no editor found on PATH
#            3  bad args
#
#   _endy_resolve_editor
#     stdout: the editor command string (binary + any flags from $ENDY_EDITOR)
#     exit:   0 found, 1 nothing usable on PATH

# Guard against double-source: callers are scripts that may also source other
# lib/*.sh which themselves may re-enter; once is enough.
if [[ -n "${_ENDY_EDITOR_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_ENDY_EDITOR_SOURCED=1

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# True iff we're running inside WSL — detected by the Microsoft marker that
# Windows kernels embed in /proc/version. Cheap, works on WSL1 and WSL2.
_endy_is_wsl() {
    [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null
}

# Convert a Linux path to a Windows path when on WSL and wslpath is available.
# On every other platform — or when conversion fails — emit the input as-is.
_endy_to_host_path() {
    local p="$1"
    if _endy_is_wsl && command -v wslpath >/dev/null 2>&1; then
        local out
        if out="$(wslpath -w "$p" 2>/dev/null)" && [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    printf '%s\n' "$p"
}

# Resolve which editor to use. Prints the command verbatim (may include args
# baked into $ENDY_EDITOR). Caller is responsible for word-splitting.
_endy_resolve_editor() {
    if [[ -n "${ENDY_EDITOR:-}" ]]; then
        printf '%s\n' "$ENDY_EDITOR"
        return 0
    fi
    if command -v code >/dev/null 2>&1; then
        printf 'code\n'; return 0
    fi
    if command -v cursor >/dev/null 2>&1; then
        printf 'cursor\n'; return 0
    fi
    if [[ -n "${EDITOR:-}" ]]; then
        local bin="${EDITOR%% *}"
        if command -v "$bin" >/dev/null 2>&1; then
            printf '%s\n' "$EDITOR"
            return 0
        fi
    fi
    return 1
}

# _endy_open_in_editor <abs-path> [--reuse]
#
# `code` / `cursor` default to opening a NEW window so the user can fan out
# multiple worktrees in parallel without each one stealing the focus of the
# previous. `--reuse` flips that to reuse the current window (`-r`), useful
# when a follow-up review is wanted in the same workspace.
_endy_open_in_editor() {
    local path="$1"
    [[ -n "$path" ]] || { echo "_endy_open_in_editor: usage: <abs-path> [--reuse]" >&2; return 3; }
    shift || true
    local reuse=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reuse) reuse=1; shift ;;
            --) shift; break ;;
            *) shift ;;  # silently ignore unknown flags — we're a leaf helper
        esac
    done

    local editor_cmd
    if ! editor_cmd="$(_endy_resolve_editor)"; then
        echo "endy: no editor found on PATH." >&2
        echo "      set \$ENDY_EDITOR, install code/cursor, or set \$EDITOR." >&2
        echo "      open the path manually:  $path" >&2
        return 2
    fi

    local host_path; host_path="$(_endy_to_host_path "$path")"

    # The command string may carry baked flags ("code --wait"). Split on first
    # whitespace: head is the binary, tail is the flag list. We then add our
    # own new-window / reuse flag for VS Code-family editors only.
    local editor_bin="${editor_cmd%% *}"
    local editor_tail=""
    [[ "$editor_cmd" != "$editor_bin" ]] && editor_tail="${editor_cmd#"$editor_bin" }"

    case "$editor_bin" in
        code|cursor|code-insiders|codium|code-oss)
            local nflag="-n"
            [[ "$reuse" == "1" ]] && nflag="-r"
            # shellcheck disable=SC2086
            "$editor_bin" $editor_tail "$nflag" "$host_path" >/dev/null 2>&1 &
            ;;
        *)
            # shellcheck disable=SC2086
            "$editor_bin" $editor_tail "$host_path" </dev/null >/dev/null 2>&1 &
            ;;
    esac
    disown 2>/dev/null || true
    return 0
}
