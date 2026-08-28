#!/usr/bin/env node
import { readFileSync, readdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
import path from 'node:path';
import { jsonlPlanVerdict } from './lib/plan-verdict.mjs';
import { stripHtmlComments } from './lib/strip-html-comments.mjs';

const argMode = (() => { const i = process.argv.indexOf('--mode'); if (i >= 0) return process.argv[i + 1]; const f = process.argv.find((a) => a.startsWith('--mode=')); return f ? f.split('=')[1] : 'report'; })();
// Resolution: AAL_BACKLOG env → CLAUDE_PROJECT_DIR/.claude/BACKLOG.md → cwd/.claude/BACKLOG.md.
let BACKLOG = process.env.AAL_BACKLOG
  || (process.env.CLAUDE_PROJECT_DIR ? path.join(process.env.CLAUDE_PROJECT_DIR, '.claude', 'BACKLOG.md') : path.join(process.cwd(), '.claude', 'BACKLOG.md'));
const ARCHIVE = process.env.AAL_ARCHIVE || path.join(path.dirname(BACKLOG), 'BACKLOG-archive.md');
let CLAUDE_DIR = path.dirname(BACKLOG);
const STATUS_WL = ['QUEUED', 'IN-DEV', 'REVIEW', 'BLOCKED', 'USER-GATED'];
const TRANSITIONS = ['REGISTERED', 'PLAN_APPROVED', 'ARCH_APPROVED', 'DEV_DELIVERED', 'PR_OPENED', 'REVIEW_APPROVED', 'REVIEW_NEEDS_FIXES', 'MERGED', 'DEPLOYED', 'DOD_PASS', 'ARCHIVED'];

const rd = (f) => { try { return readFileSync(f, 'utf8'); } catch { return null; } };
const splitL = (t) => (t || '').split(/\r?\n/);
const norm = (s) => String(s || '').toLowerCase().replace(/^feat\//, '').replace(/^t-\d+\s+/, '').replace(/[`*~]/g, '').trim();
const waveTok = (s) => (String(s).match(/((?:T-\d+\s+)?(?:R-|wave-|ROUND-)[A-Za-z0-9-]+)/) || [])[1] || s;

const waveCompat = (a, b) => { if (a === b) return true; const [s, l] = a.length <= b.length ? [a, b] : [b, a]; return l.startsWith(s + '-') && s.split('-').length >= 3; };
const orderedWaveCands = (name, prompt) => {
  const anchor = (String(prompt).match(/for wave\s+\*\*([^*\n]+)\*\*/i) || [])[1];
  const raw = ((String(name || '') + ' ' + String(prompt || '')).match(/(?:R-|wave-)[A-Za-z0-9-]+/gi) || []);
  return [...new Set([...(anchor ? [anchor] : []), ...raw].map((s) => norm(s)))];
};
const locateCardByPriority = (cands, cards) => {
  for (const k of cands) { const c = cards.find((card) => waveCompat(k, card.slug) || card.aliases.some((al) => waveCompat(k, al))); if (c) return c; }
  return null;
};

let PLAN_REVIEWS = process.env.AAL_PLAN_REVIEWS || path.join(CLAUDE_DIR, 'plan-reviews.md');
let REVIEWS_JSONL = process.env.AAL_REVIEWS_JSONL || path.join(CLAUDE_DIR, 'reviews', 'index.jsonl');
const planReviewFiles = () => {
  const dir = path.dirname(PLAN_REVIEWS), active = path.basename(PLAN_REVIEWS);
  let parts = [];
  try { parts = readdirSync(dir).filter((f) => /^plan-reviews.*\.md$/.test(f) && f !== active); } catch {  }
  return [PLAN_REVIEWS, ...parts.sort().reverse().map((f) => path.join(dir, f))];
};
const planReviewApproved = (cands, card) => {
  const keys = [...new Set([...cands, card.slug, ...card.aliases].filter(Boolean).map(norm))];
  const jv = jsonlPlanVerdict(REVIEWS_JSONL, keys);
  if (jv === 'approved') return true;
  if (jv === 'rejected') return false;
  let anyReadable = false;
  for (const file of planReviewFiles()) {
    const txt = rd(file);
    if (txt === null) continue;
    anyReadable = true;
    const L = splitL(txt);
    for (let i = 0; i < L.length; i++) {
      const h = L[i].match(/^##\s+Plan review:\s*(.+?)\s*(?:@|—|-{2,}|$)/i);
      if (!h) continue;
      if (!keys.some((k) => waveCompat(k, norm(waveTok(h[1]))))) continue;
      let blk = L[i];
      for (let j = i + 1; j < L.length && !/^##\s/.test(L[j]); j++) blk += '\n' + L[j];
      if (/verdict\**\s*:\s*\**\s*approved/i.test(blk.replace(/\uFF1A/g, ':'))) return true;
    }
  }
  return anyReadable ? false : null;
};

const resolveRepo = () => {
  if (process.env.AAL_REPO) return process.env.AAL_REPO;
  try {
    const url = execSync('git remote get-url origin', { cwd: CLAUDE_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 }).trim();
    const m = url.replace(/\.git$/, '').match(/[:/]([^/]+\/[^/]+)$/);
    return m ? m[1] : null;
  } catch { return null; }
};
let mergedSet = new Set(), openSet = new Set(), ghOk = !process.env.AAL_NO_GH && ['report', 'check'].includes(argMode);
if (ghOk) try {
  const repo = resolveRepo();
  if (!repo) { ghOk = false; }
  else {
    const g = (s) => JSON.parse(execSync(`gh pr list --repo ${repo} --state ${s} --limit 80 --json number`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 })).map((p) => String(p.number));
    mergedSet = new Set(g('merged')); openSet = new Set(g('open'));
  }
} catch { ghOk = false; }

const parseCards = (boardFile) => {
  const out = [];
  const lines = splitL(stripHtmlComments(rd(boardFile)));
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^###\s+\[([^\]]+)\]\s+(.+)$/);
    if (!m) continue;
    const status = m[1], headerRest = m[2];
    const name = headerRest.split('·')[0].split('(')[0].trim();
    const body = [lines[i]];
    for (let j = i + 1; j < lines.length && !/^#{2,3}\s/.test(lines[j]); j++) body.push(lines[j]);
    const block = body.join('\n');
    const transLines = body.filter((l) => new RegExp(`·\\s*(${TRANSITIONS.join('|')})\\s*·`).test(l));
    const am = block.match(/aliases:\s*(.+)/);
    const aliases = am ? am[1].split(',').map((x) => norm(x)).filter(Boolean) : [];
    out.push({ status, name, header: lines[i], headerRest, block, transLines, slug: norm(waveTok(name)), aliases });
  }
  return out;
};
let cards = parseCards(BACKLOG);

const rerouteBoard = (prompt) => {
  const bm = String(prompt).match(/((?:[A-Za-z]:[\/\\]|\/)[^\n`'"]*?\.claude)[\/\\]BACKLOG\.md/i);
  if (!bm) return;
  const dir = bm[1].replace(/\\/g, '/');
  const board = dir + '/BACKLOG.md';
  if (board.toLowerCase() === String(BACKLOG).replace(/\\/g, '/').toLowerCase()) return;
  BACKLOG = board; CLAUDE_DIR = dir;
  PLAN_REVIEWS = process.env.AAL_PLAN_REVIEWS || path.join(dir, 'plan-reviews.md');
  REVIEWS_JSONL = process.env.AAL_REVIEWS_JSONL || path.join(dir, 'reviews', 'index.jsonl');
  cards = parseCards(board);
};

if (argMode === 'pre-dispatch') {
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  if ((input.tool_name || '') !== 'Agent') process.exit(0);
  const ti = input.tool_input || {};
  const role = String(ti.subagent_type || '').toLowerCase();
  const name = String(ti.name || '');
  const prompt = String(ti.prompt || '');
  const looksPipeline = /^(planner|architect|developer|dev|designer|plan-?reviewer|code-?reviewer|arch|reviewer)[-_a-z0-9]*$/i.test(name);
  const pipelineRoles = ['planner', 'architect', 'developer', 'uiux-designer', 'designer', 'plan-reviewer', 'code-reviewer'];
  if (!pipelineRoles.includes(role) && !looksPipeline) process.exit(0);
  rerouteBoard(prompt);
  if (rd(BACKLOG) === null) process.exit(0);
  if (role === 'code-reviewer' || /^(code-?reviewer|reviewer)/i.test(name)) process.exit(0);

  const deny = (reason) => { process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: `BACKLOG SOP pre-dispatch: ${reason}` } })); process.exit(0); };

  if (cards.length === 0) deny(`the board at ${BACKLOG} is readable but has ZERO active cards — this dispatch's wave is unregistered. Register the wave's card under the board's "## ACTIVE" section BEFORE dispatching any pipeline role, e.g.:
### [QUEUED] <wave-name> · <P>
- aliases: <short-slug>
- problem: <what's wrong / verify the premise LIVE first>
- fix: <the planned fix + acceptance criteria>
- log:
  - <date> · REGISTERED · <who> · proof=<first-hand evidence> · next=<next action>
[STATUS] ∈ {QUEUED,IN-DEV,REVIEW,BLOCKED,USER-GATED}.`);

  const cand = orderedWaveCands(name, prompt);
  if (cand.length === 0) deny(`dispatch of '${role || name}' names no R-/wave- wave slug — cannot identify the target card. Name the wave + register a card first.`);
  const card = locateCardByPriority(cand, cards);
  if (!card) deny(`no active BACKLOG card matches the dispatched wave (candidates: ${cand.join(', ')}). Register the card (### [STATUS] <name> · P + aliases:) BEFORE dispatch.`);

  if (!STATUS_WL.includes(card.status)) deny(`card "${card.name}" status [${card.status}] not in {${STATUS_WL.join(',')}} — fix the status before dispatch.`);
  if (card.aliases.length === 0) deny(`card "${card.name}" has no aliases: line — cannot verify identity.`);

  const sha = /@?[0-9a-f]{7,}/;
  const prv = planReviewApproved(cand, card);
  const legacyPlanLine = /·\s*PLAN_APPROVED\s*·/.test(card.block) || (/plan\s+APPROVED/i.test(card.block) && sha.test(card.block));
  const planApproved = prv === null ? legacyPlanLine : prv;
  const archApproved = /·\s*ARCH_APPROVED\s*·/.test(card.block) || (/\barch(itect(ure)?)?\b[^\n]*\b(approved|accepted|spec|locked)\b/i.test(card.block) && sha.test(card.block));
  const isArch = role === 'architect' || /^arch/i.test(name);
  const isDev = role === 'developer' || /^dev/i.test(name);
  if (isArch && !planApproved) deny(`architect dispatched for "${card.name}" but NO APPROVED plan-review verdict for this wave in plan-reviews*.md. This gate verifies the plan-reviewer's OWN artifact, NOT a self-written BACKLOG "PLAN_APPROVED" line — dispatch a real plan-reviewer (Mode A) first; do NOT backfill the marker to pass.`);
  if (isDev && !archApproved) deny(`developer dispatched for "${card.name}" but the card shows NO ARCH_APPROVED proof (need an "ARCH_APPROVED" log line or "architecture spec @<sha> accepted"). Run architect first.`);
  process.exit(0);
}

if (argMode === 'pre-review') {
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  if ((input.tool_name || '') !== 'Agent') process.exit(0);
  const ti = input.tool_input || {};
  const role = String(ti.subagent_type || '').toLowerCase();
  const name = String(ti.name || '');
  const prompt = String(ti.prompt || '');
  const isPlanRev = role === 'plan-reviewer' || /^plan-?reviewer/i.test(name);
  const isCodeRev = !isPlanRev && (role === 'code-reviewer' || /^(code-?reviewer|reviewer)[-_a-z0-9]*$/i.test(name));
  if (!isPlanRev && !isCodeRev) process.exit(0);
  rerouteBoard(prompt);
  if (rd(BACKLOG) === null) process.exit(0);
  const deny = (reason) => { process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: `BACKLOG SOP pre-review: ${reason}` } })); process.exit(0); };

  if (cards.length === 0) deny(`the board at ${BACKLOG} is readable but has ZERO active cards — the reviewed wave is unregistered. Register/restore the wave's card under the board's "## ACTIVE" section BEFORE dispatching a reviewer, e.g.:
### [QUEUED] <wave-name> · <P>
- aliases: <short-slug>
- problem: <what's wrong / verify the premise LIVE first>
- fix: <the planned fix + acceptance criteria>
- log:
  - <date> · REGISTERED · <who> · proof=<first-hand evidence> · next=<next action>
[STATUS] ∈ {QUEUED,IN-DEV,REVIEW,BLOCKED,USER-GATED}.`);

  // A brief that merely MENTIONS the other mode as a NEGATION must ALLOW — only an AFFIRMATIVE
  // wrong-mode signal denies. Matching the mode token alone false-DENIES a legitimate dispatch
  // whose brief says what it is NOT doing ("you do NOT review code, that is code-reviewer Mode
  // B"), and a false deny on correct work costs a whole round. The bare "Mode B" keyword
  // additionally yields to a plan-doc path anchor: a genuine Mode-A brief citing its own plan
  // artifact while mentioning Mode B in passing is still a plan review.
  const negMention = (kw) => new RegExp(`(not\\s|never\\s|do not\\s|don't\\s|instead of|that is|rather than)[^.\\n]{0,80}${kw}`, 'i').test(prompt);
  const planDocPath = /docs\/product-specs\/\S*plan\S*\.md/i.test(prompt);
  const affModeA = /\bMode A\b/i.test(prompt) && !negMention('\\bMode A\\b');
  const affModeB = /\bMode B\b/i.test(prompt) && !negMention('\\bMode B\\b') && !planDocPath;
  if (isCodeRev && (affModeA || /\bplan review\b|review (the )?plan\b/i.test(prompt))) deny(`code-reviewer dispatched for a PLAN review — use a plan-reviewer (Mode A). code-reviewer = Mode B (PR).`);
  if (isPlanRev && (affModeB || /PR code review|code[ -]?review of (the )?pr|review (the )?pr #?\d/i.test(prompt))) deny(`plan-reviewer dispatched for a PR/CODE review — use a code-reviewer (Mode B). plan-reviewer = Mode A (plan doc).`);

  const cand = orderedWaveCands(name, prompt);
  let card = locateCardByPriority(cand, cards);
  const dPR = (name + ' ' + prompt).match(/#(\d{1,6})\b/);
  if (!card && dPR) card = cards.find((c) => new RegExp(`#${dPR[1]}\\b`).test(c.block));
  if (!card) deny(`no active BACKLOG card matches the reviewer dispatch (wave candidates: ${cand.join(', ') || 'none'}). Register/locate the card first.`);
  if (!STATUS_WL.includes(card.status)) deny(`card "${card.name}" status [${card.status}] not in {${STATUS_WL.join(',')}}.`);
  if (card.aliases.length === 0) deny(`card "${card.name}" has no aliases: line — cannot verify identity.`);

  const sha = /@?[0-9a-f]{7,}/;
  const X = card.block + ' ' + name + ' ' + prompt;

  if (isPlanRev) {
    if (/planner draft only|no committed plan|draft[\s\S]{0,12}not committed/i.test(prompt)) deny(`plan-reviewer dispatch says draft-only / no committed plan — commit the plan (docs/product-specs/...plan.md @<sha>) first.`);
    const planArtifact = /docs\/product-specs\/\S*plan\S*\.md/i.test(X) || (/\bplan\b/i.test(X) && /@[0-9a-f]{7,}/.test(X)) || /plan\s+(committed|delivered|APPROVED)/i.test(card.block);
    if (!planArtifact) deny(`plan-reviewer dispatched for "${card.name}" but NO committed plan artifact discoverable (need a docs/product-specs/...plan.md path or "plan @<sha>" / "plan committed @<sha>" in the card/brief).`);
    process.exit(0);
  }

  if (/\b(local-only|no PR yet)\b|\bPR\s*TBD\b|#TBD/i.test(prompt)) deny(`reviewer dispatch brief says local-only / PR-TBD — Mode B reviews an OPEN PR; push + open the PR first.`);

  const cardDelivered = /·\s*DEV_DELIVERED\s*·/.test(card.block) || (/\b(delivered|pushed)\b/i.test(card.block) && sha.test(card.block));
  const cardPR = /·\s*PR_OPENED\s*·/.test(card.block)
    || /\bMERGED\s*#\d{1,6}\b/i.test(card.block)
    || /(?:→|->)\s*(?:\*\*)?(?:DRAFT\s+)?PR\s*#\d{1,6}\b/i.test(card.block);
  const path1 = cardDelivered && cardPR;

  const prM = prompt.match(/pull\/(\d{1,6})\b|(?:\bPR\s*#?|#)(\d{1,6})\b/i);
  const promptPR = prM ? (prM[1] || prM[2]) : null;
  const promptSha = sha.test(prompt);
  const path2 = !!promptPR && promptSha;

  if (!path1 && !path2) {
    if (promptPR && !promptSha) deny(`code-reviewer for "${card.name}" cites PR #${promptPR} but NO pinned HEAD SHA in the dispatch — Mode B must pin the reviewed commit (≥7-hex; re-pin via gh pr view ${promptPR} --json headRefOid), OR record DEV_DELIVERED + PR_OPENED on the card.`);
    if (!promptPR && !cardPR) deny(`code-reviewer for "${card.name}": no OPEN PR found — neither a real PR# (#N / PR-URL) in the dispatch nor PR_OPENED on the card (local-only / pending-push / #TBD). Mode B reviews an OPEN PR; push + open it first.`);
    deny(`code-reviewer for "${card.name}" lacks delivery proof — need EITHER card DEV_DELIVERED + PR_OPENED, OR a real PR# / PR-URL + pinned HEAD SHA in the dispatch.`);
  }

  if (promptPR) {
    const byPR = cards.find((c) => new RegExp(`#${promptPR}\\b`).test(c.block));
    if (byPR && byPR !== card) deny(`prompt cites PR #${promptPR} (registered on card "${byPR.name}") but the dispatch names wave "${card.name}" — inconsistent; reconcile the PR# and the wave.`);
  }
  process.exit(0);
}

function validateCard(c) {
  const f = [];
  const tag = c.name || c.status;
  if (!STATUS_WL.includes(c.status)) f.push({ bucket: 'HARD', msg: `${tag}: status [${c.status}] not in {${STATUS_WL.join(',')}} (DONE→archive; no ad-hoc states)` });
  if (!/aliases:/.test(c.block)) f.push({ bucket: 'HARD', msg: `${tag}: no aliases: line` });
  if (!/problem:/.test(c.block)) f.push({ bucket: 'DEBT', msg: `${tag}: missing problem: (target-format)` });
  if (!/fix:/.test(c.block)) f.push({ bucket: 'DEBT', msg: `${tag}: missing fix: (target-format)` });
  if (c.transLines.length === 0) f.push({ bucket: 'DEBT', msg: `${tag}: no structured log transition line (free-prose log = migration debt)` });
  for (const l of c.transLines) {
    const st = (l.match(new RegExp(`·\\s*(${TRANSITIONS.join('|')})\\s*·`)) || [])[1];
    if (!/proof=/.test(l)) f.push({ bucket: 'HARD', msg: `${tag}: ${st} transition line missing proof=` });
    if (st === 'DEV_DELIVERED' && !/test/i.test(l)) f.push({ bucket: 'HARD', msg: `${tag}: DEV_DELIVERED missing tests-run evidence` });
    if (st === 'PR_OPENED' && !/#\d+/.test(l)) f.push({ bucket: 'HARD', msg: `${tag}: PR_OPENED missing PR number` });
    if ((st === 'REVIEW_APPROVED' || st === 'REVIEW_NEEDS_FIXES') && !/@?[0-9a-f]{7,}/.test(l)) f.push({ bucket: 'HARD', msg: `${tag}: ${st} missing HEAD SHA` });
  }
  if (['QUEUED', 'IN-DEV', 'REVIEW'].includes(c.status)) {
    const canon = c.headerRest.match(/\(MERGED\s*#(\d+)\s*@[0-9a-f]{7,}\s*·\s*DoD pending:[^)]+\)/i);
    const loose = c.block.match(/\bMERGED\s*#(\d+)/i);
    if (canon) {
      if (ghOk && !mergedSet.has(canon[1])) f.push({ bucket: 'HARD', msg: `${tag}: marker claims MERGED #${canon[1]} but #${canon[1]} is NOT merged` });
      else f.push({ bucket: 'INFO', msg: `${tag} [${c.status}]: MERGED #${canon[1]} · DoD-pending (allowed; confirm DoD still pending, else archive)` });
    } else if (loose) {
      const dodPending = /DoD/i.test(c.block) && /pending/i.test(c.block);
      if (dodPending) f.push({ bucket: 'DEBT', msg: `${tag} [${c.status}]: MERGED #${loose[1]} + DoD-pending noted but NON-CANONICAL marker — reformat header to "(MERGED #${loose[1]} @sha · DoD pending: <reason>)"` });
      else f.push({ bucket: 'DRIFT', msg: `${tag} [${c.status}]: acknowledges MERGED #${loose[1]} but NO DoD-pending rationale → add canonical marker or archive` });
    }
  }
  return f;
}

function validateArchiveEntry(e) {
  const f = [];
  const name = (e.match(/\*\*([^*]+)\*\*/) || [])[1] || e.slice(0, 40);
  const stripped = e.replace(/\*\*[^*]+\*\*/g, '').replace(/\[aliases:[^\]]*\]/g, '');
  const isMergedDone = /\b(MERGED|DONE)\b/i.test(stripped);
  if (isMergedDone && !/#\d+/.test(e)) f.push({ bucket: 'HARD', msg: `archive ${name}: DONE/MERGED entry missing PR #` });
  if (/\b(DONE|MERGED|DOD_PASS|ARCHIVED)\b/i.test(stripped) && !/DoD/i.test(stripped)) f.push({ bucket: 'HARD', msg: `archive ${name}: missing DoD proof` });
  return f;
}

function validateOplogRow(r) {
  const f = [];
  if (!r.fields.proof) f.push({ bucket: 'HARD', msg: `oplog "${r.title}": missing proof` });
  const status = (r.fields.status || '').toUpperCase();
  if (!r.fields.next && !['DONE', 'ARCHIVED'].includes(status)) f.push({ bucket: 'HARD', msg: `oplog "${r.title}": missing next (required unless status DONE/ARCHIVED)` });
  return f;
}

const archiveFindings = [];
{
  const lines = splitL(rd(ARCHIVE));
  for (const l of lines) if (/^\s*-\s+\*\*/.test(l) && /·/.test(l)) archiveFindings.push(...validateArchiveEntry(l));
}

let oplogFindings = [], oplogDebt = 0, oplogPath = process.env.AAL_OPLOG;
{
  let oplogFiles = [];
  if (oplogPath) { oplogFiles = [oplogPath]; }
  else { try { oplogFiles = readdirSync(CLAUDE_DIR).filter((x) => /^autoloop-log-.*\.md$/.test(x)).sort().map((f) => path.join(CLAUDE_DIR, f)); } catch { oplogFiles = []; } }
  for (const op of oplogFiles) {
    const lines = splitL(rd(op));
    for (let i = 0; i < lines.length; i++) {
      const h = lines[i].match(/^##\s+(.+·.+·.+)$/);
      if (!h) { if (/^\s*-\s+\d{1,2}:\d/.test(lines[i])) oplogDebt++; continue; }
      const fields = {};
      for (let j = i + 1; j < lines.length && !/^#{2}\s/.test(lines[j]); j++) {
        const fm = lines[j].match(/^\s*-\s*(\w+)\s*:\s*(.+)$/);
        if (fm) fields[fm[1].toLowerCase()] = fm[2].trim();
      }
      oplogFindings.push(...validateOplogRow({ title: h[1].trim(), fields }));
    }
  }
}

const all = [];
if (argMode === 'report' || argMode === 'check') {
  for (const c of cards) all.push(...validateCard(c));
  all.push(...archiveFindings, ...oplogFindings);
} else {
  console.error(`backlog-sop-validate: mode '${argMode}' not implemented (only report / pre-dispatch / pre-review). See hooks.json.`);
  process.exit(2);
}
const byBucket = (b) => all.filter((x) => x.bucket === b);
const HARD = byBucket('HARD'), DEBT = byBucket('DEBT'), DRIFT = byBucket('DRIFT'), INFO = byBucket('INFO');
const hist = (m) => /^archive |^oplog /.test(m);
const hardActive = HARD.filter((x) => !hist(x.msg));
const hardHist = HARD.filter((x) => hist(x.msg));
const CAP = (process.argv.includes('-v') || process.env.AAL_DEBT_VERBOSE) ? 99999 : 15;

const out = [];
out.push(`backlog-sop-validate (READ-ONLY · report): ${cards.length} active cards, archive+oplog scanned, gh=${ghOk ? 'ok' : 'UNAVAILABLE'}`);
const dump = (label, emoji, arr, cap = 99999) => { out.push(`${emoji} ${arr.length} ${label}:`); arr.slice(0, cap).forEach((x) => out.push(`   [${x.bucket}] ${x.msg}`)); if (arr.length > cap) out.push(`   … +${arr.length - cap} more (run -v for full)`); };
if (hardActive.length) dump('ACTIVE-CARD HARD (a gate would block this wave)', '⛔', hardActive); else out.push('⛔ 0 ACTIVE-CARD HARD (nothing blocking a current wave)');
if (DRIFT.length) dump('DRIFT (merged but NO DoD-pending rationale → add marker or archive)', '⚠️', DRIFT); else out.push('⚠️ 0 DRIFT');
if (INFO.length) dump('INFO (allowed MERGED · DoD-pending)', 'ℹ️', INFO);
out.push(`📦 MIGRATION DEBT (advisory — gates check only the CURRENT entry, never the historical board): ${DEBT.length} active-card field/marker gaps · ${hardHist.length} historical archive/oplog schema gaps · ${oplogDebt} free-prose oplog rows (pre-§E)`);
if (DEBT.length) dump('  active-card field/marker gaps', '  ·', DEBT, CAP);
if (hardHist.length) dump('  historical archive/oplog schema gaps', '  ·', hardHist, CAP);
console.log(out.join('\n'));
process.exit(hardActive.length || DRIFT.length ? 1 : 0);
