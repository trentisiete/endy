# Recording the handoff demo

Step-by-step script for the README hero GIF (`docs/media/handoff.gif`).
Everything below uses the offline `bash` stub agent, so you can record
without burning a single free-tier call. The story stays identical when
you swap `bash` for real CLIs.

## Goal

Show, in under 40 seconds: a task starts, hits a wall, and a different
agent picks it up with full context — no human re-typing the prompt.

## What the viewer should remember

1. One command (`endy handoff`) does the transfer.
2. The new agent sees the original prompt **and** the previous agent's
   full output.
3. The cadena de handoffs is visible in the tree.

## Recording setup (one-time)

- Terminal: 100x28 minimum (the tree view needs the width).
- Font: a clear monospace at ~16pt.
- Tools: [`asciinema`](https://asciinema.org/) to capture +
  [`agg`](https://github.com/asciinema/agg) to export as GIF.
- Recording dir: a clean tmp project so the prompt looks neutral.

```bash
mkdir -p /tmp/endy-demo && cd /tmp/endy-demo
echo "demo project" > README.md
asciinema rec -i 1 /tmp/endy-handoff.cast --overwrite
```

`-i 1` caps idle frames to 1 s so dead air doesn't bloat the GIF. When
done recording, exit asciinema (`Ctrl-D`) and convert:

```bash
agg --theme monokai --speed 1.2 /tmp/endy-handoff.cast docs/media/handoff.gif
```

## The script (35 seconds)

Type each block, pause where indicated, then keep going. Don't talk to
the recording; the captions in the README do that job.

### 0:00 — Set the stage (3 s)

```bash
endy start
```

Wait for the prompt to come back. The session is live.

### 0:03 — Spawn the first agent (5 s)

```bash
endy spawn bash -- "Refactor src/auth/ to use IdentityProvider, then run npm test."
```

Output shows `TASK_ID=…`, `TMUX_WINDOW=…`, `LOG=…`. Note the id (first
4 chars are enough later).

### 0:08 — Show the task running (4 s)

```bash
endy watch tree
```

The viewer sees one row with status `RUN`, the `bash` agent, the prompt
preview. This is the "an agent is working" beat.

### 0:12 — Hand off (6 s)

The "wall" we're simulating: bash has been "doing the work" for a moment.
Now the viewer sees the magic — one command transfers it:

```bash
endy handoff <id-prefix> --to opencode --reason "rate limited" --stop-parent
```

Replace `<id-prefix>` with the first 4 chars from step 0:03. The output
shows:

```
HANDOFF_FROM=…
HANDOFF_TO=opencode
HANDOFF_CHAIN=…
TASK_ID=<new>
```

…plus tmux/endy commands. The `--stop-parent` flag closes the bash
window so the dashboard stays clean.

### 0:18 — Show the chain (5 s)

```bash
endy watch tree
```

The new row appears with `↪ handoff from <short-id> · rate limited`
underneath. The viewer sees that the new agent inherited the context.

### 0:23 — The receipt (the punchline, 8 s)

```bash
endy watch view <new-id>
```

Less opens with the new task's meta + prompt + log. Scroll down to the
prompt section so the viewer sees the markers:

```
[endy handoff — you are taking over from a previous agent]
Previous agent: bash
Previous task: …
Handoff chain: …
Reason for handoff: rate limited

--- original task prompt ---
Refactor src/auth/ to use IdentityProvider, then run npm test.
--- end original task prompt ---

--- full output of previous agent's output ---
…
```

This is the proof. The new agent did not start from nothing — it has
the original prompt **and** the previous agent's full output.

Quit `less` with `q`. End of recording.

### 0:31 — End

Recording stops here. Total: ~31-35 s depending on typing speed.

## Captions for the README

If you want to overlay short captions in post (Kap, ScreenFlow, etc.),
the beats are:

| Time | Caption |
|---|---|
| 0:00 | One project, one tmux session |
| 0:03 | Agent A starts the task |
| 0:12 | One command, different agent picks up |
| 0:18 | The handoff is traceable |
| 0:23 | The new agent has the original prompt + the full previous output |

## Variants you may want to record later

- **Real-tier demo:** swap `bash` for `opencode` and run a real refactor
  prompt. Longer, more impressive, costs a free-tier call.
- **Multi-step chain:** A → B → C. Show that `handoff_chain` accumulates
  ids. Useful for a deeper-dive blog post.
- **Phone view:** record the web dashboard from the phone (Tailscale)
  while the chain unfolds on the laptop. Best for a tweet thread.

## File output

Drop the final GIF at `docs/media/handoff.gif`. The README references it
in the hero block at the top. If you want a poster image, also export
the last frame as `docs/media/handoff.png` and the README will use it
automatically (the `<img>` tag can be swapped for `<video>` if you'd
rather host an MP4).
