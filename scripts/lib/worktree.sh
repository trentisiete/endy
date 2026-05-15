#!/usr/bin/env bash
# scripts/lib/worktree.sh — git worktree helpers for endy Phase 5.
#
# Each `endy spawn --worktree` (or any spawn from inside an orchestrator
# window via ENDY_DEFAULT_WORKTREE=1) creates a fresh git worktree under
# <repo-root>/.endy/worktrees/<task-id>/ on branch endy/task-<task-id>.
# Two parallel agents working in the same project then literally cannot
# stomp each other's edits — each has its own checkout.
#
# This file provides three primitives; the spawn/cleanup integration
# lives in spawn-long-task.sh, endy-watch.sh::cmd_purge, and bin/endy::
# cmd_stop. The primitives are intentionally git-only and stdlib-only —
# no Python, no extra deps.
#
# Contract:
#   _endy_worktree_create <repo-root> <task-id>
#     stdout: absolute path to the new worktree
#     exit:   0 ok, 2 bad args, 3 not a git repo, 4 git worktree add failed
#
#   _endy_worktree_safe_to_remove <worktree-path>
#     exit:   0 safe (porcelain empty), non-zero otherwise (see exit codes)
#
#   _endy_worktree_remove <worktree-path>
#     side effect: removes the worktree dir and the endy/task-* branch if
#                  it was created by us and is fully merged elsewhere
#     exit:   0 ok (or already gone), 1 removal failed

# Guard against double-source: this file is intended to be sourced by
# multiple scripts during the lifetime of one shell.
if [[ -n "${_ENDY_WORKTREE_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_ENDY_WORKTREE_SOURCED=1

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# _endy_worktree_branch_for <task-id>  →  prints the branch name we use.
# Kept as a separate function so the convention is in one place; callers
# never hand-build "endy/task-…".
_endy_worktree_branch_for() {
    printf 'endy/task-%s\n' "$1"
}

# _endy_worktree_path_for <repo-root> <task-id>  →  prints the canonical
# absolute path where the worktree would live (does not require it to
# exist).
_endy_worktree_path_for() {
    printf '%s/.endy/worktrees/%s\n' "${1%/}" "$2"
}

# _endy_worktree_repo_root [path]  →  prints the absolute path of the
# main worktree (the "real" repo dir) for a given path. Empty stdout +
# non-zero exit if path is not in a git repo.
#
# Unlike _endy_worktree_root in session.sh (which returns the CURRENT
# worktree root), this returns the COMMON / MAIN worktree root — needed
# so child worktrees know which `.endy/worktrees/` to live under.
_endy_worktree_repo_root() {
    local p="${1:-$(pwd)}"
    command -v git >/dev/null 2>&1 || return 1

    # git rev-parse --git-common-dir gives the .git of the main worktree
    # (or .git itself if we're in the main one). Its parent is the repo
    # root.
    local common_dir
    common_dir="$(cd "$p" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    [[ -z "$common_dir" ]] && return 1

    # Normalize: if it's relative ('.git'), prepend the cwd.
    if [[ "$common_dir" != /* ]]; then
        common_dir="$(cd "$p" 2>/dev/null && cd "$common_dir" 2>/dev/null && pwd)" || return 1
    fi

    # Strip trailing '/.git' or '/.git/' to get the worktree dir.
    local root="${common_dir%/.git}"
    root="${root%/.git/}"
    # If --git-common-dir returned something unexpected, just use its parent.
    [[ "$root" == "$common_dir" ]] && root="$(dirname "$common_dir")"

    printf '%s\n' "$root"
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

# _endy_worktree_create <repo-root> <task-id>
#
# Creates <repo-root>/.endy/worktrees/<task-id>/ as a new git worktree on
# a fresh branch endy/task-<task-id> tracking the current HEAD.
#
# Prints the absolute worktree path on stdout. Exit codes are
# documented at the top of this file.
_endy_worktree_create() {
    local repo_root="$1"
    local task_id="$2"

    if [[ -z "$repo_root" || -z "$task_id" ]]; then
        echo "_endy_worktree_create: usage: <repo-root> <task-id>" >&2
        return 2
    fi
    command -v git >/dev/null 2>&1 || { echo "_endy_worktree_create: git not on PATH" >&2; return 3; }

    if ! (cd "$repo_root" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1); then
        echo "_endy_worktree_create: $repo_root is not inside a git repo" >&2
        return 3
    fi

    local wt_dir; wt_dir="$(_endy_worktree_path_for "$repo_root" "$task_id")"
    local wt_branch; wt_branch="$(_endy_worktree_branch_for "$task_id")"

    # Don't clobber an existing worktree path (e.g. if someone re-ran a
    # spawn with the same TASK_ID for some reason). Use git's own check
    # — it'll error if either the path or the branch is already in use.
    mkdir -p "$(dirname "$wt_dir")" 2>/dev/null

    # git worktree add -b <branch> <path>  →  creates <path> AND <branch>
    # from current HEAD. Stderr is captured so we can surface the actual
    # git error if it fails (helpful for "branch already exists" etc).
    local add_err
    if add_err="$(cd "$repo_root" && git worktree add -b "$wt_branch" "$wt_dir" 2>&1)"; then
        # Success path: emit the absolute path.
        # Resolve any symlinks for stability.
        local abs
        abs="$(cd "$wt_dir" 2>/dev/null && pwd)" || abs="$wt_dir"
        printf '%s\n' "$abs"
        return 0
    fi

    echo "_endy_worktree_create: git worktree add failed: $add_err" >&2
    return 4
}

# ---------------------------------------------------------------------------
# safe-to-remove
# ---------------------------------------------------------------------------

# _endy_worktree_safe_to_remove <worktree-path>
#
# Exit codes:
#   0  → safe (porcelain empty, no uncommitted edits)
#   1  → path doesn't exist (treat as already gone — caller decides)
#   2  → unsafe: uncommitted edits / untracked files in the worktree
#   3  → unsafe: not a git repo / can't read status
#
# We deliberately only block on uncommitted edits. Commits ON the
# endy/task-<id> branch persist in the repo as a ref even after the
# worktree dir is gone, so removing the dir is non-destructive. The user
# can `git branch -d endy/task-<id>` whenever they want to drop the
# branch ref itself.
_endy_worktree_safe_to_remove() {
    local wt="$1"
    [[ -d "$wt" ]] || return 1

    local porcelain
    porcelain="$(cd "$wt" 2>/dev/null && git status --porcelain 2>/dev/null)"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return 3
    fi
    if [[ -n "$porcelain" ]]; then
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

# _endy_worktree_remove <worktree-path>
#
# Removes the worktree dir via `git worktree remove`. If the worktree was
# on an endy/task-* branch, also tries `git branch -d` (refuses if
# unmerged — safe). Idempotent: missing dir → success (return 0).
#
# This function does NOT check safety. The caller is expected to have
# called _endy_worktree_safe_to_remove first and decided that yes, it's
# OK to throw away whatever was there. The only protection here is that
# git worktree remove (without --force) refuses if the index/working
# tree is dirty — that's a backstop.
_endy_worktree_remove() {
    local wt="$1"
    [[ -d "$wt" ]] || return 0

    # Capture the branch BEFORE removing, so we can delete it after.
    local branch=""
    branch="$(cd "$wt" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

    # Find the main repo root so we can issue follow-up commands from
    # there (worktree remove can be invoked from any worktree, but `git
    # branch -d` must run from somewhere that has the branch ref).
    local repo_root=""
    repo_root="$(_endy_worktree_repo_root "$wt" 2>/dev/null || true)"

    # First try without --force. That's the safe path.
    if (cd "$wt" 2>/dev/null && git worktree remove "$wt" 2>/dev/null); then
        :
    else
        # Try from the main worktree (in case `cd "$wt"` is breaking).
        if [[ -n "$repo_root" ]] && (cd "$repo_root" && git worktree remove "$wt" 2>/dev/null); then
            :
        else
            return 1
        fi
    fi

    # Best-effort cleanup of the branch we created. -d (not -D) refuses
    # to delete unmerged branches, which is the right policy: commits
    # the agent made survive until the user explicitly drops them.
    if [[ -n "$branch" && "$branch" == endy/task-* && -n "$repo_root" ]]; then
        (cd "$repo_root" && git branch -d "$branch" 2>/dev/null) || true
    fi

    return 0
}
