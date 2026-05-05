# Mobile gateway

Two phases. Phase 1 gives you the full TUI from your phone today. Phase 2 adds a chat-native interface for short prompts and notifications.

## Phase 1 — Tailscale + tmux + Blink Shell

This is the simplest path with zero feature loss. Your phone gets a real terminal that's attached to the same Codex session you use at home.

### One-time setup on the Mac mini

```bash
brew install tailscale tmux mosh
sudo tailscale up                  # follow the OAuth link, log in
sudo tailscale set --ssh           # enables Tailscale SSH (no key management)
```

Confirm:

```bash
tailscale status                   # should list this machine
tailscale ip -4                    # note the 100.x.y.z IP
```

### One-time setup on the phone

1. Install **Tailscale** from the App Store / Play Store and log in with the same account.
2. Install a terminal:
   - **iOS:** Blink Shell (paid, best mosh support, real keyboard).
   - **Android:** Termux + Termux:API, or JuiceSSH.
3. In the terminal app, add a host pointing at `$USER@$HOSTNAME` (or the Tailnet IP). With Tailscale SSH enabled you don't need to manage keys.

### Day-to-day

```bash
# from the phone:
ssh $USER@$HOSTNAME -t 'tmux attach -t endy || ~/Downloads/endy/scripts/start.sh'
```

That command attaches to the running gateway, or starts it if it's down. Same view, same Codex session, same context. Detach with `Ctrl-b d` and the session keeps running.

### Mosh upgrade (optional, recommended)

Mosh survives flaky cell connections and roaming between Wi-Fi and 4G/5G — way better than raw SSH on mobile. After installing mosh on both ends:

```bash
mosh $USER@$HOSTNAME -- tmux attach -t endy
```

Blink Shell has first-class mosh support; Termux works too.

### Security notes

- Tailscale gives you a private mesh — no port is exposed to the public internet.
- Tailscale SSH means the Mac mini's `sshd` does not need to be reachable from outside the Tailnet.
- Disable SSH passwords (`PasswordAuthentication no` in `/etc/ssh/sshd_config`) and rely on Tailscale's identity layer.

## Phase 2 — Telegram bot (later)

For when you want push notifications, voice messages, or just a chat-style "hey, run X" without launching a terminal app.

The right starting point is **[ductor](https://github.com/PleasePrompto/ductor)** — a CLI-agent Telegram bridge that already supports Codex and Claude Code. Setup outline:

1. Talk to `@BotFather` on Telegram, create a bot, get the token.
2. Talk to `@userinfobot` to get your Telegram user ID (the bot will only respond to you).
3. Clone ductor on the Mac mini, fill in the token + your ID + the agent CLI command.
4. Run it inside a tmux window in the endy session (window 3, "telegram").
5. From the phone: send a message → bot relays to Codex → response comes back.

Approval flows are awkward over chat (no rich UI for "diff approve"), so for Telegram-only work you'll likely run Codex with looser sandbox settings, or limit it to read-only / planning tasks. Keep the destructive stuff for the SSH path.

## Phase 3 — web UI (only if you want it)

Web terminal options worth a look — pick **at most one**, they're all roughly equivalent:

- **[sshx.io](https://sshx.io)** — easiest, encrypted-by-share-URL, terminal in a browser tab.
- **ttyd / Wetty** behind a Cloudflare Tunnel with Cloudflare Access for auth.

Skip the LibreChat / Open WebUI / AnythingLLM family for now. They're built around chat APIs, not CLI agents — wrapping Codex in them needs a custom adapter and you lose the TUI.
