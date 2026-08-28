#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolveTranscriptPath, READ_FRESH_MS, READ_TAIL_LINES } from './lib/spec-read-evidence.mjs';
import { readTranscriptText } from './lib/transcript-last-assistant.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { hookFilesWrittenBy } from './lib/script-mediated-hook-writes.mjs';
autoLogOnDeny('require-full-read-before-hook-edit');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit', 'Bash'].includes(tool)) allow();

const ti = payload.tool_input || {};
let fp = String(ti.file_path || ti.filePath || '').replace(/\\/g, '/');
if (tool === 'Bash') {
  const targets = hookFilesWrittenBy(payload);
  if (!targets.length) allow();
  fp = targets[0];
}

const HOME_CLAUDE = `${(process.env.CLAUDE_CONFIG_DIR || homedir().replace(/\\/g, '/') + '/.claude').replace(/\\/g, '/')}/`;
const EXCLUDED = /\/(?:__tests__|knowledge|rules-archive|projects|teams|plugins|\.state|\.aal-state|shell-snapshots|todos)\//;
const LEDGER = /^(?:struggle-log|rules-rationale|settings_notes)/i;
if (!fp.startsWith(HOME_CLAUDE) || EXCLUDED.test(fp) || !/\.(mjs|sh|md|json)$/.test(fp)) allow();
if (LEDGER.test(fp.slice(HOME_CLAUDE.length))) allow();

if (!existsSync(fp)) allow();

const tp = resolveTranscriptPath(payload);
if (!tp) allow();
let text = '';
try { text = readTranscriptText(tp).text || ''; } catch { allow(); }
if (!text) allow();

const base = fp.split('/').pop();
const baseRe = new RegExp(base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
const baseLc = base.toLowerCase();

const blocksOf = (ln) => {
  if (!baseRe.test(ln) || ln.indexOf('"tool_use"') === -1) return null;
  let obj;
  try { obj = JSON.parse(ln); } catch { return null; }
  const content = obj?.message?.content;
  return Array.isArray(content) ? content : null;
};
const isSameFile = (p) => String(p || '').replace(/\\/g, '/').split('/').pop().toLowerCase() === baseLc;

const linesAll = text.split(/\r?\n/);
const tail = linesAll.slice(Math.max(0, linesAll.length - READ_TAIL_LINES));
const now = Date.now();
const isFresh = (ln) => {
  const m = ln.match(/"timestamp"\s*:\s*"([^"]+)"/);
  if (!m) return true;
  const t = Date.parse(m[1]);
  return Number.isNaN(t) || now - t <= READ_FRESH_MS;
};

const pages = [];
let fullRead = false;
for (let i = tail.length - 1; i >= 0 && !fullRead; i--) {
  const ln = tail[i];
  if (!ln || !isFresh(ln)) continue;
  const content = blocksOf(ln);
  if (!content) continue;
  for (const b of content) {
    if (b?.type !== 'tool_use' || b.name !== 'Read') continue;
    if (!isSameFile(b.input?.file_path ?? b.input?.filePath)) continue;
    const off = Number(b.input?.offset);
    const lim = Number(b.input?.limit);
    if (!Number.isFinite(off) && !Number.isFinite(lim)) { fullRead = true; break; }
    const start = Number.isFinite(off) && off > 0 ? off : 1;
    pages.push([start, Number.isFinite(lim) && lim > 0 ? start + lim - 1 : Infinity]);
  }
}
if (fullRead) allow();

if (pages.length) {
  let total = 0;
  try {
    const ls = readFileSync(fp, 'utf8').split(/\r?\n/);
    if (ls.length && ls[ls.length - 1] === '') ls.pop();
    total = ls.length;
  } catch { allow(); }
  pages.sort((a, b) => a[0] - b[0]);
  let reached = 0;
  for (const [s, e] of pages) {
    if (s > reached + 1) break;
    if (e > reached) reached = e;
  }
  if (reached >= total) allow();
}

deny(
  `BLOCKED: Read it before you change it\n\n`
  + `    Read ${fp}\n\n`
  + `Only the Read tool counts, within 4 hours; grep / sed -n / head / tail do not. For a long file, read it through with consecutive offsets.`,
);
