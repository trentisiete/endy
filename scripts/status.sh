#!/usr/bin/env bash
# Quick "is the gateway up?" check. Nothing destructive.

set -u

ENDY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/session.sh
. "${ENDY_ROOT}/scripts/lib/session.sh"
SESSION="${ENDY_SESSION:-${1:-$(_endy_session_name "$(pwd)")}}"

printf 'tmux session "%s": ' "$SESSION"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  printf '\033[32mup\033[0m\n'
  tmux list-windows -t "$SESSION" -F '  - #I #W (#{window_panes} pane(s), active=#{window_active})'
else
  printf '\033[31mdown\033[0m  — run: endy start\n'
fi

# Show every endy* tmux session so the per-dir landscape is visible.
echo
echo "All endy tmux sessions:"
tmux list-sessions -F '  - #S (#{session_windows} window(s))' 2>/dev/null \
  | grep -E ' - endy(-|\b)' || echo "  (none)"

echo
echo "Codex MCP servers configured:"
codex mcp list 2>/dev/null | sed 's/^/  /' || echo "  (codex mcp list failed)"

echo
echo "Tailnet status:"
if command -v tailscale >/dev/null 2>&1; then
  tailscale status 2>/dev/null | head -5 | sed 's/^/  /'
else
  echo "  tailscale not installed"
fi
