#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { repoOfAnyPath, repoRoots } from './is-autoloop-lead.mjs';

const [cfg, want, dispatchPrompt] = process.argv.slice(2);
if (!cfg || !want) process.exit(0);

let members = [];
try {
  members = JSON.parse(readFileSync(cfg, 'utf8')).members || [];
} catch {
  process.exit(0);
}

const MAX_PROBES = 8;
// The POSIX branch used to be `/x/` or `/mnt/x/` — Git Bash's spelling of a drive, not a real
// POSIX root, so `/home/…` and `/srv/…` matched nothing. Both are covered by the general form.
const ABS_PATH = /(?:[A-Za-z]:[\\/]|(?<![\w.\-/:~])\/)[^\s"'`,;()\]]+/g;

const rootsCache = new Map();
const checkoutOf = (text) => {
  const paths = [...new Set(String(text || '').match(ABS_PATH) || [])]
    .map((p) => p.replace(/\\/g, '/'));
  let probes = 0;
  for (const p of paths) {
    if (probes >= MAX_PROBES) break;
    probes += 1;
    let repo = null;
    try { repo = repoOfAnyPath(p); } catch { repo = null; }
    if (!repo) continue;
    if (!rootsCache.has(repo)) {
      let r = [];
      try { r = repoRoots(repo) || []; } catch { r = []; }
      rootsCache.set(repo, r);
    }
    const lp = p.toLowerCase();
    const hit = rootsCache.get(repo)
      .filter((r) => { const lr = String(r).toLowerCase(); return lp === lr || lp.startsWith(lr + '/'); })
      .sort((x, y) => y.length - x.length)[0];
    if (hit) return String(hit).toLowerCase();
  }
  return null;
};

const mine = checkoutOf(dispatchPrompt);

const hits = members
  .filter((m) => m && m.agentType === want)
  .filter((m) => {
    if (!mine) return true;
    const theirs = checkoutOf(m.prompt);
    if (!theirs) return true;
    return theirs === mine;
  })
  .map((m) => m.name || m.agentId || '?');

process.stdout.write(hits.join(', '));
