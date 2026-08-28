#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { isDodFailedDialectDrift, statusOf } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('backlog-dialect-drift');

const REMEDY =
  'FIX: add `dod-failed-at=<ISO Z>` (from `date -u +%Y-%m-%dT%H:%M:%SZ`) to that card block if the ' +
  'failure is LIVE — that field is the only thing the enforcing gate reads. If the failure was ' +
  'RESOLVED, say so on the same line ("released") or record `dod-failed-cleared-at=<ISO Z>`. ' +
  'Prose alone is invisible to backlog-sop-validate.mjs: that is how this lock went blind on ' +
  '2026-07-28 after working for a day.';

function scan(boardText) {
  const out = [];
  for (const block of String(boardText || '').split(/\n(?=### \[)/)) {
    if (!/^### \[/.test(block)) continue;
    if (!isDodFailedDialectDrift(block)) continue;
    const header = block.split('\n')[0];
    out.push({
      name: (header.match(/R-[a-z0-9-]+/i) || ['(card)'])[0],
      status: statusOf(header),
      line: (block.split('\n').find((l) => /DoD[-\s]?FAILED/i.test(l)) || '').trim().slice(0, 120),
    });
  }
  return out;
}

const i = process.argv.indexOf('--board');
if (i >= 0) {
  const board = process.argv[i + 1];
  if (!board) { console.error('usage: node backlog-dialect-drift.mjs --board <BACKLOG.md> [--list]'); process.exit(2); }
  let txt;
  try { txt = readFileSync(board, 'utf8'); } catch (e) { console.error(`cannot read ${board}: ${e.message}`); process.exit(2); }
  const hits = scan(txt);
  const headers = txt.split(/\r?\n/).filter((l) => /^### \[/.test(l)).length;
  const mentions = txt.split(/\r?\n/).filter((l) => /DoD[-\s]?FAILED/i.test(l)).length;
  const released = txt.split(/\r?\n/).filter((l) => /DoD[-\s]?FAILED/i.test(l) && /\b(?:released|cleared|RELEASED)\b/i.test(l)).length;
  console.log(`board                       : ${board}`);
  console.log(`card headers                : ${headers}`);
  console.log(`lines mentioning DoD-FAILED : ${mentions}  (of which recorded as released: ${released})`);
  console.log(`DIALECT DRIFT (live claim, no dod-failed-at= field) : ${hits.length}`);
  if (process.argv.includes('--list')) for (const h of hits) console.log(`   ${h.name} [${h.status}] :: ${h.line}`);
  process.exit(hits.length ? 1 : 0);
}

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }
const BOARD = process.env.AAL_BACKLOG || projectPaths()?.board || '';
let board = '';
try { board = readFileSync(BOARD, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }
const hits = scan(board);
if (!hits.length) { process.stdout.write('{}'); process.exit(0); }
process.stdout.write(JSON.stringify({
  decision: 'block',
  reason:
    `DoD-FAILED DIALECT DRIFT: ${hits.length} card(s) assert a LIVE DoD failure in PROSE ` +
    `while the same card block carries no \`dod-failed-at=\` field — the enforcing gate ` +
    `(the DoD-FAILED LOCK in backlog-sop-validate.mjs) cannot see them, so the board looks like it has failures while every gate allows.\n` +
    hits.map((h) => `- ${h.name} [${h.status}] :: ${h.line}`).join('\n') + `\n${REMEDY}`,
}));
process.exit(0);
