#!/usr/bin/env bash
# Quick "is the gateway up?" check. Nothing destructive.

set -u

SESSION="endy"

printf 'tmux session "%s": ' "$SESSION"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  printf '\033[32mup\033[0m\n'
  tmux list-windows -t "$SESSION" -F '  - #I #W (#{window_panes} pane(s), active=#{window_active})'
else
  printf '\033[31mdown\033[0m  — run scripts/start.sh\n'
fi

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
