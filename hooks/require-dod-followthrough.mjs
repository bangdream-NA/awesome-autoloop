#!/usr/bin/env node
import { readFileSync, readdirSync, statSync, appendFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import path from 'node:path';
import { loadWriteToolLines, authoredHere } from './lib/authored-here.mjs';
import { DOD_VERIFIED_RE } from './lib/backlog-grammar.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-dod-followthrough');

const STATE_DIR = path.join(homeDir(), '.claude/hooks/.state');
function logErr(tag, e) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    const f = path.join(STATE_DIR, 'hook-errors.log');
    try { if (existsSync(f) && statSync(f).size > 131072) renameSync(f, f + '.1'); } catch {  }
    appendFileSync(f, `${new Date().toISOString()} require-dod-followthrough ${tag}: ${String(e).slice(0, 300)}\n`);
  } catch {  }
}

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch (e) { logErr('stdin-parse', e); stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }
const WTL = loadWriteToolLines(tp);

const DIR = process.env.DOD_FT_DIR || projectPaths()?.claude || '';
let oplog = '';
let ownsProject = false;
try {
  const files = readdirSync(DIR)
    .filter((f) => /^autoloop-log-.*\.md$/.test(f))
    .map((f) => { try { return { f, m: statSync(path.join(DIR, f)).mtimeMs }; } catch { return null; } })
    .filter(Boolean)
    .filter((x) => Date.now() - x.m < 7 * 24 * 3600 * 1000)
    .sort((a, b) => a.m - b.m);
  oplog = files.map((x) => readFileSync(path.join(DIR, x.f), 'utf8').split('\n').slice(-400).join('\n')).join('\n');
  const newest = files[files.length - 1];
  const sidm = newest && newest.f.match(/-([0-9a-f]{8})\.md$/i);
  ownsProject = !!(sidm && String(stdin.session_id || '').startsWith(sidm[1]));
} catch { process.stdout.write('{}'); process.exit(0); }
if (!oplog) { process.stdout.write('{}'); process.exit(0); }

const rows = oplog.split('\n');
const N = rows.length;
const deferred = {};
const cleared = new Set();
const prsOf = (r) => [...r.matchAll(/#(\d{3,4})(?!\d)/g)].map((m) => m[1]);

for (let i = 0; i < N; i++) {
  const r = rows[i];
  const merged = /\bMERG/i.test(r);
  const isVerified = DOD_VERIFIED_RE.test(r);
  const isGated = /DoD[-\s]?(GATED|BLOCKED)|DoD\s+(?:awaiting|pending)\s?(user|USER|apex|infra|host|data|regen)/i.test(r);
  const isDeferred = merged && /DoD/i.test(r)
    && /(pending\s?deploy|awaiting\s?deploy|pending|awaiting\s?Playwright|awaiting\s?verif|deployed|after\s?deploy|deploy\b[^\n]{0,20}then|next\s?(?:round|iteration))/i.test(r)
    && !isVerified;
  if (isDeferred && (ownsProject || authoredHere(WTL, r))) for (const pr of prsOf(r)) deferred[pr] = i;
  const isFailedAnchored = /DoD-FAILED/.test(r) && /dod-failed-at=/.test(r) && /dod-remedy-tracks=/.test(r);
  if (isVerified || isGated || isFailedAnchored) for (const pr of prsOf(r)) cleared.add(pr);
}

try {
  const boardFiles = readdirSync(DIR).filter((f) => /^BACKLOG(-archive.*)?\.md$/.test(f));
  for (const bf of boardFiles) {
    let txt = '';
    try { txt = readFileSync(path.join(DIR, bf), 'utf8'); } catch { continue; }
    for (const r of txt.split('\n')) {
      if (DOD_VERIFIED_RE.test(r)) for (const pr of prsOf(r)) cleared.add(pr);
      if (/DoD-FAILED/.test(r) && /dod-failed-at=/.test(r) && /dod-remedy-tracks=/.test(r)) {
        for (const pr of prsOf(r)) cleared.add(pr);
      }
    }
  }
} catch {  }

const stale = Object.entries(deferred).filter(([pr, i]) => !cleared.has(pr) && i < N - 2).map(([pr]) => pr);
let mergedOnly = stale;
if (stale.length && !process.env.DOD_FT_ASSUME_MERGED) {
  try {
    const { execFileSync } = await import('node:child_process');
    mergedOnly = stale.filter((pr) => {
      try {
        const out = execFileSync('gh', ['pr', 'view', pr, ...(process.env.AAL_REPO ? ['--repo', process.env.AAL_REPO] : []), '--json', 'state', '-q', '.state'], { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        return out === 'MERGED';
      } catch { return true; }
    });
  } catch { mergedOnly = stale; }
}
if (mergedOnly.length) {
  process.stdout.write(JSON.stringify({
    decision: 'block',
    reason:
      `SAY-IT-AND-NOT-DO-IT GATE: the DoD of a merged wave was only SAID, never done — PR ${mergedOnly.map((p) => '#' + p).join(', ')} are marked "pending deploy / pending / awaiting Playwright" in the op-log with no later DoD-VERIFIED evidence. Do it now, or`
  }));
  process.exit(0);
}
process.stdout.write('{}');
process.exit(0);
