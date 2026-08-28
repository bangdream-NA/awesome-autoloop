
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const iso = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');


function bin(name) {
  try {
    execFileSync(process.platform === 'win32' ? 'where' : 'which', [name], { stdio: 'ignore' });
    return name;
  } catch {
    return null;
  }
}

export function readMerges(repoDir, sources) {
  const git = bin('git');
  if (!git) {
    sources.push({ id: 'merges', ok: false, via: 'git log origin/main', reason: 'git unresolvable', at: iso() });
    return [];
  }
  try {
    const out = execFileSync(git, ['-C', repoDir, 'log', 'origin/main', '--pretty=%H\t%cI\t%s'], {
      encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 30000,
    });
    const rows = [];
    for (const line of out.split(/\r?\n/)) {
      if (!line) continue;
      const [sha, at, ...rest] = line.split('\t');
      const subject = rest.join('\t');
      const m = subject.match(/\(#(\d+)\)\s*$/);
      if (m) rows.push({ n: Number(m[1]), sha, at, subject });
    }
    sources.push({ id: 'merges', ok: true, via: 'git log origin/main', at: iso() });
    return rows;
  } catch (err) {
    sources.push({ id: 'merges', ok: false, via: 'git log origin/main', reason: String(err.message).slice(0, 120), at: iso() });
    return [];
  }
}

export function readBranches(repoDir, sources) {
  const gh = bin('gh');
  if (!gh) {
    sources.push({ id: 'branches', ok: false, via: 'gh pr list --limit 200', reason: 'gh unresolvable', at: iso() });
    return {};
  }
  try {
    const out = execFileSync(gh, ['pr', 'list', '--state', 'merged', '--limit', '200', '--json', 'number,headRefName,title'], {
      encoding: 'utf8', timeout: 20000, cwd: repoDir, stdio: ['ignore', 'pipe', 'ignore'],
    });
    const map = {};
    for (const p of JSON.parse(out)) map[p.number] = { branch: p.headRefName, title: p.title };
    sources.push({ id: 'branches', ok: true, via: 'gh pr list --limit 200', at: iso() });
    return map;
  } catch (err) {
    sources.push({ id: 'branches', ok: false, via: 'gh pr list --limit 200', reason: String(err.message).slice(0, 120), at: iso() });
    return {};
  }
}


export function readBranchCommits(repoDir, sources) {
  const git = bin('git');
  if (!git) {
    sources.push({ id: 'branchCommits', ok: false, via: 'git for-each-ref', reason: 'git unresolvable', at: iso() });
    return {};
  }
  try {
    const out = execFileSync(git, ['-C', repoDir, 'for-each-ref', '--format=%(refname:short)\t%(committerdate:iso-strict)', 'refs/heads'], {
      encoding: 'utf8', timeout: 15000,
    });
    const map = {};
    for (const line of out.split(/\r?\n/)) {
      if (!line) continue;
      const [ref, at] = line.split('\t');
      if (ref) map[ref] = { at };
    }
    sources.push({ id: 'branchCommits', ok: true, via: 'git for-each-ref refs/heads', at: iso() });
    return map;
  } catch (err) {
    sources.push({ id: 'branchCommits', ok: false, via: 'git for-each-ref', reason: String(err.message).slice(0, 120), at: iso() });
    return {};
  }
}

export function readReviews(path, sources) {
  if (!existsSync(path)) {
    sources.push({ id: 'reviews', ok: false, via: path, reason: 'not found', at: iso() });
    return { reviews: [], parsed: 0, unparseable: 0 };
  }
  const latest = new Map();
  let parsed = 0;
  let unparseable = 0;
  const text = readFileSync(path, 'utf8');
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      unparseable += 1;
      continue;
    }
    parsed += 1;
    const pr = Number(row.pr);
    if (!pr) continue;
    const prev = latest.get(pr);
    if (!prev || String(row.ts || '') > String(prev.ts || '')) {
      latest.set(pr, { pr, verdict: row.verdict, ts: row.ts });
    }
  }
  sources.push({ id: 'reviews', ok: unparseable === 0, via: path, at: iso(), ...(unparseable ? { reason: `${unparseable} unparseable lines` } : {}) });
  return { reviews: [...latest.values()], parsed, unparseable };
}


export function readOpenPRs(repoDir, sources) {
  const gh = bin('gh');
  if (!gh) {
    sources.push({ id: 'openPRs', ok: false, via: 'gh pr list --state open', reason: 'gh unresolvable', at: iso() });
    return [];
  }
  try {
    const out = execFileSync(gh, ['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,headRefName,createdAt,title'], {
      encoding: 'utf8', timeout: 20000, cwd: repoDir, stdio: ['ignore', 'pipe', 'ignore'],
    });
    sources.push({ id: 'openPRs', ok: true, via: 'gh pr list --state open', at: iso() });
    return JSON.parse(out);
  } catch (err) {
    sources.push({ id: 'openPRs', ok: false, via: 'gh pr list --state open', reason: String(err.message).slice(0, 120), at: iso() });
    return [];
  }
}


export function readArchive(dir, sources) {
  if (!existsSync(dir)) {
    sources.push({ id: 'archive', ok: false, via: dir, reason: 'not found', at: iso() });
    return '';
  }
  let out = '';
  let failed = 0;
  const names = readdirSync(dir).filter((f) => /^BACKLOG-archive.*\.md$/.test(f));
  for (const f of names) {
    try {
      out += `\n${readFileSync(join(dir, f), 'utf8')}`;
    } catch {
      failed += 1;
    }
  }
  sources.push({ id: 'archive', ok: failed === 0, via: `${dir} (${names.length} files)`, at: iso(), ...(failed ? { reason: `${failed} unreadable` } : {}) });
  return out;
}

export function gatherFacts({ boardPath, archiveDir, reviewsPath, repoDir, agents = [], ttlHours }) {
  const sources = [];
  const sha = (s) => createHash('sha256').update(s).digest('hex');

  const before = readFileSync(boardPath, 'utf8');
  const archiveText = readArchive(archiveDir, sources);
  const merges = readMerges(repoDir, sources);
  const branches = readBranches(repoDir, sources);
  const branchCommits = readBranchCommits(repoDir, sources);
  const openPRs = readOpenPRs(repoDir, sources);
  const { reviews, parsed, unparseable } = readReviews(reviewsPath, sources);
  const after = readFileSync(boardPath, 'utf8');

  sources.push({
    id: 'board', ok: sha(before) === sha(after), via: boardPath, at: iso(),
    ...(sha(before) === sha(after) ? {} : { reason: 'board changed mid-scan' }),
  });

  return {
    now: iso(),
    boardText: before,
    archiveText,
    merges,
    branches,
    openPRs,
    reviews,
    branchCommits,
    agents,
    sources,
    ttlHours: ttlHours || { 0: 4, 1: 24, 2: 72, 3: 168 },
    meta: { reviewsParsed: parsed, reviewsUnparseable: unparseable },
  };
}

export function gatherFactsFromCorpus(corpusDir, { now, agents = [], ttlHours } = {}) {
  const sources = [];
  const board = join(corpusDir, 'board');
  const derived = join(corpusDir, 'derived');
  const read = (p, id, fallback) => {
    try {
      const v = readFileSync(p, 'utf8');
      sources.push({ id, ok: true, via: p, at: now || iso() });
      return v;
    } catch (err) {
      sources.push({ id, ok: false, via: p, reason: String(err.message).slice(0, 80), at: now || iso() });
      return fallback;
    }
  };

  const boardText = read(join(board, 'BACKLOG.md'), 'board', '');
  let archiveText = '';
  let archiveFailed = 0;
  const archiveFiles = readdirSync(board).filter((f) => /^BACKLOG-archive.*\.md$/.test(f));
  for (const f of archiveFiles) {
    try { archiveText += `\n${readFileSync(join(board, f), 'utf8')}`; } catch { archiveFailed += 1; }
  }
  sources.push({ id: 'archive', ok: archiveFailed === 0, via: `${board} (${archiveFiles.length} files)`, at: now || iso() });

  const merges = [];
  const tsv = read(join(derived, 'merges-14d.tsv'), 'merges', '');
  for (const line of tsv.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const [sha, at, subject] = line.split('\t');
    const m = String(subject || '').match(/\(#(\d+)\)\s*$/);
    if (m) merges.push({ n: Number(m[1]), sha, at, subject });
  }

  const branches = {};
  try {
    for (const r of JSON.parse(read(join(derived, 'merged-prs.json'), 'branches', '[]'))) {
      branches[r.number] = { branch: r.headRefName, mergedAt: r.mergedAt };
    }
  } catch {  }

  let openPRs = [];
  try { openPRs = JSON.parse(read(join(derived, 'open-prs.json'), 'openPRs', '[]')); } catch { openPRs = []; }

  const branchCommits = {};
  const bt = read(join(derived, 'branches.tsv'), 'branchCommits', '');
  for (const line of bt.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const [ref, at] = line.split('\t');
    if (ref) branchCommits[ref] = { at };
  }

  const { reviews, parsed, unparseable } = readReviews(join(board, 'index.jsonl'), sources);

  return {
    now: now || read(join(derived, 'capture-utc.txt'), 'capture', iso()).trim(),
    boardText, archiveText, merges, branches, openPRs, reviews, branchCommits, agents, sources,
    ttlHours: ttlHours || { 0: 4, 1: 24, 2: 72, 3: 168 },
    meta: { reviewsParsed: parsed, reviewsUnparseable: unparseable },
  };
}


export function predicateHash(paths) {
  const h = createHash('sha256');
  for (const p of paths) h.update(readFileSync(p));
  return h.digest('hex');
}

export { statSync };
