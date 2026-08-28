#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { STAGE_HOLDS, pilotVerdict, cardBlockForBranch, tierOfBlock, newestLogOfBlock, newestRoleLogOfBlock } from './lib/backlog-pilot-core.mjs';
import { stageOf, liveBlocker, slugOf, statusOf, OPEN_STATUSES, isDodFailed, isDodRemedyTrack, dodRemedyFor, branchDispatchRefused, mergeOrderGateOnHeader, NEXT_BY_STAGE } from './lib/backlog-gate.mjs';
import { flagUnpushed, surveyWorktrees, flagUnreviewed, flagPushedButUnclaimed, flagDeliveredButNotHandedOff } from './lib/worktree-delivery.mjs';
import { sessionProject } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
import { ledgerRowMatchesCard } from './lib/backlog-grammar.mjs';
import { loadVerdictIndex } from './lib/verdict-at-head.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { liveAgentMembers, rosterHoldsCard } from './lib/roster-live-agents.mjs';
import { priorityLadderReason, ladderRefusesBranch } from './lib/priority-ladder.mjs';
import { resolveGh, ghArgv } from './lib/gh-path.mjs';
autoLogOnDeny('stop-open-pr-ci-watch');


function out(o) { process.stdout.write(JSON.stringify(o)); process.exit(0); }
function quiet(why) {
  if (process.env.AAL_CI_WATCH_DEBUG) console.error('QUIET@ ' + (why || 'unknown') + '\n' + new Error().stack);
  out({});
}

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) quiet();
const LEAD_REPO = sessionProject(stdin);
if (!LEAD_REPO) quiet();
const REPO_DIR = LEAD_REPO;
const REPO = (() => {
  try {
    const url = execFileSync('git', ['-C', REPO_DIR, 'remote', 'get-url', 'origin'],
      { encoding: 'utf8', timeout: 8000 }).trim();
    const m = url.match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?$/);
    return m ? m[1] : '';
  } catch { return ''; }
})();
if (!REPO) quiet();

const GH = resolveGh();
if (!GH) quiet('no-gh');
const gh = (args, opts) => execFileSync(GH.bin, ghArgv(GH, args), opts);

let prs = [];
try {
  prs = JSON.parse(gh(['pr', 'list', '--repo', REPO, '--state', 'open', '--limit', '40',
    '--json', 'number,headRefName,headRefOid,mergeStateStatus,statusCheckRollup,isDraft'],
  { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] }));
} catch { quiet('gh-pr-list-failed'); }
const boardText = (() => { try { return readFileSync(`${REPO_DIR}/.claude/BACKLOG.md`, 'utf8'); } catch { return ''; } })();
const wtRows = surveyWorktrees();
const unpushed = flagUnpushed(wtRows, Date.now());
let handoffOwed = flagDeliveredButNotHandedOff(wtRows, boardText, Date.now(), undefined, { members: liveAgentMembers() });
if (handoffOwed.length && boardText) {
  handoffOwed = handoffOwed.filter((h) => !ladderRefusesBranch(h.branch || h.name || '', boardText));
}
if (!prs.length && !unpushed.length && !handoffOwed.length) quiet('no-open-prs-and-no-worktree-debt');

function triagedAfter(prNumber, redAtMs) {
  if (!boardText || !redAtMs) return false;
  for (const block of boardText.split(/^### \[/m).slice(1)) {
    if (!new RegExp(`(?:PR|MERGED)\\s*#${prNumber}\\b`).test(block)) continue;
    let newest = 0;
    for (const m of block.matchAll(/^- log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm)) {
      const t = Date.parse(m[1]);
      if (Number.isFinite(t) && t > newest) newest = t;
    }
    if (newest > redAtMs) return true;
  }
  return false;
}


function gateHoldsFor(prNumber, openNums) {           // eslint-disable-line no-unused-vars
  if (!boardText) return '';
  for (const block of boardText.split(/^### \[/m).slice(1)) {
    if (!new RegExp(`(?:PR|MERGED)\\s*#${prNumber}\\b`).test(block)) continue;
    return mergeOrderGateOnHeader(boardText, `### [${block.split('\n')[0]}`);
  }
  return '';
}

function stageHoldsFor(prNumber, allowed = STAGE_HOLDS) {
  if (!boardText) return '';
  for (const block of boardText.split(/^### \[/m).slice(1)) {
    if (!new RegExp(`(?:PR|MERGED)\\s*#${prNumber}\\b`).test(block)) continue;
    const st = stageOf(`### [${block.split('\n')[0]}`);
    if (!allowed.has(st)) continue;
    const members = liveAgentMembers();
    if (members === null) return st;
    return rosterHoldsCard({ members, stage: st, prNumber }) ? st : '';
  }
  return '';
}
const REVIEWER_HOLDS = new Set(['review']);

const { verdictOf, approvedAtHead } = loadVerdictIndex(REPO_DIR);



const BOT = /^(dependabot|renovate|pre-commit-ci)\//i;
const DISPATCH = '\u0001';
const heldStale = [];
const mergeable = [], red = [], stale = [], bots = [], triaged = [], held = [], gated = [];
const openNums = new Set(prs.map((p) => Number(p.number)));
const verdictPrNums = new Set();
try {
  const jl = readFileSync(REPO_DIR + '/.claude/reviews/index.jsonl', 'utf8').split(String.fromCharCode(10));
  for (const raw of jl) {
    const line = raw.trim();
    if (!line.trim()) continue;
    try { const j = JSON.parse(line); if (j.pr) verdictPrNums.add(Number(j.pr)); } catch {  }
  }
} catch {  }
const reviewerInFlight = new Set(prs.filter((p) => stageHoldsFor(p.number, REVIEWER_HOLDS)).map((p) => Number(p.number)));
const unreviewedAll = flagUnreviewed(prs, verdictPrNums, { reviewerInFlight });

const dodLockedCard = (() => {
  if (!boardText) return null;
  for (const block of boardText.split(/^### \[/m).slice(1)) {
    const hdr = `### [${block.split('\n')[0]}`;
    if (statusOf(hdr) && OPEN_STATUSES.includes(statusOf(hdr)) && isDodFailed(`### [${block}`)) return slugOf(hdr);
  }
  return null;
})();
const gateCardsForPr = boardText
  ? boardText.split(/^### \[/m).slice(1).map((b) => ({ header: `### [${b.split('\n')[0]}`, block: `### [${b}` }))
  : [];
const cardHeaderForPr = (prNumber) => {
  if (!boardText) return '';
  for (const block of boardText.split(/^### \[/m).slice(1)) {
    if (!new RegExp(`(?:PR|MERGED)\\s*#${prNumber}\\b`).test(block)) continue;
    return `### [${block.split('\n')[0]}`;
  }
  return '';
};
const dispatchRefusedFor = (prNumber) => {
  const tierHdr = cardHeaderForPr(prNumber);
  if (tierHdr && gateCardsForPr.length) {
    const all = gateCardsForPr.map((c) => ({
      header: c.header, block: c.block,
      name: slugOf(c.header) || '', status: statusOf(c.header) || '',
    }));
    const me = all.find((c) => c.header === tierHdr);
    try { if (me && priorityLadderReason(me, all)) return true; } catch {  }
  }
  if (!dodLockedCard) return false;
  const hdr = cardHeaderForPr(prNumber);
  if (!hdr) return false;
  if (dodRemedyFor(hdr)) return false;
  return !isDodRemedyTrack(hdr, gateCardsForPr);
};
const heldUnreviewed = unreviewedAll.filter((p) => dispatchRefusedFor(p.number));
const heldNums = new Set(heldUnreviewed.map((p) => Number(p.number)));
const unreviewed = unreviewedAll.filter((p) => !heldNums.has(Number(p.number)));

const prHeads = new Set(prs.map((x) => String(x.headRefName || '')));
const ledgerText = (() => { try { return readFileSync(REPO_DIR + '/.claude/reviews/index.jsonl', 'utf8'); } catch { return ''; } })();
const ackText = (() => { try { return readFileSync(REPO_DIR + '/.claude/.layer6-ack', 'utf8'); } catch { return ''; } })();
let unclaimed = flagPushedButUnclaimed(surveyWorktrees(), { prHeads, ledgerText, ackText });
const _members6 = liveAgentMembers();
unclaimed = unclaimed.filter((u) => {
  if (!Array.isArray(_members6)) return true;
  let blk = '';
  try { blk = cardBlockForBranch(boardText, u.branch) || ''; } catch { blk = ''; }
  if (!blk) return true;
  const st = stageOf(blk.split('\n')[0]);
  if (!STAGE_HOLDS.has(st)) return true;
  return !rosterHoldsCard({ members: _members6, stage: st });
});

{
  const MUTE_MS = 20 * 60 * 1000;
  const now = Date.now();
  const mutedBranch = (branch) => {
    const blk = cardBlockForBranch(boardText, branch);
    if (!blk) return false;
    const st = newestLogOfBlock(blk);
    return st > 0 && now - st < MUTE_MS;
  };
  if (unclaimed.length) unclaimed = unclaimed.filter((u) => !mutedBranch(u.branch || u.name || ''));
}

const gatedBranches = [];
if (unclaimed.length) {
  unclaimed = unclaimed.filter((u) => {
    const branch = u.branch || u.name || '';
    const blk = cardBlockForBranch(boardText, branch);
    if (!blk) return true;
    const g = mergeOrderGateOnHeader(boardText, `### ${blk.split('\n')[0].replace(/^### /, '')}`);
    if (!g) return true;
    gatedBranches.push(`${branch} — card header \`${g}\``);
    return false;
  });
}

const heldUnclaimed = [];
if (unclaimed.length && boardText) {
  const keep = [];
  for (const u of unclaimed) {
    const br = u.branch || u.name || '';
    if (br && branchDispatchRefused(br, boardText)) heldUnclaimed.push(u);
    else keep.push(u);
  }
  unclaimed = keep;
}

if (unclaimed.length) {
  try {
    const hi = pilotVerdict(boardText).highest;
    if (hi != null) {
      unclaimed = unclaimed.filter((u) => {
        const blk = cardBlockForBranch(boardText, u.branch || u.name || '');
        const t = blk ? tierOfBlock(blk) : null;
        return t == null || t <= hi;
      });
    }
  } catch {  }
}

for (const p of prs) {
  if (p.isDraft) continue;
  const cs = p.statusCheckRollup || [];
  const failing = cs.filter((c) => String(c.conclusion || '').toUpperCase() === 'FAILURE');
  const fail = failing.length;
  const running = cs.filter((c) => ['IN_PROGRESS', 'QUEUED', 'PENDING'].includes(String(c.status || '').toUpperCase())).length;
  const tag = `#${p.number} (${p.headRefName})`;
  if (BOT.test(p.headRefName)) { if (fail) bots.push(`${tag} red=${fail}`); continue; }
  if (running) continue;
  if (fail) {
    const redAt = failing.reduce((mx, c) => Math.max(mx, Date.parse(c.completedAt || c.startedAt || 0) || 0), 0);
    if (triagedAfter(p.number, redAt)) { triaged.push(`${tag} red=${fail}`); continue; }
    red.push(`${tag} red=${fail}`);
    continue;
  }
  const ms = String(p.mergeStateStatus || '').toUpperCase();
  if (ms === 'CLEAN' && approvedAtHead(p.number, p.headRefOid)) { mergeable.push(tag + ' @' + String(p.headRefOid||'').slice(0,8)); continue; }
  if (ms === 'BEHIND' || ms === 'DIRTY') {
    const g = gateHoldsFor(p.number, openNums);
    if (g) { gated.push(`${tag} ${ms} — card header \`${g}\``); continue; }
    const st = stageHoldsFor(p.number);
    if (st && !approvedAtHead(p.number, p.headRefOid)) { held.push(`${tag} ${ms} — card header stage=${st}`); continue; }
  }
  let dispatchShaped = null;
  if (ms === 'BEHIND') {
    const v = verdictOf.get(String(p.number));
    if (v && v !== 'APPROVED') dispatchShaped = `${tag} BEHIND — but the newest verdict is ${v} ⇒ **dispatch a developer first. Pulling now burns a CI round and pushes the head the verdict is pinned to further away**`;
    else if (v === 'APPROVED' && !approvedAtHead(p.number, p.headRefOid)) dispatchShaped = `${tag} BEHIND — APPROVED is pinned to a DIFFERENT SHA ⇒ **this needs a fresh review, not a pull**`;
    else stale.push(`${tag} BEHIND — \`git -C <worktree> fetch origin\` then \`git merge origin/main\` (the verdict matches the current head)`);
  } else if (ms === 'DIRTY') dispatchShaped = `${tag} DIRTY — a real conflict; dispatch a developer`;
  if (dispatchShaped) {
    if (dispatchRefusedFor(p.number)) heldStale.push(dispatchShaped);
    else stale.push(`${DISPATCH}${dispatchShaped}`);
  }
}

let mainRedUnowned = [];
try {
  const fails = JSON.parse(gh(['run', 'list', '--repo', REPO, '--branch', 'main',
    '--status', 'failure', '--limit', '15', '--json', 'workflowName,headSha,createdAt'],
    { encoding: 'utf8', timeout: 20000 }));
  const seen = new Set();
  const failing = [];
  for (const f of fails) {
    if (seen.has(f.workflowName)) continue;
    seen.add(f.workflowName);
    const latest = JSON.parse(gh(['run', 'list', '--repo', REPO, '--branch', 'main',
      '--workflow', f.workflowName, '--limit', '1', '--json', 'conclusion,workflowName,headSha,createdAt,databaseId'],
      { encoding: 'utf8', timeout: 20000 }));
    if (latest[0] && latest[0].conclusion === 'failure') failing.push(latest[0]);
  }
  if (failing.length) {
    const board = boardText || '';
    const blocks = board.split('\n### ').slice(1);
    for (const r of failing) {
      let jobNames = [];
      try {
        const jobs = JSON.parse(gh(['run', 'view', String(r.databaseId),
          '--repo', REPO, '--json', 'jobs'], { encoding: 'utf8', timeout: 20000 })).jobs || [];
        jobNames = jobs.filter((j) => j.conclusion === 'failure').map((j) => String(j.name || ''));
      } catch { jobNames = []; }
      const norm = (s) => String(s).toLowerCase().replace(/\s+/g, ' ').trim();
      const names = (jobNames.length ? jobNames : [String(r.workflowName || '')]).map(norm).filter((s) => s.length >= 8);
      const owned = names.length > 0 && blocks.some((b) => {
        const hay = norm(b);
        return names.some((n) => hay.includes(n));
      });
      const isBot = /dependabot|renovate/i.test(String(r.workflowName || ''));
      if (!owned && !isBot) mainRedUnowned.push(`${r.workflowName} @${String(r.headSha).slice(0, 8)} (${r.createdAt})`);
    }
  }
} catch { mainRedUnowned = []; }

if (!mergeable.length && !red.length && !stale.length && !unpushed.length && !unreviewed.length && !unclaimed.length && !mainRedUnowned.length && !handoffOwed.length) quiet('nothing-actionable');

const lines = ['OPEN-PR / CI, as GitHub reports it (not as the board describes it):'];
if (mergeable.length) {
  lines.push('', `**1. mergeable right now** (APPROVED + CLEAN + nothing red, nothing running) (${mergeable.length}):`);
  for (const t of mergeable) lines.push(`   · ${t}`);
  lines.push('   => merge it, or write one line on the card saying why not. Merging one turns the rest BEHIND; run `gh pr update-branch` on each.');
}
if (red.length) {
  lines.push('', `**2. red, and nobody is on it** (${red.length}):`);
  for (const t of red) lines.push(`   · ${t}`);
  lines.push('   => decide code-red vs infrastructure-wedged from `.steps[]`, never from the job conclusion.');
}
if (stale.length) {
  const lead = stale.filter((t) => !t.startsWith(DISPATCH));
  const disp = stale.filter((t) => t.startsWith(DISPATCH)).map((t) => t.slice(DISPATCH.length));
  lines.push('', `**3. one step short of moving** (${stale.length}):`);
  if (lead.length) {
    lines.push(`   **3a. one command by the lead finishes it** (${lead.length}):`);
    for (const t of lead) lines.push(`   · ${t}`);
  lines.push('   => not a dispatch, so the DoD lock and the priority ladder do not apply: do it, or write one line on the card saying why not.');
    lines.push('   STOP: a pull is fetch + merge. `fetch` first, assert `rev-parse HEAD == origin/<branch>`, then merge (see principles, Do the verb).');
  }
  if (disp.length) {
    lines.push(`   **3b. needs someone dispatched** (${disp.length}):`);
    for (const t of disp) lines.push(`   · ${t}`);
    lines.push('   NOTE: a dispatch has to pass `backlog-sop-validate --mode pre-dispatch`. These are the ones it ALLOWS; the refused ones are in the group below.');
  }
}
if (handoffOwed.length) {
  lines.push('', `**7. that baton delivered and the next one was never dispatched** — artifacts newer than the dispatch stamp, tree quiet (${handoffOwed.length}):`);
  for (const h of handoffOwed) {
    const when = new Date(h.lastCommitMs).toISOString().replace(/\.\d+Z$/, 'Z');
    const stray = h.untracked > 0 ? `, WARNING: ${h.untracked} untracked file(s) still in the tree` : '';
    lines.push(`   · ${h.name} (${h.branch}) @${h.tip} — card header \`stage=${h.stage}\`, last artifact ${when}${stray}`);
  }
  lines.push('   => **send it a `shutdown_request` in THIS turn**. Do not check transcript mtimes, do not check the roster, do not ask it what it still owes.');
  lines.push('     The artifact IS the delivery; whatever is left belongs to the lead or to the next baton. It is not finished yet is not a reason to keep it on the roster.');
  lines.push('   Then, in THAT SAME turn, write `- log: <ISO Z> · shut down <who>` on the card — that stamp passes the artifact time and clears this layer by itself.');
}
if (unpushed.length) {
  lines.push('', `**4. delivered but never pushed** (invisible to the watchdog) (${unpushed.length}):`);
  for (const r of unpushed) lines.push(`   · ${r.name} (${r.branch}) — ${r.unpushed} unpushed commit(s), tree quiet${r.hasRemote ? '' : ', and the remote branch does not exist'}`);
  const gitBashRepo = String(REPO_DIR).replace(/^([A-Za-z]):/, (_, d) => `/${d.toLowerCase()}`);
  lines.push(`   => **push it now** (main checkout, as its own command): \`cd ${gitBashRepo} && git push -u origin <branch>\``);
  lines.push('      An agent holding it is not a reason — unless the reflog shows a rebase or an amend. SendMessage once it is pushed, in that same turn.');
  lines.push('   NOTE: if the artifact is a -plan.md (stage planning/plan-ok/arch) the next baton is plan-reviewer, not code-reviewer; this layer only cares that the push makes it visible.');
}
if (unreviewed.length) {
  lines.push('', `**5. open, checks finished, and NEVER REVIEWED** (${unreviewed.length}):`);
  for (const p of unreviewed) lines.push(`   · #${p.number} (${p.headRefName}) — 0 verdicts in the ledger`);
  lines.push('   => exactly two ways to clear this layer: (a) dispatch a FRESH code-reviewer, pinned to the head SHA; (b) land a verdict row in reviews/index.jsonl. Writing a log on the card does not clear it, because this layer does not read cards.');
}
if (gatedBranches.length) {
  lines.push('', `(pushed, but **the board says it cannot land first** — the card header carries an unexpired \`merge-order\`, so push the one it is waiting on: ${gatedBranches.join(' · ')})`);
  lines.push('   NOTE: this kind of gate CLEARS ITSELF — the moment the card owning the awaited PR is archived, this line disappears and the branch is promoted again.');
}
if (unclaimed.length) {
  lines.push('', `**6. pushed, but with no PR and no verdict pinned to it — the push switched (4) off and no layer picked it up** (${unclaimed.length}):`);
  for (const r of unclaimed) {
    const blk = cardBlockForBranch(boardText, r.branch || r.name || "");
    const st = blk ? stageOf("### " + (blk.split("\n")[0] || "")) : "";
    const isPlanWave = ["new", "planning", "plan-ok", "arch"].includes(st);
    const openVerdict = (() => {
      if (!blk || !ledgerText) return null;
      const newestLog = newestRoleLogOfBlock(blk);
      let best = null;
      for (const line of ledgerText.split(/\r?\n/)) {
        if (!line.trim()) continue;
        let j; try { j = JSON.parse(line); } catch { continue; }
        const head = (blk.split('\n')[0] || '');
        const prNum = (head.match(/\bPR\s*#(\d+)/) || [])[1];
        const mine = (prNum && String(j.pr || '') === prNum) || ledgerRowMatchesCard(head, j);
        if (!mine) continue;
        const ts = Date.parse(j.ts || '');
        if (!Number.isFinite(ts) || ts <= newestLog) continue;
        if (!best || ts > best.ts) best = { ts, verdict: String(j.verdict || ''), round: j.round };
      }
      return best;
    })();
    let act;
    if (openVerdict) {
      const v = openVerdict.verdict;
      const r = openVerdict.round ? `r${openVerdict.round} ` : '';
      if (/NEEDS_REVISION/i.test(v)) act = `**dispatch a \`planner\` revision round** — the ledger holds an unclaimed ${r}\`NEEDS_REVISION\`; this is not another review`;
      else if (/CHANGES_REQUIRED/i.test(v)) act = `**dispatch a \`developer\` for rework** — the ledger holds an unclaimed ${r}\`CHANGES_REQUIRED\``;
      else if (/APPROVED/i.test(v)) act = isPlanWave ? `**dispatch an \`architect\`** — the ${r}plan is APPROVED` : `**merge it, or finish its DoD** — the ${r}PR is APPROVED`;
      else act = `**read the ledger, then decide** — there is an unclaimed ${r}\`${v}\``;
    }
    else if (!blk) act = "**no card resolves to it** — work out which card owns it, or whether it is a leftover branch";
    else if (st === "new" || st === "planning") act = "**dispatch a `plan-reviewer`** (a plan wave opens no PR; the verdict pins `plan_blob`)"
      + (st === "new" ? " NOTE: card header stage=new — move it to `planning` before dispatching (forward, not back)" : "");
    else if (st === "plan-ok") act = "**dispatch an `architect`** — the plan is approved, and this layer should not wait for a plan verdict that will never appear";
    else if (st === "arch") act = "**accept the architecture (`arch`->`arch-ok`), then dispatch a `developer`** — there is no architecture-review step, "
      + "so an architecture commit will never have a verdict pinned to it, and what this layer waits for at this stage does not exist";
    else if (st === "arch-ok" || st === "dev") act = `**dispatch a \`developer\`; open the PR and dispatch a \`code-reviewer\` after it delivers** (card header stage=${st})`;
    else act = `**dispatch a \`${NEXT_BY_STAGE[st] || "?"}\`** (card header stage=${st || "(missing)"})`;
    lines.push(`   · ${r.name} (${r.branch}) @${r.tip}`);
    lines.push(`     ⇒ ${act}`);
    lines.push('     Then, in THAT SAME turn, write `- log: <ISO Z from date -u> · <who was dispatched>` on the card — that line is the clearing condition for this layer');
  }
}
if (gated.length) {
  lines.push('', `(BEHIND/DIRTY but **the board says it cannot land first** — the card header carries an unexpired \`merge-order\`, so resolving the conflict now would be undone by the next merge, and it is not promoted: ${gated.join(' · ')})`);
  lines.push('   NOTE: this kind of gate CLEARS ITSELF — the moment the awaited PR merges or the named card is archived, this line disappears and the PR is promoted again.');
  lines.push('   A user gate (`blocked-by` set to `user`) is NOT in this class: a conflict is a mechanical fact and has nothing to do with a ruling.');
}
if (held.length) lines.push('', `(someone is holding it, not promoted: ${held.join(' · ')})`);
if (triaged.length) lines.push('', `(red but **someone is already on it** — the owning card has a \`- log:\` newer than that red, so it is not promoted: ${triaged.join(' · ')})`);
if (bots.length) lines.push('', `(bot PR is red; it does not occupy a wave: ${bots.join(' · ')})`);
if (mainRedUnowned.length) {
  lines.push('', `**7. \`main\` itself is red and no active card on the board claims it** (${mainRedUnowned.length}):`);
  for (const t of mainRedUnowned) lines.push(`   · ${t}`);
  lines.push('   => **file a card in THIS turn**, on one condition: measure it first-hand — which workflow, which step, and the SHA the red starts at. Build the green-to-red timeline before you diff any code.');
  lines.push('   Clearing condition: an active card on the board claims it (its name and the workflow share at least 2 tokens).');
}

const text = lines.join('\n');

const stateDir = `${REPO_DIR}/.claude/.aal-state`;
const seenPath = `${stateDir}/pr-watch-last-block`;
const key = createHash('sha1').update(text).digest('hex').slice(0, 16);
let repeat = false;
try { repeat = existsSync(seenPath) && readFileSync(seenPath, 'utf8').split(/\s+/)[0] === key; } catch { repeat = false; }
try { mkdirSync(stateDir, { recursive: true }); writeFileSync(seenPath, `${key}\n`); } catch {  }

const actionable = mergeable.length + red.length + stale.length + unpushed.length + unreviewed.length + unclaimed.length + mainRedUnowned.length + handoffOwed.length;
if (process.env.AAL_CI_WATCH_DEBUG) {
  console.error('DEBUG ' + JSON.stringify({ prs: prs.length, verdicts: verdictPrNums.size, mergeable: mergeable.length, red: red.length, stale: stale.length, unpushed: unpushed.length, unreviewed: unreviewed.length, actionable }));
}
out(actionable === 0 ? {} : { decision: 'block', reason: text, systemMessage: String(text).split('\n')[0] });
