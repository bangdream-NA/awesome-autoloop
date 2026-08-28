#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join } from 'node:path';

// Board path: AAL_BACKLOG override → CLAUDE_PROJECT_DIR/.claude → cwd/.claude (mirrors the framework's
const BACKLOG = process.env.AAL_BACKLOG
  || (process.env.CLAUDE_PROJECT_DIR
        ? join(process.env.CLAUDE_PROJECT_DIR, '.claude/BACKLOG.md')
        : join(process.cwd(), '.claude/BACKLOG.md'));
function resolveRepo() {
  if (process.env.AAL_REPO) return process.env.AAL_REPO;
  try {
    const url = execSync('git remote get-url origin', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const m = url.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
    return m ? m[1] : '';
  } catch { return ''; }
}
const REPO = resolveRepo();
const ACTIVE = new Set(['QUEUED', 'IN-DEV', 'REVIEW']);

const norm = (s) => (s || '').toLowerCase().replace(/^feat\//, '').replace(/^t-\d+\s+/, '').replace(/[`*~]/g, '').trim();
const waveTok = (s) => (String(s).match(/((?:T-\d+\s+)?(?:R-|wave-|ROUND-)[A-Za-z0-9-]+)/) || [])[1] || s;

let text;
try { text = readFileSync(BACKLOG, 'utf8'); }
catch { console.log(`backlog-reconcile: no BACKLOG at ${BACKLOG} (skip)`); process.exit(0); }
const lines = text.split(/\r?\n/);

const cards = [];
const bareBadge = [];
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^###\s+\[([A-Z-]+)\]\s+(.+)$/);
  if (!m) {
    if (/^###\s+(?!\[)\S/.test(lines[i])) bareBadge.push(lines[i].replace(/^###\s+/, '').split('·')[0].split('(')[0].trim());
    continue;
  }
  const status = m[1];
  const headerRest = m[2];
  const name = headerRest.split('·')[0].split('(')[0].trim();
  const body = [lines[i]];
  for (let j = i + 1; j < lines.length && !/^#{2,3}\s/.test(lines[j]); j++) body.push(lines[j]);
  const block = body.join('\n');
  const am = block.match(/aliases:\s*(.+)/i);
  const aliases = am ? am[1].split(',').map((x) => norm(x)).filter(Boolean) : [];
  const ackM = headerRest.match(/MERGED\s*#(\d+)/i) || block.match(/✅\s*MERGED\s*#(\d+)/i);
  cards.push({ status, name, slug: norm(waveTok(name)), aliases, ackPR: ackM ? ackM[1] : null });
}

const queue = [];
for (const l of lines) {
  const m = l.match(/^\d+\.\s+(.+)$/);
  if (!m) continue;
  const body = m[1];
  let status = null;
  if (/~~[^~]+~~/.test(body) || /✅\s*DONE/i.test(body)) status = 'DONE';
  else { const b = body.match(/\[(QUEUED|IN-DEV|REVIEW|BLOCKED|USER-GATED)\]/); if (b) status = b[1]; }
  const donePR = (body.match(/#(\d+)/) || [])[1] || null;
  const sm = body.match(/((?:T-\d+\s+)?(?:R-|wave-|ROUND-)[A-Za-z0-9-]+)/);
  if (!sm) continue;
  queue.push({ status, slug: norm(sm[1]), donePR });
}

let merged = [], open = [], ghOk = Boolean(REPO);
const ghList = (state) => {
  const out = execSync(`gh pr list --repo ${REPO} --state ${state} --limit 80 --json number,headRefName,title`,
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 });
  return JSON.parse(out).map((p) => ({ number: p.number, branch: norm(p.headRefName), title: (p.title || '').toLowerCase() }));
};
if (ghOk) {
  try { merged = ghList('merged'); open = ghList('open'); }
  catch { ghOk = false; }
}

const drift = [];
const verify = [];
const info = [];
for (const nm of bareBadge) drift.push(`[bare-badge] "${nm}": a "### ✅/DONE/MERGED" done-marker on the ACTIVE board (no [STATUS] bracket) → done cards belong in BACKLOG-archive.md; move it.`);

const qBySlug = new Map(queue.map((q) => [q.slug, q]));
for (const c of cards) {
  const q = qBySlug.get(c.slug);
  if (q && q.status && q.status !== c.status) {
    drift.push(`[A internal] ${c.name}: card=[${c.status}] but P-queue=[${q.status}]`);
  }
}

if (ghOk) {
  const mergedByNum = new Map(merged.map((p) => [String(p.number), p]));
  const openByNum = new Map(open.map((p) => [String(p.number), p]));
  const core = (s) => s.replace(/^(r-|wave-)/, '');
  for (const c of cards) {
    if (!ACTIVE.has(c.status)) continue;
    if (c.ackPR) {
      if (mergedByNum.has(c.ackPR)) { info.push(`[B merged·DoD-pending] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED; card acks it (confirm the DoD note is genuinely pending, else archive)`); continue; }
      if (openByNum.has(c.ackPR)) { info.push(`[B open] ${c.name} [${c.status}] ← PR #${c.ackPR} still OPEN (DoD-pending)`); continue; }
      drift.push(`[B bad-ack] ${c.name} [${c.status}] claims MERGED #${c.ackPR}, but #${c.ackPR} is neither merged nor open (stale / wrong PR#)`); continue;
    }
    const keys = [c.slug, ...c.aliases];
    const exact = merged.find((p) => keys.includes(p.branch));
    if (exact) { drift.push(`[B unacked-merge] ${c.name} [${c.status}] but PR #${exact.number} (${exact.branch}) is MERGED and the card has NO MERGED ack → annotate or archive`); continue; }
    const fuzzy = merged.find((p) => { const pc = core(p.branch); return pc.length > 6 && keys.some((k) => core(k).includes(pc) || pc.includes(core(k))); });
    if (fuzzy) { verify.push(`[B? naming] ${c.name} [${c.status}] — merged PR #${fuzzy.number} (${fuzzy.branch}) MAY be this wave (branch name diverges; verify + add a "MERGED #${fuzzy.number}" ack)`); continue; }
    const openHit = open.find((p) => keys.includes(p.branch));
    if (openHit && c.status !== 'REVIEW') verify.push(`[B open] ${c.name} [${c.status}] — OPEN PR #${openHit.number} (expected REVIEW?)`);
  }
}

const parts = [];
parts.push(`backlog-reconcile (READ-ONLY): ${cards.length} cards (${cards.filter(c=>ACTIVE.has(c.status)).length} active), ${queue.length} queue rows, gh=${ghOk ? `${merged.length} merged/${open.length} open` : 'UNAVAILABLE'}`);
if (drift.length) { parts.push(`⚠️ ${drift.length} DRIFT (actionable):`); for (const d of drift) parts.push(`   - ${d}`); }
if (verify.length) { parts.push(`🔍 ${verify.length} to verify (naming-limited):`); for (const v of verify) parts.push(`   - ${v}`); }
if (info.length) { parts.push(`ℹ️ ${info.length} merged·DoD-pending (FYI, not drift):`); for (const x of info) parts.push(`   - ${x}`); }
if (!drift.length && !verify.length && !info.length) parts.push('✅ no drift / nothing to verify (board internally consistent + no merged-but-active waves)');
const report = parts.join('\n');

if (process.env.CLAUDE_HOOK || process.argv.includes('--hook')) {
  const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
  if (drift.length || verify.length) console.log(`{"systemMessage":"${esc(report)}"}`);
} else {
  console.log(report);
}
process.exit(0);
