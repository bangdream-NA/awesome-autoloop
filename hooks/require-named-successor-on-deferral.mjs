#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync, appendFileSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-named-successor-on-deferral');

const SELFTEST = process.argv.includes('--self-test');

const DEFERRAL = [
  /\bthe next\b[^.\n]{0,12}\b(?:window|wave|round|cutover)\b/i,
  /\b(?:another|a separate|a second)\b[^.\n]{0,8}\b(?:wave|card)\b/i,
  /\b(?:a )?(?:follow-?up|later|separate)\s+(?:wave|card)\b/i,
  /separate\s+wave/i,
  /follow-?up\s+card/i,
  /(is|are)\s+a\s+separate\s+/i,
  /\bleft (?:to|for)\b[^.\n]{0,10}\b(?:wave|card)\b/i,
];
const SLUG = /\bR-[a-z0-9][a-z0-9-]{4,}/g;
const PRREF = /(?:PR\s*)?#(\d{2,5})\b/g;
const WINDOW = 160;

function boardSlugs(bkPath) {
  const dir = dirname(bkPath);
  const out = new Set();
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => /^BACKLOG.*\.md$/.test(f)).map((f) => join(dir, f));
  } catch { return out; }
  for (const f of files) {
    let t = '';
    try { t = readFileSync(f, 'utf8'); } catch { continue; }
    for (const line of t.split(/\r?\n/)) {
      if (!line.startsWith('### ')) continue;
      const m = line.match(/\bR-[a-z0-9][a-z0-9-]{4,}/);
      if (m) out.add(m[0].toLowerCase());
    }
  }
  return out;
}

export function offendingDeferrals(added, known) {
  const bad = [];
  for (const re of DEFERRAL) {
    const g = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
    let m;
    while ((m = g.exec(added)) !== null) {
      const from = Math.max(0, m.index - WINDOW);
      const to = Math.min(added.length, m.index + m[0].length + WINDOW);
      const near = added.slice(from, to);
      const slugs = (near.match(SLUG) || []).map((s) => s.toLowerCase());
      const named = slugs.some((s) => known.size === 0 || known.has(s));
      const after = added.slice(m.index + m[0].length, to);
      const prAfter = (after.match(PRREF) || []).length > 0;
      if (!named && !prAfter) bad.push(m[0]);
      if (g.lastIndex === m.index) g.lastIndex++;
    }
  }
  return bad;
}

function main() {
  let payload = {};
  try { payload = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const tool = payload.tool_name || '';
  if (tool !== 'Edit' && tool !== 'Write') process.exit(0);
  const ti = payload.tool_input || {};
  const fp = ti.file_path || '';
  if (!/BACKLOG[^/\\]*\.md$/.test(basename(fp))) process.exit(0);

  const added = tool === 'Write' ? (ti.content || '') : (ti.new_string || '');
  if (!added) process.exit(0);

  const known = boardSlugs(fp);
  const bad = offendingDeferrals(added, known);
  if (!bad.length) process.exit(0);

  const reason =
    'BLOCKED: a deferral phrase that names nobody to take it:\n' + bad.map((b) => `  • "${b}"`).join('\n') +
    '\nThe way out: put an `R-<slug>` in the same sentence (it has to exist already), or a `#<PR>` AFTER the deferral phrase. If no card exists, file one first.' +
    '\nNOTE: a PR number BEFORE the phrase does not count — that describes the thing being EXCLUDED.';

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

if (SELFTEST) {
  const known = new Set(['r-w3-sudo-allowlist-skeleton-blocks-cut2', 'r-deploy-phase2-cut2-sudo']);
  let pass = 0, fail = 0;
  const arm = (label, added, wantBad) => {
    const got = offendingDeferrals(added, known).length > 0;
    const ok = got === wantBad;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label.padEnd(64)} want=${wantBad ? 'DENY' : 'allow'} got=${got ? 'DENY' : 'allow'}`);
    ok ? pass++ : fail++;
  };
  console.log('── MUST-RED: the real sentence that cost us the outage ──');
  arm('A1 verbatim card shape — "the next cutover window", no name',
    '- log: this card\u2019s DoD does not include adding the 8 new wrappers to the allowlist; installing the new build is the next cutover window.', true);
  arm('A2 THE TRAP — the same sentence carrying #1193 BEFORE the deferral',
    '- log: this card\u2019s DoD does not include the 8 wrappers #1193 added to the allowlist; installing the new build is the next cutover window.', true);
  arm('A3 English — "Rewriting the call sites is a separate wave"',
    'Rewriting 18-app-deploy.sh to call the wrappers is a separate wave.', true);
  arm('A4 names a slug that does NOT exist on the board',
    'installing the new build is the next cutover window, handed to R-no-such-card-at-all.', true);
  console.log('\n── MUST-GREEN: the three cards that did it right ──');
  arm('B1 names an existing slug next to the deferral',
    'this card\u2019s DoD does not include installing the allowlist on the production box; the follow-up wave R-w3-sudo-allowlist-skeleton-blocks-cut2 takes it.', false);
  arm('B2 PR number AFTER the deferral phrase',
    'installing the new build is the next cutover window, see #1229.', false);
  arm('B3 wikilink form',
    'this part is left to another wave, [[R-deploy-phase2-cut2-sudo]].', false);
  console.log('\n── MUST-GREEN: incidental text (§7 requires this arm) ──');
  arm('C1 no deferral phrase at all', 'this card\u2019s DoD does not include X, because that surface structurally does not exist.', false);
  arm('C2 the word wave with no hand-off', 'this wave delivers three guards.', false);
  arm('C3 incidental — quoting the rule text itself, successor named',
    'What this gate says: any "the next cutover window" has to name someone, for example R-deploy-phase2-cut2-sudo.', false);
  arm('C4 incidental — "another wave" with an existing slug in range',
    'this part belongs to [[R-w3-sudo-allowlist-skeleton-blocks-cut2]], not to another wave.', false);

  console.log('\n── PRODUCTION PATH: real hook stdin, not the exported function ──');
  const { execFileSync } = await import('node:child_process');
  const { writeFileSync, mkdtempSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const d = mkdtempSync(join(tmpdir(), 'defergate-'));
  const bk = join(d, 'BACKLOG.md');
  writeFileSync(bk, '### [QUEUED] R-w3-sudo-allowlist-skeleton-blocks-cut2 · P2 · **x**\n', 'utf8');
  const run = (input) => {
    const p = JSON.stringify(input);
    try { return execFileSync('node', [process.argv[1]], { input: p, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }); }
    catch (e) { return (e.stdout || '') + (e.stderr || ''); }
  };
  const denied = (o) => /permissionDecision"\s*:\s*"deny"/.test(o);
  const P = (label, input, want) => {
    const got = denied(run(input));
    const ok = got === want;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label.padEnd(64)} want=${want ? 'DENY' : 'allow'} got=${got ? 'DENY' : 'allow'}`);
    ok ? pass++ : fail++;
  };
  P('P1 real Edit payload, nameless deferral', { tool_name: 'Edit', tool_input: { file_path: bk, new_string: 'installing the new build is the next cutover window.' } }, true);
  P('P2 real Edit payload, existing slug named', { tool_name: 'Edit', tool_input: { file_path: bk, new_string: 'the follow-up wave R-w3-sudo-allowlist-skeleton-blocks-cut2 takes it.' } }, false);
  P('P3 slug that is NOT on this board', { tool_name: 'Edit', tool_input: { file_path: bk, new_string: 'the follow-up wave R-totally-made-up-card takes it.' } }, true);
  P('P4 wrong file — must no-op', { tool_name: 'Edit', tool_input: { file_path: join(d, 'notes.md'), new_string: 'installing the new build is the next cutover window.' } }, false);
  P('P5 wrong tool — must no-op', { tool_name: 'Bash', tool_input: { command: 'installing the new build is the next cutover window' } }, false);

  console.log('\n── PRODUCTION SHAPE: Write of a file that does NOT exist yet ──');
  P('P6 new-file Write, deferral + a slug-shaped token that is NOT a real card',
    { tool_name: 'Write', tool_input: { file_path: join(d, 'BACKLOG-brandnew.md'),
      content: '### [QUEUED] R-hookprobe-2 · P3\n- problem: installing the new build is the next cutover window.\n' } }, true);
  P('P7 new-file Write, deferral naming a REAL card on that board',
    { tool_name: 'Write', tool_input: { file_path: join(d, 'BACKLOG-brandnew2.md'),
      content: '- problem: the follow-up wave R-w3-sudo-allowlist-skeleton-blocks-cut2 takes it.\n' } }, false);
  P('P8 new-file Write, deferral with no name at all',
    { tool_name: 'Write', tool_input: { file_path: join(d, 'BACKLOG-brandnew3.md'),
      content: '- problem: installing the new build is the next cutover window.\n' } }, true);

  console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} ${pass} passed, ${fail} failed`);
  console.log('NOTE: A2 is the arm that matters: a naive "is there a PR number anywhere" check');
  console.log('   PASSES it, because #1193 describes the EXCLUDED thing, not the successor.');
  console.log('NOTE: P1-P5 exercise the REAL stdin path; the exported predicate is not what runs.');
  process.exit(fail === 0 ? 0 : 1);
} else {
  main();
}
