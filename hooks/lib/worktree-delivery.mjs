import { execFileSync } from 'node:child_process';

const REPO_DIR = projectPaths()?.repo || '';

const QUIET_MIN = 10;
export function trackedClean(r) {
  return Number.isFinite(r?.dirtyTracked) ? r.dirtyTracked === 0 : r?.uncommitted === 0;
}

export function flagUnpushed(rows) {
  return (rows || []).filter((r) => r && r.unpushed > 0 && trackedClean(r));
}

export function surveyWorktrees() {
  const rows = [];
  let list = '';
  try { list = execFileSync('git', ['-C', REPO_DIR, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 15000 }); } catch { return rows; }
  for (const blk of list.split(/\n\n+/)) {
    const dir = (blk.match(/^worktree (.+)$/m) || [])[1];
    const br = (blk.match(/^branch refs\/heads\/(.+)$/m) || [])[1];
    if (!dir || !br) continue;
    if (dir.replace(/\\/g, '/') === REPO_DIR) continue;
    const g = (args, dflt) => { try { return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', timeout: 15000 }).trim(); } catch { return dflt; } };
    const porcelain = (g(['status', '--porcelain'], '') || '').split(/\r?\n/).filter((x) => x.trim());
    const untracked = porcelain.filter((x) => x.startsWith('??')).length;
    const dirtyTracked = porcelain.length - untracked;
    const uncommitted = porcelain.length;
    const hasRemote = g(['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${br}`], '') !== '';
    const unpushed = Number(hasRemote ? g(['rev-list', '--count', `origin/${br}..HEAD`], '0') : g(['rev-list', '--count', 'origin/main..HEAD'], '0')) || 0;
    const lastCommitMs = Number(g(['log', '-1', '--format=%ct'], '0')) * 1000 || NaN;
    const tip = g(['rev-parse', '--short', 'HEAD'], '');
    rows.push({ name: dir.split(/[\/]/).pop(), dir: dir.replace(/\\/g, '/'), branch: br, uncommitted, dirtyTracked, untracked, unpushed, hasRemote, lastCommitMs, tip });
  }
  return rows;
}



export function flagPushedButUnclaimed(rows, opts = {}) {
  const prHeads = opts.prHeads || new Set();
  const ledgerText = String(opts.ledgerText || '');
  const inFlight = opts.reviewerInFlight || new Set();
  const acked = new Set(
    String(opts.ackText || '').split(/\r?\n/)
      .map((l) => (l.match(/^\s*([^\s·]+@[0-9a-f]{7,40})\s*·/) || [])[1])
      .filter(Boolean)
  );
  return (rows || []).filter((r) => r
    && r.hasRemote
    && r.unpushed === 0
    && r.uncommitted === 0
    && r.tip
    && !prHeads.has(r.branch)
    && !inFlight.has(r.branch)
    && !acked.has(`${r.branch}@${r.tip}`)
    && !ledgerText.includes(r.tip));
}

const BOT_BRANCH = /^(dependabot|renovate|pre-commit-ci)\//i;
export function flagUnreviewed(prs, verdictPrNums, opts = {}) {
  const inFlight = opts.reviewerInFlight || new Set();
  return (prs || []).filter((p) => p
    && !p.isDraft
    && !BOT_BRANCH.test(String(p.headRefName || ''))
    && !verdictPrNums.has(Number(p.number))
    && !inFlight.has(Number(p.number))
    && !(p.statusCheckRollup || []).some((c) => ['IN_PROGRESS', 'QUEUED', 'PENDING'].includes(String(c.status || '').toUpperCase())));
}

import { cardBlockForBranch, STAGE_HOLDS, WT_FRESH_MS } from './backlog-pilot-core.mjs';
import { freshestWorkFile } from './worktree-activity.mjs';
import { stageOf, isDodFailed, isDodRemedyTrack } from './backlog-gate.mjs';
import { projectPaths } from './is-autoloop-lead.mjs';
import { rosterHoldsCardByWave, holdersOfCardByWave } from './roster-live-agents.mjs';

function heldByLiveHolder(block, members, row, nowMs) {
  if (!Array.isArray(members)) return false;
  let holds = false;
  try { holds = rosterHoldsCardByWave({ members, cardBlock: String(block) }); } catch { return false; }
  if (!holds) return false;
  const dir = row && row.dir;
  if (!dir || !Number.isFinite(nowMs)) return false;
  try {
    return !!freshestWorkFile(dir, nowMs - WT_FRESH_MS);
  } catch { return false; }
}

function dodLockExcludes(board, block, header) {
  const H = (s) => `### ${String(s).replace(/^###\s*/, '')}`;
  let cards = [];
  try {
    cards = String(board).split(/^### /m).slice(1)
      .map((b) => ({ header: H(b.split('\n')[0]), block: `### ${b}` }));
  } catch { return false; }
  if (!cards.some((c) => isDodFailed(c.block))) return false;
  if (isDodFailed(block)) return false;
  try { if (isDodRemedyTrack(H(header), cards)) return false; } catch { return false; }
  return true;
}

export function flagDeliveredButNotHandedOff(rows, boardText, nowMs, quietMin = QUIET_MIN, { members } = {}) {
  const out = [];
  const board = String(boardText || '');
  if (!Array.isArray(rows) || !board) return out;
  for (const r of rows) {
    if (!r || !trackedClean(r)) continue;
    if (!Number.isFinite(r.lastCommitMs)) continue;
    if ((nowMs - r.lastCommitMs) < quietMin * 60000) continue;
    let block = '';
    try { block = cardBlockForBranch(board, r.branch) || ''; } catch { block = ''; }
    if (!block) continue;
    const stage = stageOf(block.split('\n')[0]);
    if (!STAGE_HOLDS.has(stage)) continue;
    const waveHolders = holdersOfCardByWave({ members, cardBlock: block });
    const newestJoin = waveHolders.reduce((a, m) => Math.max(a, Number(m.joinedAt) || 0), 0);
    if (newestJoin && r.lastCommitMs <= newestJoin) continue;
    if (heldByLiveHolder(block, members, r, nowMs)) continue;
    if (dodLockExcludes(board, block, block.split('\n')[0])) continue;
    out.push({ ...r, stage, dispatchedMs: newestJoin });
  }
  return out;
}
