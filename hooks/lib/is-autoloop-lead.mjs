import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';


export const LEAD_TTL_MS = 24 * 3600 * 1000;

export function defaultRepo() {
  const env = process.env.AAL_DEFAULT_REPO || process.env.AAL_LEAD_REPO;
  if (env) return env.replace(/\\/g, '/');
  let newest = null;
  for (const r of readLeadMarker()) {
    if (r.ts === Number.POSITIVE_INFINITY) continue;
    if (!newest || r.ts > newest.ts) newest = r;
  }
  return newest ? newest.repo : null;
}

export function homeDir() {
  const env = (process.env.USERPROFILE || process.env.HOME || '').replace(/\\/g, '/');
  if (env) return env;
  const self = new URL('.', import.meta.url).pathname.replace(/^\//, '').replace(/\\/g, '/');
  return path.dirname(path.dirname(path.dirname(self))).replace(/\\/g, '/');
}


export function hooksDir() {
  return (process.env.BG_HOOKS_DIR || `${homeDir()}/.claude/hooks`).replace(/\\/g, '/');
}

export function normalizeRepo(repo) {
  const clean = String(repo || '').replace(/\\/g, '/').trim().replace(/\/+$/, '');
  // Absolute on EITHER platform. Anchored to a drive letter alone, this returns null for every
  // path on Linux and macOS — and null here makes every gate that asks "which project is this?"
  // no-op in silence, which reads exactly like a gate that decided not to fire.
  if (!/^(?:[A-Za-z]:\/|\/)[^\s"'`()[\]{}]+$/.test(clean)) return null;
  if (!existsSync(clean)) return null;
  return clean;
}

function stateDir() {
  return `${homeDir()}/.claude/.aal-state`;
}

function markerPath() {
  if (process.env.AAL_LEAD_MARKER_FILE) return process.env.AAL_LEAD_MARKER_FILE;
  return `${stateDir()}/bf-autoloop-lead-session`;
}

function registryPath() {
  if (process.env.AAL_PROJECT_REGISTRY) return process.env.AAL_PROJECT_REGISTRY;
  const m = markerPath();
  return `${path.dirname(m)}/${path.basename(m)}.known-projects`;
}

export function knownProjects() {
  const seen = new Set();
  const out = [];
  const add = (r) => {
    const p = String(r || '').replace(/\\/g, '/').replace(/\/+$/, '');
    if (!p || seen.has(p)) return;
    seen.add(p);
    if (existsSync(p)) out.push(p);
  };
  try {
    for (const l of readFileSync(registryPath(), 'utf8').split(/\r?\n/)) add(l.trim());
  } catch {  }
  for (const r of readLeadMarker()) add(r.repo);
  add(process.env.CLAUDE_PROJECT_DIR);
  return out;
}

function registerProject(repo) {
  try {
    const clean = normalizeRepo(repo);
    if (!clean) return;
    const p = registryPath();
    let cur = [];
    try { cur = readFileSync(p, 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean); } catch {  }
    cur = cur.filter((l) => /^(?:[A-Za-z]:\/|\/)[^\s"'`()[\]{}]+$/.test(l));
    if (cur.includes(clean)) return;
    cur.push(clean);
    try { mkdirSync(path.dirname(p), { recursive: true }); } catch {  }
    writeFileSync(p, cur.join('\n') + '\n');
  } catch {  }
}

export function repoOfBoardPath(boardPath) {
  const p = String(boardPath || '').replace(/\\/g, '/');
  const m = p.match(/^(.*?)\/\.claude\/BACKLOG[^/]*\.md$/i);
  return m && m[1] ? m[1] : null;
}

export function readLeadMarker() {
  let txt = '';
  try { txt = readFileSync(markerPath(), 'utf8'); } catch { return []; }
  const lines = txt.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  if (!lines.length) return [];
  if (lines.length === 1 && !/\s/.test(lines[0])) {
    const envRepo = (process.env.AAL_DEFAULT_REPO || process.env.AAL_LEAD_REPO || '').replace(/\\/g, '/');
    return envRepo ? [{ sid: lines[0], repo: envRepo, ts: Number.POSITIVE_INFINITY }] : [];
  }
  const out = [];
  for (const l of lines) {
    const parts = l.split(/\s+/);
    if (parts.length < 2) continue;
    const [sid, repo, ts] = parts;
    if (!/^[0-9a-f-]{36}$/i.test(sid)) continue;
    const clean = normalizeRepo(repo);
    if (!clean) continue;
    out.push({ sid, repo: clean, ts: Date.parse(ts || '') || 0 });
  }
  return out;
}

export function armLead(sid, repoRaw, nowMs = Date.now()) {
  try {
    const repo = normalizeRepo(repoRaw);
    if (!sid || !repo) return;
    registerProject(repo);
    const rows = readLeadMarker().filter((r) => r.repo !== repo
      && (r.ts === Number.POSITIVE_INFINITY || nowMs - r.ts < LEAD_TTL_MS));
    rows.push({ sid, repo, ts: nowMs });
    const body = rows
      .map((r) => `${r.sid} ${r.repo} ${new Date(r.ts === Number.POSITIVE_INFINITY ? nowMs : r.ts).toISOString()}`)
      .join('\n');
    const p = markerPath();
    try { mkdirSync(path.dirname(p), { recursive: true }); } catch {  }
    writeFileSync(p, body + '\n');
  } catch {  }
}


export function sidOf(stdin) {
  const tp = String((stdin && stdin.transcript_path) || '').replace(/\\/g, '/');
  return String((stdin && stdin.session_id) || '')
    || (tp.match(/\/([0-9a-f-]{36})\.jsonl$/i) || [])[1]
    || String(process.env.CLAUDE_CODE_SESSION_ID || '');
}

export function sessionProject(stdin, nowMs = Date.now()) {
  if (process.env.AAL_AUTOLOOP_LEAD === '1') return process.env.AAL_LEAD_REPO || defaultRepo();
  const sid = sidOf(stdin);
  if (!sid) return null;
  for (const r of readLeadMarker()) {
    if (r.sid !== sid) continue;
    if (r.ts !== Number.POSITIVE_INFINITY && nowMs - r.ts >= LEAD_TTL_MS) continue;
    return r.repo;
  }
  return null;
}

export function isAutoloopLead(stdin) {
  return sessionProject(stdin) !== null;
}

// The ESM counterpart of `aal_is_autoloop_project` in lib/activation.sh — same four probes, same
// order. Seven hooks used to open with a scope guard matching one author's transcript directory;
// that literal was never the judgment, only the question "does this session belong to a project
// that runs the autoloop convention", which is what this answers for every user.
export function isAutoloopProjectDir(dir) {
  const d = String(dir || '').replace(/\\/g, '/').replace(/\/+$/, '');
  if (!d) return false;
  if (existsSync(`${d}/.claude/.autoloop`)) return true;
  if (existsSync(`${d}/.claude/BACKLOG.md`)) return true;
  if (existsSync(`${d}/.claude/code-reviews.md`)) return true;
  try {
    if (readFileSync(`${d}/.claude/CLAUDE.md`, 'utf8').includes('BEGIN awesome-autoloop')) return true;
  } catch {  }
  return false;
}

export function isAutoloopSession(stdin, hintPath) {
  const repo = resolveRepo(stdin, hintPath);
  return !!repo && isAutoloopProjectDir(repo);
}


const gitOut = (cwd, args) => {
  try {
    return execFileSync('git', args, {
      cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 15000,
    });
  } catch { return null; }
};

export function repoOfAnyPath(anyPath) {
  const p = String(anyPath || '').replace(/\\/g, '/');
  if (!p) return null;
  let dir = p;
  if (!existsSync(dir)) dir = path.dirname(p);
  else { try { if (!statSync(dir).isDirectory()) dir = path.dirname(p); } catch { dir = path.dirname(p); } }
  if (!existsSync(dir)) return null;
  const common = gitOut(dir, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (common) return path.dirname(common.trim()).replace(/\\/g, '/');
  const top = gitOut(dir, ['rev-parse', '--show-toplevel']);
  return top ? top.trim().replace(/\\/g, '/') : null;
}

export function resolveRepo(stdin, hintPath) {
  return repoOfBoardPath(hintPath)
    || sessionProject(stdin)
    || repoOfAnyPath(hintPath)
    || repoOfAnyPath((stdin && stdin.cwd) || '')
    || repoOfAnyPath(process.env.CLAUDE_PROJECT_DIR || '')
    || null;
}

export function worktreeParent(repo) {
  const roots = repoRoots(repo);
  const main = String(repo || '').replace(/\\/g, '/');
  const other = roots.find((r) => r !== main);
  if (other) return path.dirname(other).replace(/\\/g, '/');
  if (!main) return '';
  return `${path.dirname(main)}/${path.basename(main)}-wt`.replace(/\\/g, '/');
}

export function projectPaths(stdin, hintPath) {
  const repo = resolveRepo(stdin, hintPath);
  if (!repo) return null;
  return {
    repo,
    claude: `${repo}/.claude`,
    board: `${repo}/.claude/BACKLOG.md`,
    archive: `${repo}/.claude/BACKLOG-archive.md`,
    specs: `${repo}/docs/product-specs`,
    runbooks: `${repo}/docs/runbooks`,
    reviews: `${repo}/.claude/reviews`,
    walks: `${repo}/.claude/walks`,
    roots: () => repoRoots(repo),
  };
}

export function repoRoots(repo) {
  if (!repo) return [];
  const out = gitOut(repo, ['worktree', 'list', '--porcelain']);
  if (out == null) return [];
  const roots = [];
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^worktree\s+(.+)$/);
    if (m) roots.push(m[1].trim().replace(/\\/g, '/'));
  }
  const main = String(repo).replace(/\\/g, '/');
  return [main, ...roots.filter((r) => r !== main)];
}

const CLI = {
  '--session-project': 1, '--resolve-repo': 1, '--repo-roots': 1,
  '--default-repo': 1, '--worktree-parent': 1, '--known-projects': 1,
};
if (process.argv[2] && CLI[process.argv[2]]
  && /is-autoloop-lead\.mjs$/i.test(String(process.argv[1] || '').replace(/\\/g, '/'))) {
  const cmd = process.argv[2];
  const hint = process.argv[3] || '';
  const NO_STDIN = { '--default-repo': 1, '--worktree-parent': 1, '--known-projects': 1 };
  let stdin = {};
  if (!NO_STDIN[cmd]) {
    let raw = '';
    try { raw = readFileSync(0, 'utf8'); } catch {  }
    try { stdin = JSON.parse(raw || '{}'); } catch { stdin = {}; }
  }
  let out = '';
  if (cmd === '--session-project') out = sessionProject(stdin) || '';
  else if (cmd === '--resolve-repo') out = resolveRepo(stdin, hint) || '';
  else if (cmd === '--repo-roots') out = repoRoots(resolveRepo(stdin, hint)).join('\n');
  else if (cmd === '--default-repo') out = defaultRepo() || '';
  else if (cmd === '--worktree-parent') out = worktreeParent(repoOfAnyPath(hint) || hint) || '';
  else if (cmd === '--known-projects') out = knownProjects().join('\n');
  process.stdout.write(out);
  process.exit(0);
}
