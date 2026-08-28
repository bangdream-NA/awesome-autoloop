#!/usr/bin/env node
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { knownProjects, repoRoots, sessionProject, projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('block-duplicate-planner-dispatch');

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
let payload = {};
try { payload = JSON.parse(read(0) || '{}'); } catch { process.exit(0); }
if ((payload.tool_name || '') !== 'Agent') process.exit(0);

const ti = payload.tool_input || {};
const role = String(ti.subagent_type || '').toLowerCase();
const name = String(ti.name || '');
if (role !== 'planner' && !/^planner[-_a-z0-9]*$/i.test(name)) process.exit(0);

const prompt = String(ti.prompt || '');
if (/#\s*REPLAN-OK:/i.test(prompt)) process.exit(0);

const anchor = (prompt.match(/for wave\s+\*\*([^*\n]+)\*\*/i) || [])[1];
const firstSlug = ((name + ' ' + prompt).match(/(?:R-|wave-)[A-Za-z0-9-]+/i) || [])[0];
const wave = String(anchor || firstSlug || '').trim().replace(/[`*]/g, '');
if (!wave) process.exit(0);
const waveLc = wave.toLowerCase();

const SELF_REPO = sessionProject(payload) || projectPaths(payload)?.repo || '';
const ROOTS = SELF_REPO ? [SELF_REPO] : knownProjects();
const specDirs = [];
for (const r of ROOTS) {
  const d = `${r}/docs/product-specs`;
  if (existsSync(d)) specDirs.push(d);
}
try {
  for (const w of ROOTS.flatMap((r) => repoRoots(r)).filter((r) => !ROOTS.includes(r))) {
    const d = `${w}/docs/product-specs`;
    if (existsSync(d)) specDirs.push(d);
  }
} catch {  }

const hits = [];
for (const dir of specDirs) {
  let files = [];
  try { files = readdirSync(dir).filter((f) => f.endsWith('-plan.md')); } catch { continue; }
  for (const f of files) {
    const slug = f.replace(/-plan\.md$/, '').toLowerCase();
    const nameMatch = slug === waveLc ||
      (slug.startsWith(waveLc + '-') && waveLc.split('-').length >= 3) ||
      (waveLc.startsWith(slug + '-') && slug.split('-').length >= 3);
    if (nameMatch) { hits.push({ path: `${dir}/${f}`, how: 'filename slug' }); continue; }
    let head = '';
    try { head = readFileSync(`${dir}/${f}`, 'utf8').slice(0, 1600); } catch { continue; }
    const declares = new RegExp(
      'backlog\\s+card\\s*[`\'"]?' + waveLc.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '|' +
      '\\*\\*Wave\\*\\*:\\s*' + waveLc.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i');
    if (declares.test(head)) hits.push({ path: `${dir}/${f}`, how: 'doc header names this card' });
  }
}

if (!hits.length) process.exit(0);

{
  const REVIEWS = ROOTS.map((r) => `${r}/.claude/reviews/index.jsonl`);
  const wantsRevision = (() => {
    for (const f of REVIEWS) {
      let txt = '';
      try { txt = readFileSync(f, 'utf8'); } catch { continue; }
      const keys = [waveLc, ...hits.map((h) => h.path.split('/').pop().replace(/-plan\.md$/, '').toLowerCase())];
      let latest = null;
      for (const line of txt.split(/\r?\n/)) {
        if (!line.trim()) continue;
        let row; try { row = JSON.parse(line); } catch { continue; }
        const plan = String(row.plan || '').toLowerCase();
        if (!plan || !keys.some((k) => plan === k || plan.startsWith(k) || k.startsWith(plan))) continue;
        if (String(row.mode || '') !== 'A' && !String(row.reviewer_name || '').includes('planrev')) continue;
        latest = row;
      }
      if (latest && /NEEDS[_ ]REVISION/i.test(String(latest.verdict || ''))) return true;
    }
    return false;
  })();
  if (wantsRevision) process.exit(0);
}

const list = hits.slice(0, 4).map((h) => {
  let age = '';
  try { age = ` (mtime ${new Date(statSync(h.path).mtimeMs).toISOString().slice(0, 10)})`; } catch {  }
  return `${h.path}${age} [matched by ${h.how}]`;
}).join(' · ');

const reason =
  `BLOCKED: DUPLICATE-PLANNER GATE: wave ` +
  `"${wave}" ALREADY HAS A PLAN DOC — ${list}. A second round-1 planner would FORK the spec for one ` +
  `wave. **Read the existing plan first**, then dispatch the CORRECT next step: plan-reviewer (Mode A) ` +
  `if it has no verdict yet or a rev-N to re-review; architect if it's already APPROVED. Check ` +
  `\`.claude/reviews/index.jsonl\` for its latest plan verdict before deciding. ` +
  `INCIDENT THIS GATE EXISTS FOR: 2026-07-28 the lead re-dispatched a planner at a card whose rev2 ` +
  `plan + round-1 review already existed in a worktree (hand-off lost across a rotation) — and the ` +
  `brief recommended a lever that plan's own BLOCKER-1 had already refuted against a MERGED ` +
  `architecture lock. If a genuine fresh replan IS intended (superseded premise), say so explicitly: ` +
  `add \`# REPLAN-OK: <reason>\` to the dispatch prompt.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));
process.exit(0);
