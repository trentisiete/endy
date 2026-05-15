#!/usr/bin/env node
// Non-intrusive npm postinstall. Tells the user to run `endy install`
// manually. Never modifies HOME or tmux — see the previous audit.
//
// Also restores the executable bit on bash scripts: when the package is
// packed from a filesystem without POSIX exec bits (Windows / NTFS), npm
// stores 0644 in the tar and the installed scripts can't be run by bash.
// We chmod 0755 every .sh under scripts/ and bin/endy.

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

function chmodExecutable(p) {
  try { fs.chmodSync(p, 0o755); } catch (_) { /* best-effort */ }
}

function walkAndFix(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
  for (const ent of entries) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      walkAndFix(full);
    } else if (ent.isFile() && ent.name.endsWith('.sh')) {
      chmodExecutable(full);
    }
  }
}

// Skip on Windows — exec bits are meaningless there and the package is not
// runnable on win32 anyway (package.json sets "os": ["darwin", "linux"]).
if (process.platform !== 'win32') {
  walkAndFix(path.join(root, 'scripts'));
  const endyBin = path.join(root, 'bin', 'endy');
  if (fs.existsSync(endyBin)) chmodExecutable(endyBin);
}

const msg = `
endy installed.

To finish setup (symlinks under ~/.codex, ~/.commandcode, shell completion,
PATH wiring), run:

  endy install

Prereqs (install separately): tmux, python3, openssl, plus at least one of
codex / opencode / cmd / hermes.
`;
process.stdout.write(msg);
