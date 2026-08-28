import { execFileSync } from 'node:child_process';
import { homeDir } from './is-autoloop-lead.mjs';

// Where `gh` is, and how to invoke it — one owner, because two gates were each carrying their own
// copy of this list and they had already drifted apart in how they probed it.
//
// GH_PATH is read as a COMMAND, not as a bare path: everything up to the first space is the binary
// and the rest are leading arguments. That covers the installations `gh` actually has —
// `wsl gh`, `flatpak run io.github.cli.gh`, a wrapper script — and it is the only way to point the
// gate at anything on Windows that is not a real `.exe`: node refuses to spawn a `.cmd` or a `.bat`
// without a shell, and an extensionless shell script is not an executable image at all. Measured on
// this host: with a shell-script `gh` first on PATH, node skipped it in silence and reached the
// REAL gh instead — a stub that looks installed and is never called.
export function resolveGh(candidates = [process.env.GH_PATH, `${homeDir()}/bin/bin/gh.exe`, 'gh']) {
  for (const c of candidates) {
    if (!c) continue;
    const parts = String(c).trim().split(/\s+/).filter(Boolean);
    if (!parts.length) continue;
    const found = { bin: parts[0], pre: parts.slice(1) };
    try {
      execFileSync(found.bin, [...found.pre, '--version'], { timeout: 5000, stdio: 'ignore' });
      return found;
    } catch {  }
  }
  return null;
}

// The argument vector for one `gh` call, leading arguments included.
export function ghArgv(resolved, args) {
  return [...((resolved && resolved.pre) || []), ...args];
}
