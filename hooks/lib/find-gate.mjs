#!/usr/bin/env node
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOOKS = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hooks');
const USER_SETTINGS = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'settings.json');

const argv = process.argv.slice(2);
const asRegex = argv[0] === '--re';
const query = (asRegex ? argv[1] : argv[0]) || '';
if (!query) {
  console.error("usage: node find-gate.mjs '<a phrase from the denial text | a predicate token>'   or   --re '<regex>'");
  process.exit(2);
}
const re = asRegex ? new RegExp(query, 'i') : null;
const hit = (line) => (re ? re.test(line) : line.toLowerCase().includes(query.toLowerCase()));

const mounts = new Map();
const addMount = (base, label) => {
  if (!mounts.has(base)) mounts.set(base, []);
  if (!mounts.get(base).includes(label)) mounts.get(base).push(label);
};

const settingsFiles = [USER_SETTINGS];
for (let d = process.cwd(), i = 0; i < 8; i += 1) {
  const p = join(d, '.claude', 'settings.json');
  if (existsSync(p) && !settingsFiles.includes(p)) settingsFiles.push(p);
  const up = join(d, '..');
  if (up === d) break;
  d = up;
}
for (const sf of settingsFiles) {
  let s = null;
  try { s = JSON.parse(readFileSync(sf, 'utf8')); } catch { continue; }
  for (const [ev, groups] of Object.entries(s.hooks || {})) {
    for (const g of groups || []) {
      for (const h of g.hooks || []) {
        for (const m of String(h.command || '').matchAll(/([A-Za-z0-9._-]+\.(?:mjs|cjs|js|sh))/g)) {
          addMount(m[1], `${ev}/${g.matcher || '*'}`);
        }
      }
    }
  }
}
const files = readdirSync(HOOKS).filter((f) => /\.(mjs|cjs|js|sh)$/.test(f));
for (const f of files) {
  let src = '';
  try { src = readFileSync(join(HOOKS, f), 'utf8'); } catch { continue; }
  for (const m of src.matchAll(/([A-Za-z0-9._-]+\.(?:mjs|cjs|js|sh))/g)) {
    if (m[1] !== f && files.includes(m[1])) addMount(m[1], `delegate-of:${f}`);
  }
}

const corpora = [HOOKS, join(HOOKS, 'lib')];
const rows = [];
for (const dir of corpora) {
  let entries = [];
  try { entries = readdirSync(dir).filter((f) => /\.(mjs|cjs|js|sh)$/.test(f)); } catch { continue; }
  for (const f of entries) {
    let src = '';
    try { src = readFileSync(join(dir, f), 'utf8'); } catch { continue; }
    const lines = src.split(/\r?\n/);
    for (let i = 0; i < lines.length; i += 1) {
      if (!hit(lines[i])) continue;
      const where = (mounts.get(f) || []).join(' , ') || (dir.endsWith('lib') ? 'lib (called by another hook)' : 'NOT MOUNTED');
      rows.push(`${where} | ${dir === HOOKS ? f : 'lib/' + f}:${i + 1} | ${lines[i].trim().slice(0, 120)}`);
      break;
    }
  }
}

if (rows.length) {
  for (const r of rows) console.log(r);
  console.log(`\n${rows.length} file(s) matched.`);
} else {
  console.log('0 files matched.');
  console.log(`corpora searched: ${corpora.join(' , ')} (${files.length} hook files) + ${settingsFiles.length} settings.json file(s).`);
  console.log('WARNING: zero hits does NOT mean the gate is absent. Search again with a different token: a verbatim sentence from its denial text, or the lib name it imports,');
  console.log('   or just perform the action and let the gate answer for itself. A hand-written inventory is not a corpus for this question.');
}
process.exit(0);
