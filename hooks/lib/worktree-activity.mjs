import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';


export const SKIP_NAMES = new Set([
  '.git', 'node_modules', '.next', '.turbo', '.wrangler', '.vercel',
  'dist', 'build', 'out', 'coverage', '.venv', '__pycache__', '.pytest_cache',
]);
export const SCAN_CAP = 20000;

export function freshestWorkFile(root, freshAfterMs, cap = SCAN_CAP) {
  let scanned = 0;
  const stack = [{ dir: root, rel: '' }];
  while (stack.length) {
    const { dir, rel } = stack.pop();
    let ents;
    try { ents = readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of ents) {
      if (++scanned > cap) {
        if (process.env.PILOT_DEBUG_WT) {
          process.stderr.write(`[wt] ${root}: reached the scan cap ${cap} with no newer file => UNKNOWN, treated as "report it"\n`);
        }
        return null;
      }
      if (SKIP_NAMES.has(e.name)) continue;
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) { stack.push({ dir: abs, rel: rel ? `${rel}/${e.name}` : e.name }); continue; }
      if (!e.isFile()) continue;
      let mtimeMs;
      try { mtimeMs = statSync(abs).mtimeMs; } catch { continue; }
      if (mtimeMs > freshAfterMs) {
        return { rel: rel ? `${rel}/${e.name}` : e.name, mtimeMs };
      }
    }
  }
  return null;
}

