#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import {
  isGated, liveBlocker, statusOf, slugOf, mergeOrderWave, waveGateIsLive, OPEN_STATUSES,
} from './backlog-gate.mjs';

const board = process.argv[2];
if (!board) process.exit(0);

let lines;
try {
  lines = readFileSync(board, 'utf8').split(/\r?\n/);
} catch {
  process.exit(0);
}

const headers = [];
lines.forEach((l, i) => { if (/^### \[/.test(l)) headers.push({ n: i + 1, line: l }); });

const openSlugs = new Set(
  headers
    .filter((h) => OPEN_STATUSES.includes(statusOf(h.line)))
    .map((h) => String(slugOf(h.line) || '').toLowerCase())
    .filter(Boolean),
);

const out = [];
for (const h of headers) {
  const status = statusOf(h.line);
  if (!OPEN_STATUSES.includes(status) && status !== 'BLOCKED' && status !== 'USER-GATED') continue;
  if (!isGated(h.line)) continue;
  const tok = liveBlocker(h.line);
  if (!tok) continue;

  let kind = 'other';
  if (/^merge-order:pr#\d+$/i.test(tok)) kind = 'pr';
  else if (mergeOrderWave(tok)) kind = waveGateIsLive(mergeOrderWave(tok), openSlugs) ? 'wave-live' : 'wave-gone';
  else if (/^user$/i.test(tok)) kind = 'user';

  out.push([h.n, slugOf(h.line) || '?', status, kind, 'blocked-by=' + tok].join('\t'));
}

if (out.length) process.stdout.write(out.join('\n') + '\n');
