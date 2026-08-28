#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-expiry-on-freeze-notice');

const SELFTEST = process.argv.includes('--self-test');

const FREEZE = [
  /\b(deploy\w*|publish\w*|releas\w*)\b[^.\n]{0,20}\b(?:is )?(?:frozen|freeze|paused|suspended|halted)\b/i,
  /\b(?:freeze|frozen|pause|paused|suspend|suspended)\b[^.\n]{0,12}\b(deploy\w*|publish\w*|releas\w*)\b/i,
  /\bdeploys?\s+are\s+frozen\b/i,
  /\bfrozen\s+(between|until|from)\b/i,
  /\bMUST\s+NOT\s+be\s+run\b/i,
  /\b(do\s+not|don'?t)\s+run\b[^.\n]{0,40}\buntil\b/i,
  /\bdo not (?:run|execute|trigger) (?:it|this|that) for now\b/i,
];
const ENDPOINT = [
  /\bR-[a-z0-9][a-z0-9-]{4,}/,
  /(?:PR\s*)?#\d{2,5}\b/,
  /20\d\d-\d\d-\d\d/,
  /\bUNFREEZE-WHEN\s*:/i,
  /\bobserve-until\b/i,
];
const WINDOW = 400;

const EXEMPT_BASENAME = /^(struggle-log.*|autoloop-log.*|BACKLOG.*|.*-plan|.*-architecture)\.md$/i;

export function offendingFreezes(added) {
  const bad = [];
  for (const re of FREEZE) {
    const g = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
    let m;
    while ((m = g.exec(added)) !== null) {
      const from = Math.max(0, m.index - WINDOW);
      const to = Math.min(added.length, m.index + m[0].length + WINDOW);
      const near = added.slice(from, to);
      if (!ENDPOINT.some((e) => e.test(near))) bad.push(m[0]);
      if (g.lastIndex === m.index) g.lastIndex++;
    }
  }
  return bad;
}

function main() {
  let payload = {};
  try { payload = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const tool = payload.tool_name || '';
  if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) process.exit(0);
  const ti = payload.tool_input || {};
  const fp = ti.file_path || '';
  if (!fp) process.exit(0);
  if (EXEMPT_BASENAME.test(basename(fp))) process.exit(0);

  let added = '';
  if (tool === 'Write') added = ti.content || '';
  else if (tool === 'Edit') added = ti.new_string || '';
  else if (tool === 'MultiEdit') added = (ti.edits || []).map((e) => e.new_string || '').join('\n');
  if (!added) process.exit(0);

  const bad = offendingFreezes(added);
  if (!bad.length) process.exit(0);

  const reason =
    'BLOCKED: a freeze or pause notice with no decidable endpoint:\n' + bad.map((b) => `  • "${b}"`).join('\n') +
    '\nThe way out: nearby, write an `R-<slug>` · a `#<PR>` · an ISO date · or `UNFREEZE-WHEN: <condition>`. If the endpoint has no owner, file the card first.' +
    '\nNOTE: the struggle log, the op-log, BACKLOG and plan/architecture documents are all exempt from this gate.';

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

if (SELFTEST) {
  let pass = 0, fail = 0;
  const arm = (label, text, wantBad) => {
    const got = offendingFreezes(text).length > 0;
    const ok = got === wantBad;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label.padEnd(60)} want=${wantBad ? 'DENY' : 'allow'} got=${got ? 'DENY' : 'allow'}`);
    ok ? pass++ : fail++;
  };
  console.log('── MUST-RED: the real notice that hid a real outage ──');
  arm('A1 the verbatim allowlist header, endpoint is prose only',
    '# Deploys are frozen between step 9 and the landing of the provisioning-surface\n# wave. See the architecture.', true);
  arm('A2 second phrasing, no endpoint', 'Deploys are halted until that wave lands.', true);
  arm('A3 MUST NOT be run, no endpoint',
    '`18-app-deploy.sh`, `verify-state.sh` and `20-ci-runner.sh` MUST NOT be run against this box.', true);
  arm('A4 "do not run … until" with a nameless until', 'Do not run the deploy script until the successor lands.', true);

  console.log('\n── MUST-GREEN: the same notices, made expirable ──');
  arm('B1 names a card slug', '# Deploys are frozen until R-deploy-phase2-cut2-sudo lands.', false);
  arm('B2 names a PR', 'Deploys are halted until #1229 merges.', false);
  arm('B3 carries a dated deadline', 'MUST NOT be run against this box before 2026-08-10.', false);
  arm('B4 explicit marker', 'Deploys are frozen. UNFREEZE-WHEN: the census reports bucket 0 = 0.', false);

  console.log('\n── MUST-GREEN: incidental text (§7 requires this arm) ──');
  arm('C1 the word frozen with no prohibition', 'The historical numbers in this table are frozen and must not be re-baselined.', false);
  arm('C2 past tense narration', 'That freeze ended on 08-02.', false);
  arm('C3 unrelated prose', 'This wave delivers three guards and one runbook section.', false);

  console.log('\n── PRODUCTION PATH: real stdin, incl. the exempt-corpus arm ──');
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const d = mkdtempSync(join(tmpdir(), 'freezegate-'));
  const run = (input) => {
    try { return execFileSync('node', [process.argv[1]], { input: JSON.stringify(input), encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }); }
    catch (e) { return (e.stdout || '') + (e.stderr || ''); }
  };
  const denied = (o) => /permissionDecision"\s*:\s*"deny"/.test(o);
  const P = (label, input, want) => {
    const got = denied(run(input));
    const ok = got === want;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label.padEnd(60)} want=${want ? 'DENY' : 'allow'} got=${got ? 'DENY' : 'allow'}`);
    ok ? pass++ : fail++;
  };
  P('P1 runbook Write, nameless freeze', { tool_name: 'Write', tool_input: { file_path: join(d, 'app-deploy.md'), content: 'Deploys are frozen between step 9 and the wave.' } }, true);
  P('P2 runbook Write, freeze naming a card', { tool_name: 'Write', tool_input: { file_path: join(d, 'app-deploy.md'), content: 'Deploys are frozen until R-deploy-phase2-cut2-sudo lands.' } }, false);
  P('P3 sudoers config Edit, nameless freeze', { tool_name: 'Edit', tool_input: { file_path: join(d, 'deploy-allowlist'), new_string: '# Deploys are halted until that wave lands.' } }, true);
  P('P4 EXEMPT — the op-log may describe a freeze', { tool_name: 'Write', tool_input: { file_path: join(d, 'autoloop-log-2026-08-06-x.md'), content: 'Deploys are frozen between step 9 and the wave.' } }, false);
  P('P5 EXEMPT — the struggle log may quote it', { tool_name: 'Write', tool_input: { file_path: join(d, 'struggle-log.md'), content: 'Deploys are halted until that wave lands.' } }, false);
  P('P6 wrong tool — must no-op', { tool_name: 'Bash', tool_input: { command: 'echo Deploys are frozen' } }, false);

  console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} ${pass} passed, ${fail} failed`);
  console.log('NOTE: A1 is the sentence that actually cost days: correct, scoped, approved — and unexpirable.');
  console.log('NOTE: P4/P5 matter as much: a gate that stops you WRITING DOWN the incident is a gate that erases its own evidence.');
  process.exit(fail === 0 ? 0 : 1);
} else {
  main();
}
