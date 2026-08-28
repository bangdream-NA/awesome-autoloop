#!/usr/bin/env node
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-design-scope-before-dev');

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { process.exit(0); }
if ((payload.tool_name || '') !== 'Agent') process.exit(0);

const ti = payload.tool_input || {};
const role = String(ti.subagent_type || '').toLowerCase();
const name = String(ti.name || '');
const isDev = role === 'developer' || /^dev[-_]/i.test(name);
const isArch = role === 'architect' || /^arch[-_]/i.test(name);
if (!isDev && !isArch) process.exit(0);

const prompt = String(ti.prompt || '');

let wave =
  (prompt.match(/for wave\s+\*\*\s*([A-Za-z0-9._-]+)\s*\*\*/i) || [])[1] ||
  (prompt.match(/card\s*=\s*`?\s*(R-[A-Za-z0-9._-]+)/i) || [])[1] ||
  (prompt.match(/#\s*CARD:\s*([A-Za-z0-9._-]+)/i) || [])[1] ||
  (name.match(/^(?:dev|arch)[-_]([A-Za-z0-9._-]+)/i) || [])[1] ||
  '';
wave = wave.replace(/[-_]r\d+$/i, '');
if (!wave) process.exit(0);

const cwd = payload.cwd || process.cwd();
let board = '';
try {
  const root = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  board = readFileSync(`${root}/.claude/BACKLOG.md`, 'utf8');
} catch { process.exit(0); }

const key = wave.replace(/^r-/i, '').toLowerCase();
const blocks = board.split(/^###\s+\[/m);
const esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const headRe = new RegExp(`^[A-Za-z-]+\\]\\s+(?:[^\\n]{0,40}?·\\s*)?R-${esc}\\b`, 'i');
let block = blocks.find((b) => headRe.test(b)) || '';
if (!block) {
  const aliasRe = new RegExp(`^-\\s*aliases:.*\\b${esc}\\b`, 'im');
  block = blocks.find((b) => aliasRe.test(b)) || '';
}
if (!block) process.exit(0);
const hay = block + '\n' + prompt;

let YES = /design-scope:\s*(yes|required)|DESIGN-REQUIRED/i.test(hay);
const NO = /design-scope:\s*(no|n\/?a|none)|VISUAL-N\/?A/i.test(hay);

let planWhy = '';
if (!NO) {
  try {
    const root = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
    const dir = `${root}/docs/product-specs`;
    const cands = readdirSync(dir).filter((f) => /-plan\.md$/i.test(f) && f.toLowerCase().includes(key.split('-')[0]));
    for (const f of cands) {
      const txt = readFileSync(`${dir}/${f}`, 'utf8');
      const m1 = txt.match(/^[^\n]*\*\*Designer\*\*[^\n]*$/im) || txt.match(/^[^\n]*needs?\s+a?\s*Designer[^\n]*$/im);
      const m2 = txt.match(/^[^\n]*(?:<h1|visible copy|empty state|button (?:copy|label)|CTA|tap target|hit area|colou?r|spacing|icon)[^\n]*$/im);
      if (m1 || m2) { YES = true; planWhy = `${f}: ${(m1 || m2)[0].trim().slice(0, 150)}`; break; }
    }
  } catch {  }
}

const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

if (NO) process.exit(0);

if (YES) {
  const hasArtifact =
    /DESIGN[_ ]OK\s*@[0-9a-f]{7,40}|DESIGN[_ ]APPROVED|DESIGN DELIVERED|design doc|R-[A-Za-z0-9._-]*-design/i.test(hay) ||
    new RegExp(`${key}[a-z0-9._-]*-?design`, 'i').test(board);
  if (!hasArtifact) {
    deny(
      (planWhy
        ? `BLOCKED: the DESIGNER token is missing — the test is WHAT THE PLAN SAYS, not what the card claims about itself\n\n` +
          `  the line that triggered it (the plan's own words):\n    ${planWhy}\n\n` +
          `  FIX. If it really is design work ⇒ dispatch a \`uiux-designer\` first (it runs BEFORE the architect), and once it delivers write \`- log: <ISO Z> · DESIGN_OK @<sha>\` on the card.\n` +
          `  If no visible layer is involved ⇒ write \`design-scope: no\` plus a reason on the card header; that exemption wins.\n` +
          `  NOTE: rewording the plan does not route around this — the test is what the plan DELIVERS, not what it calls itself.\n\n`
        : '') +
      `BLOCKED: the card for "${wave}" says design-scope: yes, and no designer artifact exists yet` +
      ` (no DESIGN_APPROVED or "DESIGN DELIVERED" on the card, and no R-${key}-design document).\n` +
      `FIX: dispatch the uiux-designer first, then re-dispatch the developer.`,
    );
  }
  process.exit(0);
}

deny(
  `BLOCKED: dispatching a developer for "${wave}" while the card carries no design-scope declaration\n\n` +
  `FIX. Add exactly ONE of these to the card:\n` +
  `  · design-scope: yes — this wave introduces or changes a component, a design token, typography, a11y semantics, or visible layout;\n` +
  `    then dispatch the uiux-designer first and the developer after.\n` +
  `  · design-scope: no — <reason> — backend, data, tests or CI only, with no visible design decision.\n` +
  `You can also assert it directly in this dispatch prompt.`,
);
