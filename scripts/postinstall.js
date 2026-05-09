#!/usr/bin/env node
// Non-intrusive npm postinstall. Tells the user to run `endy install`
// manually. Never modifies HOME or tmux — see the previous audit.
const msg = `
endy installed.

To finish setup (symlinks under ~/.codex, ~/.commandcode, shell completion,
PATH wiring), run:

  endy install

Prereqs (install separately): tmux, python3, openssl, plus at least one of
codex / opencode / cmd / hermes.
`;
process.stdout.write(msg);
