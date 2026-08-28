#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync, statSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { loadWriteToolLines, authoredHere as _authoredHere, cardAuthoredHere as _cardAuthoredHere } from './lib/authored-here.mjs';
import { atCapFor } from './lib/worktree-cap.mjs';
import { isGatedOrObserving } from './lib/backlog-grammar.mjs';
import { sessionProject } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
import { isGated, priorityOf, statusOf, OPEN_STATUSES, ttlHoursFor, isDodFailed , GATE_TOKEN_HELP } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
import { resolveGh, ghArgv } from './lib/gh-path.mjs';
autoLogOnDeny('stop-node-dispatcher');

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }
const LEAD_REPO = sessionProject(stdin);
if (!LEAD_REPO) { process.stdout.write('{}'); process.exit(0); }

const BOARD_PATH = `${LEAD_REPO}/.claude/BACKLOG.md`;
const NOW = Date.parse((stdin.timestamp || new Date().toISOString()));

const boardCache = new Map();
const getBoardAt = (path) => {
  if (boardCache.has(path)) return boardCache.get(path);
  let b = '';
  try { b = readFileSync(path, 'utf8'); } catch { b = ''; }
  boardCache.set(path, b);
  return b;
};
const getActiveAt = (path) => {
  const b = getBoardAt(path);
  if (!b) return '';
  const cutIdx = b.search(/## AUDIT-R1|ALREADY DONE BELOW/);
  return cutIdx > 0 ? b.slice(0, cutIdx) : b;
};
const getCardsAt = (path) => getActiveAt(path).split(/\n(?=### \[)/).filter((c) => /^### \[/.test(c));

const deny = (reason) => {
  process.stdout.write(JSON.stringify({ decision: 'block', reason }));
  process.exit(0);
};

const writeToolLines = loadWriteToolLines(tp);
const authoredHere = (text) => _authoredHere(writeToolLines, text);
const cardAuthoredHere = (cardText) => _cardAuthoredHere(writeToolLines, cardText);

const engagedBoards = () => {
  if (!writeToolLines) return [BOARD_PATH];
  const recent = writeToolLines.length > 600_000 ? writeToolLines.slice(-600_000) : writeToolLines;
  const norm = (raw) => {
    const m = raw.replace(/\\\\/g, '/').replace(/\\/g, '/')
      .match(/^(?:([A-Za-z]):|\/([a-z]))\/(.*)\/\.claude\/BACKLOG\.md$/);
    return m ? `${(m[1] || m[2]).toUpperCase()}:/${m[3]}/.claude/BACKLOG.md` : null;
  };
  const anchorsIn = (stream) => {
    const hits = [];
    for (const m of stream.matchAll(/"file_path"\s*:\s*"((?:[^"\\]|\\.)*?[\/\\]{1,2}\.claude[\/\\]{1,2}BACKLOG\.md)"/g)) {
      const p = norm(m[1].replace(/\\\\/g, '/'));
      if (p) hits.push(p);
    }
    for (const line of stream.split('\n')) {
      if (!/BACKLOG\.md/.test(line)) continue;
      const m = line.match(/cd\s+((?:[A-Za-z]:|\/[a-z])[^\s"'&|;]*?)[\/\\]\.claude\b/);
      if (m) {
        const p = norm(m[1].replace(/\\\\/g, '/').replace(/\\/g, '/') + '/.claude/BACKLOG.md');
        if (p) hits.push(p);
      }
    }
    return hits;
  };
  const found = new Set(anchorsIn(recent));
  const fullCounts = new Map();
  for (const p of anchorsIn(writeToolLines)) fullCounts.set(p, (fullCounts.get(p) || 0) + 1);
  for (const [p, n] of fullCounts) if (n >= 10) found.add(p);
  return [...found];
};
const BOARDS = engagedBoards();


{
  const LOG_DATE_RE = /^-\s*log:\s*(\d{4})-(\d{2})-(\d{2})(?:[\sT·]*(\d{1,2})[:.]?\dxZ?|[\sT·]*(\d{1,2}):(\d{2}))?/gm;
  const newestLogTs = (cardText) => {
    let latest = 0;
    for (const m of cardText.matchAll(LOG_DATE_RE)) {
      const [, y, mo, d, hx, hf] = m;
      const hour = hx != null ? +hx : hf != null ? +hf : 12;
      const ts = Date.UTC(+y, +mo - 1, +d, Math.min(23, hour), hx != null || hf != null ? 30 : 0, 0);
      if (ts > latest) latest = ts;
    }
    return latest || null;
  };
  const hasArch = (c) =>
    /ARCH_APPROVED|ARCH DELIVERED|architecture spec @[0-9a-f]{7,}|arch @[0-9a-f]{7,}|arch spec delivered @[0-9a-f]{7,}/i.test(c);
  const hasDevProgress = (c) =>
    /DEV DELIVERED|DEV DISPATCHED|dev @[0-9a-f]{7,}|Iteration Contract/i.test(c) ||
    /PR #\d+\s*(?:MERGED|opened|OPEN|APPROVED|open)/i.test(c) ||
    /\bMERGED @[0-9a-f]{7,}/i.test(c) ||
    /\b(?:dispatch(?:ed|ing)?)\s*[`'"*(\[\s]*dev\b|dev-[a-z0-9-]+[`'"*)\]\s]*\s*(?:was\s+)?(?:dispatched|dispatching)|stage\s*=\s*dev/i.test(c);
  const FOUR_HOURS = 4 * 60 * 60 * 1000;
  const flagged = [];
  let dodLocked = false;
  for (const bp of BOARDS) {
    for (const c of getCardsAt(bp)) {
      const header = c.split('\n')[0];
      if (isDodFailed(c)) dodLocked = true;
      if (!/^### \[[^\]]*IN-DEV/.test(header)) continue;
      if (!hasArch(c)) continue;
      if (hasDevProgress(c)) continue;
      if (!cardAuthoredHere(c)) continue;
      const latest = newestLogTs(c);
      if (!latest) continue;
      if (NOW - latest < FOUR_HOURS) continue;
      const slug = (header.match(/R-[a-z0-9-]+/) || ['(card)'])[0];
      flagged.push(`${slug}(~${Math.round((NOW - latest) / 3600000)}h since last log)`);
    }
  }
  if (dodLocked) flagged.length = 0;
  if (flagged.length) {
    deny(`[IN-DEV] cards where dev was never dispatched after ARCH_APPROVED: the newest log on these cards is ARCH_APPROVED / ARCH DELIVERED, and for over 4h there has been no DEV DELIVERED, no PR and no Iteration Contract.
FIX, one of three: (1) dispatch the developer now (the architecture spec already carries the §A locks, the F-gate cheatsheet and the §B blockers, so dev can run straight away); (2) it really is gated and cannot be dispatched ⇒ change the status to [BLOCKED] and write the gate reason; (3) something is wrong with the architecture ⇒ retract to [REVIEW] or re-dispatch the architect.
cards: ${flagged.join(', ')}`);
  }
}

{
  const RECONCILE = `${homeDir()}/.claude/hooks/backlog-reconcile.mjs`;
  const mergedDirs = new Set();
  for (const line of writeToolLines.split('\n')) {
    if (!/gh pr merge/.test(line)) continue;
    if (!/"name"\s*:\s*"Bash"/.test(line)) continue;
    const cm = line.match(/"command"\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (!cm) continue;
    const cmdVal = cm[1].replace(/\\"/g, '"').replace(/\\\\/g, '\\').replace(/\\n/g, '\n');
    const stripped = cmdVal.replace(/'[^']*'/g, '').replace(/"[^"]*"/g, '');
    if (!/\bgh pr merge\b/.test(stripped)) continue;
    // The POSIX branch was `/x/…` — Git Bash's spelling of a drive, not a root — so `/srv/repo`
    // matched nothing and the merge was never associated with a repository.
    const m = cmdVal.match(/cd\s+([A-Za-z]:\/[^\s"&|;]+|\/[^\s"&|;]+)[^\n]*?gh pr merge/);
    if (!m) continue;
    let d = m[1];
    const dm = d.match(/^\/([a-z])\/(.*)$/);
    if (dm) d = dm[1].toUpperCase() + ':/' + dm[2];
    mergedDirs.add(d.replace(/\/+$/, ''));
  }
  for (const dir of mergedDirs) {
    const boardPath = dir + '/.claude/BACKLOG.md';
    if (!existsSync(boardPath) || !existsSync(RECONCILE)) continue;
    let repo = '';
    try {
      const url = spawnSync('git', ['-C', dir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', timeout: 5000 }).stdout.trim();
      const rm = url.match(/github\.com[:/]([^/\s]+\/[^\s/]+?)(?:\.git)?\s*$/);
      if (rm) repo = rm[1];
    } catch {  }
    if (!repo) continue;
    const CACHE = `${homeDir()}/.claude/hooks/.state/backlog-reconcile-clean-` + repo.replace(/[^A-Za-z0-9]/g, '_') + '.json';
    let cacheKey = '';
    try {
      const mtime = statSync(boardPath).mtimeMs;
      const head = spawnSync('git', ['-C', dir, 'rev-parse', 'HEAD'], { encoding: 'utf8', timeout: 5000 }).stdout.trim();
      let prKey = 'na';
      // One owner for "where is gh and how is it invoked" — this used to be a second copy of that
      // list, and the two had already drifted in how they probed it.
      const GH = resolveGh();
      if (GH) {
        try {
          const g = spawnSync(GH.bin, ghArgv(GH, ['pr', 'list', '--repo', repo, '--state', 'open', '--limit', '100', '--json', 'number']),
            { encoding: 'utf8', timeout: 10000 });
          if (g.status === 0 && g.stdout) {
            prKey = JSON.parse(g.stdout).map((p) => p.number).sort((a, b) => a - b).join(',') || 'none';
          }
        } catch {  }
      }
      let ledgerKey = 'nl';
      try { ledgerKey = String(statSync(`${dir}/.claude/reviews/index.jsonl`).mtimeMs); } catch {  }
      cacheKey = `${mtime}|${head}|${prKey}|${ledgerKey}`;
    } catch { cacheKey = ''; }
    let cachedClean = false;
    if (cacheKey) {
      try {
        const c = JSON.parse(readFileSync(CACHE, 'utf8'));
        cachedClean = c.key === cacheKey && Date.now() - c.ts < 30 * 60 * 1000;
      } catch {  }
    }
    if (cachedClean) continue;
    const r = spawnSync('node', [RECONCILE], {
      env: { ...process.env, CLAUDE_HOOK: '1', AAL_BACKLOG: boardPath, AAL_REPO: repo },
      encoding: 'utf8',
      timeout: 15000,
    });
    if (r.status === 0 && r.stdout && r.stdout.trim()) {
      try {
        const j = JSON.parse(r.stdout.trim());
        const report = String(j.systemMessage || '');
        if (report && (/\b\d+\s*DRIFT/.test(report) || /\b\d+\s*to verify/.test(report))) {
          deny(`BACKLOG drift vs merged PRs — project ${dir}: this session merged a PR in ${repo}, and that project's board still carries active cards for merged waves (or claims the wrong PR number).
FIX: fix them one by one on ${boardPath} (archive + a MERGED #<N> ack + the DoD note), then run \`AAL_BACKLOG=${boardPath} AAL_REPO=${repo} node <hooks>/backlog-reconcile.mjs\` to confirm it is clean, and then stop.\n\n${report}`);
        }
      } catch {  }
    }
    if (cacheKey && r.status === 0 && !/gh UNAVAILABLE/.test(r.stdout || '')) {
      try {
        mkdirSync(`${homeDir()}/.claude/hooks/.state`, { recursive: true });
        writeFileSync(CACHE, JSON.stringify({ key: cacheKey, ts: Date.now() }));
      } catch {  }
    }
  }
}


const DELEGATES = [
  'require-dod-followthrough',
  'require-visual-read-for-render-dod',
  'require-archive-gated-done-card',
  'require-askuser-when-usergated',
  'require-verdict-driven-forward',
  'backlog-dialect-drift',
  'require-runbook-update-after-state-change',
];
for (const name of DELEGATES) {
  const p = `${homeDir()}/.claude/hooks/${name}.mjs`;
  if (!existsSync(p)) continue;
  const r = spawnSync('node', [p], {
    input: JSON.stringify(stdin),
    encoding: 'utf8',
    timeout: 15000,
  });
  if (r.status === 0 && r.stdout && r.stdout.trim() && r.stdout.trim() !== '{}') {
    process.stdout.write(r.stdout);
    process.exit(0);
  }
}

process.stdout.write('{}');
process.exit(0);
