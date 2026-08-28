#!/usr/bin/env node
import './_lib.mjs';

import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

// Ported verbatim this file carried two absolute machine paths: the gate under the author's
// <config-dir> and a board inside a specific project checkout. Both are AC9b scrub payload, and both
// made the fixture test something this repository does not ship. The gate now resolves relative to
// this fixture, and the board is SYNTHESIZED — a fixture that reads a live board is not repeatable.
const DELEGATE = join(dirname(dirname(fileURLToPath(import.meta.url))), 'backlog-ownership-token-required.mjs');
const BOARD = join(mkdtempSync(join(tmpdir(), 'aal-ownertok-')), 'BACKLOG.md');
writeFileSync(BOARD, [
  '# Task Backlog',
  '',
  '## ACTIVE',
  '',
  '### [REVIEW] R-sample-wave · PR #1 · P2',
  '- aliases: r-sample-wave',
  '- problem: a synthesized card, so this fixture does not depend on any real board',
  '- fix: none',
  '',
].join('\n'));

const envelope = (filePath, content) => JSON.stringify({
  session_id: 'selftest', tool_name: 'Write',
  tool_input: { file_path: filePath, content },
});

function run(filePath, content) {
  const r = spawnSync('node', [DELEGATE], { input: envelope(filePath, content), encoding: 'utf8', timeout: 15000 });
  const out = String(r.stdout || '').trim();
  let json = null;
  try { json = out ? JSON.parse(out) : null; } catch {  }
  const decision = json?.hookSpecificOutput?.permissionDecision || 'allow';
  return { decision, status: r.status, reason: json?.hookSpecificOutput?.permissionDecisionReason || '', raw: out };
}

let pass = 0, fail = 0;
const arm = (label, mustBe, filePath, content, extra) => {
  const r = run(filePath, content);
  const ok = r.decision === mustBe && (!extra || extra(r));
  if (ok) { pass++; console.log(`PASS  [${label}] → ${r.decision}`); }
  else { fail++; console.error(`FAIL  [${label}] want ${mustBe}, got ${r.decision}` + (r.status !== 0 ? ` (exit ${r.status} — WRONG CHANNEL: guard would read this as errored and ALLOW)` : '') + `\n        reason: ${r.reason.slice(0, 160)}`); }
};

const B = '/repo/.claude/BACKLOG.md';
const hdr = (s) => `## Active\n\n${s}\n- aliases: R-x\n- log: 2026-08-02T00:00:00Z · something\n`;

console.log('--- MUST-RED arms (each is a shape that actually bit the lead on 2026-08-02) ---');

arm('R1 stage=review, no token', 'deny', B,
  hdr('### [REVIEW] R-a · stage=review · 🟠 P1 · **title**'),
  (r) => /PR #/.test(r.reason));

arm('R2 bolded PR **#1161**', 'deny', B,
  hdr('### [REVIEW] R-b · stage=review · **PR **#1161**** · 🟠 P1 · **title**'));

arm('R3 token only in body log line', 'deny', B,
  `## Active\n\n### [IN-DEV] R-c · stage=review · P1 · **title**\n- aliases: R-c\n- log: 2026-08-02T00:00:00Z · opened PR #1177, dispatched the reviewer\n`);

arm('R4 [REVIEW] status, no stage=, no token', 'deny', B,
  hdr('### [REVIEW] R-d · 🟠 P1 · **title**'));

arm('R5 stage=pr, no token', 'deny', B,
  hdr('### [IN-DEV] R-e · stage=pr · 🟠 P1 · **title**'));

console.log('\n--- MUST-GREEN controls (a gate that cannot allow is as broken as one that cannot deny) ---');

arm('G1 undecorated PR #1177', 'allow', B,
  hdr('### [REVIEW] R-f · stage=review · PR #1177 · 🟠 P1 · **title**'));

arm('G2 [QUEUED] stage=new, no token', 'allow', B,
  hdr('### [QUEUED] R-g · stage=new · 🟠 P1 · **title**'));

arm('G3 spec doc discussing the syntax', 'allow',
  '/repo/docs/product-specs/R-x-plan.md',
  '### [REVIEW] R-h · stage=review · 🟠 P1 · **a card at stage=review must carry PR #N**\n');

arm('G4 MERGED #998 form', 'allow', B,
  hdr('### [REVIEW] R-i · stage=review · ✅ MERGED #998 · 🟠 P1 · **title**'));

if (existsSync(BOARD)) {
  const real = readFileSync(BOARD, 'utf8');
  const reviewCards = real.split(/\r?\n/).filter((l) => /^### \[/.test(l) && (/stage=(pr|review)\b/.test(l) || /^### \[REVIEW\]/.test(l))).length;
  console.log(`      (production board carries ${reviewCards} in-scope card header(s) — a 0 here would make G5 vacuous)`);
  arm('G5 PRODUCTION BACKLOG.md replayed', 'allow', BOARD, real);
} else { fail++; console.error('FAIL  [G5] production board not found — the control cannot be fed its real payload'); }

console.log('\n--- REACHABILITY control (proves the harness reaches the delegate at all) ---');
const probe = run(B, hdr('### [REVIEW] R-z · stage=review · 🟠 P1 · **title**'));
if (probe.decision === 'deny' && probe.status === 0) { pass++; console.log('PASS  [reach] harness reaches the delegate AND reads the deny off stdout with exit 0'); }
else { fail++; console.error(`FAIL  [reach] decision=${probe.decision} exit=${probe.status} — if exit!==0 the guard reads ERRORED and SILENTLY ALLOWS`); }

console.log(`\n[arms] ${pass} passed + ${fail} failed = ${pass + fail} arms ran`);
process.exit(fail === 0 ? 0 : 1);
