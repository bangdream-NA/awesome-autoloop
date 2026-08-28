#!/usr/bin/env node
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { pilotVerdict, renderVerdict, actionableGhosts, cardBlockForBranch, WT_FRESH_MS } from './lib/backlog-pilot-core.mjs';
import { atCapFor as wtAtCapFor } from './lib/worktree-cap.mjs';
import { freshestWorkFile } from './lib/worktree-activity.mjs';
import { surveyWorktrees, flagDeliveredButNotHandedOff } from './lib/worktree-delivery.mjs';
import { wholeTokenRe } from './lib/scheduler-identity.mjs';
import { OBSERVE_UNTIL_RE, archivePathsFor } from './lib/backlog-grammar.mjs';
import { loadVerdictIndex } from './lib/verdict-at-head.mjs';

function approvedAtHeadMap(repoDir, prMap) {
  if (!prMap) return null;
  const { approvedAtHead } = loadVerdictIndex(repoDir);
  const out = {};
  for (const [num, meta] of Object.entries(prMap)) out[num] = approvedAtHead(num, String((meta && meta.head) || ''));
  return out;
}
import { isAutoloopLead, sessionProject, repoRoots } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { liveAgentMembers } from './lib/roster-live-agents.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('backlog-pilot');

const BIN = (name) => {
  const cands = [
    process.env[`${name.toUpperCase()}_PATH`],
    `${homeDir()}/bin/bin/${name}.exe`,
    `Z:/Program Files/Git/cmd/${name}.exe`,
    name,
  ].filter(Boolean);
  for (const c of cands) {
    try { execFileSync(c, ['--version'], { timeout: 5000, stdio: 'ignore' }); return c; } catch {  }
  }
  return null;
};

function mergedPRsOnMain(repoDir, sinceDays = 14) {
  const git = BIN('git');
  if (!git) { mergedPRsOnMain.reason = 'git is not executable (it is not on the PATH this hook runs with)'; return null; }
  try {
    const out = execFileSync(git, ['-C', repoDir, 'log', 'origin/main', `--since=${sinceDays}.days.ago`, '--pretty=%H%x09%cI%x09%s'], { encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'] });
    const rows = [];
    for (const line of out.split(/\r?\n/)) {
      const [sha, ts, ...rest] = line.split('\t');
      const m = rest.join('\t').match(/\(#(\d+)\)\s*$/);
      if (sha && m) rows.push({ n: +m[1], sha: sha.slice(0, 8), ts, subject: rest.join('\t').slice(0, 90) });
    }
    return rows;
  } catch (e) { mergedPRsOnMain.reason = `reading origin/main with git failed: ${String(e.message).slice(0, 120)}`; return null; }
}

const OPEN_PR_CACHE_SCHEMA = 3;
function openPRs(repoDir, stateDir) {
  const cache = path.join(stateDir, 'pilot-open-prs.json');
  try {
    const st = JSON.parse(readFileSync(cache, 'utf8'));
    if (st.schema === OPEN_PR_CACHE_SCHEMA && Date.now() - st.ts < 10 * 60 * 1000) return st.map;
  } catch {  }
  const git = BIN('git'), gh = BIN('gh');
  if (!git || !gh) { openPRs.reason = 'git or gh is not executable'; return null; }
  try {
    const url = execFileSync(git, ['-C', repoDir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const rm = url.match(/github\.com[:/]([^/\s]+\/[^\s/]+?)(?:\.git)?\s*$/);
    if (!rm) { openPRs.reason = 'the origin URL could not be parsed'; return null; }
    const out = execFileSync(gh, ['pr', 'list', '--repo', rm[1], '--state', 'open', '--limit', '200', '--json', 'number,headRefName,headRefOid,isDraft,mergeStateStatus,statusCheckRollup'], { encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] });
    const map = {};
    for (const p of JSON.parse(out)) {
      if (p.isDraft) continue;
      const red = (p.statusCheckRollup || [])
        .filter((c) => /FAILURE|ERROR|TIMED_OUT|CANCELLED/i.test(String(c.conclusion || '')))
        .map((c) => c.name || c.context).filter(Boolean);
      map[p.number] = { branch: p.headRefName, head: p.headRefOid || '', mergeState: p.mergeStateStatus || '', red };
    }
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(cache, JSON.stringify({ schema: OPEN_PR_CACHE_SCHEMA, ts: Date.now(), map })); } catch {  }
    return map;
  } catch (e) { openPRs.reason = `gh pr list --state open failed: ${String(e.message).slice(0, 120)}`; return null; }
}

function prBranches(repoDir, stateDir) {
  const cache = path.join(stateDir, 'pilot-pr-branches.json');
  try {
    const st = JSON.parse(readFileSync(cache, 'utf8'));
    if (Date.now() - st.ts < 10 * 60 * 1000) return st.map;
  } catch {  }
  const git = BIN('git'), gh = BIN('gh');
  if (!git) { prBranches.reason = 'git is not executable'; return null; }
  if (!gh) { prBranches.reason = 'gh is not executable (it is not on the PATH this hook runs with — it IS on an interactive shell, so the CLI itself works)'; return null; }
  try {
    const url = execFileSync(git, ['-C', repoDir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const rm = url.match(/github\.com[:/]([^/\s]+\/[^\s/]+?)(?:\.git)?\s*$/);
    if (!rm) { prBranches.reason = `could not parse owner/repo from the origin URL: ${url.slice(0, 60)}`; return null; }
    const out = execFileSync(gh, ['pr', 'list', '--repo', rm[1], '--state', 'merged', '--limit', '200', '--json', 'number,headRefName,title'], { encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] });
    const map = {};
    for (const p of JSON.parse(out)) map[p.number] = { branch: p.headRefName, title: p.title };
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(cache, JSON.stringify({ ts: Date.now(), map })); } catch {  }
    return map;
  } catch (e) { prBranches.reason = `gh pr list failed: ${String(e.message).slice(0, 120)}`; return null; }
}

function orphanMerges(merged, branches, boardText) {
  if (merged === null || branches === null) return null;
  const hay = String(boardText);
  const slugsOf = (meta) => {
    const s = new Set();
    if (!meta) return s;
    const b = String(meta.branch || '').replace(/^(feat|fix|docs|chore|refactor|test)\//, '');
    if (b) { s.add(b); if (/^r-/i.test(b)) s.add(b.replace(/^r-/i, 'R-')); }
    for (const m of String(meta.title || '').matchAll(/R-[a-z0-9][a-z0-9-]{4,}/gi)) s.add(m[0]);
    return s;
  };
  const BOT = /^(dependabot|renovate|pre-commit-ci)\//i;
  return merged.filter((pr) => {
    if (BOT.test(String((branches[pr.n] || {}).branch || ''))) return false;
    if (new RegExp(`#${pr.n}\\b`).test(hay)) return false;
    for (const slug of slugsOf(branches[pr.n])) if (wholeTokenRe(slug).test(hay)) return false;
    if (!branches[pr.n]) return false;
    pr.branch = branches[pr.n].branch;
    pr.subject = branches[pr.n].title;
    return true;
  });
}

function readArchive(dir) {
  let out = '';
  try {
    for (const p of archivePathsFor(path.join(dir, 'BACKLOG.md'))) {
      try { out += readFileSync(p, 'utf8') + '\n'; } catch {  }
    }
  } catch {  }
  return out;
}

const STATE = path.join(homeDir(), '.claude/hooks/.state');

function allVerdicts(claudeDir) {
  const out = {};
  let txt = '';
  try { txt = readFileSync(path.join(claudeDir, 'reviews', 'index.jsonl'), 'utf8'); } catch { return out; }
  for (const line of txt.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let r; try { r = JSON.parse(line); } catch { continue; }
    const slug = String(r.card || '').trim();
    if (!slug || !r.verdict) continue;
    const prev = out[slug];
    if (!prev || String(r.ts || '') >= String(prev.ts || '')) {
      out[slug] = { verdict: String(r.verdict), ts: String(r.ts || ''), round: r.round ?? null, mode: r.mode || null };
    }
  }
  return out;
}

function reviewArtifactAges(claudeDir) {
  const dir = path.join(claudeDir, 'reviews');
  let names = [];
  try { names = readdirSync(dir); } catch { return null; }
  const out = {};
  const now = Date.now();
  const ageOf = (n) => { try { return now - statSync(path.join(dir, n)).mtimeMs; } catch { return null; } };
  const put = (k, ageMs) => { if (k && ageMs != null && (!(k in out) || ageMs < out[k])) out[k] = ageMs; };

  for (const n of names) {
    if (!n.endsWith('.md')) continue;
    put(n.replace(/\.md$/, '').replace(/-planrev-r\d+$/, '').replace(/-r\d+$/, ''), ageOf(n));
  }

  try {
    const rows = readFileSync(path.join(dir, 'index.jsonl'), 'utf8').split(/\r?\n/);
    for (const line of rows) {
      if (!line.trim()) continue;
      let o; try { o = JSON.parse(line); } catch { continue; }
      const card = String((o && o.card) || '').trim();
      const f = String((o && o.file) || '').split('/').pop();
      if (!card || !f || !f.endsWith('.md')) continue;
      put(card, ageOf(f));
    }
  } catch {  }

  return out;
}

function liveWorktrees() {
  const git = BIN('git');
  if (!git) return null;
  let dirs = [];
  try {
    const repo = sessionProject() || projectPaths()?.repo || '';
    if (!repo) return null;
    dirs = repoRoots(repo).slice(1);
    if (!dirs.length) return null;
  } catch { return null; }
  const out = {};
  const now = Date.now();
  for (const wt of dirs) {
    let branch = '';
    try {
      branch = execFileSync(git, ['-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD'],
        { encoding: 'utf8', timeout: 4000 }).trim();
    } catch { continue; }
    if (!branch || branch === 'HEAD') continue;

    const found = freshestWorkFile(wt, now - WT_FRESH_MS);
    const ageMs = found ? now - found.mtimeMs : Infinity;
    const why = found ? found.rel : '';


    const prev = out[branch];
    if (!prev || ageMs < prev.ageMs) out[branch] = { ageMs, why, wt: path.basename(wt) };
  }
  return out;
}

function liveCardsFromWorktrees(boardText) {
  const wts = liveWorktrees();
  if (process.env.PILOT_DEBUG_WT) process.stderr.write('[wt] liveWorktrees -> ' + JSON.stringify(wts) + '\n');
  if (!wts) return null;
  const out = {};
  for (const [branch, info] of Object.entries(wts)) {
    if (!info) continue;
    const blk = cardBlockForBranch(boardText, branch);
    if (!blk) continue;
    const header = String(blk).split('\n')[0];
    const m = header.match(/^\s*\[[A-Z-]+\]\s*(\S+)/);
    if (!m) continue;
    out[m[1]] = { ...info, branch };
  }

  try {
    const owed = flagDeliveredButNotHandedOff(surveyWorktrees(), boardText, Date.now(), undefined, { members: liveAgentMembers() });
    for (const o of owed) {
      const blk = cardBlockForBranch(boardText, o.branch);
      if (!blk) continue;
      const m2 = String(blk).split('\n')[0].match(/^\s*\[[A-Z-]+\]\s*(\S+)/);
      if (!m2) continue;
      out[m2[1]] = {
        ...(out[m2[1]] || { ageMs: Infinity, why: '', wt: o.name }),
        branch: o.branch,
        delivered: true,
        unpushed: o.unpushed,
        tip: o.tip,
        deliveredAgoMin: Math.round((Date.now() - o.lastCommitMs) / 60000),
      };
    }
  } catch {  }
  return out;
}

function planVerdicts(claudeDir) {
  const out = {};
  let txt = '';
  try { txt = readFileSync(path.join(claudeDir, 'reviews', 'index.jsonl'), 'utf8'); } catch { return out; }
  for (const line of txt.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.mode !== 'A') continue;
    const slug = String(r.card || '').trim();
    if (!slug || !r.verdict) continue;
    const prev = out[slug];
    if (!prev || String(r.ts || '') >= String(prev.ts || '')) {
      out[slug] = { verdict: String(r.verdict), ts: String(r.ts || ''), round: r.round ?? null };
    }
  }
  return out;
}

const i = process.argv.indexOf('--board');
if (i >= 0) {
  const board = process.argv[i + 1];
  if (!board) { console.error('usage: node backlog-pilot.mjs --board <BACKLOG.md> [--json]'); process.exit(2); }
  let txt;
  try { txt = readFileSync(board, 'utf8'); } catch (e) { console.error(`cannot read ${board}: ${e.message}`); process.exit(2); }
  const cdir = path.dirname(path.resolve(board));
  const repo = path.dirname(cdir);
  const arch = readArchive(cdir);
  const j = process.argv.indexOf('--no-merge-scan');
  const allMergesCli = j >= 0 ? null : mergedPRsOnMain(repo);
  const v = pilotVerdict(txt, Date.now(), {
    mergedPRs: j >= 0 ? null : orphanMerges(allMergesCli, prBranches(repo, STATE), txt + '\n' + arch),
    allMerges: allMergesCli,
    archiveText: arch,
    openPRs: openPRs(repo, STATE),
    approvedAtHead: approvedAtHeadMap(repo, openPRs(repo, STATE)),
    planVerdicts: planVerdicts(cdir),
    allVerdicts: allVerdicts(cdir),
    rosterMembers: liveAgentMembers(),
    liveCards: liveCardsFromWorktrees(txt),
    reviewAges: reviewArtifactAges(cdir),
  });
  console.log(process.argv.includes('--json') ? JSON.stringify(v, null, 2) : renderVerdict(v));
  process.exit(0);
}

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }
const LEAD_REPO = sessionProject(stdin);
if (!LEAD_REPO) { process.stdout.write('{}'); process.exit(0); }

function dueReminders(claudeDir, todayIso, boardText = '') {
  const f = path.join(claudeDir, '.aal-state', 'due-reminders.jsonl');
  let rows = [];
  try {
    rows = readFileSync(f, 'utf8').split(/\r?\n/).filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { rows = []; }
  const seen = new Set(rows.map((r) => String(r.card || '')));
  for (const line of String(boardText).split(/\r?\n/)) {
    if (!/^### \[/.test(line)) continue;
    const m = line.match(OBSERVE_UNTIL_RE);
    if (!m) continue;
    const card = (line.match(/R-[a-z0-9-]+/i) || ['(card)'])[0];
    if (seen.has(card)) continue;
    seen.add(card);
    rows.push({ due: m[1], card, what: 'an observe-until on a card header — on the day it expires, finish that card\u2019s DoD and archive it (the test is written on the card)', src: 'header' });
  }
  if (!rows.length) return { due: [], pending: [], file: f };
  const due = rows.filter((r) => String(r.due || '') && String(r.due) <= todayIso);
  const pending = rows.filter((r) => String(r.due || '') > todayIso).sort((a, b) => String(a.due).localeCompare(String(b.due)));
  return { due, pending, file: f };
}

const BOARD = process.env.AAL_BACKLOG || `${LEAD_REPO}/.claude/BACKLOG.md`;
let board = '';
try { board = readFileSync(BOARD, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }

const cutIdx = board.search(/## AUDIT-R1|ALREADY DONE BELOW/);
const active = cutIdx > 0 ? board.slice(0, cutIdx) : board;

const CLAUDE_DIR = path.dirname(path.resolve(BOARD));
try {
  const repo = path.dirname(CLAUDE_DIR);
  const arch = readArchive(CLAUDE_DIR);
  const merged = mergedPRsOnMain(repo);
  const branches = prBranches(repo, STATE);
  const v = pilotVerdict(active, Date.now(), {
    mergedPRs: orphanMerges(merged, branches, board + '\n' + arch),
    allMerges: merged,
    archiveText: arch,
    mergeUnavailableReason: mergedPRsOnMain.reason || prBranches.reason || '',
    openPRs: openPRs(repo, STATE),
    approvedAtHead: approvedAtHeadMap(repo, openPRs(repo, STATE)),
    planVerdicts: planVerdicts(CLAUDE_DIR),
    allVerdicts: allVerdicts(CLAUDE_DIR),
    rosterMembers: liveAgentMembers(),
    liveCards: liveCardsFromWorktrees(active),
    reviewAges: reviewArtifactAges(CLAUDE_DIR),
  });
  let text = renderVerdict(v);

  const today = new Date().toISOString().slice(0, 10);
  const rem = dueReminders(CLAUDE_DIR, today, active);
  if (rem.due.length) {
    text += `\n\n**${rem.due.length} reminder(s) DUE (as of ${today} they have expired and must be handled; they cannot be pushed again)**:`;
    for (const r of rem.due) text += `\n   • ${r.due} · ${r.card || '(no card name)'} — ${r.what || '(nothing written about what to do)'}`;
    text += `\n   When it is handled, delete that row from ${rem.file}. To wait longer, write a NEW \`due\` and say why — an unrecorded extension is indistinguishable from forgetting.`;
  }

  if (process.argv.includes('--on=prompt')) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: text },
    }));
    process.exit(0);
  }

  const failedOwed = v.owed.filter((o) => /DoD-FAILED/.test(o.kind));
  const dodBlocked = failedOwed.length > 0;
  const hasActionableTrack = (o) => (o.idleTracks || []).length || (o.stuckTracks || []).length
    || (o.reviewTracks || []).length || (o.nextRoleTracks || []).length;
  const canActOnDod = dodBlocked
    ? failedOwed.some((o) => (!o.isRemedy || hasActionableTrack(o))
        && (!(o.tracks || []).length || hasActionableTrack(o)))
    : v.owed.length > 0;
  const ghostsBlocking = actionableGhosts(v)
    .filter((g) => !(g.gated && /^merge-order:/.test(String(g.blocker || ''))));
  const canOpenWave = v.owed.length === 0 && v.candidates.length > 0
    && !wtAtCapFor({ openable: v.candidates.length, inFlightSameTier: v.inFlight.length });
  const actionable = canActOnDod || canOpenWave || v.mergeSource === 'UNAVAILABLE' || rem.due.length > 0 || ghostsBlocking.length > 0;


  let looseText = '';
  try {
    const { shutdownMissing, collectShutdownNames, denialText } =
      await import('./lib/delivery-loose-ends-predicates.mjs');
    const tpath = String(stdin.transcript_path || '');
    if (tpath) {
      const { readTranscriptText } = await import('./lib/transcript-last-assistant.mjs');
      const seen = [...collectShutdownNames(readTranscriptText(tpath).text)];
      const rosterNow = liveAgentMembers();
      const nowMs2 = Date.now();
      const hits = [];
      let ledger = '';
      try { ledger = readFileSync(path.join(LEAD_REPO, '.claude', 'reviews', 'index.jsonl'), 'utf8'); } catch { ledger = ''; }
      for (const line of ledger.split(/\r?\n/)) {
        if (!line.trim()) continue;
        let r; try { r = JSON.parse(line); } catch { continue; }
        const hit = shutdownMissing(r, seen, nowMs2, rosterNow);
        if (hit) hits.push(hit);
      }
      if (hits.length) looseText = '\n\n' + denialText(hits, []);
    }
  } catch {  }
  const text2 = text + looseText;
  const actionable2 = actionable || !!looseText;

  process.stdout.write(JSON.stringify(actionable2
    ? { decision: 'block', reason: text2 }
    : {}));
} catch (e) {
  process.stdout.write(JSON.stringify({ decision: 'block', reason: `PILOT FAILED to compute this round: ${String(e && e.message).slice(0, 300)} — treat the ladder as UNKNOWN, do not read this as "all clear".` }));
}
process.exit(0);
