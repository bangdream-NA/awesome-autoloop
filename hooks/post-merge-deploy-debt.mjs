#!/usr/bin/env node
import { readFileSync, appendFileSync, existsSync, mkdirSync, statSync, renameSync } from 'node:fs';
import path from 'node:path';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';

const STATE_DIR = path.join(homeDir(), '.claude/hooks/.state');
function logErr(tag, msg) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    const f = path.join(STATE_DIR, 'hook-errors.log');
    try { if (existsSync(f) && statSync(f).size > 131072) renameSync(f, f + '.1'); } catch {  }
    appendFileSync(f, `${new Date().toISOString()} post-merge-deploy-debt ${tag}: ${String(msg).slice(0, 300)}\n`);
  } catch {  }
}

try {
  let stdin = {};
  try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch (e) { logErr('stdin-parse', e); process.exit(0); }
  if (stdin.tool_name !== 'Bash') process.exit(0);
  const cmd = String(stdin.tool_input?.command || '');
  const cwd = String(stdin.cwd || '');

  if (!/(^|[;&|(]\s*|\b&&\s*|\b\|\|\s*)gh\s+pr\s+merge\b/.test(cmd)) process.exit(0);

  const PROJ = process.env.AAL_PROJECT_NAME || (projectPaths()?.repo || '').replace(/\\/g, '/').split('/').filter(Boolean).pop() || '';
  if (!PROJ) process.exit(0);
  const projRe = new RegExp('\\b' + PROJ.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i');
  if (!projRe.test(cmd) && !projRe.test(cwd)) process.exit(0);
  const DIR = process.env.PMDD_DIR || projectPaths()?.claude || '';

  let pr = null;
  const tail = cmd.slice(cmd.search(/gh\s+pr\s+merge\b/));
  const mUrl = tail.match(/\/pull\/(\d{1,6})(?!\d)/);
  const mNum = tail.match(/\bmerge\s+(?:--\S+\s+)*#?(\d{2,6})(?!\d)/);
  if (mUrl) pr = mUrl[1]; else if (mNum) pr = mNum[1];
  if (!pr) {
    process.stdout.write('post-merge-deploy-debt: merge detected but no PR number in the command — the deploy debt is DERIVED from the board, so find the merged wave\'s card and make sure it carries the FULL-JOURNEY DoD (or a dated machine-verifiable gate). If no card exists for it, that absence is the finding.\n');
    process.exit(0);
  }

  const ledger = path.join(DIR, 'LEAD-DEBTS.md');
  const before = existsSync(ledger) ? readFileSync(ledger, 'utf8') : '';
  process.stdout.write(
    `post-merge-deploy-debt: PR #${pr} merged ⇒ prod deploy + FULL-JOURNEY DoD is now OWED ` +
    `(CLAUDE.md #8). This is DERIVED from the board every round — nothing was written to any ` +
    `ledger, and there is no row to close. It BLOCKS every stop (require-lead-debt-direct) until ` +
    `the card carries real DoD evidence and is ARCHIVED, or carries a dated machine-verifiable ` +
    `gate (\`observe-until YYYY-MM-DD\` + \`gate-observed-at=<ISO Z>\`). If PR #${pr} has no card ` +
    `on the active board, that is itself the finding: register it before stopping.\n`);
  const after = existsSync(ledger) ? readFileSync(ledger, 'utf8') : '';
  if (after !== before) logErr('reroute-violation', `LEAD-DEBTS.md changed during a re-routed run for PR #${pr}`);
  process.exit(0);
} catch (e) {
  logErr('unexpected', e);
  process.exit(0);
}
